import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  Future<ProcessResult> runCli(List<String> args) =>
      runCollectCli(args, environment: {'QUOTABOT_DEMO': '1'});

  test('suggest excludes named providers from ranking', () async {
    final result = await runCli(['suggest', '--json', '--exclude=codex']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final ranked = json['ranked'] as List;
    expect(ranked.map((entry) => entry['provider']), isNot(contains('codex')));
    expect(json['recommended']['provider'], isNot('codex'));
  });

  test('suggest local-first prefers a local runtime in demo mode', () async {
    final result = await runCli(['suggest', '--json', '--local-first']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['routing_policy'], 'local_first');
    expect(json['recommended']['local'], isTrue);
    expect(json['using_local_fallback'], isTrue);
  });

  test('models excludes named providers from the registry', () async {
    final result = await runCli([
      'models',
      '--json',
      '--exclude',
      'codex,ollama',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final providers = (json['models'] as List)
        .map((entry) => entry['provider'] as String)
        .toSet();
    expect(providers, isNot(contains('codex')));
    expect(providers, isNot(contains('ollama')));
  });

  test('status json excludes named providers from the snapshot', () async {
    final result = await runCli(['--json', '--exclude=codex,ollama']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final providers = (json['providers'] as List)
        .map((entry) => (entry as Map)['provider'] as String)
        .toSet();
    expect(providers, isNot(contains('codex')));
    expect(providers, isNot(contains('ollama')));
  });

  test('top snapshot excludes named providers', () async {
    final result = await runCli(['top', '--exclude=codex']);

    expectExitCode(result, 0);
    expect(result.stdout as String, isNot(contains('Codex')));
  });

  test('report json excludes named providers', () async {
    final result = await runCli(['report', '--json', '--exclude=codex']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final providers = (json['providers'] as List)
        .map((entry) => (entry as Map)['provider'] as String)
        .toSet();
    expect(providers, isNot(contains('codex')));
  });

  test('stats json excludes named providers', () async {
    final result = await runCli(['stats', '--json', '--exclude=codex']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json.keys, isNot(contains('codex')));
  });

  test('check treats excluded providers as out of view', () async {
    final result =
        await runCli(['check', 'codex', '--json', '--exclude=codex']);

    expectExitCode(result, 64);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['provider'], 'codex');
    expect(json['found'], isFalse);
  });

  test('watch once excludes named providers before alerting', () async {
    final result = await runCli([
      'watch',
      '--once',
      '--json',
      '--mock-provider=claude',
      '--state=exhausted',
      '--exclude=claude',
    ]);

    expectExitCode(result, 0);
    expect((result.stdout as String).trim(), isEmpty);
  });

  test('models budget local returns only local-runtime models', () async {
    final result = await runCli(['models', '--json', '--budget=local']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['budget_policy'], 'local');
    final models = json['models'] as List;
    expect(models, isNotEmpty);
    expect(models.every((entry) => (entry as Map)['local'] == true), isTrue);
  });

  test('suggest budget local recommends a concrete local model', () async {
    final result = await runCli(['suggest', '--json', '--budget=local']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest_model.v1');
    expect(json['budget_policy'], 'local');
    expect((json['recommended'] as Map)['local'], isTrue);
  });

  test('suggest can opt into expiring-quota model routing', () async {
    final result = await runCli(['suggest', '--json', '--use-expiring-quota']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest_model.v1');
    expect(json['use_expiring_quota'], isTrue);
    expect(json['expiring_quota_threshold_percent'], 35.0);
    expect(json['recommended'], isA<Map>());
  });

  test('suggest rejects malformed exclude providers', () async {
    final result = await runCli(['suggest', '--json', '--exclude=../bad']);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('invalid --exclude provider'));
  });

  test('models rejects unknown budget policies', () async {
    final result = await runCli(['models', '--json', '--budget=overage']);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unknown --budget value'));
  });
}
