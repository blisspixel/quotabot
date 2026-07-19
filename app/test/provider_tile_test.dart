import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota _q(double usedPercent, {int? resetsAt}) => ProviderQuota(
  provider: claudeProviderId,
  displayName: 'Claude',
  account: 'default',
  asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  windows: [
    QuotaWindow(label: '5h', usedPercent: usedPercent, resetsAt: resetsAt),
  ],
);

ProviderQuota _accountQ(String account) => ProviderQuota(
  provider: antigravityProviderId,
  displayName: 'Antigravity',
  account: account,
  plan: 'AI Pro',
  asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
);

Insights _ins({double? burn, double? burnSe}) => Insights(
  samples: 50,
  spanDays: 7,
  burnPerHour: burn,
  burnSePerHour: burnSe,
);

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

double _contrastRatio(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground.computeLuminance()
      : background.computeLuminance();
  final darker = foreground.computeLuminance() > background.computeLuminance()
      ? background.computeLuminance()
      : foreground.computeLuminance();
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  testWidgets('renders Claude scoped quota after shared provider windows', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final quota = ProviderQuota(
      provider: claudeProviderId,
      displayName: claudeProviderName,
      account: 'default',
      asOf: now,
      windows: [
        QuotaWindow(label: '5h', usedPercent: 45, resetsAt: now + 3600),
        QuotaWindow(
          label: 'weekly',
          usedPercent: 17,
          resetsAt: now + 5 * 86400,
        ),
      ],
      modelQuotas: [
        ModelQuota(
          model: 'Fable',
          usedPercent: 26,
          resetsAt: now + 60,
          windowLabel: 'weekly',
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: quota, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(find.text('5h'), findsOneWidget);
    expect(find.text('weekly'), findsNWidgets(2));
    expect(find.text('Fable'), findsOneWidget);
    expect(find.text('included quota not proven'), findsOneWidget);
    expect(find.text('quota'), findsNothing);
    expect(find.text('Model-specific quota (separate)'), findsOneWidget);
    expect(find.textContaining('74% free'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp('Model-specific quota.*does not replace Claude.*shared'),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Fable')).dy,
      greaterThan(tester.getTopLeft(find.text('weekly').first).dy),
    );
    expect(providerTileQuotaRowCount(quota, now), 4);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('labels Fable spend from plan evidence without overclaiming', (
    tester,
  ) async {
    const now = kClaudeFableIncludedQuotaEffectiveAt + 86400;

    ProviderQuota quota(String plan, ProviderPlanEvidenceSource source) =>
        ProviderQuota(
          provider: claudeProviderId,
          displayName: claudeProviderName,
          account: 'opaque',
          plan: plan,
          planEvidenceSource: source,
          planEvidenceAsOf: now,
          asOf: now,
          windows: [
            QuotaWindow(
              label: 'weekly',
              usedPercent: 17,
              resetsAt: now + 5 * 86400,
            ),
          ],
          modelQuotas: [
            ModelQuota(
              model: 'Fable',
              usedPercent: 26,
              resetsAt: now + 5 * 86400,
            ),
          ],
        );

    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: quota('max', ProviderPlanEvidenceSource.hostCredential),
          cardColor: const Color(0xFF1A1A1A),
          nowEpochSeconds: now,
        ),
      ),
    );
    expect(find.text('included quota not proven'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message?.contains('stored Claude credential') == true,
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: quota('max', ProviderPlanEvidenceSource.providerMetadata),
          cardColor: const Color(0xFF1A1A1A),
          nowEpochSeconds: now,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('included quota'), findsOneWidget);
    expect(find.text('included quota not proven'), findsNothing);

    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: quota('pro', ProviderPlanEvidenceSource.providerMetadata),
          cardColor: const Color(0xFF1A1A1A),
          nowEpochSeconds: now,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('credit-backed availability'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: quota('pro', ProviderPlanEvidenceSource.hostCredential),
          cardColor: const Color(0xFF1A1A1A),
          nowEpochSeconds: now,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('included quota not proven'), findsOneWidget);
    expect(find.text('credit-backed availability'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders Codex scoped quota without replacing shared quota', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final quota = ProviderQuota(
      provider: codexProviderId,
      displayName: codexProviderName,
      account: 'default',
      asOf: now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 63,
          resetsAt: now + 5 * 86400,
        ),
      ],
      modelQuotas: [
        ModelQuota(
          model: 'GPT-5.3-Codex-Spark',
          usedPercent: 0,
          resetsAt: now + 6 * 86400,
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: quota, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(find.text('weekly'), findsOneWidget);
    expect(find.text('GPT-5.3-Codex-Spark'), findsOneWidget);
    expect(find.text('quota'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp('Model-specific quota.*does not replace Codex.*shared'),
      ),
      findsOneWidget,
    );
    expect(desktopScopedModelQuotas(quota), hasLength(1));
    expect(providerTileQuotaRowCount(quota, now), 3);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'narrow scoped quota keeps full labels accessible at 2x text scale',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(210, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const modelLabel = 'GPT-5.3-Codex-Spark Preview with Extended Reasoning';
      const windowLabel = 'provider-defined weekly allowance window';
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final quota = ProviderQuota(
        provider: codexProviderId,
        displayName: codexProviderName,
        account: 'default',
        asOf: now,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 35,
            resetsAt: now + 5 * 86400,
          ),
        ],
        modelQuotas: [
          ModelQuota(
            model: modelLabel,
            windowLabel: windowLabel,
            usedPercent: 12,
            resetsAt: now + 6 * 86400,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ProviderTile(
              quota: quota,
              cardColor: const Color(0xFF1A1A1A),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip(modelLabel), findsOneWidget);
      expect(find.byTooltip(windowLabel), findsOneWidget);
      expect(find.bySemanticsLabel(modelLabel), findsOneWidget);
      expect(find.bySemanticsLabel(windowLabel), findsOneWidget);
      final modelText = tester.widget<Text>(find.text(modelLabel));
      final windowText = tester.widget<Text>(find.text(windowLabel));
      expect(modelText.maxLines, 1);
      expect(modelText.overflow, TextOverflow.ellipsis);
      expect(windowText.maxLines, 1);
      expect(windowText.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('spent Claude scoped quota does not block the provider tile', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final quota = ProviderQuota(
      provider: claudeProviderId,
      displayName: claudeProviderName,
      account: 'default',
      asOf: now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 17,
          resetsAt: now + 5 * 86400,
        ),
      ],
      modelQuotas: [
        ModelQuota(model: 'Fable', usedPercent: 100, resetsAt: now + 5 * 86400),
      ],
    );

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: quota, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(find.textContaining('83% free'), findsOneWidget);
    expect(find.textContaining('0% free'), findsOneWidget);
    expect(find.textContaining('weekly spent'), findsNothing);
    expect(find.text('Fable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expired Claude scoped quota stays last observed without blocking shared quota',
    (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final expiredFable = ModelQuota(
        model: 'Fable',
        usedPercent: 51,
        resetsAt: now - 60,
      );
      final quota = ProviderQuota(
        provider: claudeProviderId,
        displayName: claudeProviderName,
        account: 'default',
        asOf: now,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 17,
            resetsAt: now + 5 * 86400,
          ),
        ],
        modelQuotas: [expiredFable],
      );

      await tester.pumpWidget(
        _wrap(ProviderTile(quota: quota, cardColor: const Color(0xFF1A1A1A))),
      );
      await tester.pump();

      expect(find.textContaining('83% free'), findsOneWidget);
      expect(find.text('49% last observed'), findsOneWidget);
      expect(find.textContaining('100% free'), findsNothing);
      expect(
        desktopScopedModelEvidenceLabel(quota, expiredFable, now),
        'last observed',
      );
      final status = providerStatus(quota, now);
      expect(status.hasData, isTrue);
      expect(status.blocked, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('does not render Antigravity model-quota list on its tile', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final quota = ProviderQuota(
      provider: antigravityProviderId,
      displayName: antigravityProviderName,
      account: 'default',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
      modelQuotas: const [
        ModelQuota(model: 'Gemini 3.5 Flash', usedPercent: 10),
      ],
    );

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: quota, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(find.text('weekly'), findsOneWidget);
    expect(find.text('Gemini 3.5 Flash'), findsNothing);
    expect(desktopScopedModelQuotas(quota), isEmpty);
    expect(providerTileQuotaRowCount(quota, now), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a redeemable reset as a prominent green banner', (
    tester,
  ) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final spentWithReset = ProviderQuota(
      provider: 'codex',
      displayName: 'Codex',
      account: 'default',
      asOf: nowSec,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 100, resetsAt: nowSec + 3600),
      ],
      resetCreditsAvailable: 2,
    );
    await tester.pumpWidget(
      _wrap(
        ProviderTile(quota: spentWithReset, cardColor: const Color(0xFF1A1A1A)),
      ),
    );
    await tester.pump();

    final banner = find.textContaining('resets available');
    expect(banner, findsOneWidget);
    // Rendered in the actionable green, not the muted detail color, so a spent
    // card's way out stands out.
    expect(tester.widget<Text>(banner).style?.color, const Color(0xFF3FB950));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shows a plain-language runway when burning without a strand error',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          ProviderTile(
            quota: _q(60), // 40% free
            cardColor: const Color(0xFF1A1A1A),
            insights: _ins(burn: 20), // 40 / 20 = ~2 hours of runway
          ),
        ),
      );
      await tester.pump();

      expect(find.text('about 2 hours of usage left'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('warns in plain language when the window is likely to strand', (
    tester,
  ) async {
    final soon = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(80, resetsAt: soon), // 20% free, resets in an hour
          cardColor: const Color(0xFF1A1A1A),
          insights: _ins(
            burn: 40,
            burnSe: 5,
          ), // near-certain to strand by reset
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('run out before it resets'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invents no forecast for a calm window', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(20), // 80% free
          cardColor: const Color(0xFF1A1A1A),
          insights: _ins(burn: 0), // not burning
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('usage left'), findsNothing);
    expect(find.textContaining('run out'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final surface in <(String, Color)>[
    ('light', Colors.white),
    ('dark', const Color(0xFF1C1F25)),
  ]) {
    testWidgets(
      'shows accessible provider drift with contrast on ${surface.$1}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final drifted = _q(60).withProviderDrift(
          '5h usage fell 60% to 10% with no reset',
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
        await tester.pumpWidget(
          _wrap(
            ProviderTile(
              quota: drifted,
              cardColor: surface.$2,
              insights: _ins(burn: 20),
            ),
          ),
        );
        await tester.pump();

        // Compact glance label; the full explanation and reason live in the
        // tooltip and semantics, not as a wall of visible text, and there is no
        // call to action (drift self-clears on the next clean read).
        const label = 'provider drift - showing last trusted';
        expect(find.text(label), findsOneWidget);
        expect(find.textContaining('Run quotabot verify'), findsNothing);
        expect(find.textContaining('routing is disabled'), findsNothing);
        expect(
          find.text('Reason: 5h usage fell 60% to 10% with no reset'),
          findsNothing,
        );
        expect(
          find.bySemanticsLabel(
            RegExp('Provider drift detected.*last trusted.*usage fell'),
          ),
          findsOneWidget,
        );
        final warning = tester.widget<Text>(find.text(label));
        expect(
          _contrastRatio(warning.style!.color!, surface.$2),
          greaterThanOrEqualTo(4.5),
        );
        expect(find.textContaining('usage left'), findsNothing);
        expect(find.textContaining('run out'), findsNothing);
        expect(find.text('40% last trusted'), findsOneWidget);
        expect(find.textContaining('% free'), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }

  testWidgets('questionable readings are visibly unverified and not forecast', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final suspect = _q(
      60,
    ).withSuspect('weekly usage changed unexpectedly without a reset');

    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: suspect,
          cardColor: Colors.white,
          insights: _ins(burn: 20, burnSe: 1),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('reading needs review - not used for routing'),
      findsOneWidget,
    );
    expect(find.text('40% unverified'), findsOneWidget);
    expect(find.textContaining('% free'), findsNothing);
    expect(find.textContaining('usage left'), findsNothing);
    expect(find.textContaining('run out before'), findsNothing);
    expect(
      find.bySemanticsLabel(
        RegExp('Provider marked this reading for review.*not used.*Reason:'),
      ),
      findsOneWidget,
    );
    expect(
      providerStatus(
        suspect,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ).color,
      const Color(0xFFD29922),
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('provider drift guidance wraps without narrow overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(210, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drifted = _q(60).withProviderDrift(
      'weekly reset moved earlier after the provider changed its response',
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    await tester.pumpWidget(
      _wrap(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 190,
            child: ProviderTile(
              quota: drifted,
              cardColor: Colors.white,
              insights: _ins(burn: 20),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('provider drift - showing last trusted'), findsOneWidget);
    expect(find.textContaining('Run quotabot verify'), findsNothing);
    expect(
      find.textContaining('provider drift | account-wide | quota plan'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy drift quarantine never claims trusted quota exists', (
    tester,
  ) async {
    final quarantined = _q(60)
        .withSuspect('legacy drift concern')
        .asProviderDriftQuarantine(
          'unresolved legacy provider drift: legacy drift concern',
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: quarantined, cardColor: Colors.white)),
    );
    await tester.pump();

    expect(find.text('provider drift - quarantined'), findsOneWidget);
    expect(
      find.textContaining('Legacy quota evidence is quarantined'),
      findsNothing,
    );
    expect(find.textContaining('Showing the last trusted quota'), findsNothing);
    expect(
      find.textContaining('provider drift | account-wide | captured'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('qualifies a spent drift window as last trusted evidence', (
    tester,
  ) async {
    final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    final drifted = _q(100, resetsAt: future).withProviderDrift(
      '5h reset moved earlier',
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: drifted, cardColor: Colors.white)),
    );
    await tester.pump();

    expect(find.text('5h was spent (last trusted)'), findsOneWidget);
    expect(find.text('5h spent'), findsNothing);
    expect(find.textContaining('% free'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('qualifies stale quota windows as last-known evidence', (
    tester,
  ) async {
    final stale = ProviderQuota.fromJson({..._q(60).toJson(), 'stale': true});

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: stale, cardColor: Colors.white)),
    );
    await tester.pump();

    expect(find.text('40% last known'), findsOneWidget);
    expect(find.textContaining('% free'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the live failure behind stale cloud quota', (
    tester,
  ) async {
    final stale = _q(60).asStale('invalid Claude usage response');

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: stale, cardColor: Colors.white)),
    );
    await tester.pump();

    expect(find.text('40% last known'), findsOneWidget);
    expect(find.text('live read failed - showing last known'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp(
          'latest live quota read failed.*invalid Claude usage response',
          caseSensitive: false,
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps stale headroom last known after the reset passes', (
    tester,
  ) async {
    final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
    final stale = ProviderQuota.fromJson({
      ..._q(80, resetsAt: past).toJson(),
      'as_of': past - 3600,
      'stale': true,
    });

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: stale, cardColor: Colors.white)),
    );
    await tester.pump();

    expect(find.text('20% last known'), findsOneWidget);
    expect(find.text('reset passed (last known)'), findsNothing);
    expect(find.text('ready'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reset-past snapshots require a confirming refresh', (
    tester,
  ) async {
    final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
    final quota = _q(100, resetsAt: past);
    await tester.pumpWidget(
      _wrap(ProviderTile(quota: quota, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(find.text('5h was spent (unverified)'), findsOneWidget);
    expect(find.text('refresh to confirm'), findsOneWidget);
    expect(find.textContaining('unverified | account-wide'), findsOneWidget);
    expect(find.text('ready'), findsNothing);
    expect(find.textContaining('100% free'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders rounded-one-percent headroom as spent, not free', (
    tester,
  ) async {
    final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(98.6, resetsAt: future),
          cardColor: const Color(0xFF1A1A1A),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('5h spent'), findsOneWidget);
    expect(find.textContaining('1% free'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown window balance never renders as 100 percent free', (
    tester,
  ) async {
    final quota = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'default',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      windows: [QuotaWindow(label: 'weekly')],
    );

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: quota, cardColor: Colors.white)),
    );
    await tester.pump();

    expect(
      find.text('quota balance unavailable - not used for routing'),
      findsOneWidget,
    );
    expect(find.textContaining('100%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(providerTileQuotaRowCount(quota, quota.asOf), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('analytics cards are keyboard activatable and expose expansion', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var toggles = 0;
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(40),
          cardColor: Colors.white,
          insights: _ins(burn: 2, burnSe: 1),
          onToggle: () => toggles++,
        ),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Claude quota card'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(toggles, 1);
    final focusRing = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(FocusableActionDetector),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = focusRing.decoration as BoxDecoration;
    expect(decoration.border, isNotNull);
    semantics.dispose();
  });

  testWidgets('analytics card semantics disambiguate visible accounts', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    ProviderQuota account(String value) => ProviderQuota(
      provider: claudeProviderId,
      displayName: claudeProviderName,
      account: value,
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      windows: [QuotaWindow(label: '5h', usedPercent: 20)],
    );

    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            ProviderTile(
              quota: account('work@example.com'),
              cardColor: Colors.white,
              insights: _ins(burn: 2),
              onToggle: () {},
              showAccounts: true,
            ),
            ProviderTile(
              quota: account('personal@example.com'),
              cardColor: Colors.white,
              insights: _ins(burn: 2),
              onToggle: () {},
              showAccounts: true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(
      find.bySemanticsLabel('Claude (work@example.com) quota card'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Claude (personal@example.com) quota card'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('spent window shows a near-term countdown to when it is back', (
    tester,
  ) async {
    // Sit 30s into the "1h" countdown bucket (which floors at exactly 3600s), so
    // the few milliseconds that elapse before the widget reads its own clock
    // cannot tip the label down to "59m". Exactly 3600 raced on slow runners.
    final soon = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600 + 30;
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(100, resetsAt: soon),
          cardColor: const Color(0xFF1A1A1A),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('available in 1h'), findsOneWidget);
    expect(find.textContaining('resets'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('spent window shows an absolute day and time for a far reset', (
    tester,
  ) async {
    final far = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3 * 86400;
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(100, resetsAt: far),
          cardColor: const Color(0xFF1A1A1A),
        ),
      ),
    );
    await tester.pump();

    // A weekly cap days out reads as its day and clock time, not "in 2d7h".
    // The day and time are joined by a non-breaking space (matched by \s) so the
    // reset never splits mid-value in a narrow column.
    expect(
      find.textContaining(
        RegExp(r'available (Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s\d'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('available in'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('healthy window keeps its far reset intact beside the headroom', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final far = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3 * 86400;
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(63, resetsAt: far), // 37% free, resets days out
          cardColor: const Color(0xFF1A1A1A),
        ),
      ),
    );
    await tester.pump();

    // The headroom and the absolute reset share the right column; the day and
    // time stay whole (matched by \s across the non-breaking space) so a long
    // reset wraps cleanly under the headroom instead of orphaning "PM".
    expect(
      find.textContaining(
        RegExp(r'37% free\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s\d.*[AP]M'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('long account labels stay inside the provider tile header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(260, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _accountQ(
            'very.long.account.name.for.routing.validation@example.com',
          ),
          cardColor: const Color(0xFF1A1A1A),
          showAccounts: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Antigravity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long no-data setup messages stay inside provider tiles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(220, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final q = ProviderQuota(
      provider: 'nvidia',
      displayName: 'NVIDIA NIM',
      account: 'default',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ok: false,
      error: 'NVIDIA NIM not configured; set NVIDIA_API_KEY or nvapi',
      windows: const [],
    );
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 160,
          child: ProviderTile(quota: q, cardColor: const Color(0xFF1A1A1A)),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('NVIDIA NIM not configured'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long provider remediation remains visible and accessible', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const remediation =
        'no live quota (this machine only) - run: quotabot login antigravity '
        '(then sign in with this account)';
    final q = ProviderQuota(
      provider: antigravityProviderId,
      displayName: antigravityProviderName,
      account: 'default',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      error: remediation,
    );

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 220,
          child: ProviderTile(quota: q, cardColor: Color(0xFF1A1A1A)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(remediation), findsOneWidget);
    expect(find.text('no live data'), findsNothing);
    expect(find.bySemanticsLabel(remediation), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('invalid provenance is named before a generic read error', (
    tester,
  ) async {
    final q = ProviderQuota(
      provider: claudeProviderId,
      displayName: claudeProviderName,
      account: 'default',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ok: false,
      error: 'invalid provider source class',
      perMachine: true,
      sourceClass: ProviderSourceClass.passiveLocalEvidence,
    );
    expect(q.sourceClassViolation, isNotNull);

    await tester.pumpWidget(
      _wrap(ProviderTile(quota: q, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(
      find.textContaining('invalid evidence | passive local'),
      findsOneWidget,
    );
    expect(find.textContaining('error | passive local'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows normalized machine scope in the compact trust line', (
    tester,
  ) async {
    final q = ProviderQuota(
      provider: 'antigravity',
      displayName: 'Antigravity',
      account: 'user@example.com',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      windows: const [],
      perMachine: true,
    );
    await tester.pumpWidget(
      _wrap(ProviderTile(quota: q, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(
      find.textContaining('no live data | this-machine fallback | captured'),
      findsOneWidget,
    );
    expect(find.text(' (this machine)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows status-only providers without a zero quota', (
    tester,
  ) async {
    final q = ProviderQuota(
      provider: 'nvidia',
      displayName: 'NVIDIA NIM',
      account: 'default',
      plan: 'free trial',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'free trial available; balance unknown',
      details: const ['trial rate limits are model-specific and unpublished'],
      windows: const [],
    );
    await tester.pumpWidget(
      _wrap(ProviderTile(quota: q, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(find.text('free trial available; balance unknown'), findsOneWidget);
    expect(
      find.textContaining('metadata | status only | captured'),
      findsOneWidget,
    );
    expect(find.textContaining('0% free'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows this-machine fallback provenance for metadata', (
    tester,
  ) async {
    final q = ProviderQuota(
      provider: 'antigravity',
      displayName: 'Antigravity',
      account: 'user@example.com',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'local fallback data',
      windows: const [],
      perMachine: true,
    );
    await tester.pumpWidget(
      _wrap(ProviderTile(quota: q, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(
      find.textContaining('metadata | this-machine fallback | captured'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows compact trust provenance for a live quota-plan tile', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(ProviderTile(quota: _q(20), cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(
      find.textContaining('live | account-wide | quota plan | captured'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows manual and cached provenance without calling it a plan', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final manual = ProviderQuota(
      provider: 'custom-ai',
      displayName: 'Custom AI',
      account: 'work',
      source: providerQuotaManualSource,
      asOf: now - 3600,
      stale: true,
      windows: [QuotaWindow(label: 'monthly', usedPercent: 90)],
    );
    await tester.pumpWidget(
      _wrap(ProviderTile(quota: manual, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(find.textContaining('cached | manual | captured'), findsOneWidget);
    expect(find.textContaining('quota plan'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows local-runtime provenance without duplicate scope', (
    tester,
  ) async {
    final q = ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: '2 models',
      kind: ProviderQuotaKind.local,
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'qwen loaded',
      active: true,
      perMachine: true,
      models: const [ModelInfo(id: 'qwen:7b', local: true, loaded: true)],
    );
    await tester.pumpWidget(
      _wrap(ProviderTile(quota: q, cardColor: const Color(0xFF1A1A1A))),
    );
    await tester.pump();

    expect(
      find.textContaining('in use | local runtime | captured'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable local runtime never appears active', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final staleLocal = ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: '2 models',
      kind: ProviderQuotaKind.local,
      asOf: now - 3600,
      status: 'qwen loaded',
      active: true,
      stale: true,
      perMachine: true,
      models: const [ModelInfo(id: 'qwen:7b', local: true, loaded: true)],
    );

    await tester.pumpWidget(
      _wrap(
        ProviderTile(quota: staleLocal, cardColor: const Color(0xFF1A1A1A)),
      ),
    );
    await tester.pump();

    final status = providerStatus(staleLocal, now);
    expect(status.hasData, isFalse);
    expect(status.blocked, isFalse);
    expect(find.textContaining('cached | local runtime'), findsOneWidget);
    expect(find.text('local runtime unavailable'), findsOneWidget);
    expect(find.text('qwen loaded'), findsNothing);
    expect(find.text('in use'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps full passive provenance accessible at narrow width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(210, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final q = ProviderQuota(
      provider: 'cursor',
      displayName: 'Cursor',
      account: 'user@example.com',
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      windows: [QuotaWindow(label: 'monthly', usedPercent: 20)],
      perMachine: true,
    );
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 190,
          child: ProviderTile(quota: q, cardColor: const Color(0xFF1A1A1A)),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.bySemanticsLabel(
        RegExp(
          r'State: live\. Passive quota evidence from this machine only; '
          r'other devices may not be included\.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('this machine'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
