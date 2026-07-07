import 'dart:convert';
import 'dart:io';

import 'insights.dart';
import 'models.dart';
import 'util.dart';

/// Last-known-good snapshot cache.
///
/// Successful provider reads are written here; when a later read fails or comes
/// back empty (rate limit, expired token, logged-out account) the collector
/// serves the cached snapshot marked stale instead of blanking the provider.
Directory cacheDir() {
  final dir = quotabotDir('cache');
  restrictOwnerOnlyDirectory(dir);
  return dir;
}

String _safeProviderStem(String provider) {
  final safe = provider.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return safe.isEmpty ? 'unknown' : safe;
}

File _file(String provider) =>
    File('${cacheDir().path}/${_safeProviderStem(provider)}.json');

const _maxJsonBytes = 2 * 1024 * 1024;
const _maxHistoryBytes = 5 * 1024 * 1024;

/// Writes via a per-process temp file then rename, so a concurrent reader (the
/// app and the CLI can run at once) never sees a half-written file, and two
/// concurrent writers do not share one temp path.
void _atomicWrite(File f, String contents) {
  restrictOwnerOnlyDirectory(f.parent);
  final tmp = File('${f.path}.$pid.tmp');
  if (!tmp.existsSync()) tmp.createSync(recursive: true);
  restrictOwnerOnlyFile(tmp);
  tmp.writeAsStringSync(contents);
  tmp.renameSync(f.path);
  restrictOwnerOnlyFile(f);
}

