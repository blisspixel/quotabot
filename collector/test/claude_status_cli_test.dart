import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;
  const transcriptCanary = 'CANARY-transcript-path-9f3a';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_claude_status_cli_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Map<String, String> env() => {
        'LOCALAPPDATA': temp.path,
        'USERPROFILE': '${temp.path}\\home',
        'HOME': '${temp.path}/home',
        'NO_COLOR': '1',
      };

  Future<ProcessResult> runStdin(List<String> args, String body) async {
    final environment = Map<String, String>.from(Platform.environment)
      ..addAll(env());
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=.dart_tool/package_config.json',
        'bin/collect.dart',
        ...args,
      ],
      workingDirectory: Directory.current.path,
      environment: environment,
    );
    final stdoutText = process.stdout.transform(utf8.decoder).join();
    final stderrText = process.stderr.transform(utf8.decoder).join();
    process.stdin.add(utf8.encode(body));
    await process.stdin.close();
    try {
      final results = await Future.wait<Object>([
        stdoutText,
        stderrText,
        process.exitCode,
      ]).timeout(const Duration(seconds: 30));
      return ProcessResult(
        process.pid,
        results[2] as int,
        results[0] as String,
        results[1] as String,
      );
    } catch (_) {
      process.kill();
      rethrow;
    }
  }

  test('help does not create a projection or read stdin', () async {
    final result = await runCollectCli([
      'claude-status',
      '--help',
    ], environment: env());
    expectExitCode(result, 0);
    expect(result.stderr, isEmpty);
    expect(result.stdout, contains('not a routing input'));
    expect(result.stdout, contains('64 KiB'));
    expect(Directory('${temp.path}/quotabot').existsSync(), isFalse);
  });

  test('stdin projection stays out of suggest and simulated doctor', () async {
    final home = Directory('${temp.path}/home/.claude')
      ..createSync(recursive: true);
    final settings = File('${home.path}/settings.json');
    settings.writeAsStringSync('{"keep":true}');
    final before = settings.readAsBytesSync();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = jsonEncode({
      'transcript_path': transcriptCanary,
      'session_id': 'CANARY-session',
      'rate_limits': {
        'five_hour': {'used_percentage': 23.5, 'resets_at': now + 3600},
        'seven_day': {'used_percentage': 41, 'resets_at': now + 3 * 86400},
        'spend_limit': {'used_percentage': 80, 'used_usd': 12},
      },
    });

    final projected = await runStdin(['claude-status'], payload);
    expectExitCode(projected, 0);
    expect(projected.stdout, '5h 23.5% used | 7d 41% used\n');
    expect(projected.stdout, isNot(contains(transcriptCanary)));
    expect(settings.readAsBytesSync(), before);

    final suggest = await runCollectCli([
      'suggest',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ], environment: env());
    expectExitCode(suggest, 0);
    expect(suggest.stdout, contains('quotabot.suggest.v1'));
    expect(suggest.stdout, isNot(contains('claude_session_projection')));
    expect(suggest.stdout, isNot(contains(transcriptCanary)));
    expect(suggest.stdout, isNot(contains('claude_status_line')));

    final doctor = await runCollectCli([
      'doctor',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ], environment: env());
    expectExitCode(doctor, 0);
    expect(doctor.stdout, isNot(contains('claude_session_projection')));
    expect(doctor.stdout, isNot(contains(transcriptCanary)));

    final shown = await runCollectCli([
      'claude-status',
      '--show',
      '--json',
    ], environment: env());
    expectExitCode(shown, 0);
    expect(shown.stdout, contains('quotabot.claude_session_projection.v1'));
    expect(shown.stdout, contains('"routing": false'));
    expect(shown.stdout, isNot(contains(transcriptCanary)));
  });

  test('a quota-read flag is rejected before projection', () async {
    final result = await runCollectCli([
      'claude-status',
      '--profile=missing',
    ], environment: env());
    expectExitCode(result, 64);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('--profile is not valid for claude-status'));
    expect(Directory('${temp.path}/quotabot').existsSync(), isFalse);
  });

  test('oversized stdin does not create a projection file', () async {
    final result = await runStdin(['claude-status'], ' ${'x' * (64 * 1024)}');
    expectExitCode(result, 1);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('stdin_too_large'));
    expect(
      File('${temp.path}/quotabot/projections/claude_status.json').existsSync(),
      isFalse,
    );
  });
}
