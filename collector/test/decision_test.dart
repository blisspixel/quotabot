import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/decision.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/simulation.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(
  String id,
  List<QuotaWindow> windows, {
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: windows,
      kind: kind,
    );

ProviderQuota _local(String id) =>
    _q(id, const [], kind: ProviderQuotaKind.local);

QuotaWindow _win(String label, double used) =>
    QuotaWindow(label: label, usedPercent: used);

void main() {
  group('decide is the one engine, byte-for-byte with the route core', () {
    test('decide().route matches suggestRoute() for the same inputs', () {
      final quotas = [
        _q('codex', [_win('weekly', 80)]),
        _q('claude', [_win('weekly', 20)]),
      ];
      final direct = suggestRoute(quotas, _now);
      final viaDecide = decide(quotas, _now).route;
      expect(viaDecide.recommended?.provider, direct.recommended?.provider);
      expect(viaDecide.reason, direct.reason);
      expect(viaDecide.ranked.map((c) => c.provider),
          direct.ranked.map((c) => c.provider));
    });

    test('the DecisionContext forwards a routing knob to the core', () {
      final quotas = [
        _q('claude', [_win('weekly', 20)]),
        _local('ollama'),
      ];
      // preferLocal flips the recommendation to the local runtime; decide must
      // carry that through to the core identically.
      final withLocal = decide(quotas, _now,
          context: const DecisionContext(preferLocal: true));
      final direct = suggestRoute(quotas, _now, preferLocal: true);
      expect(withLocal.recommended?.provider, direct.recommended?.provider);
      expect(withLocal.recommended?.provider, 'ollama');
    });
  });

  group('SEE, ROUTE, and ALERT are views of one Decision', () {
    test('SEE forecasts are the ranked candidates, carrying uncertainty', () {
      final d = decide([
        _q('codex', [_win('weekly', 80)]),
        _q('claude', [_win('weekly', 20)]),
      ], _now);
      expect(d.forecasts, same(d.route.ranked));
      // The recommended (ROUTE) is one of the forecasts (SEE): one object.
      expect(d.forecasts.map((c) => c.provider),
          contains(d.recommended!.provider));
      // Each forecast carries the forward view, not just a headroom point.
      expect(d.forecasts.every((c) => c.headroom != null), isTrue);
    });

    test('ALERT view thresholds on the same forecasts', () {
      final d = decide([
        _q('codex', [_win('weekly', 95)]), // 5% left - below a 10% line
        _q('claude', [_win('weekly', 20)]), // 80% left - above it
      ], _now);
      final alerting = d.alertsBelow(10).map((c) => c.provider).toList();
      expect(alerting, ['codex']);
    });

    test('ALERT view excludes stale and drifted candidates', () {
      // A stale cached provider stays in the ranked SEE view as last-trusted
      // evidence, but alerting on hours-old data would misfire, so the ALERT
      // view must skip it even though its headroom is below the line.
      final staleLow = ProviderQuota(
        provider: 'codex',
        displayName: 'codex',
        account: 'a',
        asOf: _now,
        stale: true,
        windows: [_win('weekly', 95)], // 5% left, below a 10% line
      );
      final d = decide([
        staleLow,
        _q('claude', [_win('weekly', 20)])
      ], _now);
      expect(d.forecasts.map((c) => c.provider), contains('codex')); // in SEE
      expect(d.alertsBelow(10), isEmpty); // but not alerted
    });
  });

  group('replay folds the core over history, deterministically', () {
    test('replay reproduces the per-frame decisions and is deterministic', () {
      final frames = <DecisionFrame>[
        (
          observations: [
            _q('claude', [_win('weekly', 20)]),
          ],
          now: _now,
          context: const DecisionContext(),
        ),
        (
          observations: [
            _q('claude', [_win('weekly', 100)]), // now spent
            _q('codex', [_win('weekly', 30)]),
          ],
          now: _now + 3600,
          context: const DecisionContext(),
        ),
      ];

      final decisions = replay(frames);
      expect(
          decisions.map((d) => d.recommended?.provider), ['claude', 'codex']);

      // Each replayed decision equals decide() on its own frame.
      for (final f in frames) {
        final expected = decide(f.observations, f.now, context: f.context);
        final got =
            decisions[frames.indexOf(f)]; // frames are distinct instances
        expect(got.recommended?.provider, expected.recommended?.provider);
      }

      // Determinism: the same frames always yield the same decisions.
      final again = replay(frames);
      expect(again.map((d) => d.recommended?.provider),
          decisions.map((d) => d.recommended?.provider));
    });
  });

  group('a simulated fleet drives the whole pipeline with no network', () {
    test('a healthy simulated provider is routable through decide', () {
      final fleet =
          simulateFleet(provider: 'claude', state: 'healthy', now: _now);
      final d = decide(fleet!, _now);
      expect(d.recommended?.provider, 'claude');
    });

    test('an exhausted simulated provider yields no recommendation', () {
      final fleet =
          simulateFleet(provider: 'claude', state: 'exhausted', now: _now);
      final d = decide(fleet!, _now);
      expect(d.recommended, isNull);
    });
  });
}
