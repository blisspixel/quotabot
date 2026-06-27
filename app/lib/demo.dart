import 'dart:math' as math;

import 'package:quotabot_collector/collector.dart';

/// Synthetic, account-free data for screenshots and first-run previews. Enabled
/// by the QUOTABOT_DEMO=1 environment variable. The numbers are made up; no real
/// provider is contacted.

ProviderQuota _p(
  String id,
  String name,
  String plan,
  List<QuotaWindow> windows,
) => ProviderQuota(
  provider: id,
  displayName: name,
  account: 'demo',
  plan: plan,
  asOf: _now(),
  windows: windows,
);

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

QuotaWindow _w(String label, double used, int resetInSecs) => QuotaWindow(
  label: label,
  usedPercent: used,
  resetsAt: _now() + resetInSecs,
);

/// A believable fleet: each provider at a different point in its cycle.
List<ProviderQuota> demoData() => [
  _p('claude', 'Claude', 'max', [_w('5h', 26, 5226), _w('weekly', 16, 540000)]),
  _p('codex', 'Codex', 'pro', [_w('5h', 2, 10920), _w('weekly', 47, 416700)]),
  _p('antigravity', 'Antigravity', 'AI Pro', [
    _w('5h', 0, 16800),
    _w('weekly', 0, 118260),
  ]),
  _p('grok', 'Grok', 'SuperGrok', [_w('monthly', 59, 338700)]),
  ProviderQuota(
    provider: 'ollama',
    displayName: 'Ollama',
    account: '12 models',
    plan: 'local',
    kind: 'local',
    asOf: _now(),
    status: '12 installed, idle',
    details: const ['12 installed . 191.0 GB on disk'],
  ),
];

/// About 40 days of hourly buckets per metered provider so the analytics views
/// (distribution, reliability, trend, heatmap) have something to draw. The shape
/// blends a daily work-hours dip, a slow weekly drift, and light noise.
Map<String, List<HeadroomBucket>> demoBuckets() {
  final now = _now();
  final rng = math.Random(7); // fixed seed: stable screenshots
  final out = <String, List<HeadroomBucket>>{};
  final bases = {
    'claude': 62.0,
    'codex': 48.0,
    'antigravity': 88.0,
    'grok': 40.0,
  };
  bases.forEach((id, base) {
    final buckets = <HeadroomBucket>[];
    for (var h = 0; h < 24 * 40; h++) {
      final t = now - h * 3600;
      final hour = (t ~/ 3600) % 24;
      final dip = (hour >= 9 && hour <= 18) ? -22.0 : 6.0; // work hours tighter
      final drift = (h / (24 * 40)) * 14.0; // a little easing over time
      final noise = rng.nextDouble() * 16 - 8;
      final free = (base + dip + drift + noise).clamp(0.0, 100.0);
      buckets.add(HeadroomBucket(start: t - (t % 3600))..add(free));
    }
    out[id] = buckets;
  });
  return out;
}
