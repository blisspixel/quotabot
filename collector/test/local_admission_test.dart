import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

const _now = 1788652800;

ProviderQuota _local({
  List<Map<String, Object?>> scoped = const [],
  List<Map<String, Object?>> siblings = const [],
  String? sharedAdmission,
  bool stale = false,
}) =>
    ProviderQuota.fromJson({
      'provider': 'ollama',
      'display_name': 'Ollama',
      'account': 'synthetic-local-admission',
      'kind': 'local',
      'as_of': _now,
      'active': true,
      'stale': stale,
      if (sharedAdmission != null) 'request_admission': sharedAdmission,
      'models': [
        {'id': 'local-test', 'local': true, 'loaded': true},
        ...siblings,
      ],
      'model_quotas': scoped,
    });

Map<String, Object?> _pool(String model, [String? admission]) => {
      'model': model,
      'used_percent': 50,
      'resets_at': _now + 3600,
      if (admission != null) 'request_admission': admission,
    };

void main() {
  for (final sample in <String?, RequestAdmission>{
    'denied': RequestAdmission.denied,
    'unresolved': RequestAdmission.unresolved,
    'future-state': RequestAdmission.unresolved,
    'allowed': RequestAdmission.allowed,
    null: RequestAdmission.notReported,
  }.entries) {
    test(
        'scoped ${sample.key ?? 'missing'} admission agrees across local routes',
        () {
      final quota = ProviderQuota.fromJson(sanitizeProviderQuota(
        _local(scoped: [_pool('local-test', sample.key)]),
      ).toJson());
      final blocked = sample.value.blocksRequests;
      final entry = buildModelRegistry([quota], _now).single;
      final route = suggestRoute([quota], _now, preferLocal: true);

      expect(quota.modelQuotas.single.usedPercent, 50);
      expect(quota.modelQuotas.single.requestAdmission, sample.value);
      // A model's positive flag cannot fill in unreported shared admission.
      expect(entry.requestAdmission,
          blocked ? sample.value : RequestAdmission.notReported);
      expect(isLocalRuntimeReachableAt(quota, _now), isTrue);
      expect(quota.localGenerationReadiness, blocked ? isNull : 'loaded');
      expect(isLocalRuntimeAvailableAt(quota, _now), !blocked);
      expect(anyProviderUsable([quota], _now), !blocked);
      expect(entry.available, !blocked);
      expect(route.recommended?.provider, blocked ? isNull : 'ollama');
      expect(route.fallback.kind,
          blocked ? RouteFallbackKind.passthrough : RouteFallbackKind.local);
      expect(suggestModel([quota], _now).recommended?.model.id,
          blocked ? isNull : 'local-test');
    });
  }

  for (final loaded in [false, true]) {
    test(
        'a healthy ${loaded ? 'loaded' : 'cold'} sibling remains the local route',
        () {
      final quota = _local(
        scoped: [_pool('local-test', 'denied')],
        siblings: [
          {'id': 'healthy-sibling', 'local': true, 'loaded': loaded}
        ],
      );
      final entries = buildModelRegistry([quota], _now);
      final route = suggestRoute([quota], _now, preferLocal: true);

      expect(quota.active, isTrue);
      expect(quota.localGenerationReadiness, loaded ? 'loaded' : 'cold');
      expect(isLocalRuntimeAvailableAt(quota, _now), isTrue);
      expect(entries.singleWhere((e) => e.model.id == 'local-test').available,
          isFalse);
      expect(
          entries.singleWhere((e) => e.model.id == 'healthy-sibling').available,
          isTrue);
      expect(route.recommended?.localReadiness, loaded ? 'loaded' : 'cold');
      expect(route.fallback.provider, 'ollama');
      expect(
          suggestModel([quota], _now).recommended?.model.id, 'healthy-sibling');
    });
  }

  test('equal scoped variants retain every admission veto in either row order',
      () {
    final rows = [
      _pool('local-test:high', 'allowed'),
      _pool('local-test:low', 'denied'),
    ];
    for (final ordered in [rows, rows.reversed.toList()]) {
      final quota = _local(scoped: ordered);
      expect(quota.matchingModelQuotas(quota.models.single), hasLength(2));
      expect(buildModelRegistry([quota], _now).single.requestAdmission,
          RequestAdmission.denied);
      expect(quota.localGenerationReadiness, isNull);
      expect(suggestRoute([quota], _now).fallback.kind,
          RouteFallbackKind.passthrough);
    }
  });

  test('an unrelated named denial does not cross the model boundary', () {
    final quota = _local(scoped: [_pool('other-only', 'denied')]);
    expect(quota.localGenerationReadiness, 'loaded');
    expect(buildModelRegistry([quota], _now).single.requestAdmission,
        RequestAdmission.notReported);
    expect(suggestModel([quota], _now).recommended?.model.id, 'local-test');
  });

  test('positive scoped admission cannot override shared denial or stale data',
      () {
    for (final quota in [
      _local(
        sharedAdmission: 'denied',
        scoped: [_pool('local-test', 'allowed')],
      ),
      _local(stale: true, scoped: [_pool('local-test', 'allowed')]),
    ]) {
      expect(isLocalRuntimeAvailableAt(quota, _now), isFalse);
      expect(buildModelRegistry([quota], _now).single.available, isFalse);
      expect(suggestRoute([quota], _now).fallback.kind,
          RouteFallbackKind.passthrough);
      expect(suggestModel([quota], _now).recommended, isNull);
    }
  });
}
