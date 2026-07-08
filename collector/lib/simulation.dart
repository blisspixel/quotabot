/// Deterministic quota snapshots for CLI and integration tests.
///
/// Simulation mode is intentionally separate from demo mode. Demo mode shows a
/// believable mixed fleet for screenshots. Simulation mode creates one exact
/// provider state so tests can assert routing and exit-code behavior without
/// reading accounts, touching analytics history, or depending on wall-clock
/// provider data.
library;

import 'models.dart';
import 'profiles.dart';

const simulationStates = {
  'healthy',
  'low',
  'exhausted',
  'blocked',
  'signed-out',
  'stale',
  'metadata',
};

const _displayNames = {
  'antigravity': 'Antigravity',
  'claude': 'Claude',
  'codex': 'Codex',
  'cursor': 'Cursor',
  'grok': 'Grok',
  'kiro': 'Kiro',
  'windsurf': 'Devin Desktop',
};

/// Returns a normalized state name, or null when the state is unsupported.
String? normalizeSimulationState(String? state) {
  final normalized = state?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return 'healthy';
  return simulationStates.contains(normalized) ? normalized : null;
}

/// Returns one deterministic provider snapshot for [provider] in [state].
///
/// The reset offsets are fixed relative to [now], so outputs are stable enough
/// for tests while still exercising reset-aware rendering and routing logic.
ProviderQuota? simulateProvider({
  required String provider,
  required String state,
  required int now,
}) {
  final id = normalizeProviderId(provider);
  final normalizedState = normalizeSimulationState(state);
  if (id == null || normalizedState == null) return null;
  final displayName = _displayNames[id] ?? _title(id);
  if (normalizedState == 'signed-out') {
    return ProviderQuota.error(
        id, displayName, 'simulated signed-out state', now);
  }

  QuotaWindow window(String label, double used, int resetIn) => QuotaWindow(
        label: label,
        usedPercent: used,
        resetsAt: now + resetIn,
      );

  final windows = switch (normalizedState) {
    'healthy' => [
        window('5h', 24, 3 * 60 * 60),
        window('weekly', 41, 3 * 24 * 60 * 60),
      ],
    'low' => [
        window('5h', 92, 45 * 60),
        window('weekly', 58, 3 * 24 * 60 * 60),
      ],
    'exhausted' => [
        window('5h', 100, 42 * 60),
        window('weekly', 58, 3 * 24 * 60 * 60),
      ],
    'blocked' => [
        window('5h', 12, 2 * 60 * 60),
        window('weekly', 100, 27 * 60 * 60),
      ],
    'stale' => [
        window('5h', 39, 2 * 60 * 60),
        window('weekly', 52, 3 * 24 * 60 * 60),
      ],
    'metadata' => const <QuotaWindow>[],
    _ => const <QuotaWindow>[],
  };

  return ProviderQuota(
    provider: id,
    displayName: displayName,
    account: 'simulated',
    plan: 'simulation',
    asOf: normalizedState == 'stale' ? now - 3600 : now,
    stale: normalizedState == 'stale',
    error: normalizedState == 'stale' ? 'simulated stale cache' : null,
    status:
        normalizedState == 'metadata' ? 'simulated metadata-only state' : null,
    windows: windows,
  );
}

/// Returns a single-provider simulated fleet, or null for invalid input.
List<ProviderQuota>? simulateFleet({
  required String provider,
  required String state,
  required int now,
}) {
  final quota = simulateProvider(provider: provider, state: state, now: now);
  return quota == null ? null : [quota];
}

String _title(String id) => id
    .split('-')
    .map((p) => p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}')
    .join(' ');
