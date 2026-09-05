import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_analytics.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/leases.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/profiles.dart';
import 'package:quotabot_collector/webhook.dart';

const _account = 'codex-refresh-fixture';

ProviderQuota _codex({
  required int asOf,
  required int weeklyReset,
  required double weeklyUsed,
  String account = _account,
  QuotaWindow? shorterWindow,
}) => ProviderQuota(
  provider: 'codex',
  displayName: 'Codex',
  account: account,
  plan: 'pro',
  asOf: asOf,
  sourceClass: ProviderSourceClass.authoritativeLive,
  windows: [
    ?shorterWindow,
    QuotaWindow(
      label: 'weekly',
      usedPercent: weeklyUsed,
      resetsAt: weeklyReset,
    ),
  ],
);

Widget _dashboard(
  Future<List<ProviderQuota>> Function() collect, {
  DesktopAnalyticsJobStarter? analyticsJobStarter,
  Duration analyticsDeadline = const Duration(seconds: 30),
  RouteLeaseStore leaseStore = const NoopRouteLeaseStore(),
  Prefs prefs = const Prefs(
    setupDone: true,
    enableNotifications: false,
    cadence: Cadence.h1,
  ),
  DesktopNotificationClient? notificationClient,
  AlertPoster? alertPoster,
}) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    extensions: [AppChromeTheme.forSpec(Brightness.dark, appThemeDark)],
  ),
  home: Dashboard.test(
    prefs: prefs,
    demoMode: false,
    collector: collect,
    analyticsJobStarter: analyticsJobStarter,
    analyticsDeadline: analyticsDeadline,
    leaseStore: leaseStore,
    notificationClient: notificationClient,
    alertPoster: alertPoster,
    prefsSaver: (_) async {},
  ),
);

void _desktopSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(340, 760);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Finder _cardText(String text) => find.descendant(
  of: find.byType(ProviderTile),
  matching: find.textContaining(text),
);

class _AnalyticsJob implements DesktopAnalyticsJob {
  final Completer<DesktopAnalyticsData?> done = Completer();
  int cancellations = 0;

  @override
  Future<DesktopAnalyticsData?> get completed => done.future;

  @override
  void cancel() => cancellations++;
}

class _NotificationProbe implements DesktopNotificationClient {
  final List<String> lowQuotaBodies = [];

  @override
  Future<List<DesktopPendingNotification>> pendingNotifications() async => [];

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String providerLabel,
    String? payload,
  }) async {
    if (title == 'Low quota') lowQuotaBodies.add(body);
  }

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required String providerLabel,
    required DateTime scheduledDate,
  }) async {}
}

Future<void> _toggleNotifications(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  final toggle = find.byKey(const ValueKey('settings-notifications'));
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('settings-close')));
  await tester.pumpAndSettle();
}

ProviderQuota _alternative(
  String provider,
  String name,
  int now,
  double free,
) => ProviderQuota(
  provider: provider,
  displayName: name,
  account: 'default',
  asOf: now,
  sourceClass: ProviderSourceClass.authoritativeLive,
  windows: [
    QuotaWindow(
      label: 'weekly',
      usedPercent: 100 - free,
      resetsAt: now + 86400,
    ),
  ],
);

