import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;
  final retainedRoots = <String>{};
  setUp(
      () => temp = Directory.systemTemp.createTempSync('quotabot_first_run_'));
  tearDown(() {
    if (!retainedRoots.contains(temp.path)) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> invoke(bool local, List<String> args) async {
    final root = temp;
    var abandoned = false;
    final starting = Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=.dart_tool/package_config.json',
        'test/fixtures/cli_first_run.dart',
        local ? 'local' : 'absent',
        ...args
      ],
      includeParentEnvironment: false,
      environment: {
        for (final key in [
          'SYSTEMROOT',
          'WINDIR',
          'SYSTEMDRIVE',
          'ProgramData'
        ])
          if (Platform.environment[key] case final value?) key: value,
        'PATH': '',
        'HOME': temp.path,
        'USERPROFILE': temp.path,
        'LOCALAPPDATA': '${temp.path}/local',
        'APPDATA': '${temp.path}/roaming',
        'XDG_CONFIG_HOME': '${temp.path}/config',
        'XDG_DATA_HOME': '${temp.path}/data',
        'CODEX_HOME': '${temp.path}/codex',
        'TMP': temp.path,
        'TEMP': temp.path,
        'TMPDIR': temp.path,
        'NO_COLOR': '1',
        'QUOTABOT_FIRST_RUN_FIXTURE': '1',
      },
    );
    // A timed-out launch still owns its eventual child and private HOME.
    unawaited(starting.then<void>((child) async {
      if (!abandoned) return;
      final output = child.stdout.drain<void>();
      final errors = child.stderr.drain<void>();
      final drained = Future.wait([output, errors]);
      unawaited(drained.catchError((Object error) => <void>[]));
      try {
        child.kill(ProcessSignal.sigkill);
      } on Object {
        // Reaping below still owns the child and retained directory.
      }
      try {
        await child.stdin.close().timeout(const Duration(seconds: 5));
      } on Object {
        // A killed child may have already closed its pipe.
      }
      await child.exitCode;
      await drained;
      if (root.existsSync()) root.deleteSync(recursive: true);
      retainedRoots.remove(root.path);
    }, onError: (Object error, StackTrace stack) {
      if (abandoned && root.existsSync()) root.deleteSync(recursive: true);
      retainedRoots.remove(root.path);
    }).catchError((Object error) {
      // Preserve the private directory if late cleanup cannot prove settlement.
    }));
    final child =
        await starting.timeout(const Duration(seconds: 10), onTimeout: () {
      abandoned = true;
      retainedRoots.add(root.path);
      throw TimeoutException('first-run fixture launch did not settle');
    });
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    final drained = Future.wait([output, errors]);
    unawaited(drained.catchError((Object error) => <String>[]));
    try {
      await child.stdin.close().timeout(const Duration(seconds: 5));
      final code = await child.exitCode.timeout(const Duration(seconds: 45));
      return ProcessResult(
          child.pid,
          code,
          await output.timeout(const Duration(seconds: 5)),
          await errors.timeout(const Duration(seconds: 5)));
    } finally {
      try {
        child.kill(ProcessSignal.sigkill);
      } on Object {
        // Even a failed kill must still attempt reaping and retain ownership.
      }
      try {
        await child.exitCode.timeout(const Duration(seconds: 5));
        await drained.timeout(const Duration(seconds: 5));
      } on Object {
        retainedRoots.add(root.path);
        unawaited(child.exitCode.then((_) async {
          await drained;
          if (root.existsSync()) root.deleteSync(recursive: true);
          retainedRoots.remove(root.path);
        }).catchError((Object error) {}));
        rethrow;
      }
    }
  }

  test('first-run local route explains absent subscriptions in text and JSON',
      () async {
    final text = await invoke(true, ['suggest', '--no-color']);
    expectExitCode(text, 0);
    expect(text.stdout, contains('No subscription quota is available'));
    expect(text.stdout, isNot(contains('Subscriptions are low')));
    final result = await invoke(true, ['suggest', '--json']);
    expectExitCode(result, 0);
    final body = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(body['reason'],
        'No subscription quota is available - use local ollama.');
    expect(body['decision_code'], 'local_fallback');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'first-run doctor separates sign-in readiness and does not refer to itself',
      () async {
    final text = await invoke(false, ['doctor', '--no-color']);
    expectExitCode(text, 0);
    expect(text.stdout, contains('sign-in needed'));
    expect(text.stdout, contains('no quota evidence'));
    expect(text.stdout, isNot(contains('Run quotabot doctor')));
    final result = await invoke(false, ['doctor', '--json']);
    expectExitCode(result, 0);
    final body = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final rows = (body['providers'] as List).cast<Map<String, dynamic>>();
    for (final id in ['claude', 'codex']) {
      final row = rows.singleWhere((q) => q['provider'] == id);
      expect(row['read_state'], 'sign-in needed');
      expect(row['ok'], isFalse);
      expect(row['windows'], isEmpty);
    }
    expect(rows.any((q) => q['provider'] == 'cursor'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
