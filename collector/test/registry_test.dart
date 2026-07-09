import 'package:quotabot_collector/model_catalog.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _cloud(
  String id,
  double usedPercent, {
  bool stale = false,
  String? source,
  int? resetsAt,
  String account = 'a',
  bool perMachine = false,
  List<ModelQuota> modelQuotas = const [],
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: account,
      asOf: _now,
      perMachine: perMachine,
      stale: stale,
      source: source,
      modelQuotas: modelQuotas,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: usedPercent,
          resetsAt: resetsAt,
        ),
      ],
    );

ProviderQuota _local(String id, List<ModelInfo> models) => ProviderQuota(
      provider: id,
      displayName: id,
      account: 'local',
      asOf: _now,
      kind: ProviderQuotaKind.local,
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

  test('model quotas gate entries and exact matches beat family quotas', () {
    final reset = _now + 3600;
    final reg = buildModelRegistry(
      [
        _cloud(
          'antigravity',
          20,
          resetsAt: _now + 7200,
          modelQuotas: [
            ModelQuota(
              model: 'gemini',
              usedPercent: 100,
              resetsAt: _now + 7200,
            ),
            ModelQuota(
              model: 'Gemini 3.1 Pro',
              usedPercent: 10,
              resetsAt: reset,
            ),
          ],
        ),
      ],
      _now,
      catalog: const {
        'antigravity': [
          ModelInfo(
            id: 'gemini-3.1-pro',
            displayName: 'Gemini 3.1 Pro',
            reasoning: 'reasoning',
            tier: 'flagship',
          ),
          ModelInfo(
            id: 'gemini-3-flash',
            displayName: 'Gemini 3 Flash',
            tier: 'standard',
          ),
        ],
      },
    );

    final pro = reg.firstWhere((e) => e.model.id == 'gemini-3.1-pro');
    final flash = reg.firstWhere((e) => e.model.id == 'gemini-3-flash');
    expect(pro.headroomPercent, 90);
    expect(pro.resetsAt, reset);
    expect(pro.gatingWindow, '5h');
    expect(pro.available, isTrue);
    expect(flash.headroomPercent, 0);
    expect(flash.resetsAt, _now + 7200);
    expect(flash.gatingWindow, '5h');
    expect(flash.available, isFalse);
  });

  test('unmatched per-model quota does not inherit provider headroom', () {
    final reg = buildModelRegistry(
      [
        _cloud(
          'antigravity',
          20,
          modelQuotas: const [
            ModelQuota(model: 'Gemini 3 Flash', usedPercent: 0),
          ],
        ),
      ],
      _now,
      catalog: const {
        'antigravity': [
          ModelInfo(
            id: 'gemini-3.1-pro',
            displayName: 'Gemini 3.1 Pro',
            reasoning: 'reasoning',
            tier: 'flagship',
          ),
        ],
      },
    );

    expect(reg.single.headroomPercent, isNull);
    expect(reg.single.resetsAt, isNull);
    expect(reg.single.gatingWindow, isNull);
    expect(reg.single.available, isFalse);
  });

  test('model capability gates separate known capability from available budget',
      () {
    final gates = modelCapabilityGates(
      [
        _cloud(
          'antigravity',
          10,
          modelQuotas: [
            ModelQuota(
              model: 'gemini',
              usedPercent: 100,
              resetsAt: _now + 3600,
            ),
            ModelQuota(model: 'Gemini 3 Flash', usedPercent: 0),
          ],
        ),
        _cloud('claude', 40),
      ],
      _now,
      catalog: const {
        'antigravity': [
          ModelInfo(
            id: 'gemini-3.1-pro',
            displayName: 'Gemini 3.1 Pro',
            reasoning: 'reasoning',
            tier: 'flagship',
          ),
          ModelInfo(
            id: 'gemini-3-flash',
            displayName: 'Gemini 3 Flash',
            tier: 'standard',
          ),
        ],
        'claude': [
          ModelInfo(
            id: 'claude-opus',
            displayName: 'Claude Opus',
            reasoning: 'reasoning',
            tier: 'flagship',
          ),
        ],
      },
    );

    final antigravityKey = quotaIdentityKey('antigravity', 'a');
    final claudeKey = quotaIdentityKey('claude', 'a');
    expect(gates.knownQuotaKeys, containsAll([antigravityKey, claudeKey]));
    expect(gates.availableQuotaKeys, contains(claudeKey));
    expect(gates.availableQuotaKeys, isNot(contains(antigravityKey)));
    expect(gates.budgetResetByQuotaKey[antigravityKey], _now + 3600);
  });

  test('entries keep capture provenance without changing JSON shape', () {
    final reg = buildModelRegistry(
      [_cloud('claude', 20, stale: true, perMachine: true)],
      _now,
      catalog: {
        'claude': [
          const ModelInfo(id: 'claude-opus', contextTokens: 200000),
        ],
      },
    );

    final e = reg.single;
    expect(e.stale, isTrue);
    expect(e.available, isFalse);
    expect(e.headroomPercent, 80);
    expect(e.asOf, _now);
    expect(e.perMachine, isTrue);
    expect(e.toJson().containsKey('as_of'), isFalse);
    expect(e.toJson().containsKey('per_machine'), isFalse);
  });

  test('Claude catalog exposes Fable 5 with temporary quota backing', () {
    final beforeCutoff = buildModelRegistry(
      [_cloud('claude', 20)],
      1783468800,
      catalog: kModelCatalog,
    );
    final fable = beforeCutoff.singleWhere(
      (entry) => entry.model.id == 'claude-fable-5',
    );
    expect(fable.model.displayName, 'Claude Fable 5');
    expect(fable.model.contextTokens, 1000000);
    expect(fable.model.maxOutputTokens, 128000);
    expect(fable.model.toJson()['quota_included_until'], 1783494000);
    expect(fable.quotaBacked, isTrue);

    final afterCutoff = buildModelRegistry(
      [_cloud('claude', 20)],
      1783494000,
      catalog: kModelCatalog,
      requirements: const ModelRequirements(
        budgetPolicy: ModelBudgetPolicy.quota,
      ),
    );
    expect(
      afterCutoff.map((entry) => entry.model.id),
      isNot(contains('claude-fable-5')),
    );
    expect(
      afterCutoff.map((entry) => entry.model.id),
      contains('claude-sonnet-5'),
    );
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

  test('a stale cloud model sorts below an available local fallback', () {
    final reg = buildModelRegistry(
      [
        _cloud('claude', 20, stale: true),
        _local('ollama', const [ModelInfo(id: 'local-m', local: true)]),
      ],
      _now,
      catalog: {
        'claude': [const ModelInfo(id: 'claude-x')],
      },
    );
    expect(reg.first.model.id, 'local-m');
    expect(reg.last.model.id, 'claude-x');
    expect(reg.last.available, isFalse);
    expect(reg.last.headroomPercent, 80);
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

  test('a status-only cloud provider contributes no routable models', () {
    final reg = buildModelRegistry(
      [
        ProviderQuota(
          provider: 'nvidia',
          displayName: 'NVIDIA NIM',
          account: 'default',
          asOf: _now,
          status: 'free trial available; balance unknown',
          windows: const [],
        ),
      ],
      _now,
      catalog: {
        'nvidia': [const ModelInfo(id: 'nvidia-test-model')],
      },
    );
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
          _cloud('claude', 20, source: providerQuotaManualSource),
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

    test('a quota budget rejects credit-pool providers even when cataloged',
        () {
      // Cursor meters a monthly credit pool, not an included-quota plan. If a
      // future catalog update lists its models, --budget=quota must still
      // reject them; only kQuotaPlanProviders can be quota-backed.
      final reg = buildModelRegistry(
        [
          _cloud('cursor', 40),
          _cloud('codex', 30),
        ],
        _now,
        catalog: {
          ...catalog,
          'cursor': [const ModelInfo(id: 'composer-x')],
          'codex': [const ModelInfo(id: 'codex-x')],
        },
        requirements: const ModelRequirements(
          budgetPolicy: ModelBudgetPolicy.quota,
        ),
      );
      expect(reg.map((e) => e.model.id).toList(), ['codex-x']);

      // Without the budget cap the cursor model is listed, but never marked
      // quota-backed.
      final unfiltered = buildModelRegistry(
        [_cloud('cursor', 40)],
        _now,
        catalog: {
          'cursor': [const ModelInfo(id: 'composer-x')],
        },
      );
      expect(unfiltered.single.quotaBacked, isFalse);
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

    test('a hard task skips an exhausted capable per-model pool', () {
      final s = suggestModel(
        [
          _cloud(
            'antigravity',
            10,
            modelQuotas: const [
              ModelQuota(model: 'gemini', usedPercent: 100),
              ModelQuota(model: 'Gemini 3 Flash', usedPercent: 0),
            ],
          ),
          _cloud('claude', 40),
        ],
        _now,
        catalog: {
          ...catalog,
          'antigravity': const [
            ModelInfo(
              id: 'gemini-3.1-pro',
              displayName: 'Gemini 3.1 Pro',
              reasoning: 'reasoning',
              tier: 'flagship',
            ),
            ModelInfo(
              id: 'gemini-3-flash',
              displayName: 'Gemini 3 Flash',
              tier: 'standard',
            ),
          ],
        },
        requirements: taskProfile('hard'),
      );

      expect(s.recommended?.provider, 'claude');
      expect(s.recommended?.model.id, 'opus');
      final antigravity = s.ranked.firstWhere(
        (entry) => entry.provider == 'antigravity',
      );
      expect(antigravity.model.id, 'gemini-3.1-pro');
      expect(antigravity.available, isFalse);
      expect(antigravity.headroomPercent, 0);
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
            ModelInfo(
              id: 'a-loaded',
              local: true,
              loaded: true,
              contextTokens: 32768,
              vramBytes: 4 * 1024 * 1024 * 1024,
              quant: 'Q4_K_M',
            ),
          ]),
        ],
        _now,
      );
      expect(s.recommended?.model.id, 'a-loaded');
      expect(s.reason, contains('loaded and ready now'));
      expect(s.reason, contains('4.0 GB VRAM'));
      expect(s.reason, contains('32K ctx'));
      expect(s.reason, contains('Q4_K_M'));
    });

    test('a cold local model recommendation includes installed size evidence',
        () {
      final s = suggestModel(
        [
          _local('ollama', const [
            ModelInfo(
              id: 'cold-local',
              local: true,
              sizeBytes: 5 * 1024 * 1024 * 1024,
            ),
          ]),
        ],
        _now,
      );
      expect(s.recommended?.model.id, 'cold-local');
      expect(s.reason, contains('cold start may be required'));
      expect(s.reason, contains('5.0 GB on disk'));
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

    test('expiring included quota can beat local when explicitly requested',
        () {
      final reset = _now + 10 * 3600;
      final cloud = _cloud('claude', 10, resetsAt: reset);
      final local =
          _local('ollama', const [ModelInfo(id: 'qwen', local: true)]);
      final signals = expiringQuotaSignals(
        [cloud, local],
        _now,
        burnStatsByProvider: const {
          'claude': BurnStat(perHour: 2, samples: 6),
        },
      );

      final s = suggestModel(
        [cloud, local],
        _now,
        catalog: catalog,
        useExpiringQuota: true,
        expiringQuotaByProvider: signals,
      );
      final json = s.toJson(_now);

      expect(s.recommended?.provider, 'claude');
      expect(s.recommended?.local, isFalse);
      expect(s.reason, contains('expire 70% unused'));
      expect(json['use_expiring_quota'], isTrue);
      expect(json['expiring_quota']['provider'], 'claude');
      expect(json['expiring_quota']['account'], 'a');
      expect(json['expiring_quota']['projected_waste_percent'], 70.0);
    });

    test('expiring quota policy still honors a hard local budget', () {
      final reset = _now + 10 * 3600;
      final cloud = _cloud('claude', 10, resetsAt: reset);
      final local =
          _local('ollama', const [ModelInfo(id: 'qwen', local: true)]);
      final signals = expiringQuotaSignals(
        [cloud, local],
        _now,
        burnStatsByProvider: const {
          'claude': BurnStat(perHour: 2, samples: 6),
        },
      );

      final s = suggestModel(
        [cloud, local],
        _now,
        catalog: catalog,
        requirements: const ModelRequirements(
          budgetPolicy: ModelBudgetPolicy.local,
        ),
        useExpiringQuota: true,
        expiringQuotaByProvider: signals,
      );

      expect(s.recommended?.local, isTrue);
      expect(s.expiringQuotaUsed, isNull);
    });
  });

  group('expiringQuotaSignals', () {
    test('requires measured available quota near reset with projected waste',
        () {
      final reset = _now + 10 * 3600;
      final signals = expiringQuotaSignals(
        [
          _cloud('claude', 10, resetsAt: reset),
          _cloud(
            'manual',
            10,
            source: providerQuotaManualSource,
            resetsAt: reset,
          ),
          _cloud('stale', 10, stale: true, resetsAt: reset),
          _cloud('later', 10, resetsAt: _now + 48 * 3600),
          _local('ollama', const [ModelInfo(id: 'qwen', local: true)]),
        ],
        _now,
        burnStatsByProvider: const {
          'claude': BurnStat(perHour: 2, samples: 6),
          'manual': BurnStat(perHour: 2, samples: 6),
          'stale': BurnStat(perHour: 2, samples: 6),
          'later': BurnStat(perHour: 2, samples: 6),
        },
      );

      expect(signals.values.map((signal) => signal.provider).toList(), [
        'claude',
      ]);
      expect(signals.values.single.wastedAtReset, closeTo(70, 0.001));
    });

    test('skips multi-account providers while burn stats are provider-scoped',
        () {
      final reset = _now + 10 * 3600;
      final signals = expiringQuotaSignals(
        [
          _cloud('claude', 10, resetsAt: reset, account: 'a'),
          _cloud('claude', 10, resetsAt: reset, account: 'b'),
        ],
        _now,
        burnStatsByProvider: const {
          'claude': BurnStat(perHour: 2, samples: 6),
        },
      );

      expect(signals, isEmpty);
    });

    test('uses account-scoped burn for multi-account providers', () {
      final reset = _now + 10 * 3600;
      final signals = expiringQuotaSignals(
        [
          _cloud('claude', 10, resetsAt: reset, account: 'a'),
          _cloud('claude', 40, resetsAt: reset, account: 'b'),
        ],
        _now,
        burnStatsByProvider: {
          quotaIdentityKey('claude', 'a'):
              const BurnStat(perHour: 2, samples: 6),
          quotaIdentityKey('claude', 'b'):
              const BurnStat(perHour: 10, samples: 6),
        },
      );

      expect(signals.values.map((signal) => signal.account).toList(), ['a']);
      expect(signals.values.single.wastedAtReset, closeTo(70, 0.001));
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
