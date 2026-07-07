import 'dart:io';

import 'analysis.dart';
import 'cache.dart';
import 'demo.dart';
import 'drift.dart';
import 'manual_quota.dart';
import 'models.dart';
import 'provider_adapters.dart';
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

Future<List<ProviderQuota>> _listWithDeadline(
  ProviderAdapterRegistration entry,
) =>
    entry.collect().timeout(
          kAdapterDeadline,
          onTimeout: () => [
            ProviderQuota(
              provider: entry.id,
              displayName: entry.displayName,
              account: 'unknown',
              asOf: nowEpoch(),
              ok: false,
              error: 'timed out after ${kAdapterDeadline.inSeconds}s',
              kind: entry.adapterClass.quotaKind,
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
  final collected = await Future.wait([
    for (final entry in kProviderAdapterRegistry) _collectRegistered(entry),
  ]);
  final manual = loadManualProviderQuotas();
  // A local runtime that is not running is not ok; drop it so users who do not
  // run one never see an empty card. Cloud providers stay even when empty.
  // Every snapshot is sanitized last, so no provider-sourced string can carry
  // terminal control bytes to any display surface.
  final results = [
    for (final group in collected) ...group,
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

Future<List<ProviderQuota>> _collectRegistered(
  ProviderAdapterRegistration entry,
) async {
  final collected = await _listWithDeadline(entry);
  if (!entry.cached) return collected;
  final results = <ProviderQuota>[];
  for (final q in collected) {
    results.add(_cacheResult(q));
  }
  if (entry.accountScopedCache) {
    results.addAll(currentAccountFallbacks(
      liveResults: results,
      cachedSnapshots: loadAccountSnapshots(entry.id),
      currentAccounts: entry.currentAccounts!(),
    ));
  }
  return results;
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
    final entry = providerAdapterById(result.provider);
    if (entry?.accountScopedCache == true &&
        !entry!.currentAccounts!().contains(cached.account)) {
      return result;
    }
    return cached.asStale(result.error ?? 'cached', metadataFrom: result);
  }
  return result;
}

/// Loads the last-known snapshot for [result]'s provider and account.
/// Account-scoped providers are loaded by account rather than from the generic
/// provider file, because one machine can hold several provider logins.
ProviderQuota? _loadCachedSnapshot(ProviderQuota result) =>
    providerAdapterById(result.provider)?.accountScopedCache == true
        ? loadAccountSnapshot(result.provider, result.account)
        : loadSnapshot(result.provider);
