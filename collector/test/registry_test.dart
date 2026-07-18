import 'package:quotabot_collector/model_catalog.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_ids.dart';
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
  bool? perMachine,
  List<ModelQuota> modelQuotas = const [],
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: account,
      asOf: _now,
      perMachine:
          perMachine ?? const {'cursor', 'windsurf', 'kiro'}.contains(id),
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

ProviderQuota _local(
  String id,
  List<ModelInfo> models, {
  LocalHardwareInfo? hardware,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'local',
      asOf: _now,
      kind: ProviderQuotaKind.local,
      models: models,
      localHardware: hardware,
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
    expect(e.sourceClass, ProviderSourceClass.authoritativeLive);
    expect(e.toJson()['source_class'], 'authoritative_live');
    expect(e.local, isFalse);
    expect(e.headroomPercent, 80);
    expect(e.gatingWindow, 'weekly');
    expect(e.available, isTrue);
    expect(e.model.contextTokens, 200000);
  });

  test('invalid local provenance cannot make a model available', () {
    final invalid = ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: 'local',
      asOf: _now,
      kind: ProviderQuotaKind.local,
      sourceClass: ProviderSourceClass.authoritativeLive,
      models: const [ModelInfo(id: 'unsafe-local', local: true)],
    );

    final registry = buildModelRegistry([invalid], _now);
    final suggestion = suggestModel([invalid], _now);

    expect(registry, hasLength(1));
    expect(registry.single.available, isFalse);
    expect(suggestion.recommended, isNull);
    expect(suggestion.ranked.single.available, isFalse);
  });

  test('stale local runtime evidence cannot make a model available', () {
    final stale = _local(
      'ollama',
      const [ModelInfo(id: 'stale-local', local: true)],
    ).asStale('runtime not rechecked');

    final registry = buildModelRegistry([stale], _now);
    final suggestion = suggestModel([stale], _now);

    expect(registry.single.available, isFalse);
    expect(suggestion.recommended, isNull);
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

  test('per-model quota cannot bypass provider integrity rejection', () {
    final suspect = _cloud(
      'antigravity',
      20,
      modelQuotas: const [
        ModelQuota(model: 'gemini', usedPercent: 5, resetsAt: _now + 3600),
      ],
    ).withSuspect('legacy drift concern');
    final suggestion = suggestModel(
      [suspect],
      _now,
      catalog: const {
        'antigravity': [ModelInfo(id: 'gemini-3.5-pro')],
      },
    );

    expect(suggestion.recommended, isNull);
    expect(suggestion.ranked.single.available, isFalse);
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

  test('Claude Fable quota is a sparse overlay on shared provider quota', () {
    final providerReset = _now + 5 * 86400;
    final fableReset = _now + 24 * 3600;
    final claude = _cloud(
      claudeProviderId,
      20,
      resetsAt: providerReset,
      modelQuotas: [
        ModelQuota(
          model: 'Fable',
          usedPercent: 100,
          resetsAt: fableReset,
        ),
      ],
    );
    final reg = buildModelRegistry(
      [claude],
      _now,
      catalog: const {
        claudeProviderId: [
          ModelInfo(
            id: 'claude-fable-5',
            displayName: 'Claude Fable 5',
            reasoning: 'adaptive',
            tier: 'flagship',
          ),
          ModelInfo(
            id: 'claude-opus-4-8',
            displayName: 'Claude Opus 4.8',
            reasoning: 'adaptive',
            tier: 'flagship',
          ),
        ],
      },
    );

    final fable = reg.firstWhere((entry) => entry.model.id == 'claude-fable-5');
    final opus = reg.firstWhere((entry) => entry.model.id == 'claude-opus-4-8');
    expect(fable.headroomPercent, 0);
    expect(fable.resetsAt, fableReset);
    expect(fable.gatingWindow, 'daily');
    expect(fable.available, isFalse);
    expect(opus.headroomPercent, 80);
    expect(opus.resetsAt, providerReset);
    expect(opus.gatingWindow, 'weekly');
    expect(opus.available, isTrue);

    final gates = modelCapabilityGates(
      [claude],
      _now,
      catalog: const {
        claudeProviderId: [
          ModelInfo(
            id: 'claude-fable-5',
            reasoning: 'adaptive',
            tier: 'flagship',
          ),
          ModelInfo(
            id: 'claude-opus-4-8',
            reasoning: 'adaptive',
            tier: 'flagship',
          ),
        ],
      },
    );
    final key = quotaIdentityKey(claudeProviderId, 'a');
    expect(gates.knownQuotaKeys, contains(key));
    expect(gates.availableQuotaKeys, contains(key));
  });

  test('Claude Fable uses the tighter shared or scoped quota gate', () {
    const catalog = {
      claudeProviderId: [
        ModelInfo(
          id: 'claude-fable-5',
          displayName: 'Claude Fable 5',
        ),
      ],
    };
    final scopedReset = _now + 24 * 3600;
    final providerReset = _now + 5 * 86400;

    final scopedTighter = buildModelRegistry(
      [
        _cloud(
          claudeProviderId,
          20,
          resetsAt: providerReset,
          modelQuotas: [
            ModelQuota(
              model: 'Fable',
              usedPercent: 30,
              resetsAt: scopedReset,
            ),
          ],
        ),
      ],
      _now,
      catalog: catalog,
    ).single;
    expect(scopedTighter.headroomPercent, 70);
    expect(scopedTighter.resetsAt, scopedReset);
    expect(scopedTighter.gatingWindow, 'daily');

    final sharedTighter = buildModelRegistry(
      [
        _cloud(
          claudeProviderId,
          90,
          resetsAt: providerReset,
          modelQuotas: [
            ModelQuota(
              model: 'Fable',
              usedPercent: 30,
              resetsAt: scopedReset,
            ),
          ],
        ),
      ],
      _now,
      catalog: catalog,
    ).single;
    expect(sharedTighter.headroomPercent, 10);
    expect(sharedTighter.resetsAt, providerReset);
    expect(sharedTighter.gatingWindow, 'weekly');
  });

  test('Claude legacy family labels match only their scoped catalog model', () {
    final reg = buildModelRegistry(
      [
        _cloud(
          claudeProviderId,
          20,
          resetsAt: _now + 5 * 86400,
          modelQuotas: const [
            ModelQuota(model: 'Opus', usedPercent: 50),
          ],
        ),
      ],
      _now,
      catalog: const {
        claudeProviderId: [
          ModelInfo(id: 'claude-opus-4-8', displayName: 'Claude Opus 4.8'),
          ModelInfo(
            id: 'claude-sonnet-5',
            displayName: 'Claude Sonnet 5',
          ),
        ],
      },
    );

    final opus = reg.firstWhere((entry) => entry.model.id == 'claude-opus-4-8');
    final sonnet = reg.firstWhere(
      (entry) => entry.model.id == 'claude-sonnet-5',
    );
    expect(opus.headroomPercent, 50);
    expect(opus.available, isTrue);
    expect(sonnet.headroomPercent, 80);
    expect(sonnet.gatingWindow, 'weekly');
    expect(sonnet.available, isTrue);
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

  test('Claude catalog backs Fable only with live scoped quota evidence', () {
    final withScopedQuota = buildModelRegistry(
      [
        _cloud(
          claudeProviderId,
          20,
          modelQuotas: const [
            ModelQuota(model: 'Fable', usedPercent: 25),
          ],
        ),
      ],
      _now,
      catalog: kModelCatalog,
    );
    final fable = withScopedQuota.singleWhere(
      (entry) => entry.model.id == 'claude-fable-5',
    );
    expect(fable.model.displayName, 'Claude Fable 5');
    expect(fable.model.contextTokens, 1000000);
    expect(fable.model.maxOutputTokens, 128000);
    expect(fable.model.toJson().containsKey('quota_included_until'), isFalse);
    expect(fable.quotaBacked, isTrue);
    expect(fable.available, isTrue);
    expect(fable.headroomPercent, 75);

    final withoutScopedQuota = buildModelRegistry(
      [_cloud(claudeProviderId, 20)],
      _now,
      catalog: kModelCatalog,
      requirements: const ModelRequirements(
        budgetPolicy: ModelBudgetPolicy.quota,
      ),
    );
    expect(
      withoutScopedQuota.map((entry) => entry.model.id),
      isNot(contains('claude-fable-5')),
    );
    expect(
      withoutScopedQuota.map((entry) => entry.model.id),
      contains('claude-sonnet-5'),
    );

    final fableWithoutEvidence = buildModelRegistry(
      [_cloud(claudeProviderId, 20)],
      _now,
      catalog: kModelCatalog,
    ).singleWhere((entry) => entry.model.id == 'claude-fable-5');
    expect(fableWithoutEvidence.quotaBacked, isFalse);
    expect(fableWithoutEvidence.available, isFalse);
    expect(fableWithoutEvidence.headroomPercent, isNull);
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

  test('cold local models sort by passive hardware fit', () {
    const gib = 1024 * 1024 * 1024;
    final reg = buildModelRegistry(
      [
        _local(
          'ollama',
          const [
            ModelInfo(
              id: 'a-constrained',
              local: true,
              sizeBytes: 14 * gib,
            ),
            ModelInfo(id: 'm-unknown', local: true),
            ModelInfo(
              id: 'z-comfortable',
              local: true,
              sizeBytes: 4 * gib,
            ),
          ],
          hardware: const LocalHardwareInfo(
            asOf: _now,
            systemMemoryTotalBytes: 16 * gib,
            systemMemoryAvailableBytes: 12 * gib,
          ),
        ),
      ],
      _now,
    );

    expect(reg.map((e) => e.model.id), [
      'z-comfortable',
      'm-unknown',
      'a-constrained',
    ]);
    expect(reg[0].toJson()['hardware_fit'], 'comfortable');
    expect(reg[1].toJson()['hardware_fit'], 'unknown');
    expect(reg[2].toJson()['hardware_fit'], 'constrained');
  });

  test('hardware fit chooses the strongest observed memory pool', () {
    const gib = 1024 * 1024 * 1024;
    const model = ModelInfo(
      id: 'local-model',
      local: true,
      sizeBytes: 4 * gib,
    );
    const hardware = LocalHardwareInfo(
      asOf: _now,
      systemMemoryTotalBytes: 32 * gib,
      systemMemoryAvailableBytes: 4 * gib,
      gpuMemoryTotalBytes: 12 * gib,
      gpuMemoryAvailableBytes: 10 * gib,
      gpuCount: 1,
    );

    final fit = localModelHardwareFit(model, hardware);
    final json = fit.toJson();

    expect(fit.status, LocalHardwareFitStatus.comfortable);
    expect(fit.basis, 'gpu_memory');
    expect(fit.estimatedMemoryBytes, 5 * gib);
    expect(json['fit_available_bytes'], 10 * gib);
    expect(json['fit_total_bytes'], 12 * gib);
    expect(json['hardware_observed_at'], _now);
  });

  test('hardware fit distinguishes tight, constrained, unknown, and loaded',
      () {
    const gib = 1024 * 1024 * 1024;
    const hardware = LocalHardwareInfo(
      asOf: _now,
      systemMemoryTotalBytes: 16 * gib,
      systemMemoryAvailableBytes: 8 * gib,
    );

    expect(
      localModelHardwareFit(
        const ModelInfo(id: 'tight', local: true, sizeBytes: 10 * gib),
        hardware,
      ).status,
      LocalHardwareFitStatus.tight,
    );
    expect(
      localModelHardwareFit(
        const ModelInfo(id: 'large', local: true, sizeBytes: 14 * gib),
        hardware,
      ).status,
      LocalHardwareFitStatus.constrained,
    );
    expect(
      localModelHardwareFit(
        const ModelInfo(id: 'unknown', local: true),
        hardware,
      ).status,
      LocalHardwareFitStatus.unknown,
    );
    expect(
      localModelHardwareFit(
        const ModelInfo(id: 'loaded', local: true, loaded: true),
        null,
      ).status,
      LocalHardwareFitStatus.loaded,
    );
  });

  test('on-device local entries sort ahead of cloud-offloaded daemon entries',
      () {
    final reg = buildModelRegistry(
      [
        _local('ollama', const [
          ModelInfo(
            id: 'a-cloud',
            local: true,
            cloudOffloaded: true,
          ),
          ModelInfo(id: 'z-on-device', local: true),
        ]),
      ],
      _now,
    );

    expect(reg.map((e) => e.model.id), ['z-on-device', 'a-cloud']);
    expect(reg.first.hardwareFit?.status, LocalHardwareFitStatus.unknown);
    expect(reg.last.hardwareFit, isNull);
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
        ModelInfo(
          id: 'sonnet',
          contextTokens: 200000,
          tools: true,
          reasoning: 'reasoning',
          tier: 'standard',
        ),
      ],
    };

    List<String> ids(ModelRequirements r) => buildModelRegistry(
          providers,
          _now,
          catalog: catalog,
          requirements: r,
        ).map((e) => e.model.id).toList();

    test('no requirements returns everything', () {
      expect(
          ids(const ModelRequirements()).toSet(), {'opus', 'haiku', 'sonnet'});
    });

    test('require-reasoning keeps only reasoning models', () {
      expect(ids(const ModelRequirements(requireReasoning: true)),
          ['opus', 'sonnet']);
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
          {'opus', 'haiku', 'sonnet'});
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

    test('a local budget excludes a cloud-offloaded local model', () {
      // An Ollama `-cloud` model is reachable via the local daemon but runs in
      // the provider cloud, so a local-only budget must drop it while keeping
      // the on-device model.
      final reg = buildModelRegistry(
        [
          _local('ollama', const [
            ModelInfo(id: 'on-device', local: true),
            ModelInfo(id: 'qwen:480b-cloud', local: true, cloudOffloaded: true),
          ]),
        ],
        _now,
        catalog: catalog,
        requirements: const ModelRequirements(
          budgetPolicy: ModelBudgetPolicy.local,
        ),
      );
      expect(reg.map((e) => e.model.id).toList(), ['on-device']);
    });

    test('a quota budget also excludes a cloud-offloaded local model', () {
      // budget=quota admits on-device local plus measured quota plans; a
      // cloud-offloaded local model is neither, so it must not slip through.
      final reg = buildModelRegistry(
        [
          _local('ollama', const [
            ModelInfo(id: 'on-device', local: true),
            ModelInfo(id: 'qwen:480b-cloud', local: true, cloudOffloaded: true),
          ]),
        ],
        _now,
        catalog: catalog,
        requirements: const ModelRequirements(
          budgetPolicy: ModelBudgetPolicy.quota,
        ),
      );
      expect(reg.map((e) => e.model.id).toList(), ['on-device']);
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
      expect(ids(taskProfile('hard')).toSet(), {'opus', 'sonnet'});
    });

    test('the simple task profile caps the tier', () {
      expect(ids(taskProfile('simple')).toSet(), {'haiku', 'sonnet'});
    });

    test('the standard task profile keeps standard-tier models', () {
      expect(ids(taskProfile('standard')), ['sonnet']);
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

    test('a simple task prefers the local-runtime model', () {
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
      expect(s.reason, contains('hardware fit is unknown'));
    });

    test('a cold local recommendation explains its hardware-fit evidence', () {
      const gib = 1024 * 1024 * 1024;
      final s = suggestModel(
        [
          _local(
            'ollama',
            const [
              ModelInfo(
                id: 'fit-local',
                local: true,
                sizeBytes: 4 * gib,
              ),
            ],
            hardware: const LocalHardwareInfo(
              asOf: _now,
              gpuMemoryTotalBytes: 12 * gib,
              gpuMemoryAvailableBytes: 10 * gib,
              gpuCount: 1,
            ),
          ),
        ],
        _now,
      );
      final json = s.toJson(_now);

      expect(s.recommended?.model.id, 'fit-local');
      expect(s.reason, contains('comfortable metadata-only hardware fit'));
      expect(s.reason, contains('5.0 GB estimated'));
      expect(s.reason, contains('10.0 GB available of 12.0 GB GPU memory'));
      expect(json['recommended']['hardware_fit'], 'comfortable');
      expect(json['recommended']['hardware_fit_basis'], 'gpu_memory');
      expect(json['recommended']['estimated_memory_bytes'], 5 * gib);
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

    test('provider drift remains visible on unavailable model candidates', () {
      final drifted = _cloud('claude', 20).withProviderDrift(
        'weekly reset moved earlier',
        _now + 30,
      );
      final s = suggestModel(
        [drifted],
        _now + 60,
        catalog: catalog,
        requirements: const ModelRequirements(requireReasoning: true),
      );
      final candidate = s.ranked.single;
      final json = candidate.toJson();

      expect(s.recommended, isNull);
      expect(s.reason, contains('provider drift'));
      expect(s.reason, contains('quotabot verify'));
      expect(candidate.available, isFalse);
      expect(candidate.stale, isTrue);
      expect(candidate.driftReason, 'weekly reset moved earlier');
      expect(candidate.driftObservedAt, _now + 30);
      expect(json['drift_reason'], 'weekly reset moved earlier');
      expect(json['drift_observed_at'], _now + 30);
    });

    test('legacy drift quarantine explains the missing model budget', () {
      final legacy = _cloud('claude', 20)
          .withSuspect('legacy drift concern')
          .asProviderDriftQuarantine(
            'unresolved legacy provider drift: legacy drift concern',
            _now + 30,
          );
      final suggestion = suggestModel(
        [legacy],
        _now + 60,
        catalog: catalog,
        requirements: const ModelRequirements(requireReasoning: true),
      );

      expect(suggestion.recommended, isNull);
      expect(suggestion.ranked, isEmpty);
      expect(suggestion.reason, contains('Provider drift'));
      expect(suggestion.reason, contains('no trusted model-budget evidence'));
      expect(suggestion.reason, contains('quotabot verify'));
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
    expect(json['source_class'], 'authoritative_live');
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
