import 'package:quotabot_collector/alerts.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(
  String id,
  double usedPercent, {
  bool stale = false,
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
  int? resetsAt,
  String account = 'default',
}) =>
    ProviderQuota(
      provider: id,
      displayName: id[0].toUpperCase() + id.substring(1),
      account: account,
      asOf: _now,
      stale: stale,
      kind: kind,
      windows: [
        QuotaWindow(label: '5h', usedPercent: usedPercent, resetsAt: resetsAt),
      ],
    );

/// A suggestion whose recommendation is the given provider, for the route hint.
RouteSuggestion _suggestion(List<ProviderQuota> snapshot) =>
    suggestRoute(snapshot, _now);

void main() {
  group('alertSeverity', () {
    test('grades by remaining free headroom', () {
      expect(alertSeverity(80), AlertSeverity.none);
      expect(alertSeverity(25), AlertSeverity.none); // at the amber floor
      expect(alertSeverity(24), AlertSeverity.amber);
      expect(alertSeverity(10), AlertSeverity.amber); // at the red floor
      expect(alertSeverity(9), AlertSeverity.red);
      expect(alertSeverity(0), AlertSeverity.red);
    });
  });

  group('computeAlerts (red only, edge-triggered)', () {
    test('fires once when a window crosses into red, naming the route', () {
      // Codex spent (2% free), Claude healthy (40% free) is the route.
      final snap = [_q('codex', 98), _q('claude', 60)];
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
      );
      expect(r.fired, hasLength(1));
      final a = r.fired.single;
      expect(a.provider, 'codex');
      expect(a.account, 'default');
      expect(a.severity, AlertSeverity.red);
      expect(a.window, '5h');
      expect(a.routeTo, 'claude');
      expect(a.message, contains('route next to Claude'));
      expect(r.armed, {'codex'});
    });

    test('keys low-quota crossings by account and can route to a sibling', () {
      final snap = [
        _q('claude', 98, account: 'work@example.com'),
        _q('claude', 60, account: 'home@example.com'),
      ];
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
      );

      expect(r.fired, hasLength(1));
      final a = r.fired.single;
      expect(a.provider, 'claude');
      expect(a.account, 'work@example.com');
      expect(a.routeTo, 'claude');
      expect(a.routeAccount, 'home@example.com');
      expect(a.message, contains('work@example.com'));
      expect(a.message, contains('home@example.com'));
      expect(r.armed, {quotaIdentityKey('claude', 'work@example.com')});
    });

    test('does not re-fire while it stays red', () {
      final snap = [_q('codex', 98), _q('claude', 60)];
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
        armed: const {'codex'},
      );
      expect(r.fired, isEmpty);
      expect(r.armed, {'codex'}); // still armed, just silent
    });

    test('re-arms after recovery so a later crossing fires again', () {
      final snap = [_q('codex', 50), _q('claude', 60)]; // codex recovered
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
        armed: const {'codex'},
      );
      expect(r.fired, isEmpty);
      expect(r.armed, isEmpty); // disarmed; a future red crossing will fire
    });

    test('amber does not fire under the default red-only policy', () {
      final snap = [_q('codex', 80), _q('claude', 60)]; // 20% free: amber
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
      );
      expect(r.fired, isEmpty);
      expect(r.armed, isEmpty);
    });

    test('a stale provider holds its armed state and never fires', () {
      final snap = [_q('codex', 98, stale: true)];
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
        armed: const {'codex'},
      );
      expect(r.fired, isEmpty);
      expect(r.armed, {'codex'}); // preserved, not re-fired
    });

    test('local runtimes are never alerted on', () {
      final snap = [_q('ollama', 100, kind: ProviderQuotaKind.local)];
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
      );
      expect(r.fired, isEmpty);
    });

    test('omits the route when no better provider exists', () {
      // Every provider is spent: no healthy route to name.
      final snap = [_q('codex', 99), _q('claude', 99)];
      final r = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
      );
      for (final a in r.fired) {
        expect(a.routeTo, isNot(a.provider)); // never routes to itself
      }
    });

    test('serializes as quotabot.alert.v1 metadata only', () {
      final snap = [_q('codex', 98), _q('claude', 60)];
      final a = computeAlerts(
        snapshot: snap,
        suggestion: _suggestion(snap),
        now: _now,
      ).fired.single;
      final json = a.toJson();
      expect(json['schema'], 'quotabot.alert.v1');
      expect(json['kind'], 'low_quota');
      expect(json['provider'], 'codex');
      expect(json['account'], 'default');
      expect(json['severity'], 'red');
      expect(json['route_to'], 'claude');
      expect(json['route_account'], 'default');
      expect(json['as_of'], _now);
    });
  });

  group('computeProjectedWasteAlerts', () {
    test('fires once when projected waste crosses the threshold', () {
      final reset = _now + 10 * 3600;
      final snap = [_q('claude', 10, resetsAt: reset)];
      final pace = computePace(
        headroom: 90,
        resetsAt: reset,
        burnPerHour: 2,
        now: _now,
      )!;
      final r = computeProjectedWasteAlerts(
        snapshot: snap,
        paceByProvider: {'claude': pace},
        now: _now,
        thresholdPercent: 50,
      );
      expect(r.fired, hasLength(1));
      final a = r.fired.single;
      expect(a.kind, QuotaAlertKind.projectedWaste);
      expect(a.provider, 'claude');
      expect(a.account, 'default');
      expect(a.severity, AlertSeverity.amber);
      expect(a.projectedWastePercent, closeTo(70, 0.001));
      expect(a.burnPercentPerHour, closeTo(2, 0.001));
      expect(a.message, contains('would expire unused'));
      expect(r.armed, {'claude'});
    });

    test('does not re-fire while projected waste stays above threshold', () {
      final reset = _now + 10 * 3600;
      final snap = [_q('claude', 10, resetsAt: reset)];
      final pace = computePace(
        headroom: 90,
        resetsAt: reset,
        burnPerHour: 2,
        now: _now,
      )!;
      final r = computeProjectedWasteAlerts(
        snapshot: snap,
        paceByProvider: {'claude': pace},
        now: _now,
        thresholdPercent: 50,
        armed: const {'claude'},
      );
      expect(r.fired, isEmpty);
      expect(r.armed, {'claude'});
    });

    test('arms projected waste per account when account evidence exists', () {
      final reset = _now + 10 * 3600;
      final snap = [
        ProviderQuota(
          provider: 'claude',
          displayName: 'Claude',
          account: 'work',
          asOf: _now,
          windows: [
            QuotaWindow(
              label: 'weekly',
              usedPercent: 10,
              resetsAt: reset,
            ),
          ],
        ),
      ];
      final pace = computePace(
        headroom: 90,
        resetsAt: reset,
        burnPerHour: 2,
        now: _now,
      )!;
      final r = computeProjectedWasteAlerts(
        snapshot: snap,
        paceByProvider: {quotaIdentityKey('claude', 'work'): pace},
        now: _now,
        thresholdPercent: 50,
      );

      expect(r.fired, hasLength(1));
      expect(r.fired.single.account, 'work');
      expect(r.armed, {quotaIdentityKey('claude', 'work')});
    });

    test('re-arms after projected waste falls below threshold', () {
      final reset = _now + 10 * 3600;
      final snap = [_q('claude', 50, resetsAt: reset)];
      final pace = computePace(
        headroom: 50,
        resetsAt: reset,
        burnPerHour: 5,
        now: _now,
      )!;
      final r = computeProjectedWasteAlerts(
        snapshot: snap,
        paceByProvider: {'claude': pace},
        now: _now,
        thresholdPercent: 10,
        armed: const {'claude'},
      );
      expect(r.fired, isEmpty);
      expect(r.armed, isEmpty);
    });

    test('serializes projected waste as additive alert metadata', () {
      final reset = _now + 10 * 3600;
      final snap = [_q('claude', 10, resetsAt: reset)];
      final pace = computePace(
        headroom: 90,
        resetsAt: reset,
        burnPerHour: 2,
        now: _now,
      )!;
      final a = computeProjectedWasteAlerts(
        snapshot: snap,
        paceByProvider: {'claude': pace},
        now: _now,
        thresholdPercent: 50,
      ).fired.single;
      final json = a.toJson();
      expect(json['schema'], 'quotabot.alert.v1');
      expect(json['kind'], 'projected_waste');
      expect(json['account'], 'default');
      expect(json['projected_waste_percent'], 70.0);
      expect(json['burn_percent_per_hour'], 2.0);
      expect(json['route_to'], isNull);
    });
  });
}
