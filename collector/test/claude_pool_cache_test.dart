@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_claude_pool_');
  });
  tearDown(() async {
    for (var attempt = 0;; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (!Platform.isWindows ||
            error.osError?.errorCode != 32 ||
            attempt >= 5) {
          rethrow;
        }
        // A terminated fixture's native helper may still be releasing its cwd.
        await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    }
  });

  Future<Map<String, dynamic>> scenario(String name) async {
    final profile = Directory('${temp.path}/profile')..createSync();
    final scratch = Directory('${temp.path}/temp')..createSync();
    final environment = <String, String>{
      'HOME': profile.path,
      'USERPROFILE': profile.path,
      'APPDATA': '${temp.path}/appdata',
      'LOCALAPPDATA': '${temp.path}/local',
      'XDG_CONFIG_HOME': '${temp.path}/config',
      'XDG_DATA_HOME': '${temp.path}/data',
      'XDG_CACHE_HOME': '${temp.path}/cache',
      'TEMP': scratch.path,
      'TMP': scratch.path,
      for (final key in ['SystemRoot', 'WINDIR', 'COMSPEC'])
        if (Platform.environment[key] case final value?) key: value,
      'PATH': Platform.isWindows
          ? '${Platform.environment['SystemRoot']}/System32;'
              '${Platform.environment['SystemRoot']}/System32/WindowsPowerShell/v1.0'
          : '/usr/bin:/bin',
    };
    final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--enable-asserts',
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File('test/fixtures/claude_pool_isolate_scenario.dart').absolute.path,
          temp.path,
          name,
        ],
        environment: environment,
        includeParentEnvironment: false,
        workingDirectory: temp.path);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    try {
      // This budget includes native ACL operations across several fresh
      // isolates, rather than measuring one adapter's publication deadline.
      final code = await process.exitCode.timeout(
          Duration(seconds: Platform.isWindows ? 90 : 30), onTimeout: () {
        timedOut = true;
        process.kill();
        return process.exitCode;
      });
      final stderr = await errors;
      expect(timedOut, isFalse,
          reason: 'synthetic collector exceeded its deadline');
      expect(code, 0, reason: stderr);
      expect(stderr, isEmpty);
      return jsonDecode(await output) as Map<String, dynamic>;
    } finally {
      process.kill();
      await process.exitCode;
      await Future.wait([output, errors]);
    }
  }

  test(
      'a new isolate recovers the original stale capture without new analytics',
      () async {
    final result = await scenario('recover');
    expect(result, {
      'first_trusted': true,
      'association_saved': true,
      'same_account': true,
      'stale': true,
      'available': false,
      'original_capture': true,
      'windows_preserved': true,
      'analytics_unchanged': true,
      'http_status': 429,
    });
  });

  test('credential replacement and sign-out cannot revive the former pool',
      () async {
    final result = await scenario('replacement');
    expect(result, {
      'replacement_has_old_pool': false,
      'replacement_stale': false,
      'replacement_has_windows': false,
      'signed_out_has_old_pool': false,
      'signed_out_current_accounts': 0,
    });
  });

  test(
      'same-token current profile account changes replace the stale lookup target',
      () async {
    final result = await scenario('account-change');
    expect(result, {
      'account_changed': true,
      'new_account_trusted': true,
      'failed_lookup_uses_new_account': true,
      'old_account_returned': false,
      'failed_lookup_stale': true,
    });
  });

  test(
      'fresh profile-absent usage gets no duplicate stale alias or live pool proof',
      () async {
    final result = await scenario('alias');
    expect(result, {
      'rows': 1,
      'fresh': true,
      'credential_account': true,
      'borrowed_old_pool': false,
    });
  });

  test(
      'stored associations cannot prove two live pools or erase another stale account',
      () async {
    final result = await scenario('unproved-pools');
    expect(result, {
      'initial_proven_pools': 2,
      'fresh_rows': 1,
      'fresh_uses_credential': true,
      'duplicate_host_alias': false,
      'other_stale_alias_retained': true,
    });
  });
}
