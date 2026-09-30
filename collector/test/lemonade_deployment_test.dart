import 'package:quotabot_collector/adapters/lemonade.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:quotabot_collector/schema_contracts.dart';
import 'package:test/test.dart';

const _now = 1790726400;

ProviderQuota _quota(List<Map<String, Object?>> rows) => localRuntimeQuota(
      id: 'lemonade',
      name: 'Lemonade',
      asOf: _now,
      installed: lemonadeModelsFromJson({'data': rows})!,
      loaded: const [],
    );

void main() {
  test('explicit non-chat deployments stay inspectable without routing', () {
    for (final mode in [
      'embedding',
      'embeddings',
      'transcription',
      'reranking',
      'image',
      'tts',
      'audio-generation',
      'classification',
      'classifier',
      '3d',
    ]) {
      final quota = _quota([
        {
          'id': mode,
          'downloaded': true,
          'labels': [mode]
        },
      ]);
      expect(quota.models.single.textGeneration, isFalse, reason: mode);
      expect(quota.models.single.embedding,
          mode == 'embedding' || mode == 'embeddings' ? isTrue : isNull,
          reason: mode);
      expect(buildModelRegistry([quota], _now), hasLength(1), reason: mode);
      expect(isLocalRuntimeAvailableAt(quota, _now), isFalse, reason: mode);
      expect(suggestRoute([quota], _now).recommended, isNull, reason: mode);
      expect(suggestRoute([quota], _now).fallback.kind,
          RouteFallbackKind.passthrough,
          reason: mode);
      for (final budget in ModelBudgetPolicy.values) {
        final suggestion = suggestModel([quota], _now,
            requirements: ModelRequirements(budgetPolicy: budget));
        expect(suggestion.recommended, isNull, reason: '$mode $budget');
      }
    }
  });

  test('a mixed inventory selects chat while preserving non-chat inspection',
      () {
    final quota = _quota([
      {
        'id': 'image-small',
        'labels': ['image']
      },
      {
        'id': 'chat-large',
        'labels': ['chat', 'tool-calling', 'vision']
      },
    ]);
    expect(quota.models, hasLength(2));
    expect(quota.models.last.textGeneration, isTrue);
    expect(isLocalRuntimeAvailableAt(quota, _now), isTrue);
    expect(suggestModel([quota], _now).recommended?.model.id, 'chat-large');
    expect(suggestModel([quota], _now).ranked, hasLength(1));
  });

  test('legacy missing or characteristic-only deployment labels remain unknown',
      () {
    for (final row in <Map<String, Object?>>[
      {'id': 'legacy'},
      {'id': 'legacy', 'labels': <String>[]},
      {
        'id': 'legacy',
        'labels': ['coding', 'tool-calling', 'reasoning']
      },
    ]) {
      final quota = _quota([row]);
      expect(quota.models.single.textGeneration, isNull);
      expect(isLocalRuntimeAvailableAt(quota, _now), isTrue);
      expect(suggestModel([quota], _now).recommended?.model.id, 'legacy');
    }
  });

  test('malformed and conflicting declarations cannot become capacity', () {
    for (final labels in <Object?>[
      null,
      'chat',
      [1],
      ['chat', null],
      ['chat', ''],
      ['chat', 'image'],
      ['embeddings', 'tts'],
    ]) {
      final quota = _quota([
        {'id': 'unsafe', 'labels': labels},
      ]);
      expect(quota.models, isEmpty, reason: '$labels');
      expect(isLocalRuntimeAvailableAt(quota, _now), isFalse);
    }
    final aliasLabels = _quota([
      {
        'id': 'embed',
        'labels': ['embedding', ' EMBEDDINGS ']
      },
    ]);
    expect(aliasLabels.models.single.embedding, isTrue);
  });

  test(
      'declared current context wins over model maximum and health overrides it',
      () {
    final rows = [
      {
        'id': 'coder',
        'context_length': 4096,
        'max_context_window': 131072,
        'labels': ['chat'],
      },
    ];
    final quota = _quota(rows);
    expect(quota.models.single.contextTokens, 4096);
    expect(
        suggestModel([quota], _now,
                requirements: const ModelRequirements(minContextTokens: 32768))
            .recommended,
        isNull);
    final loaded = lemonadeLoadedModelsFromJson({
      'all_models_loaded': [
        {
          'model_name': 'coder',
          'recipe_options': {'ctx_size': 8192}
        },
      ],
    })!;
    final running = localRuntimeQuota(
      id: 'lemonade',
      name: 'Lemonade',
      asOf: _now,
      installed: lemonadeModelsFromJson({'data': rows})!,
      loaded: loaded,
    );
    expect(running.models.single.contextTokens, 8192);
  });

  test('new generation evidence survives sanitation and cache JSON round trips',
      () {
    final original = _quota([
      {
        'id': 'audio',
        'labels': ['tts']
      },
      {
        'id': 'coder',
        'labels': ['chat']
      },
      {'id': 'unknown'},
    ]);
    final quota =
        ProviderQuota.fromJson(sanitizeProviderQuota(original).toJson());
    expect(
        quota.models.map((model) => model.textGeneration), [false, true, null]);
    expect(quota.models.first.toJson()['text_generation'], isFalse);
    expect(quota.models.last.toJson().containsKey('text_generation'), isFalse);
    expect(suggestModel([quota], _now).ranked.map((entry) => entry.model.id),
        isNot(contains('audio')));
  });

  test('health type denial survives a positive or absent inventory declaration',
      () {
    for (final mode in ['image', 'embedding', 'llm']) {
      for (final declaredChat in [true, false]) {
        final quota = localRuntimeQuota(
          id: 'lemonade',
          name: 'Lemonade',
          asOf: _now,
          installed: lemonadeModelsFromJson({
            'data': [
              {
                'id': 'model',
                if (declaredChat) 'labels': ['chat']
              },
            ],
          })!,
          loaded: lemonadeLoadedModelsFromJson({
            'all_models_loaded': [
              {'model_name': 'model', 'type': mode}
            ],
          })!,
        );
        expect(quota.models.single.loaded, isTrue);
        expect(quota.models.single.textGeneration,
            mode == 'llm' ? (declaredChat ? true : null) : false);
        expect(
            quota.models.single.embedding, mode == 'embedding' ? true : null);
        expect(isLocalRuntimeAvailableAt(quota, _now), mode == 'llm');
      }
    }
  });

  test('invalid explicit current context cannot inherit a model maximum', () {
    for (final context in <Object?>[
      null,
      0,
      -1,
      1.5,
      double.infinity,
      double.nan,
      true,
      '4096',
      <Object>[],
    ]) {
      final quota = _quota([
        {
          'id': 'coder',
          'context_length': context,
          'max_context_window': 131072
        },
      ]);
      expect(quota.models.single.contextTokens, isNull, reason: '$context');
      expect(
          suggestModel([quota], _now,
                  requirements:
                      const ModelRequirements(minContextTokens: 32768))
              .recommended,
          isNull,
          reason: '$context');
    }
    final legacy = _quota([
      {'id': 'coder', 'max_context_window': 131072},
    ]);
    expect(legacy.models.single.contextTokens, 131072);
  });

  test('unknown or malformed loaded types cannot erase a non-text denial', () {
    for (final type in <Object?>[null, 'llm', 'unknown', 7, true]) {
      final quota = localRuntimeQuota(
        id: 'lemonade',
        name: 'Lemonade',
        asOf: _now,
        installed: lemonadeModelsFromJson({
          'data': [
            {
              'id': 'model',
              'labels': ['image']
            }
          ],
        })!,
        loaded: lemonadeLoadedModelsFromJson({
          'all_models_loaded': [
            {'model_name': 'model', 'type': type}
          ],
        })!,
      );
      expect(quota.models.single.textGeneration, isFalse);
      expect(isLocalRuntimeAvailableAt(quota, _now), isFalse);
      expect(suggestModel([quota], _now).recommended, isNull);
    }
  });

  test('snapshot contract enforces optional generation evidence as boolean',
      () {
    final quota = _quota([
      {
        'id': 'audio',
        'labels': ['tts']
      },
    ]);
    final snapshot = <String, dynamic>{
      'schema': 'quotabot.v1',
      'generated_at': _now,
      'providers': [quota.toJson()],
    };
    expect(validateQuotabotV1Snapshot(snapshot), isEmpty);
    final providers = snapshot['providers'] as List<Map<String, dynamic>>;
    final models = providers.single['models'] as List<Map<String, dynamic>>;
    models.single['text_generation'] = 'no';
    expect(validateQuotabotV1Snapshot(snapshot),
        contains(contains('text_generation')));
  });
}
