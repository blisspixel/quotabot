/// Dev helper: renders deterministic `quotabot top` frames to ANSI text files
/// for visual QA. Not part of the shipped CLI. Writes one `.ans` file per
/// scenario into docs/dev/qa-top/ (git-ignored); convert them to PNGs with
/// tools/ansi_to_png.py to review the exact bytes a terminal would show.
///
/// Usage: dart run tool/render_top_frames.dart [outDir]
library;

import 'dart:io';

import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/demo.dart' as demo;
import 'package:quotabot_collector/top.dart';

const _now = 1782000000;
const _clock = '14:32:07';

List<ProviderQuota> _stressFleet(int now) {
  QuotaWindow w(String label, double used, int resetIn) => QuotaWindow(
        label: label,
        usedPercent: used,
        resetsAt: now + resetIn,
      );
  return [
    // Binding-window collapse: healthy 5h but spent weekly.
    ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'work@example.com',
      plan: 'max',
      asOf: now,
      windows: [w('5h', 12, 2 * 3600), w('weekly', 100, 27 * 3600)],
    ),
    // Stale cache with a reason.
    ProviderQuota(
      provider: 'codex',
      displayName: 'Codex',
      account: 'default',
      plan: 'pro',
      asOf: now - 8 * 3600,
      stale: true,
      error: 'no fresh session; cached',
      windows: [w('5h', 44, 3 * 3600), w('weekly', 68, 3 * 86400)],
    ),
    // Read failure with a plain reason.
    ProviderQuota.error('grok', 'Grok', 'token expired (open Grok)', now),
    // Detected but no quota data.
    ProviderQuota(
      provider: 'kiro',
      displayName: 'Kiro',
      account: 'installed',
      asOf: now,
    ),
    // Nearly spent, resets soon.
    ProviderQuota(
      provider: 'antigravity',
      displayName: 'Antigravity',
      account: 'you@example.com',
      plan: 'ai pro',
      asOf: now,
      windows: [w('5h', 97, 20 * 60), w('weekly', 30, 4 * 86400)],
    ),
    // Two accounts of the same provider: rows must self-identify.
    ProviderQuota(
      provider: 'grok2',
      displayName: 'Grok',
      account: 'work@example.com',
      plan: 'supergrok',
      asOf: now,
      windows: [w('weekly', 57, 6 * 86400)],
    ),
    ProviderQuota(
      provider: 'grok2',
      displayName: 'Grok',
      account: 'home@gmail.com',
      plan: 'free',
      asOf: now,
      windows: [w('weekly', 22, 6 * 86400)],
    ),
    // Local runtime, idle.
    ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: '3 models',
      kind: ProviderQuotaKind.local,
      asOf: now,
      status: '3 models, idle',
      details: const ['qwen2.5-coder:7b 4.0GB Q4_K_M on disk'],
    ),
  ];
}

void main(List<String> args) {
  final outDir = Directory(args.isNotEmpty ? args.first : '../docs/dev/qa-top');
  outDir.createSync(recursive: true);

  final demoFleet = demo.demoProviders(_now);
  final demoSuggestion = decide(
    demoFleet,
    _now,
    context: providerRouteDecisionContext(
      demoFleet,
      _now,
      burnStatsByProvider: demo.demoBurnStats(),
      catalog: kModelCatalog,
    ),
  ).route;
  final stress = _stressFleet(_now);
  final stressSuggestion = decide(
    stress,
    _now,
    context: providerRouteDecisionContext(
      stress,
      _now,
      catalog: kModelCatalog,
    ),
  ).route;

  void render(
    String name, {
    required List<ProviderQuota> providers,
    required RouteSuggestion suggestion,
    required int width,
    bool color = true,
    ColorDepth depth = ColorDepth.truecolor,
    String palette = 'default',
    String updated = 'updated 3s ago',
    String sort = 'default',
    String? selected,
    int hidden = 0,
    String copied = '',
  }) {
    final lines = renderTopFrame(
      providers: providers,
      suggestion: suggestion,
      now: _now,
      width: width,
      color: color,
      clock: _clock,
      depth: depth,
      palette: paletteFromSpec(palette),
      updated: updated,
      sort: sort,
      selected: selected,
      hidden: hidden,
      copied: copied,
    );
    final file = File('${outDir.path}/$name.ans');
    file.writeAsStringSync('${lines.join('\n')}\n');
    stdout.writeln('wrote ${file.path} (${lines.length} lines x $width cols)');
  }

  render('demo-100-truecolor',
      providers: demoFleet, suggestion: demoSuggestion, width: 100);
  render('demo-80-truecolor',
      providers: demoFleet, suggestion: demoSuggestion, width: 80);
  render('demo-60-truecolor',
      providers: demoFleet, suggestion: demoSuggestion, width: 60);
  render('demo-40-truecolor',
      providers: demoFleet, suggestion: demoSuggestion, width: 40);
  render('demo-100-ansi16',
      providers: demoFleet,
      suggestion: demoSuggestion,
      width: 100,
      depth: ColorDepth.ansi16);
  render('demo-80-nocolor',
      providers: demoFleet,
      suggestion: demoSuggestion,
      width: 80,
      color: false,
      depth: ColorDepth.none,
      updated: '',
      sort: '');
  render('demo-100-green',
      providers: demoFleet,
      suggestion: demoSuggestion,
      width: 100,
      palette: 'green');
  render('demo-100-synthwave',
      providers: demoFleet,
      suggestion: demoSuggestion,
      width: 100,
      palette: 'synthwave');
  render('demo-100-selected',
      providers: demoFleet,
      suggestion: demoSuggestion,
      width: 100,
      sort: 'headroom',
      selected: 'codex',
      hidden: 2,
      copied: 'claude');
  render('stress-100-truecolor',
      providers: stress, suggestion: stressSuggestion, width: 100);
  render('stress-80-truecolor',
      providers: stress, suggestion: stressSuggestion, width: 80);
}
