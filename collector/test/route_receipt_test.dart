import 'dart:convert';

import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _quota(
  String provider,
  double used, {
  String account = 'a',
  String label = 'weekly',
  int? resetsAt,
  bool stale = false,
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
  String? source,
  bool perMachine = false,
}) =>
    ProviderQuota(
      provider: provider,
      displayName: provider,
      account: account,
      asOf: _now,
      stale: stale,
      kind: kind,
      source: source,
      perMachine: perMachine,
      windows: kind == ProviderQuotaKind.local
          ? const []
          : [
              QuotaWindow(
                label: label,
                usedPercent: used,
                resetsAt: resetsAt,
              ),
            ],
    );

ProviderQuota _local(String provider) =>
    _quota(provider, 0, kind: ProviderQuotaKind.local);

Map<String, dynamic> _receipt(RouteSuggestion suggestion) =>
    suggestion.receipt.toJson();

void main() {
  group('decision receipt', () {
    test('is deterministic, complete, and content-blind on a normal route', () {
      final codex = _quota(
        'codex',
        20,
        resetsAt: _now + 2 * 3600,
      );
      final suggestion = suggestRoute(
        [codex],
        _now,
        burnStatsByProvider: {
          quotaIdentityKeyFor(codex):
              const BurnStat(perHour: 10, sePerHour: 2, samples: 8),
        },
        riskZ: 1,
        leaseDiscountFor: (_, __) => 5,
        pipePenaltyByProvider: const {'codex': 4},
        wasteThresholdPercent: 0,
        costPenaltyByProvider: const {'codex': 1},
        costWeight: 1,
      );

      final receipt = _receipt(suggestion);
      final sameReceipt = _receipt(suggestion);
      expect(receipt['schema'], 'quotabot.receipt.v1');
      expect(receipt['decision_id'], sameReceipt['decision_id']);
      expect(receipt['decision_id'], startsWith('qb-$_now-'));
      expect(receipt['outcome'], 'best_runway');
      expect(receipt['explanation'], suggestion.explanation);
      expect(receipt['explanation'], contains('Binding pool: weekly.'));

      final snapshot = receipt['snapshot'] as Map<String, dynamic>;
      expect(snapshot, {
        'source': 'live',
        'as_of': _now,
        'age_seconds': 0,
        'stale': false,
      });
      final policy = receipt['policy'] as Map<String, dynamic>;
      expect(policy['routing'], 'balanced');
      expect(policy['spend_order'], ['subscription', 'local_fallback']);
      expect(policy['comfort_threshold_percent'], 15.0);

      final winner = receipt['winner'] as Map<String, dynamic>;
      expect(winner['provider'], 'codex');
      expect(winner['binding_pool'], 'weekly');
      expect(winner['source_class'], 'authoritative_live');
      expect(winner['spend_class'], 'quota_plan');
      expect(winner['spend_risk'], 'quota_plan');
      expect(winner['verdict'], 'selected');
      expect(winner['raw_headroom_percent'], 80.0);
      expect(winner['effective_headroom_percent'], lessThan(80));
      expect(winner['evidence_age_seconds'], 0);

      final adjustmentKinds = (winner['adjustments'] as List)
          .cast<Map<String, dynamic>>()
          .map((entry) => entry['kind'])
          .toSet();
      expect(
        adjustmentKinds,
        containsAll({
          'burn_risk',
          'lease',
          'pipe_health',
          'confidence',
          'projected_waste',
          'cost',
        }),
      );
      expect(receipt['alternatives'], isEmpty);
      expect((receipt['fallback'] as Map)['kind'], 'soonest_reset');

      final encoded = jsonEncode(receipt).toLowerCase();
      for (final forbidden in [
        'prompt',
        'source_code',
        'model_response',
        'credential',
        'access_token',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }
    });

    test('gives every alternative a low-cardinality rejection verdict', () {
      final drifted = _quota('windsurf', 5)
          .withProviderDrift('usage fell unexpectedly', _now);
      final suggestion = suggestRoute([
        _quota('codex', 10),
        _quota('claude', 20),
        _local('ollama'),
        _quota('grok', 100),
        _quota('cursor', 5, stale: true),
        drifted,
      ], _now);

      final receipt = _receipt(suggestion);
      final alternatives = {
        for (final value
            in (receipt['alternatives'] as List).cast<Map<String, dynamic>>())
          value['provider']: value,
      };
      expect((receipt['winner'] as Map)['provider'], 'codex');
      expect(alternatives['claude']?['verdict'], 'lower_runway');
      expect(alternatives['ollama']?['verdict'], 'local_fallback_only');
      expect(alternatives['grok']?['verdict'], 'spent');
      expect(alternatives['cursor']?['verdict'], 'stale');
      expect(alternatives['windsurf']?['verdict'], 'provider_drift');
      for (final alternative in alternatives.values) {
        expect(alternative['verdict_reason'], isNotEmpty);
      }
    });

    test('records preference, comfort, capability, and model-budget outcomes',
        () {
      final preferred = suggestRoute(
        [_quota('codex', 10), _quota('claude', 20)],
        _now,
        preferenceOrder: const ['claude'],
      );
      expect(_receipt(preferred)['outcome'], 'preferred_provider');
      expect(
        ((_receipt(preferred)['alternatives'] as List).single
            as Map)['verdict'],
        'lower_preference',
      );

      final low = suggestRoute(
        [_quota('codex', 90), _quota('claude', 80)],
        _now,
        comfortThreshold: 30,
      );
      expect(_receipt(low)['outcome'], 'low_quota');
      expect(
        ((_receipt(low)['alternatives'] as List).single as Map)['verdict'],
        'below_comfort',
      );

      final claude = _quota('claude', 10);
      final key = quotaIdentityKeyFor(claude);
      final noCapable = suggestRoute(
        [claude],
        _now,
        capabilityKnownQuotaKeys: const {},
        capabilityAvailableQuotaKeys: const {},
      );
      expect(_receipt(noCapable)['outcome'], 'capability_blocked');
      expect(
        ((_receipt(noCapable)['alternatives'] as List).single
            as Map)['verdict'],
        'no_capable_model',
      );

      final noBudget = suggestRoute(
        [claude],
        _now,
        capabilityKnownQuotaKeys: {key},
        capabilityAvailableQuotaKeys: const {},
      );
      expect(_receipt(noBudget)['outcome'], 'capability_budget_blocked');
      final modelGate =
          (_receipt(noBudget)['alternatives'] as List).single as Map;
      expect(modelGate['binding_pool'], 'model_budget');
      expect(modelGate['verdict'], 'model_budget_spent');
    });

    test('covers fail-soft outcomes without inventing a winner', () {
      final cases = <String, RouteSuggestion>{
        'no_data': suggestRoute(const [], _now),
        'provider_drift': suggestRoute([
          _quota('codex', 10).withProviderDrift('usage fell', _now),
        ], _now),
        'stale_evidence': suggestRoute([
          _quota('codex', 10, stale: true),
        ], _now),
        'spent_wait': suggestRoute([
          _quota('codex', 100, resetsAt: _now + 3600),
        ], _now),
        'spent_unknown_reset': suggestRoute([
          _quota('codex', 100),
        ], _now),
      };

      for (final entry in cases.entries) {
        final receipt = _receipt(entry.value);
        expect(receipt['outcome'], entry.key);
        expect(receipt['winner'], isNull);
        expect(receipt['explanation'], contains('Fallback:'));
        expect(receipt['fallback'], isA<Map<String, dynamic>>());
      }

      final localFirst = suggestRoute(
        [_quota('codex', 10), _local('ollama')],
        _now,
        preferLocal: true,
      );
      expect(_receipt(localFirst)['outcome'], 'local_first');

      final localFallback = suggestRoute(
        [_quota('codex', 99), _local('ollama')],
        _now,
      );
      expect(_receipt(localFallback)['outcome'], 'local_fallback');
    });

    test('records manual and machine-scoped confidence reasons', () {
      final manual = _quota(
        'manual-tool',
        10,
        source: providerQuotaManualSource,
      );
      final machine = _quota('cursor', 20, perMachine: true);
      final receipt = _receipt(suggestRoute([manual, machine], _now));
      final all = <Map<String, dynamic>>[
        receipt['winner'] as Map<String, dynamic>,
        ...(receipt['alternatives'] as List).cast<Map<String, dynamic>>(),
      ];
      final byProvider = {for (final value in all) value['provider']: value};
      expect(
        byProvider['manual-tool']?['confidence_reasons'],
        contains('self_reported'),
      );
      expect(
        byProvider['cursor']?['confidence_reasons'],
        contains('machine_scoped'),
      );
      expect(byProvider['manual-tool']?['spend_risk'], 'self_reported');
    });
  });
}
