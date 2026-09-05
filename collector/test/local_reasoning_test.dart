import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

// Synthetic inventory using Ollama's declared metadata shape. No model is run.
final _fixture = jsonDecode(
  File('test/fixtures/ollama_reasoning_metadata.json').readAsStringSync(),
) as Map<String, dynamic>;

Future<ProviderQuota> _collectFixture() async {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    final body = switch (request.url.path) {
      '/api/tags' => _fixture['tags'],
      '/api/ps' => _fixture['ps'],
      '/api/show' =>
        (_fixture['show'] as Map)[(jsonDecode(request.body) as Map)['model']],
      _ => null,
    };
    return http.Response(jsonEncode(body), body == null ? 404 : 200);
  });
  final quota = await OllamaAdapter(
    client: client,
    environment: const {},
    capabilityCache: OllamaCapabilityCache(),
  ).collect();
  expect(requests, hasLength(11));
  for (final request in requests) {
    expect(request.url.host, '127.0.0.1');
    expect(request.url.port, 11434);
    if (request.url.path == '/api/show') {
      expect(request.method, 'POST');
      final body = jsonDecode(request.body) as Map;
      expect(body.keys, ['model']);
      expect((_fixture['show'] as Map).containsKey(body['model']), isTrue);
    } else {
      expect(request.method, 'GET');
      expect(request.url.path, anyOf('/api/tags', '/api/ps'));
    }
  }
  // Exercise the cache/public snapshot shape before registry filtering.
  return ProviderQuota.fromJson(
    jsonDecode(jsonEncode(quota.toJson())) as Map<String, dynamic>,
  );
}

