import 'dart:io';

import 'adapters/antigravity.dart';
import 'adapters/claude.dart';
import 'adapters/codex.dart';
import 'adapters/cursor.dart';
import 'adapters/grok.dart';
import 'adapters/kiro.dart';
import 'adapters/lemonade.dart';
import 'adapters/lmstudio.dart';
import 'adapters/nvidia.dart';
import 'adapters/ollama.dart';
import 'adapters/windsurf.dart';
import 'analysis.dart';
import 'cache.dart';
import 'demo.dart';
import 'drift.dart';
import 'manual_quota.dart';
import 'models.dart';
import 'provider_ids.dart';
import 'util.dart';

export 'alerts.dart';
export 'cache.dart'
    show
        loadHistory,
        loadCachedSnapshots,
        loadBuckets,
        recentBurnByProvider,
        recentBurnStatsByProvider,
        recentBurnStatsByQuota;
export 'calibration.dart';
export 'catalog_audit.dart';
export 'insights.dart';
export 'leases.dart';
export 'litellm_metrics.dart';
export 'manual_quota.dart';
export 'model_catalog.dart';
export 'models.dart';
export 'palette.dart';
export 'profiles.dart';
export 'provider_adapters.dart';
export 'provider_filters.dart';
export 'provider_ids.dart';
export 'registry.dart';
export 'report.dart';
export 'schema_contracts.dart';
export 'simulation.dart';
export 'verification.dart';

/// Whether the one-time temp-file sweep has run this process.
bool _sweptTemp = false;

/// Hard deadline for one adapter's full collect, beyond its own per-request
/// HTTP timeouts. A hung provider (accepted TCP, no bytes; stacked retries)
/// degrades to a truthful timeout error for that provider instead of wedging
/// the whole fleet, the desktop refresh loop, and MCP snapshot calls.
const Duration kAdapterDeadline = Duration(seconds: 20);

Future<ProviderQuota> _withDeadline(
  String id,
  String displayName,
  Future<ProviderQuota> Function() run,
) =>
    run().timeout(
      kAdapterDeadline,
      onTimeout: () => ProviderQuota.error(
        id,
        displayName,
        'timed out after ${kAdapterDeadline.inSeconds}s',
        nowEpoch(),
      ),
    );

Future<List<ProviderQuota>> _listWithDeadline(
  String id,
  String displayName,
  Future<List<ProviderQuota>> Function() run,
) =>
    run().timeout(
      kAdapterDeadline,
      onTimeout: () => [
        ProviderQuota.error(
          id,
          displayName,
          'timed out after ${kAdapterDeadline.inSeconds}s',
          nowEpoch(),
        ),
      ],
    );

/// Runs every provider adapter concurrently and returns their snapshots.
/// Shared by the CLI (bin/collect.dart) and the desktop app.
Future<List<ProviderQuota>> collectAll() async {
  // Demo mode: synthetic data for previews and screenshots. Returns before any
  // adapter call or analytics write, so it touches no account and no history.
  if (Platform.environment['QUOTABOT_DEMO'] == '1') {
    return demoProviders(nowEpoch());
  }
  if (!_sweptTemp) {
    _sweptTemp = true;
    sweepStaleTempFiles(); // once per process, clear any crash leftovers
  }
  // Default order roughly follows how widely each is used, most popular first.
  // Multi-account providers are appended after this list so each account gets
  // its own cache fallback.
  final others = await Future.wait<ProviderQuota>([
    _withCache(() => _withDeadline(
        claudeProviderId, claudeProviderName, () => ClaudeAdapter().collect())),
    _withCache(() => _withDeadline(
        codexProviderId, codexProviderName, () => CodexAdapter().collect())),
    _withCache(() => _withDeadline(
        cursorProviderId, cursorProviderName, () => CursorAdapter().collect())),
    _withCache(() => _withDeadline(windsurfProviderId, windsurfProviderName,
        () => WindsurfAdapter().collect())),
    _withCache(() => _withDeadline(
        kiroProviderId, kiroProviderName, () => KiroAdapter().collect())),
    // Local runtimes are live probes: never serve a cached "available" when the
    // daemon is actually off, so they are collected without the cache fallback.
    _withDeadline(
        ollamaProviderId, ollamaProviderName, () => OllamaAdapter().collect()),
    _withDeadline(lmStudioProviderId, lmStudioProviderName,
        () => LmStudioAdapter().collect()),
    _withDeadline(lemonadeProviderId, lemonadeProviderName,
        () => LemonadeAdapter().collect()),
    _withDeadline(
        nvidiaProviderId, nvidiaProviderName, () => NvidiaAdapter().collect()),
  ]);
  final groks = await _collectGrokMulti();
  final antis = await _collectAntigravityMulti();
  final manual = loadManualProviderQuotas();
  // A local runtime that is not running is not ok; drop it so users who do not
  // run one never see an empty card. Cloud providers stay even when empty.
  // Every snapshot is sanitized last, so no provider-sourced string can carry
  // terminal control bytes to any display surface.
  final results = [
    ...others,
    ...groks,
    ...antis,
    ...manual,
  ].where((q) => !(q.isLocal && !q.ok)).map(sanitizeProviderQuota).toList();
  _recordAnalytics(results);
  return results;
}

