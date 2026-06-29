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
}
