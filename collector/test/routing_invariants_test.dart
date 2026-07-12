import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

/// Routing safety conformance.
///
/// One explicit place that proves the unsafe routes are impossible by
/// construction, rather than relying on that behavior being an emergent side
/// effect scattered across other tests. Each test names an invariant as a
/// guarantee. If one ever fails, a safety property regressed - not a detail.
///
/// The invariants asserted here (provider-route layer, via [suggestRoute]):
///  - a stale quota cannot win, and cannot be the silent pick when it is alone;
///  - a drift-quarantined provider cannot win;
///  - a spent binding (longest) window blocks a provider even if a shorter
///    window still shows headroom;
///  - a spent metered provider is never chosen over a running local fallback;
///  - a healthy metered provider is chosen over a local fallback (local is a
///    fallback, not a default);
///  - no-safe-route is an explicit null recommendation with a reason and a
///    non-null fallback, never a silent or unsafe pick;
///  - account-wide evidence is preferred over equal machine-scoped evidence
///    (the machine-scoped confidence discount stays visible in the ranking).
///
/// Model-budget invariants (cloud-offloaded local excluded from budget=local,
/// manual excluded from budget=quota, credit-pool excluded from budget=quota)
/// are asserted in registry_test.dart against buildModelRegistry.

const _now = 1782000000;

ProviderQuota _q(
  String id,
  List<QuotaWindow> windows, {
  bool stale = false,
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
  bool perMachine = false,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: windows,
      stale: stale,
      kind: kind,
      perMachine: perMachine,
    );

ProviderQuota _local(String id) =>
    _q(id, const [], kind: ProviderQuotaKind.local);

QuotaWindow _win(String label, double usedPercent) =>
    QuotaWindow(label: label, usedPercent: usedPercent);

void main() {
  group('routing safety invariants', () {
    test('a stale quota cannot win over a fresh one', () {
      final staleHealthy = _q('codex', [_win('weekly', 5)], stale: true);
      final fresh = _q('claude', [_win('weekly', 40)]);
      final s = suggestRoute([staleHealthy, fresh], _now);
      expect(s.recommended?.provider, 'claude');
    });

    test('a stale quota is not a silent pick when it is the only evidence', () {
      final staleOnly = _q('codex', [_win('weekly', 5)], stale: true);
      final s = suggestRoute([staleOnly], _now);
      expect(s.recommended, isNull);
    });

    test('a drift-quarantined provider cannot win', () {
      final drifted = _q('codex', [_win('weekly', 5)])
          .withProviderDrift('usage fell', _now);
      final fresh = _q('claude', [_win('weekly', 40)]);
      final s = suggestRoute([drifted, fresh], _now);
      expect(s.recommended?.provider, 'claude');
    });

    test('a spent binding window blocks a healthy shorter window', () {
      // codex has plenty in its 5h window but its weekly (binding, longest)
      // window is spent - it must not be routable, so a genuinely healthy
      // provider wins instead.
      final spentBinding = _q('codex', [
        _win('5h', 10), // healthy short window
        _win('weekly', 100), // spent binding window
      ]);
      final healthy = _q('claude', [_win('weekly', 30)]);
      final s = suggestRoute([spentBinding, healthy], _now);
      expect(s.recommended?.provider, 'claude');
    });

    test('a spent metered provider is never chosen over a local fallback', () {
      final spent = _q('codex', [_win('5h', 100)]);
      final s = suggestRoute([spent, _local('ollama')], _now);
      expect(s.recommended?.provider, 'ollama');
      expect(s.usingLocalFallback, isTrue);
    });

    test('a healthy metered provider is chosen over a local fallback', () {
      final healthy = _q('claude', [_win('weekly', 20)]);
      final s = suggestRoute([healthy, _local('ollama')], _now);
      expect(s.recommended?.provider, 'claude');
      expect(s.usingLocalFallback, isFalse);
    });

    test('no safe route is explicit: null recommendation, reason, fallback',
        () {
      final allSpent = [
        _q('codex', [_win('5h', 100)]),
        _q('claude', [_win('weekly', 100)]),
      ];
      final s = suggestRoute(allSpent, _now);
      expect(s.recommended, isNull);
      expect(s.usingLocalFallback, isFalse);
      expect(s.reason, isNotEmpty);
      // The fail-soft contract: a fallback object is always present.
      expect(s.fallback, isNotNull);
    });

    test('account-wide evidence is preferred over equal machine-scoped', () {
      // Same raw headroom; the machine-scoped provider carries a confidence
      // discount, so the account-wide one must rank ahead of it.
      final accountWide = _q('claude', [_win('weekly', 40)]);
      final machineScoped = _q('codex', [_win('weekly', 40)], perMachine: true);
      final s = suggestRoute([machineScoped, accountWide], _now);
      expect(s.recommended?.provider, 'claude');
    });

    test('an unknown reset is never fabricated (healthy or spent)', () {
      // Usable now on headroom, but no invented reset time.
      final healthyNoReset =
          _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 40)]);
      final healthy = providerAvailability(healthyNoReset, _now);
      expect(healthy.available, isTrue);
      expect(healthy.resetsAt, isNull);

      // Spent with an unknown reset: not available, and "when it's back" stays
      // null rather than a confident fabricated time.
      final spentNoReset =
          _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 100)]);
      final spent = providerAvailability(spentNoReset, _now);
      expect(spent.available, isFalse);
      expect(spent.resetsAt, isNull);
    });

    test('a spent unknown-reset provider is not the soonest-reset fallback',
        () {
      // All spent; only one has a known reset. The fail-soft "wait for the
      // soonest reset" fallback must point at the known reset, never invent one
      // for the unknown-reset provider.
      final knownReset = _q('claude', [
        QuotaWindow(label: 'weekly', usedPercent: 100, resetsAt: _now + 3600),
      ]);
      final unknownReset =
          _q('codex', [QuotaWindow(label: 'weekly', usedPercent: 100)]);
      final s = suggestRoute([knownReset, unknownReset], _now);
      expect(s.recommended, isNull);
      expect(s.fallback.resetsAt, anyOf(isNull, equals(_now + 3600)));
      if (s.fallback.kind == RouteFallbackKind.soonestReset) {
        expect(s.fallback.provider, 'claude');
      }
    });
  });
}
