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
  ProviderSourceClass? sourceClass,
  bool perMachine = false,
  int? resetsAt,
  String account = 'default',
  int resetCreditsAvailable = 0,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id[0].toUpperCase() + id.substring(1),
      account: account,
      asOf: _now,
      stale: stale,
      kind: kind,
      sourceClass: sourceClass,
      perMachine: perMachine,
      resetCreditsAvailable: resetCreditsAvailable,
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

  group('computeResetSignals (edge-triggered, flap-resistant)', () {
    test('fires once when a reset appears, then stays armed', () {
      final snap = [_q('codex', 100, resetCreditsAvailable: 2)];
      final first = computeResetSignals(snapshot: snap);
      expect(first.fired, hasLength(1));
      expect(first.fired.single.provider, 'codex');
      expect(first.fired.single.message, contains('2 resets available'));
      expect(first.armed, contains('codex'));

      // Same reset still present: armed, no re-fire.
      final second = computeResetSignals(snapshot: snap, armed: first.armed);
      expect(second.fired, isEmpty);
      expect(second.armed, contains('codex'));
    });

    test('a live-to-session flap does not re-notify the same reset', () {
      final live = [_q('codex', 100, resetCreditsAvailable: 2)];
      // Session fallback: this-machine scope, no reset-credit knowledge.
      final session = [_q('codex', 100, perMachine: true)];

      final armed = computeResetSignals(snapshot: live).armed;
      // Live read drops out; the fallback must not disarm...
      final duringFlap = computeResetSignals(snapshot: session, armed: armed);
      expect(duringFlap.fired, isEmpty);
      expect(duringFlap.armed, contains('codex'));
      // ...so when the live read returns, it does not fire again.
      final back = computeResetSignals(snapshot: live, armed: duringFlap.armed);
      expect(back.fired, isEmpty);
    });

    test('a fresh account-wide zero disarms so a later reset can fire again',
        () {
      final armed = computeResetSignals(
        snapshot: [_q('codex', 100, resetCreditsAvailable: 2)],
      ).armed;
      // Authoritative read genuinely reports no reset: disarm.
      final gone = computeResetSignals(
        snapshot: [_q('codex', 100, resetCreditsAvailable: 0)],
        armed: armed,
      );
      expect(gone.armed, isEmpty);
      // A new reset later fires again.
      final again = computeResetSignals(
        snapshot: [_q('codex', 100, resetCreditsAvailable: 1)],
        armed: gone.armed,
      );
      expect(again.fired, hasLength(1));
    });

    test('stale or drifted evidence never fires a reset signal', () {
      final stale = _q('codex', 100, resetCreditsAvailable: 2, stale: true);
      expect(computeResetSignals(snapshot: [stale]).fired, isEmpty);
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

    test('the alert window label and free-percent describe the same window',
        () {
      // Spent provider: the binding window (resets last) is the weekly, while the
      // provider-wide minimum headroom is the 5h's. The alert must report the
      // named window's own headroom (0.4%), not the other window's.
      final spent = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'default',
        asOf: _now,
        windows: [
          QuotaWindow(label: '5h', usedPercent: 100, resetsAt: _now + 3600),
          QuotaWindow(
              label: 'weekly', usedPercent: 99.6, resetsAt: _now + 6000),
        ],
      );
      final r = computeAlerts(
        snapshot: [spent],
        suggestion: _suggestion([spent]),
        now: _now,
      );
      final a = r.fired.single;
      expect(a.window, 'weekly');
      expect(a.freePercent, closeTo(0.4, 0.01));
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

    test('does not present plan-like account strings as identities', () {
      final alert = QuotaAlert(
        provider: 'claude',
        displayName: 'Claude',
        account: 'max',
        sourceClass: ProviderSourceClass.authoritativeLive,
        window: 'weekly',
        severity: AlertSeverity.red,
        freePercent: 4,
        asOf: _now,
        routeTo: 'codex',
        routeDisplayName: 'Codex',
        routeAccount: 'pro',
        routeSourceClass: ProviderSourceClass.authoritativeLive,
        routeFreePercent: 55,
      );

      expect(alert.message, contains('Claude weekly at 4% free'));
      expect(alert.message, contains('route next to Codex (55% free)'));
      expect(alert.message, isNot(contains('(max)')));
      expect(alert.message, isNot(contains('(pro)')));
    });

    test('abbreviates opaque credential identities in alert copy', () {
      final identity = 'credential:${List.filled(64, 'a').join()}';
      final alert = QuotaAlert(
        provider: 'claude',
        displayName: 'Claude',
        account: identity,
        sourceClass: ProviderSourceClass.authoritativeLive,
        window: 'weekly',
        severity: AlertSeverity.red,
        freePercent: 4,
        asOf: _now,
      );

      expect(alert.message, contains('Claude (account aaaaaaaa)'));
      expect(alert.message, isNot(contains(identity)));
      expect(alert.toJson()['account'], identity);
    });

    test('route provenance is enforced outside debug assertions', () {
      QuotaAlert invalid({
        String? routeTo,
        ProviderSourceClass? routeSourceClass,
      }) =>
          QuotaAlert(
            provider: 'claude',
            displayName: 'Claude',
            sourceClass: ProviderSourceClass.authoritativeLive,
            window: 'weekly',
            severity: AlertSeverity.red,
            freePercent: 4,
            asOf: _now,
            routeTo: routeTo,
            routeSourceClass: routeSourceClass,
          );

      expect(() => invalid(routeTo: 'codex'), throwsArgumentError);
      expect(
        () => invalid(
          routeSourceClass: ProviderSourceClass.authoritativeLive,
        ),
        throwsArgumentError,
      );
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

    test('integrity-rejected source evidence holds state and never fires', () {
      final invalid = _q(
        'codex',
        98,
        sourceClass: ProviderSourceClass.statusOnly,
      );
      expect(invalid.sourceClassViolation, isNotNull);

      final r = computeAlerts(
        snapshot: [invalid],
        suggestion: _suggestion([invalid]),
        now: _now,
        armed: const {'codex'},
      );

      expect(r.fired, isEmpty);
      expect(r.armed, {'codex'});
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
      expect(json['source_class'], 'authoritative_live');
      expect(json['severity'], 'red');
      expect(json['route_to'], 'claude');
      expect(json['route_account'], 'default');
      expect(json['route_source_class'], 'authoritative_live');
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

    test('skips self-reported manual quota projections', () {
      final reset = _now + 10 * 3600;
      final snap = [
        ProviderQuota(
          provider: 'custom-ai',
          displayName: 'Custom AI',
          account: 'work',
          source: providerQuotaManualSource,
          asOf: _now,
          windows: [
            QuotaWindow(label: 'monthly', usedPercent: 10, resetsAt: reset),
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
        paceByProvider: {quotaIdentityKey('custom-ai', 'work'): pace},
        now: _now,
        thresholdPercent: 50,
      );

      expect(r.fired, isEmpty);
      expect(r.armed, isEmpty);
    });

    test('skips integrity-rejected source evidence projections', () {
      final reset = _now + 10 * 3600;
      final invalid = _q(
        'claude',
        10,
        resetsAt: reset,
        sourceClass: ProviderSourceClass.statusOnly,
      );
      final pace = computePace(
        headroom: 90,
        resetsAt: reset,
        burnPerHour: 2,
        now: _now,
      )!;
      expect(invalid.sourceClassViolation, isNotNull);

      final r = computeProjectedWasteAlerts(
        snapshot: [invalid],
        paceByProvider: {'claude': pace},
        now: _now,
        thresholdPercent: 50,
        armed: const {'claude'},
      );

      expect(r.fired, isEmpty);
      expect(r.armed, {'claude'});
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
      expect(json['source_class'], 'authoritative_live');
      expect(json['projected_waste_percent'], 70.0);
      expect(json['burn_percent_per_hour'], 2.0);
      expect(json['route_to'], isNull);
      expect(json['route_source_class'], isNull);
    });
  });
}