void main() {
  test('thinking declaration distinguishes false from missing or malformed',
      () {
    final show = _fixture['show'] as Map;
    expect(ollamaShowFromJson(show['declared:7b'])!.reasoning, isTrue);
    expect(ollamaShowFromJson(show['ordinary:7b'])!.reasoning, isFalse);
    for (final name in ['deepseek-r1:7b', 'malformed:7b']) {
      expect(ollamaShowFromJson(show[name]), isNull, reason: name);
    }
    for (final name in ['mixed:7b', 'empty:7b', 'blank:7b']) {
      expect(ollamaShowFromJson(show[name])!.reasoning, isNull, reason: name);
    }
    for (final malformed in [true, false, 'thinking', 1]) {
      expect(ollamaShowFromJson({'capabilities': malformed}), isNull);
    }
  });

  test('declared reasoning survives snapshot and serialized registry filters',
      () async {
    final quota = await _collectFixture();
    final registry = jsonDecode(jsonEncode(modelRegistryJson(
      [quota],
      quota.asOf,
      requirements: const ModelRequirements(requireReasoning: true),
    ))) as Map;
    expect(registry['schema'], 'quotabot.models.v1');
    final models = registry['models'] as List;
    expect(
      models.map((model) => model['id']),
      unorderedEquals(['declared:7b', 'reasoner:cloud', 'embed:1b']),
    );
    expect(
        models.map((model) => model['reasoning']), everyElement('reasoning'));
    final declared =
        models.singleWhere((model) => model['id'] == 'declared:7b');
    expect(declared['local_readiness'], 'loaded');
    expect(declared['context_tokens'], 8192);
    expect(declared['tools'], isTrue);
    for (final model in quota.models.where((model) => ![
          'declared:7b',
          'reasoner:cloud',
          'embed:1b',
        ].contains(model.id))) {
      expect(model.toJson().containsKey('reasoning'), isFalse,
          reason: model.id);
    }
  });

  for (final budget in [ModelBudgetPolicy.local, ModelBudgetPolicy.quota]) {
    test(
        '${budget.wireName} reasoning routes preserve spend and embedding gates',
        () async {
      final quota = await _collectFixture();
      final providers = [
        quota,
        ProviderQuota(
          provider: 'claude',
          displayName: 'Manual subscription',
          account: 'manual',
          asOf: quota.asOf,
          source: providerQuotaManualSource,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 0)],
        ),
        ProviderQuota(
          provider: 'cursor',
          displayName: 'Credit pool',
          account: 'default',
          asOf: quota.asOf,
          perMachine: true,
          windows: [QuotaWindow(label: 'monthly', usedPercent: 0)],
        ),
      ];
      const catalog = {
        'claude': [ModelInfo(id: 'manual-reasoner', reasoning: 'reasoning')],
        'cursor': [ModelInfo(id: 'credit-reasoner', reasoning: 'reasoning')],
      };
      final requirements = ModelRequirements(
        requireReasoning: true,
        budgetPolicy: budget,
      );
      final json = modelRegistryJson(
        providers,
        quota.asOf,
        requirements: requirements,
        catalog: catalog,
      );
      expect(
        (json['models'] as List).map((model) => model['id']),
        unorderedEquals(['declared:7b', 'embed:1b']),
      );
      final suggestion = suggestModel(
        providers,
        quota.asOf,
        requirements: requirements,
        catalog: catalog,
      );
      expect(suggestion.recommended!.model.id, 'declared:7b');
      expect(suggestion.ranked.map((entry) => entry.model.id), ['declared:7b']);
      expect(suggestion.toJson(quota.asOf)['budget_policy'], budget.wireName);
    });
  }

  test('reasoning cannot override a configured context requirement', () async {
    final quota = await _collectFixture();
    final suggestion = suggestModel(
      [quota],
      quota.asOf,
      requirements: const ModelRequirements(
        requireReasoning: true,
        requireTools: true,
        minContextTokens: 32768,
        budgetPolicy: ModelBudgetPolicy.local,
      ),
    );
    expect(suggestion.recommended, isNull);
    expect(suggestion.ranked, isEmpty);
  });

  test('stale reasoning evidence stays inspectable but cannot win', () async {
    final quota = (await _collectFixture()).asStale('runtime unavailable');
    final suggestion = suggestModel(
      [quota],
      quota.asOf,
      requirements: const ModelRequirements(
        requireReasoning: true,
        budgetPolicy: ModelBudgetPolicy.local,
      ),
    );
    expect(suggestion.recommended, isNull);
    expect(suggestion.ranked, hasLength(1));
    expect(suggestion.ranked.single.toJson()['reasoning'], 'reasoning');
    expect(suggestion.ranked.single.toJson()['available'], isFalse);
  });

  test('LM Studio reasoning is not newly admitted without location evidence',
      () {
    final current = lmStudioV1FromJson({
      'models': [
        {
          'key': 'linked-reasoner',
          'type': 'llm',
          'loaded_instances': [
            {
              'id': 'linked-reasoner',
              'config': {'context_length': 8192},
            },
          ],
          'capabilities': {
            'trained_for_tool_use': true,
            'reasoning': {
              'allowed_options': ['off', 'on'],
              'default': 'on',
            },
          },
        },
      ],
    })!;
    final legacy = lmStudioNativeFromJson({
      'data': [
        {
          'id': 'legacy-reasoner',
          'state': 'loaded',
          'capabilities': ['tool_use', 'reasoning'],
        },
      ],
    })!;
    for (final parsed in [current, legacy]) {
      expect(parsed.installed.single.reasoning, isNull);
      final quota = localRuntimeQuota(
        id: 'lmstudio',
        name: 'LM Studio',
        asOf: 1800000000,
        installed: parsed.installed,
        loaded: parsed.loaded,
      );
      expect(quota.models.single.tools, isTrue);
      final json = modelRegistryJson(
        [quota],
        quota.asOf,
        requirements: const ModelRequirements(
          requireReasoning: true,
          budgetPolicy: ModelBudgetPolicy.local,
        ),
      );
      expect(json['models'], isEmpty);
    }
  });
}
