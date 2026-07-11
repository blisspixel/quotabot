import 'dart:math' as math;

import 'package:quotabot_collector/collector.dart';

/// Synthetic, account-free data for screenshots and first-run previews. Enabled
/// by the QUOTABOT_DEMO=1 environment variable. The numbers are made up; no real
/// provider is contacted.

ProviderQuota _p(
  String id,
  String name,
  String plan,
  String account,
  List<QuotaWindow> windows, {
  bool stale = false,
  String? note,
}) {
  final sourceClass = inferProviderSourceClass(
    provider: id,
    source: null,
    isLocal: false,
    perMachine: false,
  );
  return ProviderQuota(
    provider: id,
    displayName: name,
    account: account,
    plan: plan,
    asOf: _now(),
    stale: stale,
    error: note,
    windows: windows,
    sourceClass: sourceClass,
    perMachine: sourceClass.isMachineScoped,
  );
}

ProviderQuota _local(
  String id,
  String name,
  String account,
  String status,
  List<String> details, {
  bool active = false,
}) => ProviderQuota(
  provider: id,
  displayName: name,
  account: account,
  plan: 'local',
  kind: ProviderQuotaKind.local,
  asOf: _now(),
  status: status,
  active: active,
  details: details,
);

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

QuotaWindow _w(String label, double used, int resetInSecs) => QuotaWindow(
  label: label,
  usedPercent: used,
  resetsAt: _now() + resetInSecs,
);

/// A readable demo fleet: five metered plans at distinct points in their
/// cycles plus two local runtimes, so the display shows what quotabot does
/// without crowding the screenshot. All numbers and account names are invented
/// and do not mirror any real account or machine.
List<ProviderQuota> demoData() => [
  // A power user leaning hard on Claude (5h nearly tapped) with Antigravity
  // flush, so routing has an obvious place to send work.
  _p('claude', 'Claude', 'Max', 'you@example.com', [
    _w('5h', 81, 4500),
    _w('weekly', 52, 388800),
  ]),
  _p('codex', 'Codex', 'Pro', 'you@example.com', [
    _w('5h', 44, 11400),
    _w('weekly', 68, 297000),
  ]),
  _p('antigravity', 'Antigravity', 'AI Pro', 'you@example.com', [
    _w('5h', 9, 9600),
    _w('weekly', 21, 469800),
  ]),
  _p('grok', 'Grok', 'SuperGrok', 'you@example.com', [
    _w('weekly', 57, 540000),
  ]),
  _p('cursor', 'Cursor', 'Pro', 'you@example.com', [_w('monthly', 38, 745200)]),
  _local('ollama', 'Ollama', '3 models', 'qwen2.5-coder 7B Q4 loaded', const [
    '4.4 GB VRAM . 32K ctx',
    '3 installed . 18.6 GB on disk',
  ], active: true),
  _local('lmstudio', 'LM Studio', '2 models', 'llama-3.1-8B loaded', const [
    '5.1 GB VRAM . 16K ctx',
    '2 installed . 12.0 GB on disk',
  ], active: true),
];

/// About 40 days of hourly buckets per metered provider so the analytics views
/// (distribution, reliability, trend, heatmap) have something to draw. The shape
/// blends a daily work-hours dip, a slow weekly drift, and light noise.
Map<String, List<HeadroomBucket>> demoBuckets() {
  final now = _now();
  final rng = math.Random(7); // fixed seed: stable screenshots
  final out = <String, List<HeadroomBucket>>{};
  final bases = {
    'claude': 34.0,
    'codex': 46.0,
    'antigravity': 84.0,
    'grok': 47.0,
    'cursor': 60.0,
  };
  // The busiest plans hit an occasional spent afternoon, so reliability,
  // calendar, and trend show believable texture instead of a uniform 100%.
  const crunchEvery = {'claude': 9, 'grok': 11};
  bases.forEach((id, base) {
    final buckets = <HeadroomBucket>[];
    for (var h = 0; h < 24 * 40; h++) {
      final t = now - h * 3600;
      final hour = (t ~/ 3600) % 24;
      final day = h ~/ 24;
      final dip = (hour >= 9 && hour <= 18) ? -22.0 : 6.0; // work hours tighter
      final drift = (h / (24 * 40)) * 14.0; // a little easing over time
      final noise = rng.nextDouble() * 16 - 8;
      var free = (base + dip + drift + noise).clamp(0.0, 100.0);
      final crunch = crunchEvery[id];
      if (crunch != null && day % crunch == 2 && hour >= 12 && hour <= 17) {
        free = 0; // the cap is spent for the afternoon
      }
      buckets.add(HeadroomBucket(start: t - (t % 3600))..add(free));
    }
    out[id] = buckets;
  });
  return out;
}

RoutedRequestSummary demoRoutedRequestSummary() {
  final now = _now();
  return summarizeRoutedRequests([
    LiteLlmRouteMetric(
      at: now - 4200,
      requestedModel: 'frontier-coder',
      servedModel: 'codex/gpt-5.2',
      spend: litellmSpendQuotaPlan,
      promptTokens: 18400,
      completionTokens: 3200,
      cost: 0.42,
    ),
    LiteLlmRouteMetric(
      at: now - 2600,
      requestedModel: 'frontier-coder',
      servedModel: 'antigravity/gemini-3-pro',
      spend: litellmSpendQuotaPlan,
      promptTokens: 9100,
      completionTokens: 1800,
      cost: 0.18,
    ),
    LiteLlmRouteMetric(
      at: now - 900,
      requestedModel: 'cheap-bulk',
      servedModel: 'ollama/qwen2.5-coder',
      spend: litellmSpendLocal,
      promptTokens: 7200,
      completionTokens: 1400,
      cost: 0,
    ),
  ]);
}
