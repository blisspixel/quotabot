import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/fleet.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/provider_display.dart';
import 'package:quotabot/quota_loading_indicator.dart';
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

List<ProviderQuota> _multiAccountClaude(int now) => [
  ProviderQuota(
    provider: 'claude',
    displayName: 'Claude',
    account: 'personal@example.com',
    asOf: now,
    windows: [
      QuotaWindow(label: 'weekly', usedPercent: 25, resetsAt: now + 86400),
    ],
  ),
  ProviderQuota(
    provider: 'claude',
    displayName: 'Claude',
    account: 'work@example.com',
    asOf: now,
    windows: [
      QuotaWindow(label: 'weekly', usedPercent: 50, resetsAt: now + 86400),
    ],
  ),
];

ProviderQuota _routeQuota(
  String provider,
  String displayName,
  int now, {
  double usedPercent = 20,
  List<ModelQuota> modelQuotas = const [],
}) => ProviderQuota(
  provider: provider,
  displayName: displayName,
  account: 'default',
  asOf: now,
  windows: [
    QuotaWindow(
      label: 'weekly',
      usedPercent: usedPercent,
      resetsAt: now + 86400,
    ),
  ],
  modelQuotas: modelQuotas,
);

List<String> _providerMenuValues(WidgetTester tester) => tester
    .widgetList<CheckedPopupMenuItem<String>>(
      find.byType(CheckedPopupMenuItem<String>),
    )
    .map((item) => item.value)
    .whereType<String>()
    .where((value) => value.startsWith('show:'))
    .toList();

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

  test('expanded mode keeps a viable desktop minimum width', () {
    expect(desktopMinimumWindowSize(compact: true), const Size(120, 40));
    expect(desktopMinimumWindowSize(compact: false), const Size(320, 120));
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

  testWidgets('desktop routing honors the active profile preference', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final snapshot = [
      _routeQuota('claude', 'Claude', now, usedPercent: 30),
      _routeQuota('codex', 'Codex', now, usedPercent: 40),
    ];
    const preferred = QuotaProfile(
      name: 'preferred',
      preferenceOrder: ['codex'],
    );

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(
            activeProfile: 'preferred',
            enableNotifications: false,
            setupDone: true,
          ),
          demoMode: false,
          collector: () async => snapshot,
          testProfiles: const [
            QuotaProfile(name: defaultProfileName),
            preferred,
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Next: Codex'), findsOneWidget);
  });

  testWidgets('empty profile explains a legacy Codex credential filter', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const legacy = QuotaProfile(
      name: 'legacy-codex',
      accounts: {
        'codex': {'plus'},
      },
    );

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(
            activeProfile: 'legacy-codex',
            enableNotifications: false,
            setupDone: true,
          ),
          demoMode: false,
          collector: () async => [
            ProviderQuota(
              provider: 'codex',
              displayName: 'Codex',
              account: 'account 01234567',
              asOf: now,
              windows: [
                QuotaWindow(
                  label: 'weekly',
                  usedPercent: 20,
                  resetsAt: now + 86400,
                ),
              ],
            ),
          ],
          testProfiles: const [
            QuotaProfile(name: defaultProfileName),
            legacy,
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('older Codex account filter'), findsOneWidget);
    expect(find.textContaining('current Codex credential'), findsOneWidget);
    expect(find.text('Edit profile'), findsOneWidget);
  });

  testWidgets('all-hidden fleet explains how to restore a provider', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(
            hidden: {'claude'},
            enableNotifications: false,
            setupDone: true,
          ),
          demoMode: false,
          collector: () async => [
            _routeQuota('claude', 'Claude', now, usedPercent: 20),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    const message =
        'All providers in Default are hidden. Use the Providers menu to show one.';
    expect(find.text(message), findsOneWidget);
    expect(find.bySemanticsLabel(message), findsOneWidget);
    expect(find.textContaining('No providers in'), findsNothing);
  });

  testWidgets('desktop routing applies model capability budget gates', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final snapshot = [
      _routeQuota(
        'antigravity',
        'Antigravity',
        now,
        usedPercent: 10,
        modelQuotas: [
          ModelQuota(
            model: 'Gemini 3.1 Pro',
            usedPercent: 100,
            resetsAt: now + 3600,
          ),
          ModelQuota(
            model: 'Gemini 3 Flash',
            usedPercent: 10,
            resetsAt: now + 3600,
          ),
        ],
      ),
      _routeQuota('codex', 'Codex', now, usedPercent: 45),
    ];

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, setupDone: true),
          demoMode: false,
          collector: () async => snapshot,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Next: Codex'), findsOneWidget);
    expect(find.textContaining('Next: Antigravity'), findsNothing);
  });

  testWidgets('desktop routing honors active cross-process leases', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final leases = InMemoryRouteLeaseStore(idFactory: () => 'lease-1');
    leases.reserve(
      provider: 'claude',
      account: 'default',
      now: now,
      leaseSeconds: 120,
      weightPercent: 30,
    );
    final snapshot = [
      _routeQuota('claude', 'Claude', now, usedPercent: 20),
      _routeQuota('codex', 'Codex', now, usedPercent: 35),
    ];

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, setupDone: true),
          demoMode: false,
          collector: () async => snapshot,
          leaseStore: leases,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Next: Codex'), findsOneWidget);
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

  testWidgets(
    'slow webhook overlap stays single-flight and preserves alert arming',
    (tester) async {
      await _useDesktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      ProviderQuota quota(double used) => ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'test',
        asOf: now,
        windows: [QuotaWindow(label: '5h', usedPercent: used)],
      );
      final red = quota(100);
      final recovered = quota(20);
      var current = red;
      var posts = 0;
      final firstPostStarted = Completer<void>();
      final releaseFirstPost = Completer<void>();

      await tester.pumpWidget(
        _wrap(
          Dashboard.test(
            prefs: const Prefs(
              enableNotifications: false,
              webhookUrl: 'http://127.0.0.1:9000/quota',
              setupDone: true,
            ),
            demoMode: false,
            collector: () async => [current],
            alertPoster: (url, payload, {required allowExternal}) async {
              posts++;
              if (posts == 1) {
                firstPostStarted.complete();
                await releaseFirstPost.future;
              }
              return const WebhookResult(ok: true, statusCode: 204);
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(firstPostStarted.isCompleted, isTrue);
      expect(posts, 1);

      // A completed refresh while the first transport awaits is coalesced into
      // the same flight. It must not start a duplicate webhook batch.
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pump();
      await tester.pump();
      expect(posts, 1);

      releaseFirstPost.complete();
      await tester.pump();
      await tester.pump();
      expect(posts, 1);

      // The coalesced red check remains armed, so another steady-red refresh is
      // silent. Recovery clears the edge, and a later red crossing fires once.
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pump();
      await tester.pump();
      expect(posts, 1);

      current = recovered;
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pump();
      await tester.pump();
      expect(posts, 1);

      current = red;
      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pump();
      await tester.pump();
      expect(posts, 2);

      await tester.pumpWidget(const SizedBox());
    },
  );

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

  testWidgets('provider setup refresh keeps every matching account visible', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stale = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'old@example.com',
      asOf: now - 300,
      stale: true,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 60, resetsAt: now + 86400),
      ],
    );
    final fresh = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'fresh@example.com',
      asOf: now,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: now + 86400),
      ],
    );
    var collections = 0;
    var connections = 0;

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false),
          demoMode: false,
          collector: () async {
            collections++;
            return collections == 1 ? [stale] : [stale, fresh];
          },
          providerConnector: (provider) async {
            expect(provider, 'grok');
            connections++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(collections, 1);

    await tester.tap(find.byTooltip('Setup and help'));
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(
      find.descendant(of: dialog, matching: find.text('cached')),
      findsOneWidget,
    );
    final connect = find.descendant(
      of: dialog,
      matching: find.widgetWithText(TextButton, 'Connect'),
    );
    expect(connect, findsOneWidget);

    await tester.tap(connect);
    await tester.pumpAndSettle();

    expect(connections, 1);
    expect(collections, 2);
    expect(
      find.text(
        'Grok connected, but the selected account is still unconfirmed',
      ),
      findsOneWidget,
    );
    expect(find.text('Grok connected'), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('live')),
      findsOneWidget,
    );
    expect(find.text('Grok (old@example.com)'), findsOneWidget);
    expect(find.text('Grok (fresh@example.com)'), findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('cached')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, 'Connect'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'provider setup keeps a failed grant beside a live host account',
    (tester) async {
      await _useDesktopSurface(tester);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final hostAccount = 'credential:${List.filled(64, 'a').join()}';
      final grantAccount = 'credential:${List.filled(64, 'b').join()}';
      final liveHost = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: hostAccount,
        asOf: now,
        windows: [
          QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: now + 86400),
        ],
      );
      final failedGrant = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: grantAccount,
        asOf: now,
        ok: false,
        error: 'refresh grant unavailable',
      );

      await tester.pumpWidget(
        _wrap(
          Dashboard.test(
            prefs: const Prefs(enableNotifications: false, setupDone: true),
            demoMode: false,
            collector: () async => [liveHost, failedGrant],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Setup and help'));
      await tester.pumpAndSettle();

      final dialog = find.byType(Dialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Claude (account aaaaaaaa)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Claude (account bbbbbbbb)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('live')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('no live data')),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Set up Claude (account bbbbbbbb)'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('provider setup stays bounded at narrow width and 2x text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final invalid = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'work@example.com',
      asOf: now,
      perMachine: true,
      sourceClass: ProviderSourceClass.passiveLocalEvidence,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: now + 86400),
      ],
    );
    expect(invalid.sourceClassViolation, isNotNull);

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, setupDone: false),
          demoMode: false,
          collector: () async => [invalid],
          providerConnector: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Setup and help'));
    await tester.pumpAndSettle();

    expect(find.text('invalid evidence'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider connect recollects after an active refresh', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stale = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'test@example.com',
      asOf: now - 300,
      stale: true,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 60, resetsAt: now + 86400),
      ],
    );
    final fresh = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'test@example.com',
      asOf: now,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: now + 86400),
      ],
    );
    final activeRefresh = Completer<List<ProviderQuota>>();
    var collections = 0;
    var connections = 0;

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false),
          demoMode: false,
          collector: () {
            collections++;
            if (collections == 1) return Future.value([stale]);
            if (collections == 2) return activeRefresh.future;
            return Future.value([fresh]);
          },
          providerConnector: (provider) async {
            expect(provider, 'grok');
            connections++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Refresh now'));
    await tester.pump();
    expect(collections, 2);

    await tester.tap(find.byTooltip('Setup and help'));
    await tester.pumpAndSettle();
    final connect = find.descendant(
      of: find.byType(Dialog),
      matching: find.widgetWithText(TextButton, 'Connect'),
    );
    await tester.tap(connect);
    await tester.pump();
    expect(connections, 1);
    expect(collections, 2);

    activeRefresh.complete([stale]);
    await tester.pumpAndSettle();

    expect(collections, 3);
    expect(find.text('Grok connected'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

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

  testWidgets(
    'compact provider chips focus and reveal overflow from keyboard',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(210, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final providers = List<ProviderQuota>.generate(
        10,
        (index) => ProviderQuota(
          provider: 'provider$index',
          displayName: 'Provider $index',
          account: 'default',
          asOf: now,
          windows: [QuotaWindow(label: 'weekly', usedPercent: index * 5)],
        ),
      );

      await tester.pumpWidget(
        _wrap(
          Dashboard.test(
            prefs: const Prefs(
              compact: true,
              enableNotifications: false,
              setupDone: true,
            ),
            demoMode: false,
            collector: () async => providers,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final horizontalScroll = find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      final lastChip = find.byKey(const ValueKey('compact-provider-provider9'));
      expect(horizontalScroll, findsOneWidget);
      expect(lastChip, findsOneWidget);
      expect(
        tester.getRect(lastChip).left,
        greaterThan(tester.getRect(horizontalScroll).right),
      );

      for (var i = 0; i < providers.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }

      final focused = tester.getSemantics(lastChip).getSemanticsData();
      expect(focused.flagsCollection.isFocused, Tristate.isTrue);
      expect(
        tester.getRect(lastChip).left,
        lessThan(tester.getRect(horizontalScroll).right),
      );
      expect(
        tester.getRect(lastChip).right,
        greaterThan(tester.getRect(horizontalScroll).left),
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('profile delete failure is bounded and keeps the profile', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    const work = QuotaProfile(name: 'work', providers: {'grok'});
    var deleteAttempts = 0;
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(activeProfile: 'work', enableNotifications: false),
          testProfiles: [QuotaProfile.defaultProfile(), work],
          profileDeleter: (_) {
            deleteAttempts++;
            throw StateError('private-profile-path');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _selectMenuValue(tester, 'profiles:manage');
    expect(find.text('Profiles'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(deleteAttempts, 1);
    expect(find.text('Could not delete profile.'), findsOneWidget);
    expect(find.textContaining('private-profile-path'), findsNothing);
    expect(tester.takeException(), isNull);

    await _selectMenuValue(tester, 'profiles:manage');
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
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
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
    expect(MediaQuery.textScalerOf(appContext).scale(10), 23);
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

  testWidgets('hidden account mode uses one private provider control', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, showAccounts: false),
          demoMode: false,
          collector: () async => _multiAccountClaude(now),
          testProfiles: [QuotaProfile.defaultProfile()],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(ProviderTile), findsNWidgets(2));
    expect(find.text('personal@example.com'), findsNothing);
    expect(find.text('work@example.com'), findsNothing);

    await tester.tap(find.byTooltip('Menu: profiles, providers, and settings'));
    await tester.pumpAndSettle();
    expect(_providerMenuValues(tester), ['show:claude']);
    expect(find.text('personal@example.com'), findsNothing);
    expect(find.text('work@example.com'), findsNothing);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await _selectMenuValue(tester, 'show:claude');
    expect(find.byType(ProviderTile), findsNothing);
    await _selectMenuValue(tester, 'show:claude');
    expect(find.byType(ProviderTile), findsNWidgets(2));
  });

  testWidgets('visible account mode keeps per-account headers and controls', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, showAccounts: true),
          demoMode: false,
          collector: () async => _multiAccountClaude(now),
          testProfiles: [QuotaProfile.defaultProfile()],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('personal@example.com'), findsOneWidget);
    expect(find.text('work@example.com'), findsWidgets);

    await tester.tap(find.byTooltip('Menu: profiles, providers, and settings'));
    await tester.pumpAndSettle();
    expect(_providerMenuValues(tester), [
      'show:claude|personal@example.com',
      'show:claude|work@example.com',
    ]);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await _selectMenuValue(tester, 'show:claude|work@example.com');
    expect(find.byType(ProviderTile), findsOneWidget);
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
    expect(find.textContaining('checked '), findsOneWidget);
    expect(find.textContaining('as of '), findsNothing);
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

  testWidgets('failed refresh makes retained quota last known and unroutable', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final quota = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'default',
      asOf: now,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: now + 86400),
      ],
    );
    var collections = 0;

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, setupDone: true),
          demoMode: false,
          collector: () async {
            collections++;
            if (collections == 1) return [quota];
            throw StateError('private-token-value');
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Next: Claude'), findsOneWidget);
    expect(find.textContaining('80% free'), findsWidgets);

    await tester.tap(find.byTooltip('Refresh now'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Refresh failed; showing previous data'), findsOneWidget);
    expect(find.text('80% last known'), findsOneWidget);
    expect(find.textContaining('80% free'), findsNothing);
    expect(find.textContaining('Next: Claude'), findsNothing);
    expect(find.text('live read failed - showing last known'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Trusted quota headroom unavailable'),
      findsOneWidget,
    );
    expect(find.textContaining('private-token-value'), findsNothing);
    // Full provenance stays one tap away in the expanded card.
    await tester.tap(find.byType(ProviderTile));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('cached | account-wide'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first run offers provider review and persists completion', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Prefs? saved;
    final quota = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'default',
      asOf: now,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: now + 86400),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, setupDone: false),
          demoMode: false,
          collector: () async => [quota],
          prefsSaver: (prefs) async => saved = prefs,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Start here: review provider connections'),
      findsOneWidget,
    );
    await tester.tap(find.text('Review'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Start here: review provider connections'), findsNothing);
    expect(saved?.setupDone, isTrue);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('completed degraded refresh never looks current', (tester) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stale = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'default',
      asOf: now - 3600,
      stale: true,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 60, resetsAt: now + 86400),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, setupDone: true),
          demoMode: false,
          collector: () async => [stale],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'No current quota data; showing cached or unavailable providers',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('checked '), findsOneWidget);
    expect(find.textContaining('as of '), findsNothing);
    expect(find.text('40% last known'), findsOneWidget);
    expect(find.textContaining('40% free'), findsNothing);
    expect(
      find.bySemanticsLabel('Trusted quota headroom unavailable'),
      findsOneWidget,
    );
    // The tight default proves staleness above without the full provenance
    // line, which is one tap away in the expanded card and still never reads as
    // current.
    expect(find.textContaining('cached | account-wide'), findsNothing);
    await tester.tap(find.byType(ProviderTile));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('cached | account-wide'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual refresh announces and disables its in-flight state', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final quota = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'default',
      asOf: now,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: now + 86400),
      ],
    );
    final pending = Completer<List<ProviderQuota>>();
    var collections = 0;

    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: false, setupDone: true),
          demoMode: false,
          collector: () {
            collections++;
            return collections == 1 ? Future.value([quota]) : pending.future;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('Refresh now'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh now'));
    await tester.pump();

    expect(find.byTooltip('Refreshing quotas'), findsOneWidget);
    final disabled = tester.widget<InkWell>(
      find.descendant(
        of: find.byTooltip('Refreshing quotas'),
        matching: find.byType(InkWell),
      ),
    );
    expect(disabled.onTap, isNull);

    pending.complete([quota]);
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Refresh now'), findsOneWidget);

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
    final semantics = tester.ensureSemantics();
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
      expect(
        find.bySemanticsLabel(
          'Quota headroom history, oldest to newest. 3 samples. Latest 30 '
          'percent free; range 30 to 80 percent.',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Quota headroom heatmap by weekday and hour. 14 sampled slots, '
          'ranging from 0 to 61 percent free. Best sampled slot Sunday at 1 '
          'AM, 61 percent free.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });
}
