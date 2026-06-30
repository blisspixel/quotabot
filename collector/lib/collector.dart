import 'adapters/antigravity.dart';
import 'adapters/claude.dart';
import 'adapters/codex.dart';
import 'adapters/cursor.dart';
import 'adapters/grok.dart';
import 'adapters/kiro.dart';
import 'adapters/lemonade.dart';
import 'adapters/lmstudio.dart';
import 'adapters/ollama.dart';
import 'dart:io';

import 'adapters/windsurf.dart';
import 'analysis.dart';
import 'cache.dart';
import 'demo.dart';
import 'models.dart';
import 'util.dart';

export 'models.dart';
export 'insights.dart';
export 'alerts.dart';
export 'calibration.dart';
export 'model_catalog.dart';
export 'palette.dart';
export 'registry.dart';
export 'cache.dart'
    show
        loadHistory,
        loadBuckets,
        recentBurnByProvider,
        recentBurnStatsByProvider;

/// Whether the one-time temp-file sweep has run this process.
bool _sweptTemp = false;

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
    _withCache(() => ClaudeAdapter().collect()),
    _withCache(() => CodexAdapter().collect()),
    _withCache(() => CursorAdapter().collect()),
    _withCache(() => WindsurfAdapter().collect()),
    _withCache(() => KiroAdapter().collect()),
    // Local runtimes are live probes: never serve a cached "available" when the
    // daemon is actually off, so they are collected without the cache fallback.
    OllamaAdapter().collect(),
    LmStudioAdapter().collect(),
    LemonadeAdapter().collect(),
  ]);
  final groks = await _collectGrokMulti();
  final antis = await _collectAntigravityMulti();
  // A local runtime that is not running is not ok; drop it so users who do not
  // run one never see an empty card. Cloud providers stay even when empty.
  final results = [
    ...others,
    ...groks,
    ...antis,
  ].where((q) => !(q.isLocal && !q.ok)).toList();
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
    if (!seen.add(q.provider)) continue; // one sample per provider per collect
    final h = providerHeadroom(q, now);
    if (h != null) recordHeadroomSample(q.provider, h, now);
  }
}

Future<List<ProviderQuota>> _collectGrokMulti() async {
  final collected = await GrokAdapter().collectAccounts();
  final results = <ProviderQuota>[];
  for (final q in collected) {
    results.add(_cacheResult(q));
  }
  final currentAccts = GrokAdapter.currentAccounts;
  for (final cached in loadAllGrokSnapshots()) {
    if (cached.hasWindows &&
        currentAccts.contains(cached.account) &&
        !results.any((q) => q.account == cached.account)) {
      results.add(cached.asStale(cached.error ?? 'cached account'));
    }
  }
  return results;
}

Future<List<ProviderQuota>> _collectAntigravityMulti() async {
  final primary = await _withCache(
    () => AntigravityAdapter().collect(),
  );
  final results = <ProviderQuota>[primary];
  // include other known accounts from per-account caches ONLY if still active/detected
  // in current Antigravity profiles (to auto-hide previous accounts after switch).
  final currentAccts = AntigravityAdapter.currentAccounts;
  final others = loadAllAntigravitySnapshots();
  for (final other in others) {
    if (other.account != primary.account &&
        other.hasWindows &&
        currentAccts.contains(other.account)) {
      results.add(other.asStale(other.error ?? 'cached account'));
    }
  }
  // Full multi: discovered profiles now scanned cross-platform in adapter.
  // Additional live attempts for non-primary accounts are best-effort via cache
  // fallback; direct multi live collect can be expanded using per-db token extraction.
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
    saveSnapshot(result);
    return result;
  }
  // Read failed or returned no windows; serve last-known if we have one.
  // Antigravity is cached per account, so load the accounted file for the
  // active account rather than the generic (never-written) antigravity.json.
  final cached = switch (result.provider) {
    AntigravityAdapter.id => loadAntigravitySnapshot(result.account),
    GrokAdapter.id => loadGrokSnapshot(result.account),
    _ => loadSnapshot(result.provider),
  };
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
    return cached.asStale(result.error ?? 'cached');
  }
  return result;
}
