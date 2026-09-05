import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final transport in ['stdio', 'http', 'entrypoint']) {
    for (final protected in [false, true]) {
      test(
          '$transport ${protected ? 'covered' : 'custom'} subscription cadence follows collector capability',
          () async {
        final result =
            await _scenario('$transport-${protected ? 'covered' : 'custom'}');
        expect(result, {
          'reads_before_subscription': 0,
          'reads_after_first_poll': 1,
          'next_delay_seconds': protected ? 300 : 7200,
          'cancelled': true,
        });
      });
    }
  }

  for (final transport in ['stdio', 'http']) {
    test('$transport maximum Retry-After stays cancellable without repolling',
        () async {
      expect(await _scenario('$transport-extreme'), {
        'positive_day_chunks': true,
        'reads_after_three_chunks': 1,
        'cancelled': true,
      });
    });
  }

  test('MCP waits through full days and the remainder before the next poll',
      () async {
    expect(await _scenario('stdio-multiday'), {
      'reads_at_day_boundaries': 1,
      'remainder_seconds': 7,
      'reads_at_full_deadline': 2,
      'cancelled': true,
    });
  });
}

Future<Map<String, dynamic>> _scenario(String name) async {
  final temp = Directory.systemTemp.createTempSync('quotabot_mcp_timer_');
  Process? process;
  try {
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
      'QUOTABOT_MCP_FIXTURE_TOKEN': '0123456789abcdef0123456789abcdef',
      for (final key in ['SystemRoot', 'WINDIR', 'COMSPEC'])
        if (Platform.environment[key] case final value?) key: value,
      'PATH': Platform.isWindows
          ? '${Platform.environment['SystemRoot']}/System32;'
              '${Platform.environment['SystemRoot']}/System32/WindowsPowerShell/v1.0'
          : '/usr/bin:/bin',
    };
    process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--enable-asserts',
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('test/fixtures/mcp_subscription_scenario.dart').absolute.path,
        temp.path,
        name,
      ],
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: temp.path,
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    final running = process;
    final code = await running.exitCode.timeout(const Duration(seconds: 25),
        onTimeout: () {
      timedOut = true;
      running.kill();
      return running.exitCode;
    });
    final stderr = await errors;
    expect(timedOut, isFalse,
        reason: 'isolated subscription exceeded deadline');
    expect(code, 0, reason: stderr);
    if (name.startsWith('entrypoint-')) {
      expect(
          stderr.trim(),
          matches(RegExp(
            r'^quotabot MCP Streamable HTTP listening on http://127\.0\.0\.1:\d+/mcp\r?\n'
            r'bearer token auth: required and enabled$',
          )));
    } else {
      expect(stderr, isEmpty);
    }
    return jsonDecode(await output) as Map<String, dynamic>;
  } finally {
    process?.kill();
    await process?.exitCode;
    temp.deleteSync(recursive: true);
  }
}
