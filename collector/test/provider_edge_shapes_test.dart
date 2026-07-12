import 'dart:convert';
import 'dart:io';

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