/// Deletes leftover atomic-write temp files (e.g. from a process killed between
/// write and rename). Best-effort; safe because temp files end in ".tmp" and
/// loaders only read ".json"/".jsonl".
void sweepStaleTempFiles() {
  try {
    final dir = cacheDir();
    if (!dir.existsSync()) return;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    for (final e in dir.listSync()) {
      if (e is File &&
          e.path.endsWith('.tmp') &&
          e.statSync().modified.isBefore(cutoff)) {
        try {
          e.deleteSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
}

void saveSnapshot(ProviderQuota q) {
  try {
    _atomicWrite(_accountedFile(q), jsonEncode(q.toJson()));
    saveHistory(q);
  } catch (_) {
    // Cache is best-effort; ignore write failures.
  }
}

/// Most history rows retained per provider. Bounds file growth so the jsonl
/// never grows without limit and the tail read stays cheap.
const _historyCap = 200;

void saveHistory(ProviderQuota q) {
  try {
    final f = _historyFile(q.provider, account: q.account);
    final line = jsonEncode(q.toJson());
    if (!f.existsSync() || f.lengthSync() > _maxHistoryBytes) {
      _atomicWrite(f, '$line\n');
      return;
    }
    final lines = f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList()
      ..add(line);
    final kept = lines.length > _historyCap
        ? lines.sublist(lines.length - _historyCap)
        : lines;
    _atomicWrite(f, '${kept.join('\n')}\n');
  } catch (_) {}
}

/// True when an account string names a specific account worth keying a per-
/// account cache file by, rather than a placeholder.
bool _hasAccount(String account) => hasSpecificQuotaAccount(account);

const _accountScopedProviders = {'antigravity', 'grok'};

/// Path of the per-account snapshot file for [provider]/[account], e.g.
/// `antigravity_work_at_example.com.json`. One machine can hold several logins
/// for a provider, so each account's last-known-good snapshot is cached apart.
File _accountedPath(String provider, String account) => File(
    '${cacheDir().path}/${_safeProviderStem(provider)}_${_safeProviderStem(account)}.json');

File _accountedFile(ProviderQuota q) {
  if (_accountScopedProviders.contains(q.provider) && _hasAccount(q.account)) {
    return _accountedPath(q.provider, q.account);
  }
  return _file(q.provider);
}

ProviderQuota? loadSnapshot(String provider) {
  try {
    final f = _file(provider);
    if (!f.existsSync()) return null;
    if (f.lengthSync() > _maxJsonBytes) return null;
    return ProviderQuota.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  } catch (_) {
    return null;
  }
}

/// Loads the last-known-good per-account snapshot for [provider]/[account], or
/// null when none exists. Per-account snapshots are written as
/// `<provider>_<account>.json` because one machine can hold several logins, so
/// the plain `loadSnapshot(provider)` path never finds them.
ProviderQuota? loadAccountSnapshot(String provider, String account) {
  if (!_hasAccount(account)) return null;
  final f = _accountedPath(provider, account);
  if (!f.existsSync() || f.lengthSync() > _maxJsonBytes) return null;
  try {
    return ProviderQuota.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  } catch (_) {
    return null;
  }
}

/// Every cached per-account snapshot for [provider] across the accounts seen on
/// this machine, plus the plain file when it holds a distinct account. The
/// generic form of the per-account scan (used today by Antigravity).
List<ProviderQuota> loadAccountSnapshots(String provider) {
  final results = <ProviderQuota>[];
  final dir = cacheDir();
  if (!dir.existsSync()) return results;
  final stem = _safeProviderStem(provider);
  try {
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      // Per-account files are "<stem>_<account>.json"; this prefix excludes the
      // history_/buckets_ siblings, and the parsed provider is checked below.
      if (!entity.uri.pathSegments.last.startsWith('${stem}_')) continue;
      try {
        if (entity.lengthSync() > _maxJsonBytes) continue;
        final q = ProviderQuota.fromJson(
          jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>,
        );
        if (q.provider == provider) results.add(q);
      } catch (_) {}
    }
    final main = loadSnapshot(provider);
    if (main != null && !results.any((r) => r.account == main.account)) {
      results.add(main);
    }
  } catch (_) {}
  return results;
}

/// Loads every last-known provider snapshot in the cache directory without
/// touching live providers. This is the cheap routing surface for per-request
/// routers: it trades freshness for speed, and callers receive explicit age and
/// stale metadata from the MCP layer.
List<ProviderQuota> loadCachedSnapshots({int? now}) {
  final dir = cacheDir();
  if (!dir.existsSync()) return const [];
  final byIdentity = <String, ProviderQuota>{};
  final newestAllowedAsOf = (now ?? nowEpoch()) + 60;
  try {
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.json') || name.startsWith('buckets_')) continue;
      if (entity.lengthSync() > _maxJsonBytes) continue;
      try {
        final q = ProviderQuota.fromJson(
          jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>,
        );
        if (q.asOf > newestAllowedAsOf) continue;
        if (!_isCanonicalSnapshotFileName(name, q)) continue;
        final key = '${q.provider}\u0000${q.account}';
        final existing = byIdentity[key];
        if (existing == null || q.asOf >= existing.asOf) {
          byIdentity[key] = q;
        }
      } catch (_) {}
    }
  } catch (_) {}
  final out = byIdentity.values.toList()
    ..sort((a, b) {
      final byProvider = a.provider.compareTo(b.provider);
      return byProvider != 0 ? byProvider : a.account.compareTo(b.account);
    });
  return out;
}

bool _isCanonicalSnapshotFileName(String name, ProviderQuota quota) {
  if (_accountScopedProviders.contains(quota.provider) &&
      _hasAccount(quota.account)) {
    return name ==
        '${_safeProviderStem(quota.provider)}_${_safeProviderStem(quota.account)}.json';
  }
  return name == '${_safeProviderStem(quota.provider)}.json';
}

/// Antigravity's per-account snapshot, by account. Thin alias over the generic
/// [loadAccountSnapshot]; kept for call-site clarity.
ProviderQuota? loadAntigravitySnapshot(String account) =>
    loadAccountSnapshot('antigravity', account);

/// All cached Antigravity snapshots across logged-in accounts. Thin alias over
/// the generic [loadAccountSnapshots].
List<ProviderQuota> loadAllAntigravitySnapshots() =>
    loadAccountSnapshots('antigravity');

ProviderQuota? loadGrokSnapshot(String account) =>
    loadAccountSnapshot('grok', account);

List<ProviderQuota> loadAllGrokSnapshots() => loadAccountSnapshots('grok');

/// Returns stale cache fallbacks only for accounts still present in the live
/// account index and not already returned by the adapter. This is the
/// signed-out auto-hide rule for multi-account providers.
List<ProviderQuota> currentAccountFallbacks({
  required Iterable<ProviderQuota> liveResults,
  required Iterable<ProviderQuota> cachedSnapshots,
  required Set<String> currentAccounts,
}) {
  final liveAccounts = {for (final q in liveResults) q.account};
  final out = <ProviderQuota>[];
  for (final cached in cachedSnapshots) {
    if (cached.hasWindows &&
        currentAccounts.contains(cached.account) &&
        !liveAccounts.contains(cached.account)) {
      out.add(cached.asStale(cached.error ?? 'cached account'));
    }
  }
  return out;
}

// --- Long-term analytics buckets -------------------------------------------
//
// A second, coarser history tier sits alongside the raw buffer above: headroom
// is folded into hourly aggregate buckets retained for 90 days. The raw buffer
// gives the recent fine-grained shape; the buckets give cheap long-range
// analytics (see insights.dart). Both are fed from one ingestion point.

File _historyFile(String provider, {String? account}) {
  final suffix = account != null && _hasAccount(account)
      ? '_${_safeProviderStem(account)}'
      : '';
  return File(
    '${cacheDir().path}/history_${_safeProviderStem(provider)}$suffix.jsonl',
  );
}

File _bucketsFile(String provider, {String? account}) {
  final suffix = account != null && _hasAccount(account)
      ? '_${_safeProviderStem(account)}'
      : '';
  return File(
    '${cacheDir().path}/buckets_${_safeProviderStem(provider)}$suffix.json',
  );
}

/// Folds one headroom reading into the provider/account current hour bucket,
/// pruning anything older than the retention window. Best-effort and bounded.
void recordHeadroomSample(
  String provider,
  double headroom,
  int now, {
  String? account,
}) {
  try {
    final buckets = loadBuckets(
      provider,
      account: account,
      fallbackToProvider: false,
    );
    final start = bucketStart(now);
    final cutoff = now - kRetentionDays * 86400;
    buckets.removeWhere((b) => b.start < cutoff);
    var current =
        buckets.isNotEmpty && buckets.last.start == start ? buckets.last : null;
    if (current == null) {
      current = HeadroomBucket(start: start);
      buckets.add(current);
    }
    current.add(headroom);
    _atomicWrite(
      _bucketsFile(provider, account: account),
      jsonEncode(buckets.map((b) => b.toJson()).toList()),
    );
  } catch (_) {
    // Analytics are best-effort; never let a write failure affect collection.
  }
}

/// Recent burn per provider (percent of quota per hour) read from local history,
/// for burn-aware routing. Null for a provider without enough history. A thin
/// I/O shell over [loadBuckets] and [burnRatePerHour] so [suggestRoute] stays a
/// pure function: the burn map is built here at the I/O boundary and passed in.
Map<String, double?> recentBurnByProvider(Iterable<String> providers, int now) {
  final stats = recentBurnStatsByProvider(providers, now);
  return {for (final e in stats.entries) e.key: e.value.perHour};
}

/// Recent burn with its uncertainty per provider, for risk-aware routing. A thin
/// I/O shell over [loadBuckets] and [burnRateWithError] so [suggestRoute] stays
/// pure: the stats are read here at the I/O boundary and passed in.
Map<String, BurnStat> recentBurnStatsByProvider(
  Iterable<String> providers,
  int now,
) {
  final out = <String, BurnStat>{};
  for (final provider in providers) {
    out[provider] = burnRateWithError(loadBuckets(provider), now);
  }
  return shrinkBurnStats(out);
}

/// Recent burn with account precision when the snapshot identifies an account.
/// Account-specific history is preferred. A provider-level fallback is used only
/// when this provider has a single account in the current snapshot, preserving
/// old history without applying one account's burn to another.
Map<String, BurnStat> recentBurnStatsByQuota(
  Iterable<ProviderQuota> providers,
  int now,
) {
  final list = providers.where((q) => !q.isLocal).toList();
  final measuredCounts = <String, int>{};
  for (final q in list) {
    if (q.isManual || !q.hasWindows) continue;
    measuredCounts[q.provider] = (measuredCounts[q.provider] ?? 0) + 1;
  }
  final out = <String, BurnStat>{};
  for (final q in list) {
    if (q.isManual || !q.hasWindows) continue;
    final key = quotaIdentityKeyFor(q);
    var buckets = hasSpecificQuotaAccount(q.account)
        ? loadBuckets(q.provider, account: q.account, fallbackToProvider: false)
        : loadBuckets(q.provider);
    if (buckets.isEmpty && (measuredCounts[q.provider] ?? 0) == 1) {
      buckets = loadBuckets(q.provider);
    }
    out[key] = burnRateWithError(buckets, now);
  }
  return shrinkBurnStats(out);
}

/// Loads a provider/account hourly bucket series, oldest first. Empty when
/// absent. When [fallbackToProvider] is true, account reads can fall back to the
/// legacy provider-only bucket file.
List<HeadroomBucket> loadBuckets(
  String provider, {
  String? account,
  bool fallbackToProvider = true,
}) {
  try {
    var f = _bucketsFile(provider, account: account);
    if (!f.existsSync() && account != null && fallbackToProvider) {
      f = _bucketsFile(provider);
    }
    if (!f.existsSync()) return [];
    if (f.lengthSync() > _maxJsonBytes) return [];
    final list = jsonDecode(f.readAsStringSync()) as List;
    // Drop only a malformed element, not the whole history: up to 90 days of
    // buckets is the most expensive local data to lose, and the lease and
    // manual stores are already per-entry resilient the same way.
    final buckets = <HeadroomBucket>[];
    for (final e in list) {
      if (e is! Map) continue;
      try {
        buckets.add(HeadroomBucket.fromJson(e.cast<String, dynamic>()));
      } catch (_) {}
    }
    buckets.sort((a, b) => a.start.compareTo(b.start));
    return buckets;
  } catch (_) {
    return [];
  }
}

List<ProviderQuota> loadHistory(String provider, {String? account}) {
  final results = <ProviderQuota>[];
  var f = _historyFile(provider, account: account);
  if (!f.existsSync() && account != null) {
    f = _historyFile(provider);
  }
  if (!f.existsSync()) return results;
  if (f.lengthSync() > _maxHistoryBytes) return results;
  try {
    final lines = f.readAsLinesSync();
    // Last 48 raw checks: enough for a readable sparkline and a stable average.
    for (final line in lines.reversed.take(48)) {
      if (line.trim().isEmpty) continue;
      final content = jsonDecode(line) as Map<String, dynamic>;
      results.add(ProviderQuota.fromJson(content));
    }
  } catch (_) {}
  return results.reversed.toList();
}
