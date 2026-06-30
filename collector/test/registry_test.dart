import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _cloud(
  String id,
  double usedPercent, {
  bool stale = false,
  String? source,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      stale: stale,
      source: source,
      windows: [QuotaWindow(label: 'weekly', usedPercent: usedPercent)],
    );

ProviderQuota _local(String id, List<ModelInfo> models) => ProviderQuota(
      provider: id,
      displayName: id,
      account: 'local',
      asOf: _now,
      kind: 'local',
      models: models,
    );

void main() {
  test('cloud models come from the catalog and inherit provider budget', () {
    final reg = buildModelRegistry(
      [_cloud('claude', 20)],
      _now,
      catalog: {
        'claude': [
          const ModelInfo(id: 'claude-opus', contextTokens: 200000),
        ],
      },
    );
    expect(reg, hasLength(1));
    final e = reg.first;
    expect(e.provider, 'claude');
    expect(e.local, isFalse);
    expect(e.headroomPercent, 80);
    expect(e.gatingWindow, 'weekly');
    expect(e.available, isTrue);
    expect(e.model.contextTokens, 200000);
  });

  test('local models come from the snapshot, no catalog needed', () {
    final reg = buildModelRegistry(
      [
        _local('ollama', const [
          ModelInfo(id: 'llama3:8b', local: true, loaded: true),
        ]),
      ],
      _now,
    );
    expect(reg, hasLength(1));
    expect(reg.first.local, isTrue);
    expect(reg.first.headroomPercent, isNull);
    expect(reg.first.available, isTrue);
  });

  test('available cloud leads, local is the tail fallback', () {
    final reg = buildModelRegistry(
      [
        _cloud('codex', 10), // 90% free
        _cloud('claude', 95), // 5% free, still available
        _local('ollama', const [ModelInfo(id: 'm', local: true)]),
      ],
      _now,
      catalog: {
        'codex': [const ModelInfo(id: 'codex-x')],
        'claude': [const ModelInfo(id: 'claude-x')],
      },
    );
    expect(reg.map((e) => e.model.id).toList(), ['codex-x', 'claude-x', 'm']);
  });

  test('a spent cloud model sorts below an available local fallback', () {
    final reg = buildModelRegistry(
      [
        _cloud('claude', 100), // spent
        _local('ollama', const [ModelInfo(id: 'local-m', local: true)]),
      ],
      _now,
      catalog: {
        'claude': [const ModelInfo(id: 'claude-x')],
      },
    );
    expect(reg.first.model.id, 'local-m'); // available beats spent
    expect(reg.last.available, isFalse);
  });

  test('loaded local models sort ahead of cold local models', () {
    final reg = buildModelRegistry(
      [
        _local('ollama', const [
          ModelInfo(id: 'z-cold', local: true),
          ModelInfo(id: 'a-loaded', local: true, loaded: true),
        ]),
      ],
      _now,
    );
    expect(reg.map((e) => e.model.id).toList(), ['a-loaded', 'z-cold']);
    expect(reg.first.toJson()['local_readiness'], 'loaded');
    expect(reg.last.toJson()['local_readiness'], 'cold');
  });

  test('a cloud provider absent from the catalog contributes no models', () {
    final reg = buildModelRegistry([_cloud('grok', 30)], _now);
    expect(reg, isEmpty);
  });

  group('requirement filtering', () {
    final providers = [_cloud('claude', 20)];
    const catalog = {
      'claude': [
        ModelInfo(
          id: 'opus',
          contextTokens: 200000,
          tools: true,
          vision: true,
          reasoning: 'reasoning',
          tier: 'flagship',
        ),
        ModelInfo(
            id: 'haiku', contextTokens: 200000, tools: true, tier: 'light'),
      ],
    };

    List<String> ids(ModelRequirements r) => buildModelRegistry(
          providers,
          _now,
          catalog: catalog,
          requirements: r,
        ).map((e) => e.model.id).toList();

    test('no requirements returns everything', () {
      expect(ids(const ModelRequirements()).toSet(), {'opus', 'haiku'});
    });

    test('require-reasoning keeps only the reasoning model', () {
      expect(ids(const ModelRequirements(requireReasoning: true)), ['opus']);
    });

    test('require-vision filters by declared capability', () {
      expect(ids(const ModelRequirements(requireVision: true)), ['opus']);
    });

    test('a tier floor excludes lighter tiers', () {
      expect(ids(const ModelRequirements(tierFloor: 'flagship')), ['opus']);
    });

    test('a tier ceiling excludes heavier tiers', () {
      expect(ids(const ModelRequirements(tierCeiling: 'light')), ['haiku']);
    });

    test('min-context excludes models below the requirement', () {
      expect(ids(const ModelRequirements(minContextTokens: 500000)), isEmpty);
      expect(ids(const ModelRequirements(minContextTokens: 100000)).toSet(),
          {'opus', 'haiku'});
    });

    test('a local budget keeps only local-runtime models', () {
      final reg = buildModelRegistry(
        [
          _cloud('claude', 20),
          _local('ollama', const [ModelInfo(id: 'local-m', local: true)]),
        ],
        _now,
        catalog: catalog,
        requirements: const ModelRequirements(
          budgetPolicy: ModelBudgetPolicy.local,
        ),
      );
      expect(reg.map((e) => e.model.id).toList(), ['local-m']);
    });

    test('a quota budget rejects self-reported manual cloud quotas', () {
      final reg = buildModelRegistry(
        [
          _cloud('claude', 20, source: 'manual'),
          _cloud('grok', 0),
          _cloud('codex', 30),
          _local('ollama', const [ModelInfo(id: 'local-m', local: true)]),
        ],
        _now,
        catalog: {
          ...catalog,
          'codex': [const ModelInfo(id: 'codex-x')],
          'grok': [const ModelInfo(id: 'grok-x')],
        },
        requirements: const ModelRequirements(
          budgetPolicy: ModelBudgetPolicy.quota,
        ),
      );
      expect(
        reg.map((e) => e.model.id).toList(),
        ['grok-x', 'codex-x', 'local-m'],
      );
    });

    test('the hard task profile requires reasoning', () {
      expect(ids(taskProfile('hard')), ['opus']);
    });

    test('the simple task profile caps the tier', () {
      expect(ids(taskProfile('simple')), ['haiku']);
    });

    test('merge overlays explicit flags on a task profile', () {
      final merged = taskProfile('simple')
          .merge(const ModelRequirements(requireTools: true));
      expect(merged.tierCeiling, 'standard');
      expect(merged.requireTools, isTrue);
    });

    test('an unknown task label adds no constraints', () {
      expect(taskProfile('banana').isEmpty, isTrue);
    });
  });

  group('suggestModel', () {
    final providers = [
      _cloud('claude', 20), // 80% free, available
      _local('ollama', const [ModelInfo(id: 'qwen', local: true)]),
    ];
    const catalog = {
      'claude': [
        ModelInfo(
          id: 'opus',
          contextTokens: 200000,
          tools: true,
          reasoning: 'reasoning',
          tier: 'flagship',
        ),
        ModelInfo(
            id: 'haiku', contextTokens: 200000, tools: true, tier: 'light'),
      ],
    };
    ModelSuggestion sg(ModelRequirements r) =>
        suggestModel(providers, _now, catalog: catalog, requirements: r);

    test('a simple task prefers the free local model', () {
      final s = sg(taskProfile('simple'));
      expect(s.recommended?.local, isTrue);
      expect(s.recommended?.model.id, 'qwen');
    });

    test('a hard task escalates past local to the qualifying cloud model', () {
      final s = sg(taskProfile('hard')); // reasoning + tier >= standard
      expect(s.recommended?.local, isFalse);
      expect(s.recommended?.model.id, 'opus'); // only opus declares reasoning
    });

    test('the lightest cloud tier wins when several qualify', () {
      final s = sg(const ModelRequirements(requireTools: true));
      expect(s.recommended?.model.id, 'haiku'); // light beats flagship
    });

    test('a loaded local model beats a cold local model', () {
      final s = suggestModel(
        [
          _local('ollama', const [
            ModelInfo(id: 'z-cold', local: true),
            ModelInfo(id: 'a-loaded', local: true, loaded: true),
          ]),
        ],
        _now,
      );
      expect(s.recommended?.model.id, 'a-loaded');
      expect(s.reason, contains('loaded and ready now'));
    });

    test('no model with budget yields a null pick and a reason', () {
      final s = suggestModel(
        [_cloud('claude', 100)], // spent
        _now,
        catalog: catalog,
        requirements: const ModelRequirements(requireReasoning: true),
      );
      expect(s.recommended, isNull);
      expect(s.reason, isNotEmpty);
    });

    test('the model suggestion JSON names the active budget policy', () {
      final s = suggestModel(
        providers,
        _now,
        catalog: catalog,
        requirements: const ModelRequirements(
          budgetPolicy: ModelBudgetPolicy.local,
        ),
      );
      expect(s.toJson(_now)['budget_policy'], 'local');
    });
  });

  test('entry JSON merges the model with its budget', () {
    final json = buildModelRegistry(
      [_cloud('claude', 20)],
      _now,
      catalog: {
        'claude': [const ModelInfo(id: 'claude-opus', tools: true)],
      },
    ).first.toJson();
    expect(json['id'], 'claude-opus');
    expect(json['tools'], isTrue);
    expect(json['provider'], 'claude');
    expect(json['headroom_percent'], 80);
    expect(json['gating_window'], 'weekly');
    expect(json['quota_backed'], isTrue);
  });

  test('registry JSON names the active budget policy', () {
    final json = modelRegistryJson(
      [
        _local('ollama', const [ModelInfo(id: 'local-m', local: true)])
      ],
      _now,
      requirements: const ModelRequirements(
        budgetPolicy: ModelBudgetPolicy.local,
      ),
    );
    expect(json['budget_policy'], 'local');
  });
}
