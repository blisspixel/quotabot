import 'package:quotabot_collector/decision.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:quotabot_collector/routing_context.dart';
import 'package:test/test.dart';

void main() {
  const now = 1800000000;
  const small = ModelInfo(
      id: 'loaded-8k', local: true, loaded: true, contextTokens: 8192);
  const large = ModelInfo(id: 'cold-262k', local: true, contextTokens: 262144);
  ProviderQuota runtime(List<ModelInfo> models) => ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: 'local',
      asOf: now,
      kind: ProviderQuotaKind.local,
      models: models);

  test(
      'default provider advice names capable cold model and loaded context limit',
      () {
    final providers = [
      runtime([small, large])
    ];
    final route = decide(providers, now,
            context: providerRouteDecisionContext(providers, now))
        .route;
    expect(route.recommended!.localModel!.modelId, large.id);
    expect(route.recommended!.localModel!.reason, contains('8K'));
    expect(route.explanation, contains(large.id));
    expect('below the requested floor'.allMatches(route.explanation),
        hasLength(1));
    final json = route.toJson();
    expect((json['recommended'] as Map)['local_model'],
        containsPair('model_id', large.id));
  });

  test('context shortfall is explicit without changing provider eligibility',
      () {
    final providers = [
      runtime([small])
    ];
    final route = decide(providers, now,
            context: providerRouteDecisionContext(providers, now))
        .route;
    expect(route.recommended!.provider, 'ollama');
    expect(route.recommended!.localModel!.modelId, isNull);
    expect(route.explanation, contains('No available model meets the 32K'));
  });

  test('explicit profile overrides default floor and retains loaded preference',
      () {
    final providers = [
      runtime([small, large])
    ];
    final advice = localRouteModelAdvice(providers, now,
        requirements: const ModelRequirements(minContextTokens: 4096));
    expect(advice.values.single.modelId, small.id);
    expect(advice.values.single.minContextTokens, 4096);
    expect(suggestModel(providers, now).recommended!.model.id, small.id);
  });

  test(
      'unknown residency, remote routes and non-text models cannot meet advice',
      () {
    final providers = [
      runtime(const [
        ModelInfo(
            id: 'unknown',
            local: true,
            loadedStateKnown: false,
            contextTokens: 262144),
        ModelInfo(
            id: 'cloud',
            local: true,
            cloudOffloaded: true,
            contextTokens: 262144),
        ModelInfo(
            id: 'upstream',
            local: true,
            upstreamRouting: UpstreamRouting.declared,
            contextTokens: 262144),
        ModelInfo(
            id: 'embedding',
            local: true,
            embedding: true,
            contextTokens: 262144),
      ])
    ];
    final advice = localRouteModelAdvice(providers, now).values.single;
    expect(advice.modelId, isNull);
    expect(advice.meetsContextFloor, isFalse);
  });

  test(
      'unavailable or denied models stay excluded and advice is account scoped',
      () {
    final denied = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'denied',
        asOf: now,
        kind: ProviderQuotaKind.local,
        models: [large],
        requestAdmission: RequestAdmission.denied);
    final advice = localRouteModelAdvice([
      runtime([small]),
      denied
    ], now);
    expect(advice, hasLength(2));
    expect(advice.values.every((value) => value.modelId == null), isTrue);
  });
}
