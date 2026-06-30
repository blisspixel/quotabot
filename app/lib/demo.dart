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
}) => ProviderQuota(
  provider: id,
  displayName: name,
  account: account,
  plan: plan,
  asOf: _now(),
  stale: stale,
  error: note,
  windows: windows,
);

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
  kind: 'local',
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

/// Every supported service at a made-up point in its cycle, including two
/// Antigravity accounts to show multi-account display. All numbers and the
/// account names are invented for the demo and do not mirror any real account
/// or machine.
List<ProviderQuota> demoData() => [
  // A power user leaning hard on Claude (5h nearly tapped), with Kiro getting
  // low and Antigravity flush, so routing has an obvious place to send work.
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
  _p('antigravity', 'Antigravity', 'AI Pro', 'work@example.com', [
    _w('5h', 34, 14400),
    _w('weekly', 46, 381600),
  ]),
  _p('grok', 'Grok', 'SuperGrok', 'you@example.com', [
    _w('monthly', 57, 712800),
  ]),
  _p('cursor', 'Cursor', 'Pro', 'you@example.com', [_w('monthly', 38, 745200)]),
  _p('windsurf', 'Windsurf', 'Pro', 'you@example.com', [
    _w('daily', 66, 48600),
    _w('weekly', 55, 360000),
  ]),
  _p('kiro', 'Kiro', 'Pro', 'you@example.com', [_w('credit', 78, 280800)]),
  _local('ollama', 'Ollama', '3 models', 'qwen2.5-coder 7B Q4 loaded', const [
    '4.4 GB VRAM . 32K ctx',
    '3 installed . 18.6 GB on disk',
  ], active: true),
  _local('lmstudio', 'LM Studio', '2 models', 'llama-3.1-8B loaded', const [
    '5.1 GB VRAM . 16K ctx',
    '2 installed . 12.0 GB on disk',
  ], active: true),
  _local('lemonade', 'Lemonade', '1 model', '1 installed, idle', const [
    '1 installed . 4.7 GB on disk',
  ]),
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
    'windsurf': 41.0,
    'kiro': 28.0,
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
