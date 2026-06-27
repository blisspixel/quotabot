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

Insights _ins() => const Insights(
  samples: 200,
  spanDays: 14,
  mean: 55,
  stddev: 18,
  p10: 22,
  p50: 58,
  p90: 88,
  reliability: 0.95,
  trendPerDay: -1.2,
  trendConfidence: 0.4,
  tightestHour: 14,
  tightestDay: 2,
  burnPerHour: 3.5,
);

List<List<double?>> _heatmap() => List.generate(
  7,
  (d) => List.generate(
    24,
    (h) => ((d + h) % 5 == 0) ? null : ((h * 4) % 100).toDouble(),
  ),
);

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
    final insights = {
      for (final id in ['codex', 'claude', 'grok', 'antigravity']) id: _ins(),
    };
    final heatmaps = {
      for (final id in ['codex', 'claude']) id: _heatmap(),
    };

    await tester.pumpWidget(
      _wrap(
        FleetScreen(
          data: data,
          insights: insights,
          heatmaps: heatmaps,
          dark: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('FLEET ANALYTICS'), findsOneWidget);
    expect(find.text('CONSTELLATION'), findsOneWidget);
    expect(find.text('BEST TIME TO RUN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FleetScreen handles an empty fleet gracefully', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        const FleetScreen(data: [], insights: {}, heatmaps: {}, dark: false),
      ),
    );
    await tester.pump();

    expect(find.text('FLEET ANALYTICS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('fleetColor maps the headroom scale', () {
    expect(fleetColor(80), const Color(0xFF3FB950));
    expect(fleetColor(30), const Color(0xFFD29922));
    expect(fleetColor(5), const Color(0xFFDB6D28));
    expect(fleetColor(0), const Color(0xFFF85149));
  });
}
