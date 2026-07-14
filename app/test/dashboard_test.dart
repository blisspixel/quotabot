import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/fleet.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/provider_display.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/webhook.dart';

Widget _wrap(Widget child, {bool disableAnimations = false}) {
  final chrome = AppChromeTheme.forSpec(Brightness.dark, appThemeDark);
  return MaterialApp(
    theme: ThemeData.dark().copyWith(extensions: [chrome]),
    builder: disableAnimations
        ? (context, built) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: built!,
          )
        : null,
    home: child,
  );
}

Future<void> _useDesktopSurface(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(700, 1800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _selectMenuValue(WidgetTester tester, String value) async {
  final menu = tester.widget<PopupMenuButton<String>>(
    find.byType(PopupMenuButton<String>),
  );
  menu.onSelected!(value);
  await tester.pumpAndSettle();
}

ProviderQuota _historyPoint(double usedPercent) => ProviderQuota(
  provider: 'claude',
  displayName: 'Claude',
  account: 'default',
  asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  windows: [QuotaWindow(label: '5h', usedPercent: usedPercent)],
);

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  tearDown(() {
    appThemeSpec.value = appThemeSystem;
    textScale.value = 1;
  });

  test('webhook delivery status never exposes raw transport errors', () {
    expect(
      webhookDeliveryStatus(
        const WebhookResult(ok: false, error: 'secret-bearing-url'),
      ),
      'Last delivery failed',
    );
    expect(
      webhookDeliveryStatus(const WebhookResult(ok: false, statusCode: 503)),
      'Last delivery failed (HTTP 503)',
    );
    expect(
      webhookDeliveryStatus(const WebhookResult(ok: true, statusCode: 204)),
      'Last delivery succeeded',
    );
  });

  test('pool headroom excludes stale, drifted, and invalid-time evidence', () {
    const now = 1782000000;
    final trusted = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'default',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    final stale = ProviderQuota.fromJson({...trusted.toJson(), 'stale': true});
    final drifted = trusted.withProviderDrift(
      'weekly usage fell without a reset',
      now,
    );
    final missingTime = ProviderQuota.fromJson({
      ...trusted.toJson(),
      'as_of': 0,
    });
    final future = ProviderQuota.fromJson({
      ...trusted.toJson(),
      'as_of': now + kQuotaEvidenceClockSkewSeconds + 1,
    });

    expect(
      trustedPoolHeadroom([trusted, stale, drifted, missingTime, future], now),
      80,
    );
    expect(
      trustedPoolHeadroom([stale, drifted, missingTime, future], now),
      isNull,
    );
  });

  test('preference load warnings preserve the actual failure class', () {
    final invalid = preferenceLoadWarning(
      const PrefsLoadResult(
        prefs: Prefs(),
        failure: PrefsLoadFailure.invalidData,
        retainedExistingFile: true,
      ),
    );
    final unsupported = preferenceLoadWarning(
      const PrefsLoadResult(
        prefs: Prefs(),
        failure: PrefsLoadFailure.unsupportedFile,
        retainedExistingFile: true,
      ),
    );

    expect(invalid, contains('invalid'));
    expect(invalid, isNot(contains('protected')));
    expect(unsupported, contains('unsupported'));
    expect(
      preferenceLoadWarning(const PrefsLoadResult(prefs: Prefs())),
      isNull,
    );
  });

  testWidgets('dashboard exposes a bounded webhook delivery failure', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    var posts = 0;
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(
            enableNotifications: false,
            webhookUrl: 'http://127.0.0.1:9000/quota',
          ),
          demoMode: false,
          collector: () async => [
            ProviderQuota(
              provider: 'claude',
              displayName: 'Claude',
              account: 'test',
              asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              windows: [QuotaWindow(label: '5h', usedPercent: 100)],
            ),
          ],
          alertPoster: (url, payload, {required allowExternal}) async {
            posts++;
            return const WebhookResult(
              ok: false,
              statusCode: 503,
              error: 'secret-bearing-url',
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(posts, 1);
    await tester.tap(find.byTooltip('Menu: profiles, providers, and settings'));
    await tester.pumpAndSettle();
    expect(find.text('Alert webhook: delivery failed'), findsOneWidget);

    await tester.tap(find.text('Alert webhook: delivery failed'));
    await tester.pumpAndSettle();
    expect(find.text('Last delivery failed (HTTP 503)'), findsOneWidget);
    expect(find.textContaining('secret-bearing-url'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Menu: profiles, providers, and settings'));
    await tester.pumpAndSettle();
    expect(find.text('Alert webhook: delivery failed'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'setup labels legacy provider drift accessibly in ${brightness.name}',
      (tester) async {
        await _useDesktopSurface(tester);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final legacy =
            ProviderQuota(
                  provider: 'claude',
                  displayName: 'Claude',
                  account: 'test',
                  asOf: now - 3600,
                  windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
                )
                .withSuspect('legacy concern')
                .asProviderDriftQuarantine(
                  'unresolved legacy provider drift: legacy concern',
                  now - 30,
                );
        final chrome = AppChromeTheme.forSpec(brightness, appThemeSystem);
        final theme = ThemeData(
          brightness: brightness,
        ).copyWith(extensions: [chrome]);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Dashboard.test(
              prefs: const Prefs(enableNotifications: false),
              demoMode: false,
              collector: () async => [legacy],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Setup and help'));
        await tester.pumpAndSettle();

        final label = tester.widget<Text>(find.text('provider drift'));
        final dialogContext = tester.element(find.byType(Dialog));
        final dialog = tester.widget<Dialog>(find.byType(Dialog));
        final background =
            dialog.backgroundColor ??
            Theme.of(dialogContext).dialogTheme.backgroundColor ??
            Theme.of(dialogContext).colorScheme.surface;
        expect(
          _contrastRatio(label.style!.color!, background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.text('no live data'),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed secure preference save stays visible and actionable', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    var saveAttempts = 0;
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(),
          prefsSaver: (_) async {
            saveAttempts++;
            throw const PrefsStorageException();
          },
        ),
      ),
    );
    await tester.pump();

    await _selectMenuValue(tester, 'webhook');
    await tester.enterText(
      find.byType(TextField),
      'http://127.0.0.1:9000/quota',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(saveAttempts, 1);
    expect(
      find.text('Webhook not saved (storage unavailable)'),
      findsOneWidget,
    );
    expect(
      find.text('Settings not saved (storage unavailable)'),
      findsOneWidget,
    );
  });

  testWidgets('compact mode keeps a failed preference save visible', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(),
          prefsSaver: (_) async => throw const PrefsStorageException(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Collapse'));
    await tester.pumpAndSettle();

    const warning = 'Settings not saved (storage unavailable)';
    final warningTooltip = find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == warning,
    );
    expect(find.byTooltip('Expand'), findsOneWidget);
    expect(warningTooltip, findsOneWidget);
    expect(
      find.descendant(
        of: warningTooltip,
        matching: find.byIcon(Icons.warning_amber_rounded),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(warning), findsOneWidget);
  });

  testWidgets('demo dashboard exercises quota, compact, and analytics views', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    await tester.pumpWidget(
      _wrap(const Dashboard.test(prefs: Prefs(showAccounts: true))),
    );
    await tester.pump();

    expect(find.text('Quota'), findsOneWidget);
    expect(find.byType(ProviderTile), findsNWidgets(7));
    expect(find.text('Claude'), findsWidgets);
    expect(find.byIcon(Icons.alt_route_rounded), findsOneWidget);

    await tester.tap(find.byType(ProviderTile).first);
    await tester.pump();
    expect(find.byType(InsightsPanel), findsOneWidget);

    await tester.tap(find.byTooltip('Quota analytics'));
    await tester.pump();
    expect(find.text('Analytics'), findsOneWidget);
    expect(find.byType(FleetScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back to quotas'));
    await tester.pump();
    expect(find.text('Quota'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse'));
    await tester.pump();
    expect(find.byTooltip('Expand'), findsOneWidget);
    expect(find.byType(ProviderTile), findsNothing);

    await tester.tap(find.byTooltip('Expand'));
    await tester.pump();
    expect(find.byType(ProviderTile), findsNWidgets(7));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('app applies theme and text-scale changes to the full subtree', (
    tester,
  ) async {
    late BuildContext appContext;
    textScale.value = TextSize.large.scale;
    appThemeSpec.value = appThemeLight;

    await tester.pumpWidget(
      QuotaBotApp.test(
        prefs: const Prefs(),
        testHome: Builder(
          builder: (context) {
            appContext = context;
            return const Text('ready');
          },
        ),
      ),
    );
    await tester.pump();

    expect(Theme.of(appContext).brightness, Brightness.light);
    expect(MediaQuery.textScalerOf(appContext).scale(10), 11.5);
    expect(Theme.of(appContext).textTheme.bodyMedium?.fontFeatures, isNotEmpty);

    appThemeSpec.value = appThemeHacker;
    await tester.pumpAndSettle();
    expect(Theme.of(appContext).brightness, Brightness.dark);
    expect(
      Theme.of(appContext).extension<AppChromeTheme>()?.accent,
      const Color(0xFF39FF14),
    );
  });

  testWidgets('dashboard menus update local state without host side effects', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    await tester.pumpWidget(_wrap(const Dashboard.test(prefs: Prefs())));
    await tester.pump();

    await tester.tap(find.byTooltip('Menu: profiles, providers, and settings'));
    await tester.pumpAndSettle();
    expect(find.text('Alphabetical'), findsOneWidget);
    expect(find.text('Alert webhook...'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    for (final value in [
      'sort:alpha',
      'sort:avail',
      'sort:used',
      'sort:default',
      'cad:m15',
      'cad:h1',
      'cad:smart',
      'always_on_top',
      'show_in_taskbar',
      'notifications',
      'show_accounts',
      'text:small',
      'text:large',
      'text:medium',
    ]) {
      await _selectMenuValue(tester, value);
    }

    await _selectMenuValue(tester, 'profiles:manage');
    expect(find.text('Profiles'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    await _selectMenuValue(tester, 'webhook');
    await tester.enterText(
      find.byType(TextField),
      'https://alerts.example.test/quota',
    );
    await tester.pump();
    expect(find.textContaining('not loopback'), findsOneWidget);
    final blockedSave = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Save'),
    );
    expect(blockedSave.onPressed, isNull);
    await tester.tap(
      find.widgetWithText(
        CheckboxListTile,
        'Allow an external (non-loopback) host',
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Setup and help'));
    await tester.pumpAndSettle();
    expect(find.text('Providers'), findsOneWidget);
    await tester.tap(find.byTooltip('Close providers'));
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(ProviderTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set up Claude'));
    await tester.pumpAndSettle();
    expect(find.text('Set up Claude'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(ProviderTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide Claude'));
    await tester.pumpAndSettle();
    expect(find.byType(ProviderTile), findsNWidgets(6));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('initial refresh failure leaves an actionable dashboard', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final failure = Completer<List<ProviderQuota>>();
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false),
          demoMode: false,
          collector: () => failure.future,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(QuotaLoadingIndicator), findsOneWidget);

    failure.completeError(TimeoutException('private-token-value'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Quota'), findsOneWidget);
    expect(find.textContaining('timed out'), findsOneWidget);
    expect(find.textContaining('retrying automatically'), findsOneWidget);
    expect(find.textContaining('private-token-value'), findsNothing);
    expect(find.byType(ProviderTile), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('injected refresh renders without reading host account state', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final collected = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'test@example.com',
      asOf: now,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 25, resetsAt: now + 86400),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(),
          demoMode: false,
          collector: () async => [collected],
          testProfiles: [QuotaProfile.defaultProfile()],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(ProviderTile), findsOneWidget);
    expect(find.text('Claude'), findsWidgets);
    expect(find.textContaining('75% free'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('loading indicator honors reduced motion and repaints safely', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const QuotaLoadingIndicator(
          color: Colors.green,
          trackColor: Colors.grey,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.descendant(
        of: find.byType(QuotaLoadingIndicator),
        matching: find.byType(AnimatedBuilder),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _wrap(
        const QuotaLoadingIndicator(
          size: 42,
          color: Colors.orange,
          trackColor: Colors.black,
        ),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(QuotaLoadingIndicator),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNothing,
    );
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('window bars cover ready, reset, and unbounded states', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final view in [
      WinView('weekly', 0, true, now - 1),
      WinView('5h', 47, false, now + 3660),
      const WinView('baseline', 82, false, null),
    ]) {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 500,
            child: WindowBar(view: view, muted: Colors.grey, fg: Colors.white),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('82% free'), findsOneWidget);
  });

  testWidgets('insights panel renders reliability, trend, pace, and heatmap', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final history = [_historyPoint(20), _historyPoint(45), _historyPoint(70)];
    final heatmap = List<List<double?>>.generate(
      7,
      (day) => List<double?>.generate(
        24,
        (hour) => hour < 2 ? (day * 10 + hour).toDouble() : null,
      ),
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    for (final testCase in [
      (0.99, -2.0, 'almost never runs out'),
      (0.95, 2.0, 'rarely runs out'),
      (0.80, -2.0, 'sometimes gets tight'),
      (0.50, 2.0, 'often maxed out'),
    ]) {
      await tester.pumpWidget(
        _wrap(
          InsightsPanel(
            insights: Insights(
              samples: 50,
              spanDays: 10,
              mean: 55,
              p10: 20,
              p90: 90,
              reliability: testCase.$1,
              trendPerDay: testCase.$2,
              trendConfidence: 0.9,
              burnPerHour: 20,
            ),
            history: history,
            heatmap: heatmap,
            bindingRemaining: 10,
            bindingResetsAt: now + 7200,
            muted: Colors.grey,
            fg: Colors.white,
            dark: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining(testCase.$3), findsOneWidget);
      expect(find.textContaining('usually 20-90% free'), findsOneWidget);
      expect(find.textContaining('before reset'), findsOneWidget);
      expect(find.textContaining('free by hour'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
