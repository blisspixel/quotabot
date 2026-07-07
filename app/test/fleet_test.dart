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

Color _defaultPaletteColor(num remaining) {
  final rgb = kDefaultPalette.rgbFor(remaining.toDouble());
  return Color.fromARGB(0xFF, rgb.r, rgb.g, rgb.b);
}

List<HeadroomBucket> _scheduleBuckets() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final nextHour =
      now - (now % Duration.secondsPerHour) + Duration.secondsPerHour;
  final bucket = HeadroomBucket(start: nextHour - Duration.secondsPerDay * 7)
    ..add(92)
    ..add(90);
  return [bucket];
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
    expect(find.text('HEADROOM'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Switch to the 90d historical view.
    await tester.tap(find.text('90d'));
    await tester.pump();
    expect(find.text('DISTRIBUTION'), findsOneWidget);
    expect(find.text('CALENDAR'), findsOneWidget);
    expect(find.text('BEST TIME TO RUN'), findsOneWidget);
    expect(find.textContaining('Best:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FleetScreen handles an empty fleet gracefully', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(const FleetScreen(data: [], buckets: {}, dark: false)),
    );
    await tester.pump();

    expect(find.text('Now'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('7d'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('FleetScreen is a body under the dashboard chrome', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(520, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        FleetScreen(
          data: [_q('codex', 'Codex', 20, resetsAt: 1782050000)],
          buckets: const {},
          dark: true,
        ),
      ),
    );
    await tester.pump();

    // The header, back button, and close button belong to the dashboard; the
    // analytics body brings only its range tabs and cards.
    expect(find.text('Quota Analytics'), findsNothing);
    expect(find.byTooltip('Back to quotas'), findsNothing);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('7d'), findsOneWidget);
    expect(find.text('90d'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FleetScreen finds history stored under account-scoped keys', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // The dashboard stores buckets as provider|account when the account is
    // specific; the history views must find them there, not only under the
    // plain provider id.
    await tester.pumpWidget(
      _wrap(
        FleetScreen(
          data: [_q('codex', 'Codex', 20, resetsAt: 1782050000)],
          buckets: {'codex|codex@example.com': _buckets(40)},
          dark: true,
          initialRange: FleetRange.quarter,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('DISTRIBUTION'), findsOneWidget);
    expect(find.textContaining('history is still warming up'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FleetScreen shows a reset-aware best slot', (tester) async {
    await tester.binding.setSurfaceSize(const Size(520, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await tester.pumpWidget(
      _wrap(
        FleetScreen(
          data: [_q('codex', 'Codex', 20, resetsAt: now + 3 * 3600)],
          buckets: {'codex': _scheduleBuckets()},
          dark: true,
          initialRange: FleetRange.week,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('BEST TIME TO RUN'), findsOneWidget);
    expect(find.textContaining('next strong slot'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FleetScreen shows LiteLLM routed-request metrics', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(520, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final summary = summarizeRoutedRequests([
      const LiteLlmRouteMetric(
        at: 1782042000,
        requestedModel: 'frontier-coder',
        servedModel: 'codex/gpt-5.2',
        spend: litellmSpendQuotaPlan,
        promptTokens: 1200,
        completionTokens: 300,
        cost: 0.08,
      ),
      const LiteLlmRouteMetric(
        at: 1782045600,
        requestedModel: 'frontier-coder',
        servedModel: 'claude/sonnet-4.5',
        spend: litellmSpendPaidApi,
        promptTokens: 2400,
        completionTokens: 600,
        cost: 0.16,
      ),
      const LiteLlmRouteMetric(
        at: 1782046500,
        requestedModel: 'codex/gpt-5.2',
        servedModel: 'codex/gpt-5.2',
        spend: litellmSpendLocal,
        promptTokens: 500,
        completionTokens: 100,
        cost: 0.02,
      ),
    ]);

    await tester.pumpWidget(
      _wrap(
        FleetScreen(
          data: [_q('codex', 'Codex', 20, resetsAt: 1782050000)],
          buckets: const {},
          dark: true,
          routedRequests: summary,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ROUTED REQUESTS'), findsOneWidget);
    expect(find.text('2 routed'), findsOneWidget);
    expect(
      find.text('spend: 1 local | 1 quota | 1 paid API (\$0.16)'),
      findsOneWidget,
    );
    expect(find.textContaining('top served:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('fleetColor maps the shared collector palette scale', () {
    for (final remaining in [80, 30, 5, 0]) {
      expect(fleetColor(remaining), _defaultPaletteColor(remaining));
    }
  });
}
