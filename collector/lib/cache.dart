import 'dart:convert';
import 'dart:io';

import 'drift.dart';
import 'insights.dart';
import 'models.dart';
import 'provider_adapters.dart';
import 'util.dart';

/// Last-known-good snapshot cache.
///
/// Admitted fresh provider reads are written here; when a later read fails,
/// comes back empty, or is rejected for drift, the collector serves trusted
/// cached evidence marked stale instead of blanking or laundering the provider.
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
const _maxDriftBytes = 16 * 1024;
const _driftSchema = 'quotabot.provider-drift.v1';
const _cacheObservedAtMicrosKey = 'cache_observed_at_micros';
const _driftObservedAtMicrosKey = 'observed_at_micros';

File _driftFile(String provider, String account) => File(
    '${cacheDir().path}/drift_${_safeProviderStem(provider)}_${_safeProviderStem(account)}.json');

File _evidenceLockFile(String provider, String account) {
  final scope =
      _accountScopedProviders.contains(provider) && _hasAccount(account)
          ? account
          : 'provider';
  return File(
    '${cacheDir().path}/evidence_${_safeProviderStem(provider)}_${_safeProviderStem(scope)}.lock',
  );
}

T _withEvidenceLock<T>(
  String provider,
  String account,
  T Function() run,
) {
  final file = _evidenceLockFile(provider, account);
  restrictOwnerOnlyDirectory(file.parent);
  if (!file.existsSync()) file.createSync(recursive: true);
  restrictOwnerOnlyFile(file);
  final lock = file.openSync(mode: FileMode.write);
  try {
    lock.lockSync(FileLock.blockingExclusive);
    return run();
  } finally {
    try {
      lock.unlockSync();
    } catch (_) {}
    lock.closeSync();
  }
}

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

void saveSnapshot(
  ProviderQuota q, {
  int? observedAtMicros,
}) {
  final observedAt = nowEpoch();
  if (!isTrustedQuotaEvidenceAt(q, observedAt)) return;
  final admittedMicros = observedAtMicros ?? _nowMicros();
  if (admittedMicros < 0) return;
  try {
    _withEvidenceLock(q.provider, q.account, () {
      final snapshotFile = _accountedFile(q);
      final candidate = _readCanonicalSnapshotEvidence(
        snapshotFile,
        provider: q.provider,
        account: q.account,
        newestAllowedAsOf: observedAt + kQuotaEvidenceClockSkewSeconds,
      );
      final existing = candidate != null &&
              (isTrustedQuotaEvidence(candidate) ||
                  isLegacySuspectQuotaEvidence(candidate))
          ? candidate
          : null;
      if (existing != null && existing.asOf > q.asOf) return;
      final existingMicros =
          existing == null ? null : _cacheFileObservationMicros(snapshotFile);
      if (existingMicros != null && existingMicros >= admittedMicros) return;
      _writeTrustedSnapshotUnlocked(q, admittedMicros);
    });
  } catch (_) {
    // Cache is best-effort; ignore write failures.
  }
}

int _nowMicros() => DateTime.now().microsecondsSinceEpoch;

void _writeTrustedSnapshotUnlocked(ProviderQuota quota, int observedMicros) {
  _atomicWrite(
    _accountedFile(quota),
    jsonEncode({
      ...quota.toJson(),
      _cacheObservedAtMicrosKey: observedMicros,
    }),
  );
  saveHistory(quota);
  _clearProviderDriftObservation(
    quota.provider,
    quota.account,
    observedMicros,
  );
}

