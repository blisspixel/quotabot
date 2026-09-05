import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provenance.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:quotabot_collector/schema_contracts.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

const _now = 1788600000;
const _remote = {
  'remote_host': 'http://private-runtime.example:11434/private',
  'remote_model': 'private-upstream-model:7b',
};

ProviderQuota _provider(List<ModelInfo> models, {bool active = true}) =>
    ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: 'fixture',
      asOf: _now,
      kind: ProviderQuotaKind.local,
      models: models,
      active: active,
      localHardware: const LocalHardwareInfo(
        asOf: _now,
        systemMemoryTotalBytes: 32 * 1024 * 1024 * 1024,
        systemMemoryAvailableBytes: 24 * 1024 * 1024 * 1024,
      ),
    );

ProviderQuota _normalize(
  List<Map<String, Object?>> installed, [
  List<Map<String, Object?>> loaded = const [],
]) =>
    localRuntimeQuota(
      id: 'ollama',
      name: 'Ollama',
      asOf: _now,
      installed: ollamaModelsFromJson({'models': installed}),
      loaded: ollamaModelsFromJson({'models': loaded}),
    );

MockClient _runtime(
  List<Map<String, Object?>> installed, {
  List<Map<String, Object?>> loaded = const [],
  Map<String, Object?> show = const {},
  void Function()? onShow,
}) =>
    MockClient((request) async {
      expect(request.url.host, '127.0.0.1');
      expect(request.url.port, 11434);
      Object? body;
      switch (request.url.path) {
        case '/api/tags':
          expect(request.method, 'GET');
          body = {'models': installed};
        case '/api/ps':
          expect(request.method, 'GET');
          body = {'models': loaded};
        case '/api/show':
          expect(request.method, 'POST');
          final query = jsonDecode(request.body) as Map;
          expect(query.keys, ['model']);
          expect(installed.any((model) => model['name'] == query['model']),
              isTrue);
          onShow?.call();
          body = show[query['model']];
        default:
          fail('Unexpected metadata request: ${request.url.path}');
      }
      return http.Response(jsonEncode(body), body == null ? 404 : 200);
    });

void _expectNoLocalCapacity(ProviderQuota quota, int now) {
  expect(isLocalRuntimeAvailableAt(quota, now), isFalse);
  expect(quota.localGenerationReadiness, isNull);
  for (final policy in [ModelBudgetPolicy.local, ModelBudgetPolicy.quota]) {
    expect(
      buildModelRegistry([quota], now,
          requirements: ModelRequirements(budgetPolicy: policy)),
      isEmpty,
    );
    expect(
      suggestModel([quota], now,
              requirements: ModelRequirements(budgetPolicy: policy))
          .recommended,
      isNull,
    );
  }
  for (final policy in ['balanced', 'local_first', 'quota_stretch']) {
    final decision = suggestResponse(
      [quota],
      now,
      preferLocal: policy == 'local_first',
      quotaStretch: policy == 'quota_stretch',
    );
    expect(decision['recommended'], isNull, reason: policy);
    expect((decision['fallback'] as Map)['kind'], 'passthrough');
    expect(decision['ranked'], isEmpty);
    final encoded = jsonEncode(decision);
    expect(encoded, isNot(contains(_remote['remote_host']!)));
    expect(encoded, isNot(contains(_remote['remote_model']!)));
    expect(encoded, isNot(contains('"spend_class":"local"')));
  }
}

