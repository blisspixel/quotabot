import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_analytics.dart';
import 'package:quotabot/desktop_refresh_recovery.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/models.dart';
import 'package:window_manager/window_manager.dart';

class _Clock {
  DateTime now = DateTime.utc(2026, 9, 5, 12);

  void advance(Duration duration) => now = now.add(duration);
}

class _AnalyticsJob implements DesktopAnalyticsJob {
  final done = Completer<DesktopAnalyticsData?>();

  @override
  Future<DesktopAnalyticsData?> get completed => done.future;

  @override
  void cancel() {}
}

ProviderQuota _quota({
  String provider = 'codex',
  double free = 95,
  int? asOf,
  String? pipeHealth,
  int? retryAfterSeconds,
  int? weeklyReset,
  QuotaWindow? shorterWindow,
  bool stale = false,
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return ProviderQuota(
    provider: provider,
    displayName: provider == 'codex' ? 'Codex' : 'Claude',
    account: 'recovery-fixture',
    asOf: asOf ?? now,
    sourceClass: ProviderSourceClass.authoritativeLive,
    stale: stale,
    pipeHealth: pipeHealth,
    retryAfterSeconds: retryAfterSeconds,
    windows: [
      ?shorterWindow,
      QuotaWindow(
        label: 'weekly',
        usedPercent: 100 - free,
        resetsAt: weeklyReset ?? now + 3 * 3600,
      ),
    ],
  );
}

Widget _dashboard(
  _Clock clock,
  Future<List<ProviderQuota>> Function() collect, {
  Cadence cadence = Cadence.h1,
  bool demoMode = false,
  bool screenshotCapture = false,
  bool readinessProbe = false,
  DesktopAnalyticsJobStarter? analyticsJobStarter,
}) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    extensions: [AppChromeTheme.forSpec(Brightness.dark, appThemeDark)],
  ),
  home: Dashboard.test(
    prefs: Prefs(setupDone: true, enableNotifications: false, cadence: cadence),
    demoMode: demoMode,
    collector: collect,
    refreshRecovery: DesktopRefreshRecovery(
      clock: () => clock.now,
      screenshotCapture: screenshotCapture,
      readinessProbe: readinessProbe,
    ),
    analyticsJobStarter: analyticsJobStarter,
    analyticsDeadline: const Duration(minutes: 10),
    prefsSaver: (_) async {},
  ),
);

void _desktopSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(340, 760);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

WindowListener _window(WidgetTester tester) =>
    tester.state(find.byType(Dashboard)) as WindowListener;

void _returnEvents(WindowListener window) {
  // The native plugin calls the generic event before its typed callback.
  window.onWindowEvent('show');
  window.onWindowEvent('restore');
  window.onWindowRestore();
  window.onWindowEvent('focus');
}

Finder _cardText(String text) => find.descendant(
  of: find.byType(ProviderTile),
  matching: find.textContaining(text),
);