/// Linearizable evidence admission for one provider/account. The comparison,
/// generation check, trusted-cache update, and drift-marker update share one
/// interprocess lock so a stalled older collector cannot overwrite or clear a
/// newer observation.
ProviderQuota admitAndCacheQuotaEvidence(
  ProviderQuota fresh, {
  required int observedAt,
  required int observedAtMicros,
  String? rejectionReason,
}) {
  final unusableReason = rejectionReason == null
      ? unusableQuotaEvidenceDriftReason(
          fresh,
          observedAt: observedAt,
        )
      : boundedQuotaDriftReason(rejectionReason);
  if ((!isTrustedQuotaEvidence(fresh) && unusableReason == null) ||
      observedAtMicros < 0) {
    return fresh;
  }
  try {
    return _withEvidenceLock(fresh.provider, fresh.account, () {
      final file = _accountedFile(fresh);
      final current = _readCanonicalSnapshotEvidence(
        file,
        provider: fresh.provider,
        account: fresh.account,
        newestAllowedAsOf: observedAt + kQuotaEvidenceClockSkewSeconds,
      );
      final baseline = current != null &&
              (isTrustedQuotaEvidence(current) ||
                  isLegacySuspectQuotaEvidence(current))
          ? current
          : null;
      final currentMicros =
          baseline == null ? null : _cacheFileObservationMicros(file);
      if (baseline != null &&
          ((unusableReason == null && baseline.asOf > fresh.asOf) ||
              (currentMicros != null && currentMicros >= observedAtMicros))) {
        if (isLegacySuspectQuotaEvidence(baseline)) {
          return quarantineLegacyQuotaEvidence(
            baseline,
            observedAt: observedAt,
            metadataFrom: fresh,
          );
        }
        return _attachProviderDriftObservationUnlocked(
          baseline,
          now: observedAt,
        );
      }

      final admission = admitQuotaEvidence(
        fresh,
        baseline,
        observedAt: observedAt,
        rejectionReason: rejectionReason,
      );
      if (admission.shouldPersist) {
        _writeTrustedSnapshotUnlocked(admission.snapshot, observedAtMicros);
        return _attachProviderDriftObservationUnlocked(
          admission.snapshot,
          now: observedAt,
        );
      }
      if (baseline != null &&
          isTrustedQuotaEvidence(baseline) &&
          admission.driftReason != null) {
        _saveProviderDriftObservationUnlocked(
          baseline,
          admission.driftReason!,
          admission.snapshot.driftObservedAt ?? observedAt,
          observedAtMicros,
        );
      }
      return admission.snapshot;
    });
  } catch (_) {
    // Lock failure means the read cannot be ordered against concurrent
    // collectors. Never expose the fresh observation as current capacity.
    final current = _readCanonicalSnapshotEvidence(
      _accountedFile(fresh),
      provider: fresh.provider,
      account: fresh.account,
      newestAllowedAsOf: observedAt + kQuotaEvidenceClockSkewSeconds,
    );
    final baseline = current != null &&
            (isTrustedQuotaEvidence(current) ||
                isLegacySuspectQuotaEvidence(current))
        ? current
        : null;
    return _lockUnavailableAdmissionResult(
      fresh,
      baseline,
      observedAt: observedAt,
      rejectionReason: rejectionReason,
    );
  }
}

ProviderQuota _lockUnavailableAdmissionResult(
  ProviderQuota fresh,
  ProviderQuota? baseline, {
  required int observedAt,
  String? rejectionReason,
}) {
  if (rejectionReason != null) {
    final reason = boundedQuotaDriftReason(rejectionReason);
    if (baseline != null && isTrustedQuotaEvidence(baseline)) {
      return baseline.withProviderDrift(reason, observedAt);
    }
    return quarantineUnusableQuotaEvidence(fresh, reason, observedAt);
  }
  if (baseline != null && isLegacySuspectQuotaEvidence(baseline)) {
    return quarantineLegacyQuotaEvidence(
      baseline,
      observedAt: observedAt,
      metadataFrom: fresh,
    );
  }
  if (baseline != null && isTrustedQuotaEvidence(baseline)) {
    final withDrift =
        _attachProviderDriftObservationUnlocked(baseline, now: observedAt);
    if (withDrift.driftReason != null) return withDrift;
    return baseline.asStale(
      'quota evidence admission unavailable; showing last trusted snapshot',
      metadataFrom: fresh,
    );
  }
  return ProviderQuota(
    provider: fresh.provider,
    displayName: fresh.displayName,
    account: fresh.account,
    plan: fresh.plan,
    source: fresh.source,
    sourceClass: fresh.sourceClass,
    ok: false,
    error: 'quota evidence admission unavailable; no trusted snapshot is '
        'available',
    asOf: fresh.asOf,
    stale: true,
    kind: fresh.kind,
    status: fresh.status,
    active: fresh.active,
    details: fresh.details,
    models: fresh.models,
    perMachine: fresh.perMachine,
    pipeHealth: fresh.pipeHealth,
    httpStatus: fresh.httpStatus,
    retryAfterSeconds: fresh.retryAfterSeconds,
  );
}

