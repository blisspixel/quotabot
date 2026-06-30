import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  Future<ProcessResult> runCli(List<String> args) {
    final env = Map<String, String>.from(Platform.environment)
      ..['QUOTABOT_DEMO'] = '1'
      ..['NO_COLOR'] = '1';
    return Process.run(
      Platform.resolvedExecutable,
      ['bin/collect.dart', ...args],
      workingDirectory: Directory.current.path,
      environment: env,
    );
  }

  test('suggest excludes named providers from ranking', () async {
    final result = await runCli(['suggest', '--json', '--exclude=codex']);

    expect(result.exitCode, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final ranked = json['ranked'] as List;
    expect(ranked.map((entry) => entry['provider']), isNot(contains('codex')));
    expect(json['recommended']['provider'], isNot('codex'));
  });

  test('models excludes named providers from the registry', () async {
    final result = await runCli([
      'models',
      '--json',
      '--exclude',
      'codex,ollama',
    ]);

    expect(result.exitCode, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final providers = (json['models'] as List)
        .map((entry) => entry['provider'] as String)
        .toSet();
    expect(providers, isNot(contains('codex')));
    expect(providers, isNot(contains('ollama')));
  });

  test('suggest rejects malformed exclude providers', () async {
    final result = await runCli(['suggest', '--json', '--exclude=../bad']);

    expect(result.exitCode, 64);
    expect(result.stderr as String, contains('invalid --exclude provider'));
  });
}
