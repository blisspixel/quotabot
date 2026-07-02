import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_simulation_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    return runCollectCli(args, environment: {'LOCALAPPDATA': temp.path});
  }

  test('json snapshot accepts separated simulation flag values', () async {
    final result = await runCli([
      '--json',
      '--mock-provider',
      'claude',
      '--state',
      'exhausted',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.v1');
    final providers = json['providers'] as List;
    expect(providers, hasLength(1));
    final claude = providers.single as Map<String, dynamic>;
    expect(claude['provider'], 'claude');
    expect(claude['account'], 'simulated');
    final windows = claude['windows'] as List;
    expect(
      windows.any(
        (w) =>
            (w as Map<String, dynamic>)['label'] == '5h' &&
            w['used_percent'] == 100,
      ),
      isTrue,
    );
  });

  test('check exits unavailable for an exhausted mock provider', () async {
    final result = await runCli([
      'check',
      'claude',
      '--json',
      '--mock-provider=claude',
      '--state=exhausted',
    ]);

    expectExitCode(result, 69);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.check.v1');
    expect(json['as_of'], isA<int>());
    expect(json['provider'], 'claude');
    expect(json['available'], isFalse);
    expect(json['headroom_percent'], 0);
  });

  test('suggest uses the mock snapshot without real burn history', () async {
    final result = await runCli([
      'suggest',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest.v1');
    expect((json['recommended'] as Map)['provider'], 'claude');
    expect((json['ranked'] as List), hasLength(1));
  });

  test('invalid simulation state is a usage error', () async {
    final result = await runCli([
      '--json',
      '--mock-provider=claude',
      '--state=missing',
    ]);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unknown --state "missing"'));
  });

  test('models says filters excluded everything, not "no models detected"',
      () async {
    final result = await runCollectCli(
      ['models', '--min-context=999000000'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('no models match these filters'));
    expect(out, isNot(contains('no models detected')));
  });

  test('watch --once confirms an all-clear run instead of printing nothing',
      () async {
    final result = await runCli([
      'watch',
      '--once',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    expect(result.stdout as String, contains('all clear'));
  });

  test('watch --once stays silent in JSON mode when nothing fires', () async {
    final result = await runCli([
      'watch',
      '--once',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    expect((result.stdout as String).trim(), isEmpty);
  });

  test('watch rejects invalid projected-waste thresholds', () async {
    final result = await runCli([
      'watch',
      '--once',
      '--waste-threshold=bad',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 64);
    expect(
      result.stderr as String,
      contains('--waste-threshold must be between 0 and 100'),
    );
  });
}