/// Most history rows retained per provider. Bounds file growth so the jsonl
/// never grows without limit and the tail read stays cheap.
const _historyCap = 200;

void saveHistory(ProviderQuota q) {
  if (!isTrustedQuotaEvidenceAt(q, nowEpoch())) return;
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

Set<String> get _accountScopedProviders => {
      for (final entry in kProviderAdapterRegistry)
        if (entry.accountScopedCache) entry.id,
    };

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

ProviderQuota? _readSnapshotEvidence(File file) {
  if (!file.existsSync() || file.lengthSync() > _maxJsonBytes) return null;
  try {
    return ProviderQuota.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  } catch (_) {
    return null;
  }
}

ProviderQuota? _readCanonicalSnapshotEvidence(
  File file, {
  required String provider,
  required String account,
  required int newestAllowedAsOf,
  bool requireExactAccount = false,
}) {
  final quota = _readSnapshotEvidence(file);
  if (quota == null ||
      quota.provider != provider ||
      !_isRegisteredCacheEvidence(quota) ||
      quota.asOf <= 0 ||
      quota.asOf > newestAllowedAsOf) {
    return null;
  }
  final accountScoped =
      _accountScopedProviders.contains(provider) && _hasAccount(account);
  if ((requireExactAccount || accountScoped) && quota.account != account) {
    return null;
  }
  return quota;
}

bool _isRegisteredCacheEvidence(ProviderQuota quota) =>
    registeredSourceClassViolation(
      quota,
      providerAdapterById(quota.provider),
    ) ==
    null;

ProviderQuota? loadSnapshot(String provider) {
  final quota = _readCanonicalSnapshotEvidence(
    _file(provider),
    provider: provider,
    account: '',
    newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
  );
  return quota != null && isTrustedQuotaEvidence(quota) ? quota : null;
}

/// Loads trusted quota or a pre-quarantine legacy suspect snapshot solely for
/// admission comparison. Callers must never route, display windows from, or
/// append history from a legacy result.
ProviderQuota? loadSnapshotForAdmission(String provider) {
  final quota = _readCanonicalSnapshotEvidence(
    _file(provider),
    provider: provider,
    account: '',
    newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
  );
  return quota != null &&
          (isTrustedQuotaEvidence(quota) || isLegacySuspectQuotaEvidence(quota))
      ? quota
      : null;
}

/// Loads the last-known-good per-account snapshot for [provider]/[account], or
/// null when none exists. Per-account snapshots are written as
/// `<provider>_<account>.json` because one machine can hold several logins, so
/// the plain `loadSnapshot(provider)` path never finds them.
ProviderQuota? loadAccountSnapshot(String provider, String account) {
  if (!_hasAccount(account)) return null;
  final quota = _readCanonicalSnapshotEvidence(
    _accountedPath(provider, account),
    provider: provider,
    account: account,
    newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
    requireExactAccount: true,
  );
  return quota != null && isTrustedQuotaEvidence(quota) ? quota : null;
}

/// Per-account counterpart to [loadSnapshotForAdmission].
ProviderQuota? loadAccountSnapshotForAdmission(
  String provider,
  String account,
) {
  if (!_hasAccount(account)) return null;
  final quota = _readCanonicalSnapshotEvidence(
    _accountedPath(provider, account),
    provider: provider,
    account: account,
    newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
    requireExactAccount: true,
  );
  return quota != null &&
          (isTrustedQuotaEvidence(quota) || isLegacySuspectQuotaEvidence(quota))
      ? quota
      : null;
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
        if (q.provider == provider &&
            _isRegisteredCacheEvidence(q) &&
            q.asOf > 0 &&
            q.asOf <= nowEpoch() + kQuotaEvidenceClockSkewSeconds &&
            entity.uri.pathSegments.last ==
                '${stem}_${_safeProviderStem(q.account)}.json' &&
            isTrustedQuotaEvidence(q)) {
          results.add(q);
        }
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
  final detectedAt = now ?? nowEpoch();
  final newestAllowedAsOf = detectedAt + kQuotaEvidenceClockSkewSeconds;
  try {
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.json') ||
          name.startsWith('buckets_') ||
          name.startsWith('drift_')) {
        continue;
      }
      if (entity.lengthSync() > _maxJsonBytes) continue;
      try {
        final q = ProviderQuota.fromJson(
          jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>,
        );
        if (!_isRegisteredCacheEvidence(q)) continue;
        final trusted = isTrustedQuotaEvidence(q);
        final legacySuspect = isLegacySuspectQuotaEvidence(q);
        if (!trusted && !legacySuspect) continue;
        if (q.asOf <= 0 || q.asOf > newestAllowedAsOf) continue;
        if (!_isCanonicalSnapshotFileName(name, q)) continue;
        final key = '${q.provider}\u0000${q.account}';
        final visible = legacySuspect
            ? quarantineLegacyQuotaEvidence(
                q,
                observedAt: detectedAt,
              )
            : q;
        final existing = byIdentity[key];
        if (existing == null || visible.asOf >= existing.asOf) {
          byIdentity[key] = visible;
        }
      } catch (_) {}
    }
  } catch (_) {}
  final out = byIdentity.values
      .map((quota) => isTrustedQuotaEvidence(quota)
          ? attachProviderDriftObservation(quota, now: now)
          : quota)
      .toList()
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