void main() {
  testWidgets(
    'header refresh replaces Codex 95 percent with 70 and new capture evidence',
    (tester) async {
      _desktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final initial = _codex(
        asOf: now - 300,
        weeklyReset: now + 3 * 86400,
        weeklyUsed: 5,
      );
      final refreshed = _codex(
        asOf: now - 60,
        weeklyReset: now + 3 * 86400,
        weeklyUsed: 30,
      );
      final pending = Completer<List<ProviderQuota>>();
      var collections = 0;
      var activeCollections = 0;
      var peakCollections = 0;

      await tester.pumpWidget(
        _dashboard(() {
          collections++;
          activeCollections++;
          if (activeCollections > peakCollections) {
            peakCollections = activeCollections;
          }
          return (collections == 1 ? Future.value([initial]) : pending.future)
              .whenComplete(() => activeCollections--);
        }),
      );
      await tester.pumpAndSettle();
      expect(collections, 1);
      expect(_cardText('95% free'), findsOneWidget);
      await tester.tap(find.byType(ProviderTile));
      await tester.pumpAndSettle();
      expect(_cardText('captured 5m ago'), findsOneWidget);
      expect(_cardText('live | scope: whole account'), findsOneWidget);

      final refresh = find.byTooltip('Refresh now');
      // Two taps before the next frame exercise coalescing as well as the
      // disabled button shown after the frame rebuilds.
      await tester.tap(refresh);
      await tester.tap(refresh);
      await tester.pump();
      expect(collections, 2);
      expect(activeCollections, 1);
      expect(peakCollections, 1);
      final refreshing = find.byTooltip('Refreshing quotas');
      expect(refreshing, findsOneWidget);
      final disabled = tester.widget<InkWell>(
        find.descendant(of: refreshing, matching: find.byType(InkWell)),
      );
      expect(disabled.onTap, isNull);
      await tester.tap(refreshing);
      await tester.pump();
      expect(collections, 2);
      expect(_cardText('95% free'), findsOneWidget);
      expect(_cardText('captured 5m ago'), findsOneWidget);

      pending.complete([refreshed]);
      await tester.pumpAndSettle();

      expect(find.byType(ProviderTile), findsOneWidget);
      final card = tester.widget<ProviderTile>(find.byType(ProviderTile));
      expect(card.quota.account, _account);
      expect(card.quota.asOf, refreshed.asOf);
      expect(_cardText('70% free'), findsOneWidget);
      expect(_cardText('95% free'), findsNothing);
      expect(_cardText('captured 1m ago'), findsOneWidget);
      expect(_cardText('captured 5m ago'), findsNothing);
      expect(_cardText('live | scope: whole account'), findsOneWidget);
      expect(find.textContaining('Refresh failed'), findsNothing);
      expect(find.byTooltip('Refreshing quotas'), findsNothing);
      final enabled = tester.widget<InkWell>(
        find.descendant(
          of: find.byTooltip('Refresh now'),
          matching: find.byType(InkWell),
        ),
      );
      expect(enabled.onTap, isNotNull);
      expect(collections, 2);
      expect(activeCollections, 0);
      expect(peakCollections, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Codex refresh shows a spent weekly cap despite a healthy short window',
    (tester) async {
      _desktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final shorter = QuotaWindow(
        label: '5h',
        usedPercent: 5,
        resetsAt: now + 7200,
      );
      final initial = _codex(
        asOf: now - 300,
        weeklyReset: now + 3 * 86400,
        weeklyUsed: 30,
        shorterWindow: shorter,
      );
      final refreshed = _codex(
        asOf: now - 60,
        weeklyReset: now + 3 * 86400,
        weeklyUsed: 100,
        shorterWindow: shorter,
      );
      var collections = 0;
      await tester.pumpWidget(
        _dashboard(
          () async => [++collections == 1 ? initial : refreshed],
          analyticsJobStarter: (_) => _AnalyticsJob(),
        ),
      );
      await tester.pumpAndSettle();
      expect(_cardText('95% free'), findsOneWidget);
      expect(_cardText('70% free'), findsOneWidget);

      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();

      expect(collections, 2);
      expect(_cardText('weekly spent'), findsOneWidget);
      expect(_cardText('95% free'), findsNothing);
      expect(_cardText('70% free'), findsNothing);
      expect(find.textContaining('Next: Codex'), findsNothing);
      final card = tester.widget<ProviderTile>(find.byType(ProviderTile));
      expect(card.quota.account, _account);
      expect(card.quota.asOf, refreshed.asOf);
      expect(card.quota.windows, hasLength(2));
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('refresh preserves the profile selected while analytics waits', (
    tester,
  ) async {
    _desktopSurface(tester);
    const personalAccount =
        'credential:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const workAccount =
        'credential:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const personal = QuotaProfile(
      name: 'personal',
      accounts: {
        'codex': {personalAccount},
      },
    );
    const work = QuotaProfile(
      name: 'work',
      accounts: {
        'codex': {workAccount},
      },
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final initial = [
      _codex(
        asOf: now - 300,
        weeklyReset: now + 86400,
        weeklyUsed: 5,
        account: personalAccount,
      ),
      _codex(
        asOf: now - 300,
        weeklyReset: now + 86400,
        weeklyUsed: 25,
        account: workAccount,
      ),
    ];
    final refreshed = [
      _codex(
        asOf: now - 60,
        weeklyReset: now + 86400,
        weeklyUsed: 10,
        account: personalAccount,
      ),
      _codex(
        asOf: now - 60,
        weeklyReset: now + 86400,
        weeklyUsed: 30,
        account: workAccount,
      ),
    ];
    final analyticsPending = _AnalyticsJob();
    var collections = 0;
    var analyticsReads = 0;
    Prefs? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: [AppChromeTheme.forSpec(Brightness.dark, appThemeDark)],
        ),
        home: Dashboard.test(
          prefs: const Prefs(
            setupDone: true,
            enableNotifications: false,
            cadence: Cadence.h1,
            activeProfile: 'personal',
          ),
          demoMode: false,
          testProfiles: [QuotaProfile.defaultProfile(), personal, work],
          prefsSaver: (prefs) async => saved = prefs,
          collector: () async => ++collections == 1 ? initial : refreshed,
          analyticsJobStarter: (request) {
            analyticsReads++;
            if (analyticsReads == 2) {
              expect(request.targets.map((target) => target.quota), refreshed);
              return analyticsPending;
            }
            return _AnalyticsJob()..done.complete(const DesktopAnalyticsData());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_cardText('95% free'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh now'));
    await tester.pumpAndSettle();
    expect(collections, 2);
    expect(analyticsReads, 2);
    expect(find.byTooltip('Refresh now'), findsOneWidget);
    expect(_cardText('90% free'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    expect(saved?.activeProfile, 'work');
    expect(find.text('Work'), findsOneWidget);
    expect(_cardText('70% free'), findsOneWidget);

    analyticsPending.done.complete(const DesktopAnalyticsData());
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsNothing);
    expect(find.byType(ProviderTile), findsOneWidget);
    final card = tester.widget<ProviderTile>(find.byType(ProviderTile));
    expect(card.quota.account, workAccount);
    expect(card.quota.asOf, refreshed.last.asOf);
    expect(_cardText('70% free'), findsOneWidget);
    expect(_cardText('75% free'), findsNothing);
    expect(_cardText('90% free'), findsNothing);
    expect(saved?.activeProfile, 'work');
    expect(find.byTooltip('Refresh now'), findsOneWidget);
    expect(collections, 2);
    expect(analyticsReads, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'quota publishes before analytics and only the newest history applies',
    (tester) async {
      _desktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final snapshots = [
        for (final used in [5.0, 30.0, 40.0])
          _codex(asOf: now, weeklyReset: now + 86400, weeklyUsed: used),
      ];
      final jobs = <_AnalyticsJob>[];
      final requested = <ProviderQuota>[];
      var collections = 0;
      await tester.pumpWidget(
        _dashboard(
          () async => [snapshots[collections++]],
          analyticsJobStarter: (request) {
            requested.add(request.targets.single.quota);
            final job = _AnalyticsJob();
            jobs.add(job);
            return job;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(_cardText('95% free'), findsOneWidget);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(find.text('Recent usage checks pending'), findsOneWidget);
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();
      expect(_cardText('70% free'), findsOneWidget);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();
      expect(_cardText('60% free'), findsOneWidget);
      expect(jobs, hasLength(1));
      expect(collections, 3);

      const key = 'codex|$_account';
      jobs.first.done.complete(
        const DesktopAnalyticsData(
          insights: {key: Insights(samples: 2, spanDays: 1, mean: 99)},
        ),
      );
      await tester.pumpAndSettle();
      expect(jobs, hasLength(2));
      expect(requested, [snapshots.first, snapshots.last]);
      var tile = tester.widget<ProviderTile>(find.byType(ProviderTile));
      expect(tile.quota, snapshots.last);
      expect(tile.insights, isNull);
      expect(find.text('Recent usage checks pending'), findsOneWidget);

      const latest = Insights(samples: 3, spanDays: 1, mean: 60);
      jobs.last.done.complete(
        const DesktopAnalyticsData(insights: {key: latest}),
      );
      await tester.pumpAndSettle();
      tile = tester.widget<ProviderTile>(find.byType(ProviderTile));
      expect(tile.quota, snapshots.last);
      expect(tile.insights, same(latest));
      expect(_cardText('60% free'), findsOneWidget);
      expect(find.text('Recent usage checks pending'), findsNothing);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'analytics failure keeps quota fresh and lease deductions explicit',
    (tester) async {
      _desktopSurface(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final quota = _codex(asOf: now, weeklyReset: now + 86400, weeklyUsed: 30);
      final leases = InMemoryRouteLeaseStore(idFactory: () => 'fixture-lease');
      leases.reserve(
        provider: 'codex',
        account: _account,
        now: now,
        leaseSeconds: 300,
        weightPercent: 20,
      );
      final job = _AnalyticsJob();
      await tester.pumpWidget(
        _dashboard(
          () async => [quota],
          analyticsJobStarter: (_) => job,
          leaseStore: leases,
        ),
      );
      await tester.pumpAndSettle();
      expect(_cardText('70% free'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message?.contains('50% after leases') == true &&
              widget.message?.contains('adjustments are pending') == true,
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Quota analytics'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Loading history and recent usage.'),
        findsOneWidget,
      );
      expect(find.textContaining('No routed requests'), findsNothing);
      job.done.completeError(StateError('synthetic private analytics path'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('History and recent usage are unavailable.'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic private'), findsNothing);
      await tester.tap(find.byTooltip('Back to quotas'));
      await tester.pumpAndSettle();
      final tile = tester.widget<ProviderTile>(find.byType(ProviderTile));
      expect(tile.quota, same(quota));
      expect(tile.quota.stale, isFalse);
      expect(find.text('Recent usage checks unavailable'), findsOneWidget);
      expect(find.textContaining('Refresh failed'), findsNothing);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message?.contains('50% after leases') == true &&
              widget.message?.contains('adjustments are unavailable') == true,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed collection invalidates late analytics and remains unroutable',
    (tester) async {
      _desktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final quota = _codex(asOf: now, weeklyReset: now + 86400, weeklyUsed: 30);
      final job = _AnalyticsJob();
      var collections = 0;
      await tester.pumpWidget(
        _dashboard(() async {
          if (++collections == 1) return [quota];
          throw StateError('synthetic read failure');
        }, analyticsJobStarter: (_) => job),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();
      expect(job.cancellations, 1);
      expect(find.textContaining('Next: Codex'), findsNothing);
      job.done.complete(
        const DesktopAnalyticsData(
          insights: {
            'codex|$_account': Insights(samples: 2, spanDays: 1, mean: 99),
          },
        ),
      );
      await tester.pumpAndSettle();
      final tile = tester.widget<ProviderTile>(find.byType(ProviderTile));
      expect(tile.quota.stale, isTrue);
      expect(tile.insights, isNull);
      expect(_cardText('70% last known'), findsOneWidget);
      expect(find.text('Recent usage checks unavailable'), findsOneWidget);
      expect(find.textContaining('Next: Codex'), findsNothing);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'dashboard disposal cancels pending analytics without late UI work',
    (tester) async {
      _desktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final job = _AnalyticsJob();
      await tester.pumpWidget(
        _dashboard(
          () async => [
            _codex(asOf: now, weeklyReset: now + 86400, weeklyUsed: 30),
          ],
          analyticsJobStarter: (_) => job,
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(job.cancellations, 1);
      job.done.complete(const DesktopAnalyticsData());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending and unavailable analytics keep alerts timely without alternatives',
    (tester) async {
      _desktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      var weeklyUsed = 100.0;
      var collections = 0;
      final jobs = <_AnalyticsJob>[];
      final notifications = _NotificationProbe();
      final posts = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        _dashboard(
          () async {
            collections++;
            return [
              _codex(
                asOf: now,
                weeklyReset: now + 86400,
                weeklyUsed: weeklyUsed,
              ),
              _alternative('claude', 'Claude', now, 70),
            ];
          },
          prefs: const Prefs(
            setupDone: true,
            enableNotifications: true,
            cadence: Cadence.h1,
            webhookUrl: 'http://127.0.0.1:9000/fixture',
          ),
          analyticsDeadline: const Duration(seconds: 2),
          analyticsJobStarter: (_) {
            final job = _AnalyticsJob();
            jobs.add(job);
            return job;
          },
          notificationClient: notifications,
          alertPoster: (_, payload, {required allowExternal}) async {
            posts.add(payload);
            return const WebhookResult(ok: true, statusCode: 204);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Recent usage checks pending'), findsOneWidget);
      expect(find.byTooltip('Refresh now'), findsOneWidget);
      expect(notifications.lowQuotaBodies, ['Codex weekly at 0% free']);
      expect(posts, hasLength(1));
      expect(jobs.single.done.isCompleted, isFalse);

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Recent usage checks unavailable'), findsOneWidget);
      expect(jobs.single.cancellations, 1);
      weeklyUsed = 10;
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      weeklyUsed = 100;
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pumpAndSettle();
      expect(find.text('Recent usage checks unavailable'), findsOneWidget);
      expect(posts, hasLength(2));
      expect(notifications.lowQuotaBodies, [
        'Codex weekly at 0% free',
        'Codex weekly at 0% free',
      ]);
      for (final post in posts) {
        expect(post['schema'], 'quotabot.alert.v1');
        expect(post['kind'], 'low_quota');
        expect(post['account'], _account);
        expect(post['window'], 'weekly');
        expect(post['free_percent'], 0);
        expect(post['as_of'], now);
        expect(post['route_is_local'], isFalse);
        expect(
          post.keys.where(
            (key) => key.startsWith('route_') && key != 'route_is_local',
          ),
          isEmpty,
        );
      }

      // The old worker must exit before matching checks can finish. Neither
      // completion nor a later steady-red alert check re-fires the crossing.
      jobs.single.done.complete(const DesktopAnalyticsData());
      await tester.pumpAndSettle();
      expect(jobs, hasLength(2));
      jobs.last.done.complete(const DesktopAnalyticsData());
      await tester.pumpAndSettle();
      expect(find.text('Recent usage checks pending'), findsNothing);
      expect(find.text('Recent usage checks unavailable'), findsNothing);
      await _toggleNotifications(tester);
      await _toggleNotifications(tester);
      expect(posts, hasLength(2));
      expect(notifications.lowQuotaBodies, hasLength(2));
      expect(collections, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('ready analytics keeps the adjusted native alert alternative', (
    tester,
  ) async {
    _desktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final notifications = _NotificationProbe();
    final job = _AnalyticsJob();
    await tester.pumpWidget(
      _dashboard(
        () async => [
          _codex(asOf: now, weeklyReset: now + 86400, weeklyUsed: 100),
          _alternative('claude', 'Claude', now, 70),
          _alternative('grok', 'Grok', now, 65),
        ],
        analyticsJobStarter: (_) => job,
        notificationClient: notifications,
      ),
    );
    await tester.pumpAndSettle();
    expect(notifications.lowQuotaBodies, isEmpty);
    job.done.complete(
      const DesktopAnalyticsData(
        burnStats: {'claude': BurnStat(perHour: 50, samples: 8)},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recent usage checks pending'), findsNothing);
    await _toggleNotifications(tester);
    expect(notifications.lowQuotaBodies, [
      'Codex weekly at 0% free - route next to Grok (65% free)',
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
