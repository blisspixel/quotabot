import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota _q(double usedPercent, {int? resetsAt}) => ProviderQuota(
  provider: 'claude',
  displayName: 'Claude',
  account: 'default',
  asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  windows: [
    QuotaWindow(label: '5h', usedPercent: usedPercent, resetsAt: resetsAt),
  ],
);

ProviderQuota _accountQ(String account) => ProviderQuota(
  provider: 'antigravity',
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
      find.textContaining('provider drift | authoritative | quota plan'),
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
      find.textContaining('provider drift | authoritative | captured'),
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

    expect(find.text('5h spent (last trusted)'), findsOneWidget);
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

  testWidgets('renders reset-past exhausted snapshots as ready', (
    tester,
  ) async {
    final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
    await tester.pumpWidget(
      _wrap(
        ProviderTile(
          quota: _q(100, resetsAt: past),
          cardColor: const Color(0xFF1A1A1A),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ready'), findsOneWidget);
    expect(find.textContaining('spent'), findsNothing);
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
      find.textContaining('live | authoritative | quota plan | captured'),
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
        RegExp(r'live \| passive local \| metered plan \| captured .* ago'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('this machine'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