/// Folds the current binding headroom of each live subscription into the
/// long-term analytics buckets. Local runtimes are skipped (their headroom is a
/// constant), and so are providers with no usable windows.
void _recordAnalytics(List<ProviderQuota> results) {
  final now = nowEpoch();
  final seen = <String>{};
  for (final q in results) {
    if (q.isLocal || !q.hasWindows) continue;
    if (q.isManual) continue;
    if (!seen.add(quotaIdentityKeyFor(q))) continue;
    final h = providerHeadroom(q, now);
    if (h != null) {
      recordHeadroomSample(q.provider, h, now, account: q.account);
    }
  }
}

Future<List<ProviderQuota>> _collectGrokMulti() async {
  final collected = await _listWithDeadline(
      grokProviderId, grokProviderName, () => GrokAdapter().collectAccounts());
  final results = <ProviderQuota>[];
  for (final q in collected) {
    results.add(_cacheResult(q));
  }
  results.addAll(currentAccountFallbacks(
    liveResults: results,
    cachedSnapshots: loadAllGrokSnapshots(),
    currentAccounts: GrokAdapter.currentAccounts,
  ));
  return results;
}

Future<List<ProviderQuota>> _collectAntigravityMulti() async {
  final collected = await _listWithDeadline(antigravityProviderId,
      antigravityProviderName, () => AntigravityAdapter().collectAccounts());
  final results = <ProviderQuota>[];
  for (final q in collected) {
    results.add(_cacheResult(q));
  }
  results.addAll(currentAccountFallbacks(
    liveResults: results,
    cachedSnapshots: loadAllAntigravitySnapshots(),
    currentAccounts: AntigravityAdapter.currentAccounts,
  ));
  return results;
}

/// Persists good reads and falls back to the last-known snapshot on failure.
Future<ProviderQuota> _withCache(
  Future<ProviderQuota> Function() run,
) async {
  final result = await run();
  return _cacheResult(result);
}

ProviderQuota _cacheResult(ProviderQuota result) {
  if (result.ok && result.hasWindows) {
    // Validate the fresh read against the last one before trusting it: a value
    // that is implausible versus the previous read (a reset that moved earlier,
    // usage that fell with no reset) is flagged suspect, not hidden.
    final previous = _loadCachedSnapshot(result);
    final drift = previous == null ? null : detectQuotaDrift(result, previous);
    final flagged = drift == null ? result : result.withSuspect(drift);
    saveSnapshot(flagged);
    return flagged;
  }
  // Read failed or returned no windows; serve last-known if we have one.
  final cached = _loadCachedSnapshot(result);
  if (cached != null && cached.hasWindows) {
    // For antigravity, only serve the cache if its account is still one of the
    // currently logged-in profiles. This prevents showing a previous account's
    // quota after the active login has switched.
    if (result.provider == AntigravityAdapter.id &&
        !AntigravityAdapter.currentAccounts.contains(cached.account)) {
      return result; // active login changed; surface the fresh (empty) result
    }
    if (result.provider == GrokAdapter.id &&
        !GrokAdapter.currentAccounts.contains(cached.account)) {
      return result;
    }
    return cached.asStale(result.error ?? 'cached', metadataFrom: result);
  }
  return result;
}

/// Loads the last-known snapshot for [result]'s provider and account.
/// Antigravity and Grok are cached per account, so the accounted file is loaded
/// for the active account rather than the generic (never-written) file.
ProviderQuota? _loadCachedSnapshot(ProviderQuota result) =>
    switch (result.provider) {
      AntigravityAdapter.id => loadAntigravitySnapshot(result.account),
      GrokAdapter.id => loadGrokSnapshot(result.account),
      _ => loadSnapshot(result.provider),
    };