void main() {
  testWidgets(
    'focus while visible refreshes old quota without waiting for analytics',
    (tester) async {
      _desktopSurface(tester);
      final clock = _Clock();
      final initial = _quota(
        asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
      );
      final refreshed = _quota(free: 70);
      final pending = Completer<List<ProviderQuota>>();
      final jobs = <_AnalyticsJob>[];
      var calls = 0;
      await tester.pumpWidget(
        _dashboard(
          clock,
          () => ++calls == 1 ? Future.value([initial]) : pending.future,
          analyticsJobStarter: (_) {
            final job = _AnalyticsJob();
            jobs.add(job);
            return job;
          },
        ),
      );
      await tester.pumpAndSettle();
      final window = _window(tester);
      clock.advance(const Duration(minutes: 4, seconds: 59));
      window.onWindowEvent('focus');
      expect(calls, 1);
      jobs.single.done.complete(const DesktopAnalyticsData());
      await tester.pumpAndSettle();

      // Finishing advice does not reset the quota attempt's five-minute age.
      clock.advance(const Duration(seconds: 1));
      window.onWindowEvent('focus');
      await tester.pump();
      expect(calls, 2);
      expect(find.byTooltip('Refreshing quotas'), findsOneWidget);
      pending.complete([refreshed]);
      await tester.pumpAndSettle();
      expect(_cardText('70% free'), findsOneWidget);
      final card = tester.widget<ProviderTile>(find.byType(ProviderTile));
      expect(card.quota.asOf, refreshed.asOf);
      expect(card.quota.account, initial.account);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(jobs, hasLength(2));
      expect(jobs.last.done.isCompleted, isFalse);
      expect(find.textContaining('Recent usage checks pending'), findsWidgets);
      _returnEvents(window);
      await tester.pump();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('startup and return bursts share one active collection', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    final first = Completer<List<ProviderQuota>>();
    final second = Completer<List<ProviderQuota>>();
    var calls = 0;
    var active = 0;
    var peak = 0;
    await tester.pumpWidget(
      _dashboard(clock, () {
        calls++;
        active++;
        if (active > peak) peak = active;
        return (calls == 1 ? first.future : second.future).whenComplete(
          () => active--,
        );
      }),
    );
    final window = _window(tester);
    clock.advance(const Duration(minutes: 6));
    _returnEvents(window);
    await tester.pump();
    expect(calls, 1);
    first.complete([_quota()]);
    await tester.pumpAndSettle();
    _returnEvents(window);
    expect(calls, 1);

    clock.advance(const Duration(minutes: 5));
    // The old frame still exposes the actual manual control for this burst.
    window.onWindowEvent('focus');
    await tester.tap(find.byTooltip('Refresh now'));
    _returnEvents(window);
    await tester.pump();
    expect(calls, 2);
    expect(peak, 1);
    second.complete([_quota(free: 70)]);
    await tester.pumpAndSettle();
    _returnEvents(window);
    await tester.pump();
    expect(calls, 2);
    expect(active, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    _returnEvents(window);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('display pause recovers visible quota but never hidden quota', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    var calls = 0;
    await tester.pumpWidget(
      _dashboard(clock, () async {
        calls++;
        return [_quota()];
      }),
    );
    await tester.pumpAndSettle();
    final window = _window(tester);
    // A short suspension does not override the five-minute quota age.
    clock.advance(const Duration(minutes: 4));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 1);
    // Exactly two minutes is not a pause signal.
    clock.advance(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 1);
    clock.advance(const Duration(minutes: 2, seconds: 1));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 2);

    window.onWindowEvent('hide');
    clock.advance(const Duration(minutes: 6));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 2);
    clock.advance(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 2);
    window.onWindowEvent('show');
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ordinary display ticks do not create a five-minute poll loop', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    var calls = 0;
    await tester.pumpWidget(
      _dashboard(clock, () async {
        calls++;
        return [_quota()];
      }),
    );
    await tester.pumpAndSettle();
    for (var tick = 0; tick < 12; tick++) {
      clock.advance(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
    }
    expect(calls, 1);
    _window(tester).onWindowEvent('focus');
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'smart timer reads renewed binding quota while continuously visible',
    (tester) async {
      _desktopSurface(tester);
      final clock = _Clock();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final shorter = QuotaWindow(
        label: '5h',
        usedPercent: 5,
        resetsAt: now + 5 * 3600,
      );
      final spent = _quota(
        free: 0,
        weeklyReset: now + 30,
        shorterWindow: shorter,
      );
      final renewed = _quota(
        free: 95,
        weeklyReset: now + 7 * 86400,
        shorterWindow: shorter,
      );
      var calls = 0;
      await tester.pumpWidget(
        _dashboard(
          clock,
          () async => [++calls == 1 ? spent : renewed],
          cadence: Cadence.smart,
        ),
      );
      await tester.pumpAndSettle();
      expect(_cardText('weekly spent'), findsOneWidget);
      // No focus event, no pause gap, and no manual control. The existing smart
      // cadence already schedules a read at this imminent reset.
      clock.advance(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      expect(calls, 1);
      clock.advance(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(_cardText('weekly spent'), findsNothing);
      expect(_cardText('95% free'), findsWidgets);
      expect(
        tester.widget<ProviderTile>(find.byType(ProviderTile)).quota,
        same(renewed),
      );
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final focus in [false, true]) {
    testWidgets(
      'reset crossed during a visible pause, focus=$focus, shares one read',
      (tester) async {
        _desktopSurface(tester);
        final clock = _Clock();
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final spent = _quota(free: 0, weeklyReset: now + 5 * 60);
        final renewed = _quota(free: 95, weeklyReset: now + 7 * 86400);
        final pending = Completer<List<ProviderQuota>>();
        var calls = 0;
        await tester.pumpWidget(
          _dashboard(
            clock,
            () => ++calls == 1 ? Future.value([spent]) : pending.future,
            cadence: Cadence.smart,
          ),
        );
        await tester.pumpAndSettle();
        expect(_cardText('weekly spent'), findsOneWidget);
        clock.advance(const Duration(minutes: 6));
        final window = _window(tester);
        if (focus) window.onWindowEvent('focus');
        // The display pause check and original 60-second smart timer can both
        // fire while the same post-pause quota request is pending.
        await tester.pump(const Duration(minutes: 1, seconds: 1));
        expect(calls, 2);
        pending.complete([renewed]);
        await tester.pumpAndSettle();
        expect(_cardText('weekly spent'), findsNothing);
        expect(_cardText('95% free'), findsOneWidget);
        expect(find.byTooltip('Refresh now'), findsOneWidget);
        window.onWindowEvent('focus');
        await tester.pump();
        expect(calls, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'failed attempts preserve backoff while manual refresh recovers',
    (tester) async {
      _desktopSurface(tester);
      final clock = _Clock();
      var calls = 0;
      await tester.pumpWidget(
        _dashboard(clock, () async {
          calls++;
          if (calls <= 2) throw StateError('synthetic read failure');
          return [_quota()];
        }, cadence: Cadence.smart),
      );
      await tester.pumpAndSettle();
      final window = _window(tester);
      clock.advance(const Duration(minutes: 59, seconds: 59));
      _returnEvents(window);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(calls, 1);
      clock.advance(const Duration(seconds: 1));
      window.onWindowEvent('focus');
      await tester.pumpAndSettle();
      expect(calls, 2);

      // The second failed attempt moves the smart schedule to six hours.
      clock.advance(const Duration(hours: 5, minutes: 59));
      _returnEvents(window);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.textContaining('Refresh failed'), findsNothing);
      clock.advance(const Duration(minutes: 5));
      window.onWindowEvent('focus');
      await tester.pumpAndSettle();
      expect(calls, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'throttle retry deadline and scheduled timer coalesce on return',
    (tester) async {
      _desktopSurface(tester);
      final clock = _Clock();
      final pending = Completer<List<ProviderQuota>>();
      var calls = 0;
      await tester.pumpWidget(
        _dashboard(
          clock,
          () => ++calls == 1
              ? Future.value([
                  _quota(provider: 'claude'),
                  _quota(
                    pipeHealth: providerPipeHealthThrottled,
                    retryAfterSeconds: 45 * 60,
                    stale: true,
                  ),
                ])
              : pending.future,
          cadence: Cadence.smart,
        ),
      );
      await tester.pumpAndSettle();
      final window = _window(tester);
      clock.advance(const Duration(minutes: 44, seconds: 59));
      _returnEvents(window);
      await tester.pump(const Duration(minutes: 44));
      expect(calls, 1);
      clock.advance(const Duration(seconds: 1));
      window.onWindowEvent('focus');
      // Elapse the original scheduled timer while the return read is pending.
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      _returnEvents(window);
      expect(calls, 2);
      pending.complete([_quota(free: 70)]);
      await tester.pumpAndSettle();
      expect(_cardText('70% free'), findsOneWidget);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'smart cadence observes weekly-only changes while still visible',
    (tester) async {
      _desktopSurface(tester);
      final clock = _Clock();
      var calls = 0;
      await tester.pumpWidget(
        _dashboard(clock, () async {
          calls++;
          return [
            _quota(
              free: calls == 1 ? 5 : 70,
              weeklyReset:
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 5 * 86400,
            ),
          ];
        }, cadence: Cadence.smart),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(_cardText('5% free'), findsOneWidget);
      await tester.pump(const Duration(minutes: 4, seconds: 59));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(_cardText('70% free'), findsOneWidget);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a just-expired pool is checked again without manual refresh', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    var calls = 0;
    await tester.pumpWidget(
      _dashboard(clock, () async {
        calls++;
        return [
          _quota(
            free: calls == 1 ? 0 : 95,
            weeklyReset:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 +
                (calls == 1 ? -1 : 86400),
          ),
        ];
      }, cadence: Cadence.smart),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(_cardText('95% free'), findsNothing);
    await tester.pump(const Duration(seconds: 29));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(_cardText('95% free'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Retry-After alone protects the selected smart schedule', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    var calls = 0;
    await tester.pumpWidget(
      _dashboard(clock, () async {
        calls++;
        return [_quota(retryAfterSeconds: calls == 1 ? 3600 : null)];
      }, cadence: Cadence.smart),
    );
    await tester.pumpAndSettle();
    final window = _window(tester);
    clock.advance(const Duration(minutes: 59, seconds: 59));
    _returnEvents(window);
    expect(calls, 1);
    clock.advance(const Duration(seconds: 1));
    window.onWindowEvent('focus');
    await tester.pumpAndSettle();
    expect(calls, 2);
    clock.advance(const Duration(minutes: 5));
    window.onWindowEvent('focus');
    await tester.pumpAndSettle();
    expect(calls, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final cadence in [Cadence.m15, Cadence.h1]) {
    testWidgets('fixed $cadence honors an uncovered Retry-After', (
      tester,
    ) async {
      _desktopSurface(tester);
      final clock = _Clock();
      var calls = 0;
      await tester.pumpWidget(
        _dashboard(clock, () async {
          calls++;
          return [_quota(retryAfterSeconds: calls == 1 ? 7200 : null)];
        }, cadence: cadence),
      );
      await tester.pumpAndSettle();
      clock.advance(const Duration(hours: 1, minutes: 59, seconds: 59));
      await tester.pump(const Duration(hours: 1, minutes: 59, seconds: 59));
      _returnEvents(_window(tester));
      expect(calls, 1);
      clock.advance(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('extreme Retry-After cannot spin desktop refresh', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    var calls = 0;
    await tester.pumpWidget(
      _dashboard(clock, () async {
        calls++;
        return [_quota(retryAfterSeconds: 0x7fffffffffffffff, stale: true)];
      }, cadence: Cadence.smart),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    clock.advance(const Duration(days: 3));
    await tester.pump(const Duration(days: 3));
    _returnEvents(_window(tester));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing cadence updates the protected due time', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    var calls = 0;
    await tester.pumpWidget(
      _dashboard(clock, () async {
        calls++;
        throw StateError('synthetic read failure');
      }, cadence: Cadence.smart),
    );
    await tester.pumpAndSettle();
    clock.advance(const Duration(minutes: 1));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final cadence = find.byKey(const ValueKey('settings-cadence-15m'));
    await tester.ensureVisible(cadence);
    await tester.tap(cadence);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    final window = _window(tester);
    clock.advance(const Duration(minutes: 14, seconds: 59));
    _returnEvents(window);
    expect(calls, 1);
    clock.advance(const Duration(seconds: 1));
    window.onWindowEvent('focus');
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in ['screenshot', 'readiness']) {
    testWidgets('$mode automation does not add return or pause reads', (
      tester,
    ) async {
      _desktopSurface(tester);
      final clock = _Clock();
      var calls = 0;
      await tester.pumpWidget(
        _dashboard(
          clock,
          () async {
            calls++;
            return [_quota()];
          },
          screenshotCapture: mode == 'screenshot',
          readinessProbe: mode == 'readiness',
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      clock.advance(const Duration(minutes: 6));
      _returnEvents(_window(tester));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(calls, 1);
      // Existing explicit refresh remains independent of automatic recovery.
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('demo startup and return events never collect real quota', (
    tester,
  ) async {
    _desktopSurface(tester);
    final clock = _Clock();
    var calls = 0;
    await tester.pumpWidget(
      _dashboard(clock, () async {
        calls++;
        return [_quota()];
      }, demoMode: true),
    );
    await tester.pumpAndSettle();
    clock.advance(const Duration(minutes: 6));
    _returnEvents(_window(tester));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
