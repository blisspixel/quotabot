import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:quotabot_collector/provider_adapters.dart';
import 'package:test/test.dart';

/// Degraded provider response shapes pinned as committed, sanitized fixtures and
/// driven through the pure parsers.
///
/// The healthy shape per adapter lives in the registry fixture set (one per
/// adapter, checked by provider_registry_test). These edge fixtures live under
/// `edge/` (ignored by that parity check, which counts only top-level files) and
/// capture the safety-critical states that were previously only exercised with
/// inline synthetic data: an exhausted plan, and a partial response missing a
/// window. Pinning the real shapes keeps the parsers honest under the states
/// that actually govern a "you are spent" decision.

Map<String, dynamic> _edge(String name) => jsonDecode(
      File('$kProviderFixtureRoot/edge/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  group('codex degraded shapes', () {
    test('an exhausted plan yields both windows fully spent', () {
      final windows = codexWindows(_edge('codex_exhausted.json'));
      expect(windows.map((w) => w.label), ['5h', 'weekly']);
      expect(windows.every((w) => w.usedPercent == 100), isTrue);
    });

    test('a response missing the weekly window parses the primary alone', () {
      final windows = codexWindows(_edge('codex_primary_only.json'));
      expect(windows.map((w) => w.label), ['5h']);
      expect(windows.single.usedPercent, 45);
    });
  });

  group('lm studio v1 shape (captured from a real 0.4.0+ server)', () {
    test('parses the real /api/v1/models body into loaded + installed', () {
      final parsed = lmStudioV1FromJson(_edge('lmstudio_v1.json'));
      expect(parsed!.installed.length, 2);
      expect(parsed.loaded.length, 1);
      final loaded = parsed.loaded.single;
      expect(loaded.name, 'example/coder-8b');
      expect(loaded.param, '7.5B');
      expect(loaded.quant, 'Q4_K_M');
      expect(loaded.context, 8192); // the running instance's context
    });
  });

  group('claude degraded shapes', () {
    test('an exhausted plan keeps every window with its spent utilization', () {
      final windows = claudeWindows(_edge('claude_exhausted.json'));
      expect(windows.map((w) => w.label), ['5h', 'weekly', 'opus']);
      final fiveHour = windows.firstWhere((w) => w.label == '5h');
      expect(fiveHour.usedPercent, 100);
      expect(fiveHour.resetsAt, isNotNull);
    });
  });
}
