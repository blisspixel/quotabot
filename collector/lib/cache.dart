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
Directory cacheDir() => quotabotDir('cache');

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
  final tmp = File('${f.path}.$pid.tmp');
  tmp.writeAsStringSync(contents);
  tmp.renameSync(f.path);
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
    final f = File(
        '${cacheDir().path}/history_${_safeProviderStem(q.provider)}.jsonl');
    final line = jsonEncode(q.toJson());
    if (!f.existsSync() || f.lengthSync() > _maxHistoryBytes) {
      f.writeAsStringSync('$line\n');
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
bool _hasAccount(String account) =>
    account.isNotEmpty && account != 'unknown' && account != 'default';

/// Path of the per-account snapshot file for [provider]/[account], e.g.
/// `antigravity_work_at_example.com.json`. One machine can hold several logins
/// for a provider, so each account's last-known-good snapshot is cached apart.
File _accountedPath(String provider, String account) => File(
    '${cacheDir().path}/${_safeProviderStem(provider)}_${_safeProviderStem(account)}.json');

File _accountedFile(ProviderQuota q) {
  // Antigravity is the one provider that currently reads several accounts, so
  // its snapshot is keyed per account. Other providers write the plain file
  // until they gain multi-account reads; the keying itself is generic
  // ([_accountedPath]) so opting a provider in is a one-line change.
  if (q.provider == 'antigravity' && _hasAccount(q.account)) {
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

/// Antigravity's per-account snapshot, by account. Thin alias over the generic
/// [loadAccountSnapshot]; kept for call-site clarity.
ProviderQuota? loadAntigravitySnapshot(String account) =>
    loadAccountSnapshot('antigravity', account);

/// All cached Antigravity snapshots across logged-in accounts. Thin alias over
/// the generic [loadAccountSnapshots].
List<ProviderQuota> loadAllAntigravitySnapshots() =>
    loadAccountSnapshots('antigravity');

// --- Long-term analytics buckets -------------------------------------------
//
// A second, coarser history tier sits alongside the raw buffer above: headroom
// is folded into hourly aggregate buckets retained for 90 days. The raw buffer
// gives the recent fine-grained shape; the buckets give cheap long-range
// analytics (see insights.dart). Both are fed from one ingestion point.

File _bucketsFile(String provider) =>
    File('${cacheDir().path}/buckets_${_safeProviderStem(provider)}.json');

/// Folds one headroom reading into the provider's current hour bucket, pruning
/// anything older than the retention window. Best-effort and bounded.
void recordHeadroomSample(String provider, double headroom, int now) {
  try {
    final buckets = loadBuckets(provider);
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
      _bucketsFile(provider),
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
  return out;
}

/// Loads a provider's hourly bucket series, oldest first. Empty when absent.
List<HeadroomBucket> loadBuckets(String provider) {
  try {
    final f = _bucketsFile(provider);
    if (!f.existsSync()) return [];
    if (f.lengthSync() > _maxJsonBytes) return [];
    final list = jsonDecode(f.readAsStringSync()) as List;
    final buckets = list
        .map((e) => HeadroomBucket.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return buckets;
  } catch (_) {
    return [];
  }
}

List<ProviderQuota> loadHistory(String provider) {
  final results = <ProviderQuota>[];
  final f =
      File('${cacheDir().path}/history_${_safeProviderStem(provider)}.jsonl');
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
