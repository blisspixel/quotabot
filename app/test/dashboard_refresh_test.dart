import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/profiles.dart';

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

Widget _dashboard(Future<List<ProviderQuota>> Function() collect) =>
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: [AppChromeTheme.forSpec(Brightness.dark, appThemeDark)],
      ),
      home: Dashboard.test(
        prefs: const Prefs(
          setupDone: true,
          enableNotifications: false,
          cadence: Cadence.h1,
        ),
        demoMode: false,
        collector: collect,
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
        _dashboard(() async => [++collections == 1 ? initial : refreshed]),
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
    final analyticsPending = Completer<void>();
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
          analyticsStorageCollector: (active) async {
            analyticsReads++;
            if (analyticsReads == 2) {
              expect(active, refreshed);
              await analyticsPending.future;
            }
            return (
              notices: const <AnalyticsStorageNotice>[],
              inventory: const AnalyticsIncidentInventory.suppressed(),
            );
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
    expect(find.byTooltip('Refreshing quotas'), findsOneWidget);
    expect(_cardText('95% free'), findsOneWidget);

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
    expect(_cardText('75% free'), findsOneWidget);

    analyticsPending.complete();
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
}
