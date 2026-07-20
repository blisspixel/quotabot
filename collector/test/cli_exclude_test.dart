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
    final receipt = json['receipt'] as Map;
    expect(receipt['schema'], 'quotabot.receipt.v1');
    expect(receipt['decision_id'], startsWith('qb-'));
  });

  test('suggest local-first prefers a local runtime in demo mode', () async {
    final result = await runCli(['suggest', '--json', '--local-first']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['routing_policy'], 'local_first');
    expect(json['recommended']['local'], isTrue);
    expect(json['using_local_fallback'], isTrue);
  });

  test('suggest exposes explicit provider cost policy', () async {
    final result = await runCli([
      'suggest',
      '--json',
      '--cost-penalty=codex:2',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest.v1');
    expect(json['cost_weight'], 1.0);
    final codex = (json['ranked'] as List<Object?>)
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (entry) => entry['provider'] == 'codex',
        );
    expect(codex['cost_penalty'], 2.0);
    expect(codex['cost_discount'], closeTo(1 / 3, 0.0001));
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
    final providers = (json['providers'] as List<Object?>)
        .map((entry) => (entry as Map<String, dynamic>)['provider'] as String)
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
    final providers = (json['providers'] as List<Object?>)
        .map((entry) => (entry as Map<String, dynamic>)['provider'] as String)
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

  test('check names a filtered provider as hidden, not unknown', () async {
    final result = await runCli(['check', 'codex', '--exclude=codex']);

    expectExitCode(result, 64);
    final err = result.stderr as String;
    expect(err, contains('hidden by the current'));
    expect(err, isNot(contains('no provider named')));
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
    final models = json['models'] as List<Object?>;
    expect(models, isNotEmpty);
    expect(
      models.every((entry) => (entry as Map<String, dynamic>)['local'] == true),
      isTrue,
    );
  });

  test('suggest budget local recommends a concrete local model', () async {
    final result = await runCli(['suggest', '--json', '--budget=local']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest_model.v1');
    expect(json['budget_policy'], 'local');
    expect((json['recommended'] as Map<String, dynamic>)['local'], isTrue);
  });

  test('model listing is unrestricted but model suggestion defaults quota',
      () async {
    final models = await runCli(['models', '--json']);
    final safeSuggestion = await runCli(['suggest', '--json', '--task=hard']);
    final unrestricted = await runCli([
      'suggest',
      '--json',
      '--task=hard',
      '--budget=any',
    ]);

    expectExitCode(models, 0);
    expectExitCode(safeSuggestion, 0);
    expectExitCode(unrestricted, 0);
    expect(
      (jsonDecode(models.stdout as String)
          as Map<String, dynamic>)['budget_policy'],
      'any',
    );
    expect(
      (jsonDecode(safeSuggestion.stdout as String)
          as Map<String, dynamic>)['budget_policy'],
      'quota',
    );
    expect(
      (jsonDecode(unrestricted.stdout as String)
          as Map<String, dynamic>)['budget_policy'],
      'any',
    );
  });

  test('suggest can opt into expiring-quota model routing', () async {
    final result = await runCli(['suggest', '--json', '--use-expiring-quota']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest_model.v1');
    expect(json['use_expiring_quota'], isTrue);
    expect(json['expiring_quota_threshold_percent'], 35.0);
    expect(json['recommended'], isA<Map<String, dynamic>>());
  });

  test('suggest rejects malformed exclude providers', () async {
    final result = await runCli(['suggest', '--json', '--exclude=../bad']);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('invalid --exclude provider'));
  });

  test('suggest rejects malformed cost policy', () async {
    final result = await runCli([
      'suggest',
      '--json',
      '--cost-penalty=../bad:1',
    ]);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('invalid cost-penalty provider'));
  });

  test('suggest cost policy is not silently ignored for model routing',
      () async {
    final result = await runCli([
      'suggest',
      '--json',
      '--task=hard',
      '--cost-penalty=codex:1',
    ]);

    expectExitCode(result, 64);
    expect(
      result.stderr as String,
      contains('apply to provider suggestions only'),
    );
  });

  test('models rejects unknown budget policies', () async {
    final result = await runCli(['models', '--json', '--budget=overage']);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unknown --budget value'));
  });

  test('models rejects an explicitly empty budget policy', () async {
    final result = await runCli(['models', '--json', '--budget=']);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unknown --budget value'));
    expect(result.stdout as String, isEmpty);
  });
}