/// Records a rejected provider observation without modifying the trusted quota
/// snapshot or burn history. The diagnostic is local, bounded, sanitized, and
/// cleared by the next successfully admitted snapshot for the same identity.
void saveProviderDriftObservation(
  ProviderQuota trusted,
  String reason,
  int observedAt, {
  int? observedAtMicros,
}) {
  if (!isTrustedQuotaEvidence(trusted) || observedAt < 0) return;
  final observedMicros = observedAtMicros ?? _nowMicros();
  if (observedMicros < 0) return;
  final boundedReason = boundedQuotaDriftReason(reason);
  if (boundedReason.isEmpty) return;
  try {
    _withEvidenceLock(trusted.provider, trusted.account, () {
      _saveProviderDriftObservationUnlocked(
        trusted,
        boundedReason,
        observedAt,
        observedMicros,
      );
    });
  } catch (_) {
    // Diagnostics are best-effort. The in-memory result still fails closed.
  }
}

/// Attaches a persisted unresolved drift diagnostic to trusted quota evidence.
/// Invalid, mismatched, or future-dated diagnostics are ignored.
ProviderQuota attachProviderDriftObservation(
  ProviderQuota trusted, {
  int? now,
}) {
  if (!isTrustedQuotaEvidence(trusted)) return trusted;
  try {
    return _withEvidenceLock(
      trusted.provider,
      trusted.account,
      () => _attachProviderDriftObservationUnlocked(trusted, now: now),
    );
  } catch (_) {
    // If lock creation itself is unavailable, a best-effort read is safer than
    // silently dropping an existing fail-closed diagnostic.
    return _attachProviderDriftObservationUnlocked(trusted, now: now);
  }
}

