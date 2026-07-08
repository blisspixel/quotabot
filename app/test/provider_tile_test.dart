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

void main() {
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

  testWidgets('shows machine scope in the compact trust line', (tester) async {
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
      find.textContaining(
        'no live data | metadata only | this machine | captured',
      ),
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
      find.textContaining('metadata | metadata only | captured'),
      findsOneWidget,
    );
    expect(find.textContaining('0% free'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows local fallback state for status-only per-machine data', (
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
      find.textContaining(
        'local fallback | metadata only | this machine | captured',
      ),
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

    expect(find.textContaining('live | quota plan | captured'), findsOneWidget);
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

  testWidgets('shows local loaded provenance and machine scope', (
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
      find.textContaining('in use | local loaded | this machine | captured'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