void main() {
  group('producer declarations', () {
    test('private, public and loopback targets declare upstream, not price',
        () {
      for (final host in [
        _remote['remote_host']!,
        'https://ollama.com:443',
        'http://localhost:11435/custom',
        'http://[::1]:11434',
      ]) {
        final quota = _normalize([
          {'name': 'ordinary-alias:7b', ..._remote, 'remote_host': host}
        ]);
        final model = quota.models.single;
        expect(model.upstreamRouting, UpstreamRouting.declared);
        expect(model.cloudOffloaded, isFalse);
        expect(quota.active, isFalse);
        expect(quota.status, 'reachable - upstream routing declared');
        _expectNoLocalCapacity(quota, _now);
        final entry = buildModelRegistry([quota], _now).single;
        expect(entry.available, isTrue);
        expect(entry.localReadiness, isNull);
        expect(entry.hardwareFit, isNull);
        expect(entry.headroomPercent, isNull);
        expect(entry.quotaBacked, isFalse);
        final recommendation = suggestModel([quota], _now,
            requirements: const ModelRequirements());
        expect(recommendation.recommended?.model.id, model.id);
        expect(recommendation.reason, contains('cost are unverified'));
        expect(recommendation.reason, isNot(contains('paid')));
      }
    });

    test('absent fields preserve legacy eligibility without positive proof',
        () {
      for (final metadata in [
        null,
        false,
        <Object?>[],
        <String, Object?>{},
        {'cloud': false}
      ]) {
        expect(ollamaUpstreamRoutingFromJson(metadata),
            UpstreamRouting.notReported);
      }
      final quota = _normalize([
        {'name': 'ordinary:7b', 'cloud': false}
      ]);
      expect(quota.models.single.upstreamRouting, UpstreamRouting.notReported);
      expect(quota.models.single.toJson(), isNot(contains('upstream_routing')));
      expect(isLocalRuntimeAvailableAt(quota, _now), isTrue);
    });

    final invalid = <String, Map<String, Object?>>{
      'host only': {'remote_host': _remote['remote_host']},
      'model only': {'remote_model': _remote['remote_model']},
      'empty pair': {'remote_host': '', 'remote_model': ''},
      'null host': {..._remote, 'remote_host': null},
      'boolean model': {..._remote, 'remote_model': false},
      'non-string host': {..._remote, 'remote_host': 1},
      'relative host': {..._remote, 'remote_host': '/proxy'},
      'missing authority': {..._remote, 'remote_host': 'http:/private'},
      'unsupported scheme': {..._remote, 'remote_host': 'file:///private'},
      'invalid port': {..._remote, 'remote_host': 'http://localhost:99999'},
      'malformed port': {..._remote, 'remote_host': 'http://localhost:no'},
      'zero port': {..._remote, 'remote_host': 'http://localhost:0'},
      'whitespace host': {..._remote, 'remote_host': 'http://host with space'},
      'control model': {..._remote, 'remote_model': 'private\u0000model'},
      'oversize host': {..._remote, 'remote_host': 'https://${'x' * 2048}'},
      'oversize model': {..._remote, 'remote_model': 'm' * 513},
    };
    for (final fixture in invalid.entries) {
      test('${fixture.key} is unresolved and never locally eligible', () {
        final quota = _normalize([
          {'name': 'ambiguous:7b', ...fixture.value}
        ]);
        expect(quota.models.single.upstreamRouting, UpstreamRouting.unresolved);
        expect(quota.models.single.cloudOffloaded, isFalse);
        _expectNoLocalCapacity(quota, _now);
        final entry = buildModelRegistry([quota], _now).single;
        expect(entry.available, isFalse);
        expect(entry.localReadiness, isNull);
        expect(entry.hardwareFit, isNull);
        expect(
            suggestModel([quota], _now, requirements: const ModelRequirements())
                .recommended,
            isNull);
      });
    }

    test('known cloud-name evidence survives partial upstream metadata', () {
      final quota = _normalize([
        {'name': 'reasoner:cloud', 'remote_model': 'private'}
      ]);
      expect(quota.models.single.cloudOffloaded, isTrue);
      expect(quota.models.single.upstreamRouting, UpstreamRouting.unresolved);
      _expectNoLocalCapacity(quota, _now);
    });
  });

  group('show metadata and cache', () {
    for (final capabilities in [
      null,
      'malformed',
      <Object?>[1]
    ]) {
      test(
          'upstream show evidence survives invalid capability metadata '
          '$capabilities', () async {
        var probes = 0;
        final installed = [
          <String, Object?>{'name': 'alias:7b', 'digest': 'stable-digest'}
        ];
        final cache = OllamaCapabilityCache();
        final adapter = OllamaAdapter(
          environment: const {},
          capabilityCache: cache,
          client: _runtime(installed,
              show: {
                'alias:7b': {..._remote, 'capabilities': capabilities}
              },
              onShow: () => probes++),
        );
        final first = await adapter.collect();
        final second = await adapter.collect();
        expect(probes, 1);
        for (final quota in [first, second]) {
          expect(quota.models.single.upstreamRouting, UpstreamRouting.declared);
          _expectNoLocalCapacity(quota, quota.asOf);
        }
      });
    }

    test('partial show declarations survive cache and known reasoning',
        () async {
      final cache = OllamaCapabilityCache();
      final adapter = OllamaAdapter(
        environment: const {},
        capabilityCache: cache,
        client: _runtime([
          {'name': 'alias:7b', 'digest': 'stable-digest'}
        ], show: {
          'alias:7b': {
            'remote_host': _remote['remote_host'],
            'capabilities': ['completion', 'thinking', 'tools'],
          }
        }),
      );
      for (final quota in [await adapter.collect(), await adapter.collect()]) {
        expect(quota.models.single.upstreamRouting, UpstreamRouting.unresolved);
        expect(quota.models.single.reasoning, 'reasoning');
        expect(quota.models.single.tools, isTrue);
        _expectNoLocalCapacity(quota, quota.asOf);
      }
    });

    test('fresh tags veto overrides cached undeclared show metadata', () async {
      final installed = [
        <String, Object?>{'name': 'alias:7b', 'digest': 'stable-digest'}
      ];
      var probes = 0;
      final adapter = OllamaAdapter(
        environment: const {},
        capabilityCache: OllamaCapabilityCache(),
        client: _runtime(installed,
            show: {
              'alias:7b': {
                'capabilities': ['completion']
              }
            },
            onShow: () => probes++),
      );
      final first = await adapter.collect();
      expect(first.models.single.upstreamRouting, UpstreamRouting.notReported);
      installed.single.addAll(_remote);
      final second = await adapter.collect();
      expect(probes, 1);
      expect(second.models.single.upstreamRouting, UpstreamRouting.declared);
      _expectNoLocalCapacity(second, second.asOf);
    });
  });

  group('residency and generation evidence', () {
    test('loaded upstream and embedding entries cannot override a cold model',
        () {
      final quota = _provider(const [
        ModelInfo(
            id: 'upstream',
            loaded: true,
            upstreamRouting: UpstreamRouting.declared),
        ModelInfo(id: 'embedding', loaded: true, embedding: true),
        ModelInfo(id: 'cold'),
      ]);
      expect(quota.localGenerationReadiness, 'cold');
      expect(providerSpendClass(quota), 'cold');
      final route = suggestRoute([quota], _now, preferLocal: true);
      expect(route.recommended?.localReadiness, 'cold');
      final registry = buildModelRegistry([quota], _now);
      expect(registry.first.model.id, 'cold');
      for (final entry in registry.where((entry) => entry.model.id != 'cold')) {
        expect(entry.localReadiness, isNull);
      }
      expect(suggestModel([quota], _now).recommended?.model.id, 'cold');
    });

    test('an embedding-only inventory never supplies generation fallback', () {
      final quota = _provider(const [
        ModelInfo(id: 'embedding', loaded: true, embedding: true),
      ]);
      expect(quota.active, isTrue);
      expect(quota.localGenerationReadiness, isNull);
      expect(isLocalRuntimeAvailableAt(quota, _now), isFalse);
      expect(providerSpendClass(quota), isNull);
      expect(buildModelRegistry([quota], _now), hasLength(1));
      expect(suggestModel([quota], _now).recommended, isNull);
      expect(
          suggestRoute([quota], _now, preferLocal: true).recommended, isNull);
    });

    test('unrepresented loaded models do not make installed inventory active',
        () {
      final quota = _normalize([
        {'name': 'cold:7b'}
      ], [
        {'name': 'missing-from-tags:7b', 'size_vram': 9999}
      ]);
      expect(quota.active, isFalse);
      expect(quota.localGenerationReadiness, 'cold');
      expect(quota.details.join(' '), isNot(contains('GPU resident')));
    });

    test('ordinary digest replacement stays cold without upstream evidence',
        () {
      final quota = _normalize([
        {'name': 'alias:7b', 'digest': 'new-digest'}
      ], [
        {'name': 'alias:7b', 'digest': 'old-digest', 'size_vram': 9999}
      ]);
      expect(quota.models.single.upstreamRouting, UpstreamRouting.notReported);
      expect(quota.models.single.loaded, isFalse);
      expect(quota.models.single.vramBytes, isNull);
      expect(quota.localGenerationReadiness, 'cold');
      expect(isLocalRuntimeAvailableAt(quota, _now), isTrue);
    });

    test('negative evidence from either list survives digest mismatch', () {
      for (final onInstalled in [true, false]) {
        final quota = _normalize([
          {
            'name': 'alias:7b',
            'digest': 'new-digest',
            if (onInstalled) ..._remote
          }
        ], [
          {
            'name': 'alias:7b',
            'digest': 'old-digest',
            if (!onInstalled) ..._remote,
            'size_vram': 9999
          }
        ]);
        expect(quota.models.single.upstreamRouting, UpstreamRouting.declared);
        expect(quota.models.single.loaded, isFalse);
        expect(quota.models.single.vramBytes, isNull);
        _expectNoLocalCapacity(quota, _now);
      }
    });

    test('unresolved evidence wins over a complete declaration', () {
      final quota = _normalize([
        {'name': 'alias:7b', ..._remote}
      ], [
        {'name': 'alias:7b', 'remote_host': null}
      ]);
      expect(quota.models.single.upstreamRouting, UpstreamRouting.unresolved);
      _expectNoLocalCapacity(quota, _now);
    });

    test('different usable targets remain declarations without target claims',
        () {
      final quota = _normalize([
        {'name': 'alias:7b', ..._remote}
      ], [
        {
          'name': 'alias:7b',
          'remote_host': 'https://another-private-runtime.example',
          'remote_model': 'another-private-model'
        }
      ]);
      expect(quota.models.single.upstreamRouting, UpstreamRouting.declared);
      expect(jsonEncode(quota.toJson()),
          isNot(contains('another-private-runtime')));
      _expectNoLocalCapacity(quota, _now);
    });

    test('upstream evidence cannot bypass existing spend or capability gates',
        () {
      final quota = _provider(const [
        ModelInfo(
            id: 'safe-reasoner',
            reasoning: 'reasoning',
            tools: true,
            contextTokens: 8192),
        ModelInfo(
            id: 'upstream-reasoner',
            reasoning: 'reasoning',
            tools: true,
            contextTokens: 131072,
            upstreamRouting: UpstreamRouting.declared),
        ModelInfo(
            id: 'cloud-reasoner',
            reasoning: 'reasoning',
            tools: true,
            cloudOffloaded: true),
        ModelInfo(
            id: 'embedding',
            reasoning: 'reasoning',
            tools: true,
            embedding: true),
        ModelInfo(id: 'undeclared'),
      ]);
      final providers = [
        quota,
        ProviderQuota(
            provider: 'claude',
            displayName: 'Manual',
            account: 'fixture',
            asOf: _now,
            source: providerQuotaManualSource,
            windows: [QuotaWindow(label: 'weekly', usedPercent: 0)]),
        ProviderQuota(
            provider: 'cursor',
            displayName: 'Credit pool',
            account: 'fixture',
            asOf: _now,
            perMachine: true,
            windows: [QuotaWindow(label: 'monthly', usedPercent: 0)]),
      ];
      const catalog = {
        'claude': [
          ModelInfo(id: 'manual', reasoning: 'reasoning', tools: true)
        ],
        'cursor': [
          ModelInfo(id: 'credit', reasoning: 'reasoning', tools: true)
        ],
      };
      for (final budget in [ModelBudgetPolicy.local, ModelBudgetPolicy.quota]) {
        final result = suggestModel(providers, _now,
            catalog: catalog,
            requirements: ModelRequirements(
                budgetPolicy: budget,
                requireTools: true,
                requireReasoning: true));
        expect(result.ranked.map((entry) => entry.model.id), ['safe-reasoner']);
        expect(result.recommended?.model.id, 'safe-reasoner');
        expect(
            suggestModel(providers, _now,
                    catalog: catalog,
                    requirements: ModelRequirements(
                        budgetPolicy: budget,
                        requireTools: true,
                        requireReasoning: true,
                        minContextTokens: 32768))
                .recommended,
            isNull);
      }
    });

    test('direct hardware-fit calls cannot attach host memory to upstream', () {
      final quota = _provider(const [
        ModelInfo(
            id: 'upstream',
            loaded: true,
            sizeBytes: 1000,
            upstreamRouting: UpstreamRouting.declared)
      ]);
      final fit =
          localModelHardwareFit(quota.models.single, quota.localHardware);
      expect(fit.status, LocalHardwareFitStatus.unknown);
      expect(fit.toJson(), {
        'hardware_fit': 'unknown',
        'hardware_fit_basis': 'local_execution_unverified',
      });
      expect(buildModelRegistry([quota], _now).single.hardwareFit, isNull);
    });
  });

  group('schema and persistent migration', () {
    test('bounded evidence survives sanitization, snapshot and registry output',
        () {
      final quota = sanitizeProviderQuota(_normalize([
        {'name': 'alias:7b', ..._remote}
      ]));
      final snapshot = quotasSnapshot([quota], _now);
      expect(validateQuotabotV1Snapshot(snapshot), isEmpty);
      final decoded = jsonDecode(jsonEncode(snapshot)) as Map;
      final restored = ProviderQuota.fromJson(
          (decoded['providers'] as List).single as Map<String, dynamic>);
      final registry = modelRegistryJson([restored], _now);
      expect(
          (registry['models'] as List).single['upstream_routing'], 'declared');
      for (final output in [snapshot, registry]) {
        final encoded = jsonEncode(output);
        expect(encoded, isNot(contains(_remote['remote_host']!)));
        expect(encoded, isNot(contains(_remote['remote_model']!)));
        expect(encoded, isNot(contains('remote_host')));
        expect(encoded, isNot(contains('remote_model')));
      }
      final schema = listModelsOutputSchema.toJson();
      final modelSchema =
          ((schema['properties'] as Map)['models'] as Map)['items'] as Map;
      expect(
          ((modelSchema['properties'] as Map)['upstream_routing']
              as Map)['enum'],
          UpstreamRouting.wireValues);
    });

    test('unknown or malformed persisted enums fail closed', () {
      for (final value in [
        'future-state',
        null,
        false,
        1,
        <String, Object?>{},
        <Object?>[]
      ]) {
        final model = ModelInfo.fromJson({
          'id': 'alias:7b',
          'local': true,
          'upstream_routing': value,
        });
        expect(model.upstreamRouting, UpstreamRouting.unresolved);
        expect(model.toJson()['upstream_routing'], 'unresolved');
        final quota = _provider([model]);
        _expectNoLocalCapacity(quota, _now);
        final malformedSnapshot = quotasSnapshot([quota], _now);
        (((malformedSnapshot['providers'] as List).single as Map)['models']
                as List)
            .single['upstream_routing'] = value;
        expect(validateQuotabotV1Snapshot(malformedSnapshot),
            contains(contains('upstream_routing')));
      }
      for (final raw in [
        {'id': 'legacy'},
        {'id': 'legacy', 'upstream_routing': 'not_reported'}
      ]) {
        final model = ModelInfo.fromJson(raw);
        expect(model.upstreamRouting, UpstreamRouting.notReported);
        expect(model.toJson(), isNot(contains('upstream_routing')));
      }
    });

    test('quota cache rejects local evidence and cached DTO keeps its veto',
        () {
      final temp = Directory.systemTemp.createTempSync('quotabot_upstream_');
      setQuotabotDirOverrideForTesting(temp);
      try {
        final quota = _normalize([
          {'name': 'alias:7b', ..._remote}
        ]);
        saveSnapshot(quota);
        // Quota history intentionally excludes local-runtime inventory. The
        // cache-only decision DTO still accepts an already captured snapshot.
        expect(loadAccountSnapshot(quota.provider, quota.account), isNull);
        final cached = ProviderQuota.fromJson(
            jsonDecode(jsonEncode(quota.toJson())) as Map<String, dynamic>);
        expect(cached.models.single.upstreamRouting, UpstreamRouting.declared);
        final decision = decideNowResponse(
          CachedQuotaSnapshot(providers: [cached], asOf: _now, source: 'cache'),
          _now,
          preferLocal: true,
        );
        expect(decision['recommended'], isNull);
        expect((decision['fallback'] as Map)['kind'], 'passthrough');
        expect(
            buildModelRegistry([cached], _now,
                requirements: const ModelRequirements(
                    budgetPolicy: ModelBudgetPolicy.local)),
            isEmpty);
      } finally {
        setQuotabotDirOverrideForTesting(null);
        temp.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
