import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/decision.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:quotabot_collector/routing_context.dart';
import 'package:test/test.dart';

const _now = 1782000000;
const _capable = ModelInfo(
  id: 'capable-model',
  contextTokens: 200000,
  tools: true,
  vision: true,
  reasoning: 'reasoning',
  tier: 'standard',
);
const _catalog = {
  'codex': [_capable],
};

ProviderQuota _local(
  String provider,
  List<ModelInfo> models, {
  List<ModelQuota> modelQuotas = const [],
}) =>
    ProviderQuota(
      provider: provider,
      displayName: provider,
      account: 'synthetic-local',
      asOf: _now,
      kind: ProviderQuotaKind.local,
      models: models,
      modelQuotas: modelQuotas,
    );

ProviderQuota _cloud(double used) => ProviderQuota(
      provider: 'codex',
      displayName: 'codex',
      account: 'synthetic-cloud',
      asOf: _now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
    );

RouteSuggestion _route(
  List<ProviderQuota> providers, {
  ModelRequirements? requirements,
  bool preferLocal = false,
  bool quotaStretch = false,
}) =>
    decide(
      providers,
      _now,
      context: providerRouteDecisionContext(
        providers,
        _now,
        catalog: _catalog,
        routeRequirements: requirements,
        preferLocal: preferLocal,
        quotaStretch: quotaStretch,
      ),
    ).route;

