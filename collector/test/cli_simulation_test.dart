import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_simulation_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    final env = Map<String, String>.from(Platform.environment)
      ..['LOCALAPPDATA'] = temp.path
      ..['NO_COLOR'] = '1';
    return Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/collect.dart', ...args],
      workingDirectory: Directory.current.path,
      environment: env,
    );
  }

  test('json snapshot accepts separated simulation flag values', () async {
    final result = await runCli([
      '--json',
      '--mock-provider',
      'claude',
      '--state',
      'exhausted',
    ]);

    expect(result.exitCode, 0);
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

    expect(result.exitCode, 69);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
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

    expect(result.exitCode, 0);
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

    expect(result.exitCode, 64);
    expect(result.stderr as String, contains('unknown --state "missing"'));
  });
}