ProviderQuota _attachProviderDriftObservationUnlocked(
  ProviderQuota trusted, {
  int? now,
}) {
  try {
    final file = _driftFile(trusted.provider, trusted.account);
    if (!file.existsSync() || file.lengthSync() > _maxDriftBytes) {
      return trusted;
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return trusted;
    final record = decoded.cast<String, dynamic>();
    final reason = record['reason'];
    final observedAt = record['observed_at'];
    final observedAtMicros = _driftObservationMicros(record);
    final trustedObservedAtMicros = _cacheObservationMicros(trusted);
    if (record['schema'] != _driftSchema ||
        record['provider'] != trusted.provider ||
        record['account'] != trusted.account ||
        reason is! String ||
        reason.trim().isEmpty ||
        observedAt is! int ||
        observedAt < 0 ||
        observedAtMicros == null ||
        (trustedObservedAtMicros != null &&
            trustedObservedAtMicros > observedAtMicros) ||
        observedAt > (now ?? nowEpoch()) + kQuotaEvidenceClockSkewSeconds) {
      return trusted;
    }
    return trusted.withProviderDrift(
      boundedQuotaDriftReason(reason),
      observedAt,
    );
  } catch (_) {
    return trusted;
  }
}

int? _driftObservationMicros(Map<String, dynamic> record) {
  final value = record[_driftObservedAtMicrosKey];
  if (value is int && value >= 0) return value;
  if (value != null) return null;
  final observedAt = record['observed_at'];
  return observedAt is int && observedAt >= 0 ? observedAt * 1000000 : null;
}

Map<String, dynamic>? _readDriftRecord(File file) {
  if (!file.existsSync() || file.lengthSync() > _maxDriftBytes) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

void _saveProviderDriftObservationUnlocked(
  ProviderQuota trusted,
  String boundedReason,
  int observedAt,
  int observedMicros,
) {
  final cacheMicros = _cacheFileObservationMicros(_accountedFile(trusted));
  if (cacheMicros != null && cacheMicros > observedMicros) return;
  final driftFile = _driftFile(trusted.provider, trusted.account);
  final currentDrift = _readDriftRecord(driftFile);
  final currentMicros =
      currentDrift == null ? null : _driftObservationMicros(currentDrift);
  if (currentMicros != null && currentMicros >= observedMicros) return;
  _atomicWrite(
    driftFile,
    jsonEncode({
      'schema': _driftSchema,
      'provider': trusted.provider,
      'account': trusted.account,
      'observed_at': observedAt,
      _driftObservedAtMicrosKey: observedMicros,
      'reason': boundedReason,
    }),
  );
}

int? _cacheFileObservationMicros(File file) {
  if (!file.existsSync() || file.lengthSync() > _maxJsonBytes) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final record = decoded.cast<String, dynamic>();
    final exact = record[_cacheObservedAtMicrosKey];
    final newestAllowed =
        _nowMicros() + kQuotaEvidenceClockSkewSeconds * 1000000;
    if (exact is int && exact >= 0 && exact <= newestAllowed) return exact;
    final asOf = record['as_of'];
    if (asOf is! int || asOf <= 0) return null;
    final fallback = asOf * 1000000;
    return fallback <= newestAllowed ? fallback : null;
  } catch (_) {
    return null;
  }
}

int? _asOfObservationMicros(int asOf) {
  if (asOf <= 0) return null;
  final value = asOf * 1000000;
  final newestAllowed = _nowMicros() + kQuotaEvidenceClockSkewSeconds * 1000000;
  return value <= newestAllowed ? value : null;
}

/// Returns the exact local observation generation stored with [trusted] when
/// it still matches the canonical cache record. Legacy cache files fall back to
/// `as_of` precision; equality remains quarantined conservatively.
int? _cacheObservationMicros(ProviderQuota trusted) {
  try {
    final file = _accountedFile(trusted);
    if (!file.existsSync() || file.lengthSync() > _maxJsonBytes) {
      return _asOfObservationMicros(trusted.asOf);
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final record = decoded.cast<String, dynamic>();
    if (record['provider'] != trusted.provider ||
        record['account'] != trusted.account ||
        record['as_of'] != trusted.asOf) {
      return _asOfObservationMicros(trusted.asOf);
    }
    return _cacheFileObservationMicros(file) ??
        _asOfObservationMicros(trusted.asOf);
  } catch (_) {
    return _asOfObservationMicros(trusted.asOf);
  }
}

void _clearProviderDriftObservation(
  String provider,
  String account,
  int admittedMicros,
) {
  try {
    final file = _driftFile(provider, account);
    if (!file.existsSync() || file.lengthSync() > _maxDriftBytes) return;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return;
    final record = decoded.cast<String, dynamic>();
    if (record['schema'] != _driftSchema ||
        record['provider'] != provider ||
        record['account'] != account) {
      return;
    }
    final driftMicros = _driftObservationMicros(record);
    if (driftMicros != null && admittedMicros > driftMicros) {
      file.deleteSync();
    }
  } catch (_) {}
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
    if (isTrustedQuotaEvidence(cached) &&
        currentAccounts.contains(cached.account) &&
        !liveAccounts.contains(cached.account)) {
      final withDrift = attachProviderDriftObservation(cached);
      out.add(withDrift.driftReason == null
          ? cached.asStale(cached.error ?? 'cached account')
          : withDrift);
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
    final observedAt = nowEpoch();
    // Last 48 raw checks: enough for a readable sparkline and a stable average.
    for (final line in lines.reversed.take(48)) {
      if (line.trim().isEmpty) continue;
      final content = jsonDecode(line) as Map<String, dynamic>;
      final quota = ProviderQuota.fromJson(content);
      if (_isRegisteredCacheEvidence(quota) &&
          isTrustedQuotaEvidenceAt(quota, observedAt)) {
        results.add(quota);
      }
    }
  } catch (_) {}
  return results.reversed.toList();
}
