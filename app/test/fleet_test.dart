import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/fleet.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota _q(String id, String name, double usedPercent, {int? resetsAt}) {
  return ProviderQuota(
    provider: id,
    displayName: name,
    account: '$id@example.com',
    asOf: 1782046566,
    windows: [
      QuotaWindow(label: '5h', usedPercent: usedPercent, resetsAt: resetsAt),
    ],
  );
}

/// A few weeks of synthetic hourly buckets so the historical views have data.
List<HeadroomBucket> _buckets(double base) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final out = <HeadroomBucket>[];
  for (var i = 0; i < 24 * 30; i++) {
    final start = now - i * 3600;
    final b = HeadroomBucket(start: start - (start % 3600));
    b.add((base + (i % 17) - 8).clamp(0, 100).toDouble());
    out.add(b);
  }
  return out;
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('FleetScreen renders a full fleet without errors', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final data = [
      _q('codex', 'Codex', 2, resetsAt: 1782050000),
      _q('claude', 'Claude', 26, resetsAt: 1782090000),
      _q('grok', 'Grok', 59, resetsAt: 1782300000),
      _q('antigravity', 'Antigravity', 88),
      // A local runtime must be ignored by the fleet charts.
      ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: '',
        asOf: 1782046566,
        kind: 'local',
      ),
    ];
    final buckets = {
      'codex': _buckets(20),
      'claude': _buckets(55),
      'grok': _buckets(70),
      'antigravity': _buckets(88),
    };

    await tester.pumpWidget(
      _wrap(FleetScreen(data: data, buckets: buckets, dark: true)),
    );
    await tester.pump();

    // Now view by default.
    expect(find.text('Quota Analytics'), findsOneWidget);
    expect(find.text('HEADROOM'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Switch to the 90d historical view.
    await tester.tap(find.text('90d'));
    await tester.pump();
    expect(find.text('DISTRIBUTION'), findsOneWidget);
    expect(find.text('BEST TIME TO RUN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FleetScreen handles an empty fleet gracefully', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(const FleetScreen(data: [], buckets: {}, dark: false)),
    );
    await tester.pump();

    expect(find.text('Quota Analytics'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('7d'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('fleetColor maps the headroom scale', () {
    expect(fleetColor(80), const Color(0xFF3FB950));
    expect(fleetColor(30), const Color(0xFFD29922));
    expect(fleetColor(5), const Color(0xFFDB6D28));
    expect(fleetColor(0), const Color(0xFFF85149));
  });
}
