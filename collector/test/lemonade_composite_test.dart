import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/lemonade.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

Map<String, Object?> _leaf(String id, {String recipe = 'llamacpp'}) => {
      'id': id,
      'recipe': recipe,
      'downloaded': true,
      'labels': ['chat'],
      'components': <String>[],
    };

Map<String, Object?> _cloud(String id) => {
      ..._leaf(id, recipe: 'cloud'),
      'cloud_provider': 'test-provider',
      'downloaded': false,
    };

Map<String, Object?> _collection(String id, List<Map<String, Object?>> children,
        {String recipe = 'collection.router'}) =>
    {
      ..._leaf(id, recipe: recipe),
      'components': [for (final child in children) child['id']],
      'models': children,
    };

ProviderQuota _quota(Map<String, Object?> model) => localRuntimeQuota(
      id: 'lemonade',
      name: 'Lemonade',
      asOf: 100,
      installed: lemonadeModelsFromJson({
        'data': [model]
      })!,
      loaded: const [],
    );

void main() {
  test('complete nested cloud components veto local and quota routing', () {
    for (final recipe in ['collection.router', 'collection.omni']) {
      final model = _collection(
          'test-composite',
          [
            _leaf('local-chat'),
            _collection('nested-router', [_cloud('cloud-chat')]),
          ],
          recipe: recipe);
      final quota = _quota(model);
      expect(quota.models, hasLength(1));
      expect(quota.models.single.cloudOffloaded, isTrue);
      expect(quota.models.single.upstreamRouting, UpstreamRouting.notReported);
      expect(isLocalRuntimeReachableAt(quota, 100), isTrue);
      expect(isLocalRuntimeAvailableAt(quota, 100), isFalse);
      for (final budget in [ModelBudgetPolicy.local, ModelBudgetPolicy.quota]) {
        expect(
            buildModelRegistry([quota], 100,
                requirements: ModelRequirements(budgetPolicy: budget)),
            isEmpty);
        expect(
            suggestModel([quota], 100,
                    requirements: ModelRequirements(budgetPolicy: budget))
                .recommended,
            isNull);
      }
      expect(buildModelRegistry([quota], 100).single.localReadiness, isNull);
      expect(buildModelRegistry([quota], 100).single.hardwareFit, isNull);
      final cached = ProviderQuota.fromJson(quota.toJson());
      expect(cached.models.single.cloudOffloaded, isTrue);
      expect(isLocalRuntimeAvailableAt(cached, 100), isFalse);
    }
  });

  test('complete supported non-cloud components retain legacy eligibility', () {
    final quota = _quota(_collection('test-composite', [
      _leaf('local-chat'),
      _collection('nested-omni', [_leaf('other-chat', recipe: 'flm')],
          recipe: 'collection.omni'),
    ]));
    expect(quota.models.single.cloudOffloaded, isFalse);
    expect(isLocalRuntimeAvailableAt(quota, 100), isTrue);
    expect(
        buildModelRegistry([quota], 100,
            requirements:
                const ModelRequirements(budgetPolicy: ModelBudgetPolicy.local)),
        hasLength(1));
    expect(quota.models.single.toJson(), isNot(contains('execution_location')));
  });

  test('collection policies are outside component metadata normalization', () {
    final model = _collection('test-composite', [_leaf('local-chat')]);
    model['routing'] = Object();
    model['system_prompt'] = Object();
    expect(_quota(model).models.single.cloudOffloaded, isFalse);
  });

  test('shared component identities require consistent scope declarations', () {
    final shared = _leaf('shared-chat');
    final consistent = _collection('test-composite', [
      _collection('first-router', [shared]),
      _collection('second-router', [shared]),
    ]);
    expect(_quota(consistent).models.single.cloudOffloaded, isFalse);
    for (final conflicting in [
      _cloud('shared-chat'),
      _leaf('shared-chat', recipe: 'flm')
    ]) {
      final inconsistent = _collection('test-composite', [
        _collection('first-router', [shared]),
        _collection('second-router', [conflicting]),
      ]);
      expect(_quota(inconsistent).models, isEmpty);
    }
  });

  final local = _leaf('local-chat');
  final unresolved = <String, Map<String, Object?>>{
    'unsupported collection':
        _collection('test-composite', [local], recipe: 'collection.future'),
    'missing embedded models': {
      ..._collection('test-composite', [local])
    }..remove('models'),
    'missing named component': {
      ..._collection('test-composite', [local]),
      'components': ['missing'],
    },
    'missing component identity list': {
      ..._collection('test-composite', [local])
    }..remove('components'),
    'duplicate component identities': {
      ..._collection('test-composite', [local, local]),
    },
    'duplicate embedded identities': {
      ..._collection('test-composite', [local, _leaf('other-chat')]),
      'models': [local, local],
    },
    'conflicting embedded identity': {
      ..._collection('test-composite', [local]),
      'models': [_cloud('other-chat')],
    },
    'unsupported leaf recipe': _collection('test-composite', [
      _leaf('unknown-chat', recipe: 'future-backend'),
    ]),
    'missing leaf recipe': _collection('test-composite', [
      {...local}..remove('recipe'),
    ]),
    'missing leaf component evidence': _collection('test-composite', [
      {...local}..remove('components'),
    ]),
    'undownloaded component': _collection('test-composite', [
      {...local, 'downloaded': false},
    ]),
    'undownloaded collection': {
      ..._collection('test-composite', [local]),
      'downloaded': false,
    },
    'malformed embedded model': {
      ..._collection('test-composite', [local]),
      'models': [7],
    },
    'malformed component identity': _collection('test-composite', [
      {...local, 'id': 'x' * 513},
    ]),
    'malformed component provider': _collection('test-composite', [
      {...local, 'cloud_provider': 7},
    ]),
    'conflicting cloud and backend declarations':
        _collection('test-composite', [
      {...local, 'cloud_provider': 'test-provider'},
    ]),
    'cloud leaf carrying composite metadata': _collection('test-composite', [
      {..._cloud('cloud-chat'), 'models': <Object?>[]},
    ]),
    'cyclic identity': _collection('test-composite', [_leaf('test-composite')]),
    'unsupported child beside known cloud': _collection('test-composite', [
      _cloud('cloud-chat'),
      _leaf('unknown-chat', recipe: 'future-backend'),
    ]),
  };
  for (final fixture in unresolved.entries) {
    test('${fixture.key} is omitted instead of inventing local or cloud scope',
        () {
      final quota = _quota(fixture.value);
      expect(quota.models, isEmpty);
      expect(isLocalRuntimeAvailableAt(quota, 100), isFalse);
      expect(suggestModel([quota], 100).recommended, isNull);
    });
  }

  test('component normalization has bounded depth and node count', () {
    var nested = _leaf('leaf');
    for (var depth = 0; depth < 4; depth++) {
      nested = _collection('nested-$depth', [nested]);
    }
    expect(_quota(nested).models, isEmpty);
    final complete = _collection('bounded-router', [
      for (var index = 0; index < 63; index++) _leaf('child-$index'),
    ]);
    expect(_quota(complete).models, hasLength(1));
    final oversized = _collection('oversized-router', [
      for (var index = 0; index < 64; index++) _leaf('child-$index'),
    ]);
    expect(_quota(oversized).models, isEmpty);
  });

  test('omitted composites stay omitted after health and explain unknown scope',
      () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      return http.Response(
          jsonEncode(request.url.path.endsWith('/models')
              ? {
                  'data': [
                    unresolved['missing embedded models'],
                    _leaf('local-chat')
                  ]
                }
              : {
                  'all_models_loaded': [
                    {
                      'model_name': 'test-composite',
                      'type': 'llm',
                      'recipe_options': {'ctx_size': 8192}
                    },
                  ]
                }),
          200);
    });
    try {
      final quota = await LemonadeAdapter(client: client, environment: const {})
          .collect();
      expect(quota.models.single.id, 'local-chat');
      expect(quota.models.single.loaded, isFalse);
      expect(quota.active, isFalse);
      expect(quota.details,
          contains('1 composite model omitted - component scope unresolved'));
      expect(paths, ['/api/v1/models', '/api/v1/health']);
    } finally {
      client.close();
    }
  });
}