void main() {
  group('explicit provider-route capabilities apply to local fallback', () {
    for (final profile in const [
      (name: 'tools', requirements: ModelRequirements(requireTools: true)),
      (name: 'vision', requirements: ModelRequirements(requireVision: true)),
      (
        name: 'context',
        requirements: ModelRequirements(minContextTokens: 128000),
      ),
    ]) {
      test('${profile.name} keeps an undeclared loaded local model out', () {
        final local = _local('ollama', const [
          ModelInfo(id: 'undeclared', local: true, loaded: true),
        ]);
        for (final policy in const [
          (preferLocal: true, quotaStretch: false, cloudUsed: 10.0),
          (preferLocal: false, quotaStretch: false, cloudUsed: 95.0),
          (preferLocal: false, quotaStretch: true, cloudUsed: 95.0),
        ]) {
          final route = _route(
            [local, _cloud(policy.cloudUsed)],
            requirements: profile.requirements,
            preferLocal: policy.preferLocal,
            quotaStretch: policy.quotaStretch,
          );
          expect(route.recommended?.provider, 'codex');
          expect(route.usingLocalFallback, isFalse);
          expect(route.fallback.kind, isNot(RouteFallbackKind.local));
          final localCandidate =
              route.ranked.singleWhere((entry) => entry.isLocal);
          expect(localCandidate.available, isFalse);
          expect(localCandidate.capabilityLimited, isTrue);
          expect(localCandidate.localReadiness, isNull);
        }
      });
    }

    test(
        'a runtime that lacks the requested capability cannot be the only route',
        () {
      final route = _route(
        [
          _local('ollama', const [
            ModelInfo(id: 'text-only', local: true, vision: false),
          ]),
        ],
        requirements: const ModelRequirements(requireVision: true),
        preferLocal: true,
      );
      expect(route.recommended, isNull);
      expect(route.fallback.kind, RouteFallbackKind.passthrough);
      expect(route.decisionCode, RouteDecisionCode.capabilityBlocked);
      expect(route.reason, contains('requested capability profile'));
    });

    test('a capable local sibling wins and reports matching model readiness',
        () {
      final route = _route(
        [
          _local('ollama', const [
            ModelInfo(id: 'unsupported', local: true, loaded: true),
          ]),
          _local('lmstudio', const [
            ModelInfo(id: 'loaded-text', local: true, loaded: true),
            ModelInfo(id: 'vision-model', local: true, vision: true),
          ]),
          _cloud(95),
        ],
        requirements: const ModelRequirements(requireVision: true),
      );
      expect(route.recommended?.provider, 'lmstudio');
      expect(route.recommended?.localReadiness, 'cold');
      expect(route.fallback.provider, 'lmstudio');
      expect(route.usingLocalFallback, isTrue);
    });

    test('empty local inventory supplies no explicit capability evidence', () {
      final route = _route(
        [_local('ollama', const [])],
        requirements: const ModelRequirements(requireTools: true),
        preferLocal: true,
      );
      expect(route.recommended, isNull);
      expect(route.fallback.kind, RouteFallbackKind.passthrough);
    });

    test(
        'non-text and cloud-offloaded models cannot qualify another local model',
        () {
      for (final excluded in const [
        ModelInfo(
            id: 'image', local: true, vision: true, textGeneration: false),
        ModelInfo(id: 'embedding', local: true, tools: true, embedding: true),
        ModelInfo(id: 'cloud', local: true, vision: true, cloudOffloaded: true),
        ModelInfo(
          id: 'upstream',
          local: true,
          vision: true,
          upstreamRouting: UpstreamRouting.declared,
        ),
      ]) {
        final route = _route(
          [
            _local('ollama', [
              const ModelInfo(id: 'plain-text', local: true, loaded: true),
              excluded,
            ]),
          ],
          requirements: ModelRequirements(
            requireVision: excluded.vision == true,
            requireTools: excluded.tools == true,
          ),
        );
        expect(route.recommended, isNull);
        expect(route.fallback.kind, RouteFallbackKind.passthrough);
      }
    });

    test('admission for a qualifying local model remains a veto', () {
      final route = _route(
        [
          _local(
            'ollama',
            const [
              ModelInfo(id: 'plain-text', local: true, loaded: true),
              ModelInfo(id: 'vision-model', local: true, vision: true),
            ],
            modelQuotas: const [
              ModelQuota(
                model: 'vision-model',
                requestAdmission: RequestAdmission.denied,
              ),
            ],
          ),
        ],
        requirements: const ModelRequirements(requireVision: true),
      );
      expect(route.recommended, isNull);
      expect(route.fallback.kind, RouteFallbackKind.passthrough);
      expect(route.decisionCode, RouteDecisionCode.requestBlocked);
      expect(route.ranked.single.requestAdmission, RequestAdmission.denied);
    });

    test('quota-stretch ranks a loaded qualifying local before a cold one', () {
      final route = _route(
        [
          _local('ollama', const [
            ModelInfo(id: 'cold-vision', local: true, vision: true),
          ]),
          _local('lmstudio', const [
            ModelInfo(
                id: 'loaded-vision', local: true, loaded: true, vision: true),
          ]),
          _cloud(95),
        ],
        requirements: const ModelRequirements(requireVision: true),
        quotaStretch: true,
      );
      expect(route.recommended?.provider, 'lmstudio');
      expect(route.recommended?.localReadiness, 'loaded');
      expect(route.fallback.provider, 'lmstudio');
    });
  });

  test('unfiltered local-first preserves undeclared runtime compatibility', () {
    final route = _route(
      [
        _cloud(10),
        _local('ollama', const [
          ModelInfo(id: 'undeclared', local: true, loaded: true),
        ]),
      ],
      preferLocal: true,
    );
    expect(route.recommended?.provider, 'ollama');
    expect(route.recommended?.localReadiness, 'loaded');
    expect(route.recommended?.capabilityLimited, isFalse);
    expect(route.fallback.kind, RouteFallbackKind.local);
  });

  test('unknown load state remains fallback for inventory and declared tools',
      () {
    final local = _local('ollama', const [
      ModelInfo(
        id: 'load-unreported',
        local: true,
        loadedStateKnown: false,
        contextTokens: 131072,
        tools: true,
      ),
    ]);
    expect(isLocalRuntimeAvailableAt(local, _now), isTrue);
    for (final requirements in const [
      null,
      ModelRequirements(requireTools: true),
    ]) {
      for (final policy in const [
        (preferLocal: true, quotaStretch: false, cloudUsed: 10.0),
        (preferLocal: false, quotaStretch: false, cloudUsed: 95.0),
        (preferLocal: false, quotaStretch: true, cloudUsed: 95.0),
      ]) {
        final route = _route(
          [local, _cloud(policy.cloudUsed)],
          requirements: requirements,
          preferLocal: policy.preferLocal,
          quotaStretch: policy.quotaStretch,
        );
        expect(route.recommended?.provider, 'ollama');
        expect(route.recommended?.available, isTrue);
        expect(route.recommended?.localReadiness, isNull);
        expect(route.recommended!.toJson(), isNot(contains('local_readiness')));
        expect(route.fallback.kind, RouteFallbackKind.local);
        expect(route.receipt.winner?.available, isTrue);
        expect(route.receipt.winner?.spendRisk, 'runtime_unverified');
      }
    }
  });

  test('explicit context cannot use a maximum when load state is unknown', () {
    final local = _local('ollama', const [
      ModelInfo(
        id: 'load-unreported',
        local: true,
        loadedStateKnown: false,
        contextTokens: 131072,
      ),
    ]);
    for (final policy in const [
      (preferLocal: true, quotaStretch: false, cloudUsed: 10.0),
      (preferLocal: false, quotaStretch: false, cloudUsed: 95.0),
      (preferLocal: false, quotaStretch: true, cloudUsed: 95.0),
    ]) {
      final route = _route(
        [local, _cloud(policy.cloudUsed)],
        requirements: const ModelRequirements(minContextTokens: 65536),
        preferLocal: policy.preferLocal,
        quotaStretch: policy.quotaStretch,
      );
      expect(route.recommended?.provider, 'codex');
      expect(route.fallback.kind, isNot(RouteFallbackKind.local));
      final candidate = route.ranked.singleWhere((entry) => entry.isLocal);
      expect(candidate.available, isFalse);
      expect(candidate.capabilityLimited, isTrue);
      expect(candidate.localReadiness, isNull);
    }
    final route = _route(
      [local],
      requirements: const ModelRequirements(minContextTokens: 65536),
      preferLocal: true,
    );
    expect(route.recommended, isNull);
    expect(route.fallback.kind, RouteFallbackKind.passthrough);
  });

  test('matching unknown state dominates cold but not a matching loaded model',
      () {
    const unknown = ModelInfo(
      id: 'unknown-vision',
      local: true,
      loadedStateKnown: false,
      vision: true,
    );
    const cold = ModelInfo(id: 'cold-vision', local: true, vision: true);
    const unrelated = ModelInfo(id: 'loaded-text', local: true, loaded: true);
    const loaded = ModelInfo(
      id: 'loaded-vision',
      local: true,
      loaded: true,
      vision: true,
    );
    for (final matching in const [
      [unknown, cold],
      [cold, unknown],
      [unknown, loaded],
      [loaded, unknown],
      [cold],
    ]) {
      final local = _local('ollama', [unrelated, ...matching]);
      expect(local.localGenerationReadiness, 'loaded');
      final route = _route(
        [local],
        requirements: const ModelRequirements(requireVision: true),
        quotaStretch: true,
      );
      expect(route.recommended?.provider, 'ollama');
      expect(
        route.recommended?.localReadiness,
        matching.contains(loaded)
            ? 'loaded'
            : matching.contains(unknown)
                ? null
                : 'cold',
      );
    }
  });
}
