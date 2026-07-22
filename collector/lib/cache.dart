import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'drift.dart';
import 'insights.dart';
import 'models.dart';
import 'provider_adapters.dart';
import 'provider_ids.dart';
import 'schema_contracts.dart';
import 'storage_keys.dart';
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
  // Canonicalize first so cache/history/bucket filenames stay consistent under a
  // provider rename. Identity until a rename is registered.
  final canonical = canonicalizeProviderId(provider);
  final safe = canonical.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
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
const _legacyBucketOwnerSchema = 'quotabot.legacy-bucket-owner.v1';
const _analyticsMigrationSchema = 'quotabot.analytics-migration.v1';
const _analyticsLegacyBucketOwnerDigestKey = 'legacy_bucket_owner_digest';
const _analyticsRecoverySchema = 'quotabot.analytics-recovery.v1';
const _analyticsRecoveryEvidenceSchema =
    'quotabot.analytics-recovery-evidence.v1';
const _maxAnalyticsMigrationBytes = 1024 * 1024;
const _maxAnalyticsCheckpointBuckets = kRetentionDays * 24 + 2;
const _maxAnalyticsRecoveryEvidenceBytes = 16 * 1024 * 1024;
const _maxAnalyticsIncidents = 256;
const _maxAnalyticsIncidentScanBytes = 16 * 1024 * 1024;
const _maxAnalyticsIncidentDirectoryEntries = 4096;
const _maxAnalyticsIdentityBytes = 64 * 1024;
const _maxAnalyticsIncidentScanDuration = Duration(seconds: 10);
const _analyticsRecoveryTiers = {'history', 'buckets'};
const _analyticsRecoveryPreserved = [
  'current quota and credentials',
  'profiles, preferences, manual entries, leases, and alerts',
  'every other provider account',
  'the unselected analytics tier',
  'provider-only compatibility analytics',
];

/// Bounded, identity-safe evidence that a legacy analytics path changed after
/// the current canonical path was established, or that its checkpoint is no
/// longer trustworthy. Affected tiers fail closed until reconciliation can
/// prove a delta.
class AnalyticsStorageNotice {
  final String provider;
  final String account;
  final List<String> tiers;
  final int observedAt;

  const AnalyticsStorageNotice({
    required this.provider,
    required this.account,
    required this.tiers,
    required this.observedAt,
  });

  String get summary {
    final tierLabel = tiers.length == 1
        ? tiers.single == 'history'
            ? 'recent history'
            : 'hourly analytics'
        : 'recent history and hourly analytics';
    return 'History incomplete - local $tierLabel changed unexpectedly. '
        'Affected analytics are quarantined. Close every older quotabot process '
        'now. Exact merge is unavailable. Run quotabot doctor for the scoped '
        'archive-and-reset path.';
  }

  Map<String, dynamic> toJson() => {
        'state': 'diverged',
        'tiers': tiers,
        'observed_at': observedAt,
        'detail': summary,
      };
}

/// Public evidence for one unresolved local analytics incident.
///
/// No raw account, account digest, path, or recovery authority is retained in
/// this object. A provider row index is present only when the exact identity is
/// already visible in the enclosing snapshot.
class AnalyticsStorageIncident {
  final String provider;
  final List<String> tiers;
  final int recordedAt;
  final int? providerRowIndex;
  final String? incidentId;

  const AnalyticsStorageIncident({
    required this.provider,
    required this.tiers,
    required this.recordedAt,
    this.providerRowIndex,
    this.incidentId,
  });

  bool get exactAccountInSnapshot => providerRowIndex != null;

  String get providerName =>
      providerAdapterById(provider)?.displayName ?? provider;

  Map<String, dynamic> toJson() => {
        'schema': quotabotAnalyticsIncidentV1SchemaId,
        'state': 'diverged',
        'provider': provider,
        'tiers': tiers,
        'recorded_at': recordedAt,
        'exact_account_in_snapshot': exactAccountInSnapshot,
        if (providerRowIndex != null) 'provider_row_index': providerRowIndex,
        if (incidentId != null) 'incident_id': incidentId,
      };
}

/// Bounded scan result for the local analytics incident inventory.
///
/// A partial result never means clean. Consumers can use [state] and the
/// bounded counts to distinguish a verified empty inventory from incomplete
/// local evidence.
class AnalyticsIncidentInventory {
  final List<AnalyticsStorageIncident> incidents;
  final String state;
  final String scope;
  final int scannedMarkers;
  final int unverifiableMarkers;
  final int invalidMarkers;
  final bool truncated;
  final Set<String> uncertainProviders;
  final bool globalUncertainty;

  const AnalyticsIncidentInventory({
    required this.incidents,
    required this.state,
    required this.scope,
    required this.scannedMarkers,
    required this.unverifiableMarkers,
    required this.invalidMarkers,
    required this.truncated,
    this.uncertainProviders = const {},
    this.globalUncertainty = false,
  });

  const AnalyticsIncidentInventory.suppressed()
      : incidents = const [],
        state = 'suppressed',
        scope = 'simulation',
        scannedMarkers = 0,
        unverifiableMarkers = 0,
        invalidMarkers = 0,
        truncated = false,
        uncertainProviders = const {},
        globalUncertainty = false;

  bool get complete => state == 'complete';

  Map<String, dynamic> toJson() => {
        'schema': quotabotAnalyticsIncidentInventoryV1SchemaId,
        'state': state,
        'scope': scope,
        'scanned_markers': scannedMarkers,
        'unverifiable_markers': unverifiableMarkers,
        'invalid_markers': invalidMarkers,
        'truncated': truncated,
        'incidents': [for (final incident in incidents) incident.toJson()],
      };
}

class _AnalyticsIncidentEntry {
  final AnalyticsStorageIncident incident;
  final String accountDigest;

  const _AnalyticsIncidentEntry(this.incident, this.accountDigest);
}

class _AnalyticsIncidentResolution {
  final _AnalyticsIncidentEntry? entry;
  final bool complete;

  const _AnalyticsIncidentResolution(this.entry, {required this.complete});
}

/// Inspect or archive-and-reset outcome for one exact analytics conflict tier.
///
/// The result is intentionally bounded. The explicitly supplied account is
/// returned to the caller. The manifest and opaque bundle id omit raw account
/// and source-path text; archived source files retain their original quota
/// metadata by design and are protected by checked owner-only permissions.
class AnalyticsStorageRecoveryResult {
  final String mode;
  final String provider;
  final String account;
  final String tier;
  final List<String> activeTiers;
  final bool ready;
  final bool recovered;
  final String status;
  final String detail;
  final String? evidenceBundle;
  final List<String> archivedRoles;

  const AnalyticsStorageRecoveryResult({
    required this.mode,
    required this.provider,
    required this.account,
    required this.tier,
    required this.activeTiers,
    required this.ready,
    required this.recovered,
    required this.status,
    required this.detail,
    this.evidenceBundle,
    this.archivedRoles = const [],
  });

  Map<String, dynamic> toJson() => {
        'schema': _analyticsRecoverySchema,
        'mode': mode,
        'provider': provider,
        'account': account,
        'tier': tier,
        'active_tiers': activeTiers,
        'ready': ready,
        'recovered': recovered,
        'status': status,
        'detail': detail,
        'impact': {
          'selected_tier': recovered
              ? 'archived, then restarted empty'
              : evidenceBundle != null
                  ? 'archive attempted; quarantine retained'
                  : mode == 'inspect' && ready
                      ? 'would be archived, then restarted empty'
                      : 'unchanged',
          'exact_merge_performed': false,
          'preserved': _analyticsRecoveryPreserved,
        },
        if (evidenceBundle != null) 'evidence_bundle': evidenceBundle,
        if (archivedRoles.isNotEmpty) 'archived_roles': archivedRoles,
      };
}

class _AnalyticsRecoveryEvidence {
  final String role;
  final File source;
  final String extension;
  final List<int> precheckBytes;
  final String precheckDigest;
  final bool moveOriginal;

  const _AnalyticsRecoveryEvidence({
    required this.role,
    required this.source,
    required this.extension,
    required this.precheckBytes,
    required this.precheckDigest,
    required this.moveOriginal,
  });
}

String _accountStem(String account) => accountStorageStem(account);

File _legacyDriftFile(String provider, String account) => File(
    '${cacheDir().path}/drift_${_safeProviderStem(provider)}_${_safeProviderStem(account)}.json');

File _driftFile(String provider, String account) => File(
    '${cacheDir().path}/drift_${_safeProviderStem(provider)}_${_accountStem(account)}.json');

List<File> _driftFiles(String provider, String account) {
  final canonical = _driftFile(provider, account);
  final legacy = _legacyDriftFile(provider, account);
  return canonical.path == legacy.path ? [canonical] : [canonical, legacy];
}

List<File> _evidenceLockFiles(
  String provider,
  String account, {
  bool includeLegacy = false,
}) {
  final accountScoped =
      _accountScopedProviders.contains(provider) && _hasAccount(account);
  final scope = accountScoped ? _accountStem(account) : 'provider';
  final dir = cacheDir().path;
  final canonical = File(
    '$dir/evidence_${_safeProviderStem(provider)}_$scope.lock',
  );
  if (!accountScoped ||
      (!includeLegacy &&
          !_legacyAccountArtifactsExist(provider, account, dir))) {
    return [canonical];
  }
  final legacy = File(
    '$dir/evidence_${_safeProviderStem(provider)}_${_safeProviderStem(account)}.lock',
  );
  return legacy.path == canonical.path ? [canonical] : [legacy, canonical];
}

bool _legacyAccountArtifactsExist(
  String provider,
  String account,
  String dir,
) {
  final providerStem = _safeProviderStem(provider);
  final accountStem = _safeProviderStem(account);
  return [
    File('$dir/${providerStem}_$accountStem.json'),
    File('$dir/drift_${providerStem}_$accountStem.json'),
    File('$dir/history_${providerStem}_$accountStem.jsonl'),
    File('$dir/buckets_${providerStem}_$accountStem.json'),
    File('$dir/evidence_${providerStem}_$accountStem.lock'),
  ].any((file) => file.existsSync());
}

T _withEvidenceLock<T>(
  String provider,
  String account,
  T Function() run, {
  bool includeLegacy = false,
}) {
  final files = _evidenceLockFiles(
    provider,
    account,
    includeLegacy: includeLegacy,
  );
  T lockAt(int index) {
    if (index == files.length) return run();
    final file = files[index];
    restrictOwnerOnlyDirectory(file.parent);
    if (!file.existsSync()) file.createSync(recursive: true);
    restrictOwnerOnlyFile(file);
    final lock = file.openSync(mode: FileMode.write);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      return lockAt(index + 1);
    } finally {
      try {
        lock.unlockSync();
      } catch (_) {}
      lock.closeSync();
    }
  }

  return lockAt(0);
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

void _atomicWriteBytes(File f, List<int> contents) {
  restrictOwnerOnlyDirectory(f.parent);
  final tmp = File('${f.path}.$pid.tmp');
  if (!tmp.existsSync()) tmp.createSync(recursive: true);
  restrictOwnerOnlyFile(tmp);
  tmp.writeAsBytesSync(contents, flush: true);
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
      final evidence = _readSnapshotEvidenceForIdentity(
        q.provider,
        q.account,
        newestAllowedAsOf: observedAt + kQuotaEvidenceClockSkewSeconds,
      );
      final candidate = evidence?.quota;
      final existing = candidate != null &&
              (isTrustedQuotaEvidence(candidate) ||
                  isLegacySuspectQuotaEvidence(candidate))
          ? candidate
          : null;
      if (existing != null && existing.asOf > q.asOf) return;
      final existingMicros =
          existing == null ? null : _cacheFileObservationMicros(evidence!.file);
      if (existingMicros != null && existingMicros >= admittedMicros) return;
      _writeTrustedSnapshotUnlocked(q, admittedMicros);
    });
  } catch (_) {
    // Cache is best-effort; ignore write failures.
  }
}

int _nowMicros() => DateTime.now().microsecondsSinceEpoch;

/// The persisted form of a snapshot: its JSON minus fields valid only on a live,
/// fresh read. Reset-credit availability is such a signal - serving it back from
/// disk would assert a redeemable reset from stale evidence, which its contract
/// forbids - so it never enters the cache or history files.
Map<String, dynamic> _persistedSnapshotJson(ProviderQuota quota) =>
    quota.toJson()..remove('reset_credits_available');

void _writeTrustedSnapshotUnlocked(ProviderQuota quota, int observedMicros) {
  _atomicWrite(
    _accountedFile(quota),
    jsonEncode({
      ..._persistedSnapshotJson(quota),
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

/// Outcome of an explicit provider-drift baseline recovery attempt.
///
/// Status values are stable enough for the CLI's versioned recovery envelope.
/// A failed result never changes the persisted baseline or drift marker.
class ProviderDriftBaselineRecoveryResult {
  final bool recovered;
  final String status;
  final String detail;
  final ProviderQuota? snapshot;

  const ProviderDriftBaselineRecoveryResult({
    required this.recovered,
    required this.status,
    required this.detail,
    this.snapshot,
  });
}

ProviderDriftBaselineRecoveryResult _baselineRecoveryFailure(
  String status,
  String detail,
) =>
    ProviderDriftBaselineRecoveryResult(
      recovered: false,
      status: status,
      detail: detail,
    );

/// Replaces one exact provider/account drift baseline with a separately
/// verified fresh observation.
///
/// This exceptional path deliberately does not append or clear history. It
/// changes only the exact snapshot baseline and its older matching drift
/// diagnostic. The evidence lock and local observation generation prevent a
/// live read that started earlier from overwriting a newer cache or drift
/// decision.
ProviderDriftBaselineRecoveryResult recoverProviderDriftBaseline(
  ProviderQuota fresh, {
  required int observedAt,
  required int observedAtMicros,
}) {
  final registration = providerAdapterById(fresh.provider);
  final sourceViolation = registeredSourceClassViolation(
    fresh,
    registration,
    allowManual: false,
  );
  final newestAllowedMicros =
      _nowMicros() + kQuotaEvidenceClockSkewSeconds * 1000000;
  if (sourceViolation != null ||
      !isTrustedQuotaEvidenceAt(fresh, observedAt) ||
      observedAtMicros < 0 ||
      observedAtMicros > newestAllowedMicros) {
    return _baselineRecoveryFailure(
      'invalid_live_evidence',
      sourceViolation == null
          ? 'fresh provider evidence did not pass the quota trust boundary'
          : 'fresh provider evidence failed its registered source contract',
    );
  }

  try {
    return _withEvidenceLock(fresh.provider, fresh.account, () {
      final evidence = _readSnapshotEvidenceForIdentity(
        fresh.provider,
        fresh.account,
        newestAllowedAsOf: observedAt + kQuotaEvidenceClockSkewSeconds,
        requireExactAccount: true,
      );
      final baseline = evidence?.quota;
      if (baseline == null ||
          (!isTrustedQuotaEvidence(baseline) &&
              !isLegacySuspectQuotaEvidence(baseline))) {
        return _baselineRecoveryFailure(
          'baseline_not_found',
          'no recoverable baseline exists for the exact provider account',
        );
      }
      if (baseline.provider != fresh.provider ||
          baseline.account != fresh.account) {
        return _baselineRecoveryFailure(
          'identity_mismatch',
          'fresh evidence does not match the persisted baseline identity',
        );
      }

      final baselineMicros = _cacheFileObservationMicros(evidence!.file) ??
          _asOfObservationMicros(baseline.asOf);
      if (baseline.asOf > fresh.asOf ||
          (baselineMicros != null && baselineMicros >= observedAtMicros)) {
        return _baselineRecoveryFailure(
          'superseded',
          'a newer baseline was stored after this live read began',
        );
      }

      final legacyQuarantine = isLegacySuspectQuotaEvidence(baseline);
      if (!legacyQuarantine) {
        final visible = _attachProviderDriftObservationUnlocked(
          baseline,
          now: observedAt,
        );
        if (visible.driftReason == null) {
          return _baselineRecoveryFailure(
            'no_active_drift',
            'the exact provider account has no active drift quarantine',
          );
        }
      }

      final latestDrift = _latestDriftRecord(
        baseline.provider,
        baseline.account,
      );
      final driftMicros =
          latestDrift == null ? null : _driftObservationMicros(latestDrift);
      if (driftMicros != null && driftMicros >= observedAtMicros) {
        return _baselineRecoveryFailure(
          'superseded',
          'newer provider drift was recorded after this live read began',
        );
      }

      _writeRecoveredBaselineUnlocked(fresh, observedAtMicros);
      return ProviderDriftBaselineRecoveryResult(
        recovered: true,
        status: 'recovered',
        detail: 'fresh verified quota is now the exact account baseline',
        snapshot: fresh,
      );
    });
  } catch (_) {
    return _baselineRecoveryFailure(
      'storage_unavailable',
      'the exact provider account baseline could not be updated safely',
    );
  }
}

void _writeRecoveredBaselineUnlocked(
  ProviderQuota quota,
  int observedMicros,
) {
  _atomicWrite(
    _accountedFile(quota),
    jsonEncode({
      ..._persistedSnapshotJson(quota),
      _cacheObservedAtMicrosKey: observedMicros,
    }),
  );
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
      final evidence = _readSnapshotEvidenceForIdentity(
        fresh.provider,
        fresh.account,
        newestAllowedAsOf: observedAt + kQuotaEvidenceClockSkewSeconds,
      );
      final current = evidence?.quota;
      final baseline = current != null &&
              (isTrustedQuotaEvidence(current) ||
                  isLegacySuspectQuotaEvidence(current))
          ? current
          : null;
      final currentMicros =
          baseline == null ? null : _cacheFileObservationMicros(evidence!.file);
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
    final current = _readSnapshotEvidenceForIdentity(
      fresh.provider,
      fresh.account,
      newestAllowedAsOf: observedAt + kQuotaEvidenceClockSkewSeconds,
    )?.quota;
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
    planEvidenceSource: fresh.planEvidenceSource,
    planEvidenceAsOf: fresh.planEvidenceAsOf,
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
    if (_hasAccount(q.account) &&
        !_ensureHistoryMigrationBaseline(
          q.provider,
          q.account,
          canonicalExisted: f.existsSync(),
        )) {
      return;
    }
    final line = jsonEncode(_persistedSnapshotJson(q));
    final lines = f.existsSync() && f.lengthSync() <= _maxHistoryBytes
        ? f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList()
        : _legacyHistoryLinesForIdentity(q.provider, q.account);
    lines.add(line);
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

/// Opaque path of the per-account snapshot file for [provider]/[account]. One
/// machine can hold several logins for a provider, so each account's
/// last-known-good snapshot is cached apart without putting the account name in
/// its filename.
File _accountedPath(String provider, String account) => File(
    '${cacheDir().path}/${_safeProviderStem(provider)}_${_accountStem(account)}.json');

File _legacyAccountedPath(String provider, String account) => File(
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

({ProviderQuota quota, File file})? _readSnapshotEvidenceForIdentity(
  String provider,
  String account, {
  required int newestAllowedAsOf,
  bool requireExactAccount = false,
}) {
  final accountScoped =
      _accountScopedProviders.contains(provider) && _hasAccount(account);
  final files = accountScoped
      ? [
          _accountedPath(provider, account),
          _legacyAccountedPath(provider, account)
        ]
      : [_file(provider)];
  final seen = <String>{};
  ({ProviderQuota quota, File file})? selected;
  var selectedMicros = -1;
  for (final file in files) {
    if (!seen.add(file.path)) continue;
    final quota = _readCanonicalSnapshotEvidence(
      file,
      provider: provider,
      account: account,
      newestAllowedAsOf: newestAllowedAsOf,
      requireExactAccount: requireExactAccount || accountScoped,
    );
    if (quota == null) continue;
    final micros = _cacheFileObservationMicros(file) ?? quota.asOf * 1000000;
    if (selected == null ||
        quota.asOf > selected.quota.asOf ||
        (quota.asOf == selected.quota.asOf && micros > selectedMicros)) {
      selected = (quota: quota, file: file);
      selectedMicros = micros;
    }
  }
  return selected;
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
/// null when none exists. Per-account snapshots use an opaque account digest
/// because one machine can hold several logins, so the plain
/// `loadSnapshot(provider)` path never finds them. Legacy sanitized names are
/// still read only when the embedded account identity matches exactly.
ProviderQuota? loadAccountSnapshot(String provider, String account) {
  if (!_hasAccount(account)) return null;
  final quota = _readSnapshotEvidenceForIdentity(
    provider,
    account,
    newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
    requireExactAccount: true,
  )?.quota;
  return quota != null && isTrustedQuotaEvidence(quota) ? quota : null;
}

/// Per-account counterpart to [loadSnapshotForAdmission].
ProviderQuota? loadAccountSnapshotForAdmission(
  String provider,
  String account,
) {
  if (!_hasAccount(account)) return null;
  final quota = _readSnapshotEvidenceForIdentity(
    provider,
    account,
    newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
    requireExactAccount: true,
  )?.quota;
  return quota != null &&
          (isTrustedQuotaEvidence(quota) || isLegacySuspectQuotaEvidence(quota))
      ? quota
      : null;
}

/// Every cached per-account snapshot for [provider] across the accounts seen on
/// this machine, plus the plain file when it holds a distinct account. The
/// generic form of the per-account scan (used today by Antigravity).
List<ProviderQuota> loadAccountSnapshots(String provider) {
  final byIdentity = <String, ({ProviderQuota quota, int micros})>{};
  final dir = cacheDir();
  if (!dir.existsSync()) return const [];
  final stem = _safeProviderStem(provider);
  try {
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      // Per-account files start with the provider stem. This prefix excludes
      // the history_/buckets_ siblings, and the parsed provider is checked
      // below before either opaque or legacy names are accepted.
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
            _isCanonicalSnapshotFileName(
              entity.uri.pathSegments.last,
              q,
            ) &&
            isTrustedQuotaEvidence(q)) {
          final key = quotaIdentityKeyFor(q);
          final micros = _cacheFileObservationMicros(entity) ??
              q.asOf * Duration.microsecondsPerSecond;
          final existing = byIdentity[key];
          if (existing == null ||
              q.asOf > existing.quota.asOf ||
              (q.asOf == existing.quota.asOf && micros > existing.micros)) {
            byIdentity[key] = (quota: q, micros: micros);
          }
        }
      } catch (_) {}
    }
    final main = loadSnapshot(provider);
    if (main != null) {
      final key = quotaIdentityKeyFor(main);
      final existing = byIdentity[key];
      if (existing == null || main.asOf > existing.quota.asOf) {
        byIdentity[key] = (
          quota: main,
          micros: main.asOf * Duration.microsecondsPerSecond,
        );
      }
    }
  } catch (_) {}
  return byIdentity.values.map((entry) => entry.quota).toList()
    ..sort((a, b) => a.account.compareTo(b.account));
}

/// Loads every last-known provider snapshot in the cache directory without
/// touching live providers. This is the cheap routing surface for per-request
/// routers: it trades freshness for speed, and callers receive explicit age and
/// stale metadata from the MCP layer.
List<ProviderQuota> loadCachedSnapshots({int? now}) {
  final dir = cacheDir();
  if (!dir.existsSync()) return const [];
  final byIdentity = <String, ({ProviderQuota quota, int micros})>{};
  final detectedAt = now ?? nowEpoch();
  final newestAllowedAsOf = detectedAt + kQuotaEvidenceClockSkewSeconds;
  try {
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.json') ||
          name.startsWith('buckets_') ||
          name.startsWith('drift_') ||
          name.startsWith('analytics_migration_') ||
          name.startsWith('legacy_bucket_owner_')) {
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
        final micros = _cacheFileObservationMicros(entity) ??
            q.asOf * Duration.microsecondsPerSecond;
        final existing = byIdentity[key];
        if (existing == null ||
            visible.asOf > existing.quota.asOf ||
            (visible.asOf == existing.quota.asOf && micros > existing.micros)) {
          byIdentity[key] = (quota: visible, micros: micros);
        }
      } catch (_) {}
    }
  } catch (_) {}
  final out = byIdentity.values
      .map((entry) => entry.quota)
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
    final provider = _safeProviderStem(quota.provider);
    return name == '${provider}_${_accountStem(quota.account)}.json' ||
        name == '${provider}_${_safeProviderStem(quota.account)}.json';
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
    final trustedObservedAtMicros = _cacheObservationMicros(trusted);
    Map<String, dynamic>? selected;
    var selectedMicros = -1;
    for (final file in _driftFiles(trusted.provider, trusted.account)) {
      final record = _readDriftRecord(file);
      if (!_isDriftRecordForIdentity(
        record,
        trusted.provider,
        trusted.account,
      )) {
        continue;
      }
      final validRecord = record!;
      final reason = validRecord['reason'];
      final observedAt = validRecord['observed_at'];
      final observedAtMicros = _driftObservationMicros(validRecord);
      if (reason is! String ||
          reason.trim().isEmpty ||
          observedAt is! int ||
          observedAt < 0 ||
          observedAtMicros == null ||
          (trustedObservedAtMicros != null &&
              trustedObservedAtMicros > observedAtMicros) ||
          observedAt > (now ?? nowEpoch()) + kQuotaEvidenceClockSkewSeconds ||
          observedAtMicros <= selectedMicros) {
        continue;
      }
      selected = validRecord;
      selectedMicros = observedAtMicros;
    }
    if (selected == null) return trusted;
    return trusted.withProviderDrift(
      boundedQuotaDriftReason(selected['reason'] as String),
      selected['observed_at'] as int,
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

bool _isDriftRecordForIdentity(
  Map<String, dynamic>? record,
  String provider,
  String account,
) =>
    record != null &&
    record['schema'] == _driftSchema &&
    record['provider'] == provider &&
    record['account'] == account;

Map<String, dynamic>? _latestDriftRecord(
  String provider,
  String account,
) {
  Map<String, dynamic>? selected;
  var selectedMicros = -1;
  for (final file in _driftFiles(provider, account)) {
    final record = _readDriftRecord(file);
    if (!_isDriftRecordForIdentity(record, provider, account)) continue;
    final micros = _driftObservationMicros(record!);
    if (micros != null && micros > selectedMicros) {
      selected = record;
      selectedMicros = micros;
    }
  }
  return selected;
}

void _saveProviderDriftObservationUnlocked(
  ProviderQuota trusted,
  String boundedReason,
  int observedAt,
  int observedMicros,
) {
  final cacheMicros = _cacheObservationMicros(trusted);
  if (cacheMicros != null && cacheMicros > observedMicros) return;
  final driftFile = _driftFile(trusted.provider, trusted.account);
  final currentDrift = _latestDriftRecord(trusted.provider, trusted.account);
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
    final evidence = _readSnapshotEvidenceForIdentity(
      trusted.provider,
      trusted.account,
      newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
    );
    final file = evidence?.file;
    if (file == null ||
        !file.existsSync() ||
        file.lengthSync() > _maxJsonBytes) {
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
    for (final file in _driftFiles(provider, account)) {
      final record = _readDriftRecord(file);
      if (!_isDriftRecordForIdentity(record, provider, account)) continue;
      final driftMicros = _driftObservationMicros(record!);
      if (driftMicros != null && admittedMicros > driftMicros) {
        file.deleteSync();
      }
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
      ? '_${_accountStem(account)}'
      : '';
  return File(
    '${cacheDir().path}/history_${_safeProviderStem(provider)}$suffix.jsonl',
  );
}

File _legacyHistoryFile(String provider, {String? account}) {
  final suffix = account != null && _hasAccount(account)
      ? '_${_safeProviderStem(account)}'
      : '';
  return File(
    '${cacheDir().path}/history_${_safeProviderStem(provider)}$suffix.jsonl',
  );
}

File _bucketsFile(String provider, {String? account}) {
  final suffix = account != null && _hasAccount(account)
      ? '_${_accountStem(account)}'
      : '';
  return File(
    '${cacheDir().path}/buckets_${_safeProviderStem(provider)}$suffix.json',
  );
}

File _legacyBucketsFile(String provider, {String? account}) {
  final suffix = account != null && _hasAccount(account)
      ? '_${_safeProviderStem(account)}'
      : '';
  return File(
    '${cacheDir().path}/buckets_${_safeProviderStem(provider)}$suffix.json',
  );
}

File _analyticsMigrationFile(String provider, String account) => File(
      '${cacheDir().path}/analytics_migration_${_safeProviderStem(provider)}_${_accountStem(account)}.json',
    );

String _analyticsMigrationFileNameForDigest(
  String provider,
  String accountDigest,
) =>
    'analytics_migration_${_safeProviderStem(provider)}_account_$accountDigest.json';

List<File> _analyticsRecoveryTierFiles(
  String provider,
  String account,
  String tier,
) {
  final candidates = tier == 'history'
      ? [
          _historyFile(provider, account: account),
          _legacyHistoryFile(provider, account: account),
        ]
      : [
          _bucketsFile(provider, account: account),
          _legacyBucketsFile(provider, account: account),
        ];
  final seen = <String>{};
  return [
    for (final file in candidates)
      if (seen.add(file.path)) file
  ];
}

String _contentDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String _lineDigest(String line) => _contentDigest(line.trim());

Map<String, dynamic> _historyCheckpoint(String provider, String account) {
  final lines = _legacyHistoryLinesForIdentity(provider, account);
  final rowDigests = lines.map(_lineDigest).toList(growable: false);
  return {
    'digest': _contentDigest(rowDigests.join('\n')),
    'count': rowDigests.length,
    'row_digests': rowDigests,
  };
}

Map<String, dynamic> _emptyHistoryCheckpoint() => {
      'digest': _contentDigest(''),
      'count': 0,
      'row_digests': const <String>[],
    };

Map<String, dynamic> _emptyBucketCheckpoint() => {
      'digest': _contentDigest('[]'),
      'count': 0,
      'buckets': const <Map<String, dynamic>>[],
    };

({bool valid, List<HeadroomBucket> buckets}) _readBucketFile(File file) {
  if (!file.existsSync()) return (valid: true, buckets: const []);
  if (file.lengthSync() > _maxJsonBytes) {
    return (valid: false, buckets: const []);
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List) return (valid: false, buckets: const []);
    final buckets = <HeadroomBucket>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        buckets.add(
          HeadroomBucket.fromJson(entry.cast<String, dynamic>()),
        );
      } catch (_) {}
    }
    buckets.sort((a, b) => a.start.compareTo(b.start));
    return (valid: true, buckets: buckets);
  } catch (_) {
    return (valid: false, buckets: const []);
  }
}

Map<String, dynamic>? _bucketCheckpoint(File file) {
  final read = _readBucketFile(file);
  if (!read.valid || read.buckets.length > _maxAnalyticsCheckpointBuckets) {
    return null;
  }
  final baseline = read.buckets.map((bucket) => bucket.toJson()).toList();
  return {
    'digest': _contentDigest(jsonEncode(baseline)),
    'count': baseline.length,
    'buckets': baseline,
  };
}

Map<String, dynamic>? _readAnalyticsMigrationRecord(
  String provider,
  String account,
) {
  final file = _analyticsMigrationFile(provider, account);
  if (!file.existsSync() || file.lengthSync() > _maxAnalyticsMigrationBytes) {
    return null;
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final record = decoded.cast<String, dynamic>();
    if (record['schema'] != _analyticsMigrationSchema ||
        record['provider'] != provider ||
        record['account_digest'] != accountIdentityDigest(account)) {
      return null;
    }
    return record;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _newAnalyticsMigrationRecord(
  String provider,
  String account,
) =>
    {
      'schema': _analyticsMigrationSchema,
      'provider': provider,
      'account_digest': accountIdentityDigest(account),
      'observed_at': nowEpoch(),
    };

bool _validAnalyticsIncidentId(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

bool _validAnalyticsIncidentTimestamp(Object? value) =>
    value is int && value > 0;

String _newAnalyticsIncidentId() {
  final random = Random.secure();
  return List<int>.generate(16, (_) => random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

void _markAnalyticsConflict(
  Map<String, dynamic> record,
  String tier,
  String reason,
) {
  record['${tier}_conflict'] = true;
  record['${tier}_reason'] = reason;
  if (!_validAnalyticsIncidentId(record['incident_id'])) {
    record['incident_id'] = _newAnalyticsIncidentId();
  }
  if (!_validAnalyticsIncidentTimestamp(record['incident_observed_at'])) {
    record['incident_observed_at'] = nowEpoch();
  }
}

void _copyAnalyticsIncidentMetadata(
  Map<String, dynamic> target,
  Map<String, dynamic>? source,
) {
  final incidentId = source?['incident_id'];
  if (_validAnalyticsIncidentId(incidentId)) {
    target['incident_id'] = incidentId;
  }
  final observedAt = source?['incident_observed_at'];
  if (_validAnalyticsIncidentTimestamp(observedAt)) {
    target['incident_observed_at'] = observedAt;
  }
}

bool _writeAnalyticsMigrationRecord(
  String provider,
  String account,
  Map<String, dynamic> record,
) {
  try {
    record['observed_at'] = nowEpoch();
    final encoded = jsonEncode(record);
    if (utf8.encode(encoded).length > _maxAnalyticsMigrationBytes) return false;
    _atomicWrite(_analyticsMigrationFile(provider, account), encoded);
    return true;
  } catch (_) {
    return false;
  }
}

bool _checkpointMatches(Object? baseline, Map<String, dynamic> current) {
  if (baseline is! Map) return false;
  return baseline['digest'] == current['digest'] &&
      baseline['count'] == current['count'];
}

List<({int asOf, String digest})> _historyCheckpointRows(
  Iterable<String> lines,
) {
  final rows = <({int asOf, String digest})>[];
  for (final line in lines) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) continue;
      final quota = ProviderQuota.fromJson(decoded.cast<String, dynamic>());
      rows.add((asOf: quota.asOf, digest: _lineDigest(line)));
    } catch (_) {}
  }
  return rows;
}

bool _canonicalHistoryCoversLegacy(
  String provider,
  String account,
) {
  final legacyLines = _legacyHistoryLinesForIdentity(provider, account);
  if (legacyLines.isEmpty) return true;
  final canonicalLines = _historyLinesForIdentity(
    _historyFile(provider, account: account),
    provider,
    account,
  );
  final canonical = _historyCheckpointRows(canonicalLines);
  if (canonical.isEmpty) return false;
  final oldestCanonical = canonical
      .map((row) => row.asOf)
      .reduce((left, right) => left < right ? left : right);
  final canonicalDigests = canonical.map((row) => row.digest).toSet();
  for (final row in _historyCheckpointRows(legacyLines)) {
    if (row.asOf >= oldestCanonical && !canonicalDigests.contains(row.digest)) {
      return false;
    }
  }
  return true;
}

bool _bucketCovers(HeadroomBucket canonical, HeadroomBucket legacy) {
  const epsilon = 0.000001;
  if (canonical.count < legacy.count ||
      canonical.sum + epsilon < legacy.sum ||
      canonical.sumSq + epsilon < legacy.sumSq ||
      canonical.exhausted < legacy.exhausted) {
    return false;
  }
  if (legacy.count > 0 &&
      (canonical.min > legacy.min + epsilon ||
          canonical.max + epsilon < legacy.max)) {
    return false;
  }
  for (var index = 0; index < kHistBins; index++) {
    if (canonical.hist[index] < legacy.hist[index]) return false;
  }
  return true;
}

bool _canonicalBucketsCoverLegacy(File canonicalFile, File legacyFile) {
  final canonicalRead = _readBucketFile(canonicalFile);
  final legacyRead = _readBucketFile(legacyFile);
  if (!canonicalRead.valid || !legacyRead.valid) return false;
  if (legacyRead.buckets.isEmpty) return true;
  if (canonicalRead.buckets.isEmpty) return false;
  if (!legacyFile.lastModifiedSync().isBefore(
        canonicalFile.lastModifiedSync(),
      )) {
    return false;
  }
  final byStart = {
    for (final bucket in canonicalRead.buckets) bucket.start: bucket,
  };
  final oldestCanonical = canonicalRead.buckets.first.start;
  for (final legacy in legacyRead.buckets) {
    if (legacy.start < oldestCanonical) continue;
    final canonical = byStart[legacy.start];
    if (canonical == null || !_bucketCovers(canonical, legacy)) return false;
  }
  return true;
}

bool _ensureHistoryMigrationBaseline(
  String provider,
  String account, {
  required bool canonicalExisted,
}) {
  final canonical = _historyFile(provider, account: account);
  final legacy = _legacyHistoryFile(provider, account: account);
  if (canonical.path == legacy.path) return true;
  final marker = _analyticsMigrationFile(provider, account);
  final existing = _readAnalyticsMigrationRecord(provider, account);
  if (marker.existsSync() && existing == null) return false;
  final record = existing ?? _newAnalyticsMigrationRecord(provider, account);
  if (record['history_conflict'] == true) return false;
  final current = _historyCheckpoint(provider, account);
  if (record.containsKey('history')) {
    if (_checkpointMatches(record['history'], current)) return true;
    _markAnalyticsConflict(
      record,
      'history',
      'legacy history changed after checkpoint',
    );
    _writeAnalyticsMigrationRecord(provider, account, record);
    return false;
  }
  if (canonicalExisted && !_canonicalHistoryCoversLegacy(provider, account)) {
    _markAnalyticsConflict(
      record,
      'history',
      'legacy history changed before checkpoint',
    );
    _writeAnalyticsMigrationRecord(provider, account, record);
    return false;
  }
  record['history'] = current;
  if (_writeAnalyticsMigrationRecord(provider, account, record)) return true;
  record.remove('history');
  _markAnalyticsConflict(
    record,
    'history',
    'legacy history checkpoint could not be stored',
  );
  _writeAnalyticsMigrationRecord(provider, account, record);
  return false;
}

bool _ensureBucketMigrationBaseline(
  String provider,
  String account, {
  required bool canonicalExisted,
}) {
  final canonical = _bucketsFile(provider, account: account);
  final legacy = _legacyBucketsFile(provider, account: account);
  if (canonical.path == legacy.path) return true;
  final marker = _analyticsMigrationFile(provider, account);
  final existing = _readAnalyticsMigrationRecord(provider, account);
  if (marker.existsSync() && existing == null) return false;
  final record = existing ?? _newAnalyticsMigrationRecord(provider, account);
  if (record['buckets_conflict'] == true) return false;
  final legacyOwned = !legacy.existsSync() ||
      _legacyBucketOwnerAllows(provider, account, claim: true);
  if (!legacyOwned) return true;
  final current = _bucketCheckpoint(legacy);
  if (current == null) {
    _markAnalyticsConflict(
      record,
      'buckets',
      'legacy hourly analytics are invalid',
    );
    _writeAnalyticsMigrationRecord(provider, account, record);
    return false;
  }
  if (record.containsKey('buckets')) {
    if (_checkpointMatches(record['buckets'], current)) return true;
    _markAnalyticsConflict(
      record,
      'buckets',
      'legacy hourly analytics changed after checkpoint',
    );
    _writeAnalyticsMigrationRecord(provider, account, record);
    return false;
  }
  if (canonicalExisted &&
      legacy.existsSync() &&
      !_canonicalBucketsCoverLegacy(canonical, legacy)) {
    _markAnalyticsConflict(
      record,
      'buckets',
      'legacy hourly analytics changed before checkpoint',
    );
    _writeAnalyticsMigrationRecord(provider, account, record);
    return false;
  }
  record['buckets'] = current;
  if (_writeAnalyticsMigrationRecord(provider, account, record)) return true;
  record.remove('buckets');
  _markAnalyticsConflict(
    record,
    'buckets',
    'legacy hourly analytics checkpoint could not be stored',
  );
  _writeAnalyticsMigrationRecord(provider, account, record);
  return false;
}

int _fileObservedAt(File file) {
  try {
    return file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
  } catch (_) {
    return nowEpoch();
  }
}

bool _historyMigrationConflict(String provider, String account) {
  final canonical = _historyFile(provider, account: account);
  final legacy = _legacyHistoryFile(provider, account: account);
  if (canonical.path == legacy.path) return false;
  final marker = _analyticsMigrationFile(provider, account);
  final record = _readAnalyticsMigrationRecord(provider, account);
  if (marker.existsSync() && record == null) return true;
  if (record?['history_conflict'] == true) return true;
  final current = _historyCheckpoint(provider, account);
  if (record?.containsKey('history') == true) {
    return !_checkpointMatches(record?['history'], current);
  }
  if (!canonical.existsSync()) return false;
  if ((current['count'] as int) == 0 && record == null) return false;
  return true;
}

bool _bucketMigrationConflict(String provider, String account) {
  final canonical = _bucketsFile(provider, account: account);
  final legacy = _legacyBucketsFile(provider, account: account);
  if (canonical.path == legacy.path) return false;
  final marker = _analyticsMigrationFile(provider, account);
  final record = _readAnalyticsMigrationRecord(provider, account);
  if (marker.existsSync() && record == null) return true;
  if (record?['buckets_conflict'] == true) return true;
  final legacyOwned = !legacy.existsSync() ||
      _legacyBucketOwnerAllows(provider, account, claim: false);
  if (record?.containsKey('buckets') == true) {
    if (!legacyOwned) return true;
    final current = _bucketCheckpoint(legacy);
    return current == null || !_checkpointMatches(record?['buckets'], current);
  }
  if (!canonical.existsSync()) return false;
  if (!legacyOwned) return false;
  if (!legacy.existsSync()) return false;
  final current = _bucketCheckpoint(legacy);
  return current == null || record != null || (current['count'] as int) > 0;
}

List<HeadroomBucket>? _bucketsFromCheckpoint(Object? checkpoint) {
  if (checkpoint is! Map) return null;
  final rawBuckets = checkpoint['buckets'];
  final count = checkpoint['count'];
  final digest = checkpoint['digest'];
  if (rawBuckets is! List ||
      count is! int ||
      digest is! String ||
      count != rawBuckets.length ||
      count > _maxAnalyticsCheckpointBuckets ||
      _contentDigest(jsonEncode(rawBuckets)) != digest) {
    return null;
  }
  final buckets = <HeadroomBucket>[];
  try {
    for (final entry in rawBuckets) {
      if (entry is! Map) return null;
      buckets.add(HeadroomBucket.fromJson(entry.cast<String, dynamic>()));
    }
  } catch (_) {
    return null;
  }
  buckets.sort((left, right) => left.start.compareTo(right.start));
  return buckets;
}

List<HeadroomBucket> _trustedBucketsDuringConflict(
  String provider,
  String account,
) {
  final canonical = _bucketsFile(provider, account: account);
  if (canonical.existsSync()) {
    final read = _readBucketFile(canonical);
    if (read.valid) return List<HeadroomBucket>.of(read.buckets);
  }
  final record = _readAnalyticsMigrationRecord(provider, account);
  return List<HeadroomBucket>.of(
    _bucketsFromCheckpoint(record?['buckets']) ?? const [],
  );
}

double? _conservativeMaximum(double? left, double? right) {
  final finiteLeft = left != null && left.isFinite ? left : null;
  final finiteRight = right != null && right.isFinite ? right : null;
  if (finiteLeft == null) return finiteRight;
  if (finiteRight == null) return finiteLeft;
  return finiteLeft >= finiteRight ? finiteLeft : finiteRight;
}

BurnStat _conservativeBurnStat(BurnStat left, BurnStat right) => BurnStat(
      perHour: _conservativeMaximum(left.perHour, right.perHour),
      sePerHour: _conservativeMaximum(left.sePerHour, right.sePerHour),
      samples: left.samples <= right.samples ? left.samples : right.samples,
    );

({BurnStat onBoundary, BurnStat afterBoundary}) _conflictBurnCandidates(
  List<HeadroomBucket> buckets, {
  int? lookbackHours,
}) {
  if (buckets.isEmpty) {
    return (
      onBoundary: const BurnStat(),
      afterBoundary: const BurnStat(),
    );
  }

  BurnStat evaluate(int evaluationTime) => lookbackHours == null
      ? burnRateWithError(buckets, evaluationTime)
      : burnRateWithError(
          buckets,
          evaluationTime,
          lookbackHours: lookbackHours,
        );

  // The trusted snapshot records hourly bucket starts, not the sub-hour offset
  // of the last healthy evaluation. An exact-hour cutoff includes one boundary
  // bucket that every later offset excludes. Evaluate both possible sets and
  // retain both candidates so the conservative envelope can be enforced after
  // cross-provider shrinkage as well as before it.
  final onBoundary = evaluate(buckets.last.start);
  final afterBoundary = evaluate(buckets.last.start + 1);
  return (onBoundary: onBoundary, afterBoundary: afterBoundary);
}

/// Returns a bounded mixed-version analytics warning for one identity. No path,
/// raw account, sample, or file content leaves the storage boundary.
AnalyticsStorageNotice? analyticsStorageNotice(
  String provider, {
  String? account,
}) {
  final exactAccount = account != null && _hasAccount(account) ? account : null;
  if (exactAccount == null) return null;
  final tiers = <String>[];
  if (_historyMigrationConflict(provider, exactAccount)) tiers.add('history');
  if (_bucketMigrationConflict(provider, exactAccount)) tiers.add('buckets');
  if (tiers.isEmpty) return null;
  final legacyHistory = _legacyHistoryFile(provider, account: exactAccount);
  final legacyBuckets = _legacyBucketsFile(provider, account: exactAccount);
  final marker = _analyticsMigrationFile(provider, exactAccount);
  final observedAt = [legacyHistory, legacyBuckets, marker]
      .where((file) => file.existsSync())
      .map(_fileObservedAt)
      .fold(0, (latest, value) => value > latest ? value : latest);
  return AnalyticsStorageNotice(
    provider: provider,
    account: exactAccount,
    tiers: List.unmodifiable(tiers),
    observedAt: observedAt == 0 ? nowEpoch() : observedAt,
  );
}

AnalyticsStorageRecoveryResult _analyticsRecoveryResult({
  required String mode,
  required String provider,
  required String account,
  required String tier,
  required List<String> activeTiers,
  required bool ready,
  required bool recovered,
  required String status,
  required String detail,
  String? evidenceBundle,
  List<String> archivedRoles = const [],
}) =>
    AnalyticsStorageRecoveryResult(
      mode: mode,
      provider: provider,
      account: account,
      tier: tier,
      activeTiers: List.unmodifiable(activeTiers),
      ready: ready,
      recovered: recovered,
      status: status,
      detail: detail,
      evidenceBundle: evidenceBundle,
      archivedRoles: List.unmodifiable(archivedRoles),
    );

String? _legacyHistoryRecoveryFailure(
  List<int> bytes,
  String provider,
  String account,
) {
  try {
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map ||
          decoded['provider'] is! String ||
          decoded['account'] is! String) {
        return 'unsafe_evidence';
      }
      if (decoded['provider'] != provider || decoded['account'] != account) {
        return 'shared_legacy_evidence';
      }
    }
  } catch (_) {
    return 'unsafe_evidence';
  }
  return null;
}

({List<_AnalyticsRecoveryEvidence> evidence, String? failure})
    _analyticsRecoveryEvidence(
  String provider,
  String account,
  String tier,
) {
  final candidates =
      <({String role, File source, String extension, bool moveOriginal})>[];
  if (tier == 'history') {
    candidates.addAll([
      (
        role: 'canonical-history',
        source: _historyFile(provider, account: account),
        extension: '.jsonl',
        moveOriginal: true,
      ),
      (
        role: 'legacy-history',
        source: _legacyHistoryFile(provider, account: account),
        extension: '.jsonl',
        moveOriginal: true,
      ),
    ]);
  } else {
    candidates.addAll([
      (
        role: 'canonical-buckets',
        source: _bucketsFile(provider, account: account),
        extension: '.json',
        moveOriginal: true,
      ),
      (
        role: 'legacy-buckets',
        source: _legacyBucketsFile(provider, account: account),
        extension: '.json',
        moveOriginal: true,
      ),
      (
        role: 'legacy-bucket-owner',
        source: _legacyBucketOwnerFile(provider, account),
        extension: '.json',
        moveOriginal: false,
      ),
    ]);
  }
  candidates.add((
    role: 'migration-marker',
    source: _analyticsMigrationFile(provider, account),
    extension: '.json',
    moveOriginal: false,
  ));

  final evidence = <_AnalyticsRecoveryEvidence>[];
  final seenPaths = <String>{};
  var totalBytes = 0;
  for (final candidate in candidates) {
    if (!seenPaths.add(candidate.source.path)) continue;
    final type = FileSystemEntity.typeSync(
      candidate.source.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.file) {
      return (evidence: const [], failure: 'unsafe_evidence');
    }
    try {
      final length = candidate.source.lengthSync();
      if (length < 0 ||
          length > _maxAnalyticsRecoveryEvidenceBytes ||
          totalBytes + length > _maxAnalyticsRecoveryEvidenceBytes) {
        return (evidence: const [], failure: 'evidence_too_large');
      }
      final bytes = candidate.source.readAsBytesSync();
      if (bytes.length != length ||
          totalBytes + bytes.length > _maxAnalyticsRecoveryEvidenceBytes) {
        return (evidence: const [], failure: 'evidence_changed');
      }
      if (candidate.role == 'legacy-history') {
        final failure = _legacyHistoryRecoveryFailure(
          bytes,
          provider,
          account,
        );
        if (failure != null) return (evidence: const [], failure: failure);
      }
      if (candidate.role == 'legacy-buckets' &&
          !_legacyBucketRecoveryOwned(provider, account)) {
        return (evidence: const [], failure: 'shared_legacy_evidence');
      }
      totalBytes += bytes.length;
      evidence.add(
        _AnalyticsRecoveryEvidence(
          role: candidate.role,
          source: candidate.source,
          extension: candidate.extension,
          precheckBytes: bytes,
          precheckDigest: sha256.convert(bytes).toString(),
          moveOriginal: candidate.moveOriginal,
        ),
      );
    } catch (_) {
      return (evidence: const [], failure: 'unsafe_evidence');
    }
  }
  return (evidence: evidence, failure: null);
}

/// Read-only readiness check for one exact quarantined analytics tier.
///
/// This never creates a recovery bundle or lock file and never contacts a
/// provider. A confirmed recovery must repeat every check while holding the
/// exact provider/account evidence lock.
AnalyticsStorageRecoveryResult inspectAnalyticsStorageRecovery(
  String provider,
  String account,
  String tier,
) {
  final canonicalProvider =
      canonicalizeProviderId(provider.trim().toLowerCase());
  final selectedTier = tier.trim().toLowerCase();
  if (providerAdapterById(canonicalProvider) == null) {
    return _analyticsRecoveryResult(
      mode: 'inspect',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: const [],
      ready: false,
      recovered: false,
      status: 'unsupported_target',
      detail: 'The provider is not registered with this quotabot build.',
    );
  }
  if (!_hasAccount(account)) {
    return _analyticsRecoveryResult(
      mode: 'inspect',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: const [],
      ready: false,
      recovered: false,
      status: 'invalid_target',
      detail: 'Recovery requires one exact non-placeholder account identity.',
    );
  }
  if (!_analyticsRecoveryTiers.contains(selectedTier)) {
    return _analyticsRecoveryResult(
      mode: 'inspect',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: const [],
      ready: false,
      recovered: false,
      status: 'invalid_target',
      detail: 'Tier must be history or buckets.',
    );
  }

  final notice = analyticsStorageNotice(
    canonicalProvider,
    account: account,
  );
  final activeTiers = notice?.tiers ?? const <String>[];
  if (notice == null) {
    return _analyticsRecoveryResult(
      mode: 'inspect',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: activeTiers,
      ready: false,
      recovered: false,
      status: 'no_active_conflict',
      detail: 'No analytics storage conflict is active for this identity.',
    );
  }
  if (!activeTiers.contains(selectedTier)) {
    return _analyticsRecoveryResult(
      mode: 'inspect',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: activeTiers,
      ready: false,
      recovered: false,
      status: 'tier_not_conflicted',
      detail: 'The selected tier is not quarantined for this identity.',
    );
  }

  final evidence = _analyticsRecoveryEvidence(
    canonicalProvider,
    account,
    selectedTier,
  );
  if (evidence.failure != null) {
    final tooLarge = evidence.failure == 'evidence_too_large';
    final shared = evidence.failure == 'shared_legacy_evidence';
    return _analyticsRecoveryResult(
      mode: 'inspect',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: activeTiers,
      ready: false,
      recovered: false,
      status: evidence.failure!,
      detail: tooLarge
          ? 'Selected recovery evidence exceeds the 16 MiB safety limit.'
          : shared
              ? 'The legacy analytics file is not exclusive to this exact '
                  'account. No scoped recovery files can be changed safely.'
              : 'Selected recovery evidence is not a stable regular-file set.',
    );
  }
  return _analyticsRecoveryResult(
    mode: 'inspect',
    provider: canonicalProvider,
    account: account,
    tier: selectedTier,
    activeTiers: activeTiers,
    ready: true,
    recovered: false,
    status: 'ready',
    detail: 'Ready to archive this exact tier and restart it empty. '
        'Exact merge is unavailable; every listed preserved surface remains '
        'unchanged.',
  );
}

Directory _createAnalyticsRecoveryBundle(
  String provider,
  String account,
  String tier,
) {
  final root = quotabotDir('analytics-recovery');
  if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('unsafe recovery root');
  }
  enforceOwnerOnlyDirectory(root);
  final digest = accountIdentityDigest(account).substring(0, 16);
  final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  for (var attempt = 0; attempt < 100; attempt++) {
    final suffix = attempt == 0 ? '' : '_$attempt';
    final bundle = Directory(
      '${root.path}/${_safeProviderStem(provider)}_${digest}_${tier}_${micros}_$pid$suffix',
    );
    if (bundle.existsSync()) continue;
    bundle.createSync();
    enforceOwnerOnlyDirectory(bundle);
    return bundle;
  }
  throw const FileSystemException('could not allocate recovery bundle');
}

void _writeAnalyticsRecoveryManifest(
  Directory bundle, {
  required String provider,
  required String account,
  required String tier,
  required String state,
  required List<_AnalyticsRecoveryEvidence> evidence,
  required Set<String> archivedRoles,
  String? failure,
}) {
  final manifest = File('${bundle.path}/manifest.json');
  _atomicWrite(
    manifest,
    jsonEncode({
      'schema': _analyticsRecoveryEvidenceSchema,
      'state': state,
      'provider': provider,
      'account_digest': accountIdentityDigest(account),
      'tier': tier,
      'observed_at': nowEpoch(),
      'exact_merge_performed': false,
      'selected_tier_action': 'archived_then_restarted_empty',
      'files': [
        for (final item in evidence)
          {
            'role': item.role,
            'bytes': item.precheckBytes.length,
            'sha256': item.precheckDigest,
            'archived': archivedRoles.contains(item.role),
            'moved_original':
                item.moveOriginal && archivedRoles.contains(item.role),
          },
      ],
      if (failure != null) 'failure': failure,
    }),
  );
  enforceOwnerOnlyFile(manifest);
}

String _analyticsRecoveryReceiptKey(String tier) => '${tier}_recovery';

void _copyAnalyticsRecoveryReceipts(
  Map<String, dynamic> target,
  Map<String, dynamic>? source,
) {
  for (final tier in _analyticsRecoveryTiers) {
    final receipt = source?[_analyticsRecoveryReceiptKey(tier)];
    if (receipt is! Map ||
        receipt['bundle_id'] is! String ||
        receipt['observed_at'] is! int) {
      continue;
    }
    final bundleId = receipt['bundle_id'] as String;
    if (!RegExp(r'^[a-zA-Z0-9._-]{1,220}$').hasMatch(bundleId)) continue;
    target[_analyticsRecoveryReceiptKey(tier)] = {
      'bundle_id': bundleId,
      'observed_at': receipt['observed_at'],
    };
  }
}

Map<String, dynamic> _analyticsMigrationRecordAfterRecovery(
  String provider,
  String account,
  String selectedTier,
  Set<String> unresolvedTiers,
  Map<String, dynamic>? previous,
) {
  final record = _newAnalyticsMigrationRecord(provider, account);
  _copyAnalyticsRecoveryReceipts(record, previous);
  if (unresolvedTiers.isNotEmpty) {
    _copyAnalyticsIncidentMetadata(record, previous);
  }
  final ownerDigest = previous?[_analyticsLegacyBucketOwnerDigestKey];
  if (ownerDigest == accountIdentityDigest(account)) {
    record[_analyticsLegacyBucketOwnerDigestKey] = ownerDigest;
  }
  for (final tier in _analyticsRecoveryTiers) {
    if (tier == selectedTier) {
      record[tier] = tier == 'history'
          ? _emptyHistoryCheckpoint()
          : _emptyBucketCheckpoint();
      continue;
    }
    if (unresolvedTiers.contains(tier)) {
      final previousCheckpoint = previous?[tier];
      if (previousCheckpoint is Map) {
        record[tier] = Map<String, dynamic>.from(previousCheckpoint);
      }
      final previousReason = previous?['${tier}_reason'];
      _markAnalyticsConflict(
        record,
        tier,
        previousReason is String
            ? previousReason
            : 'unresolved during scoped analytics recovery',
      );
      continue;
    }

    if (tier == 'history') {
      record[tier] = _historyCheckpoint(provider, account);
      continue;
    }
    final legacy = _legacyBucketsFile(provider, account: account);
    final owned = !legacy.existsSync() ||
        _legacyBucketOwnerAllows(provider, account, claim: false);
    if (!owned) continue;
    final checkpoint = _bucketCheckpoint(legacy);
    if (checkpoint != null) {
      record[tier] = checkpoint;
    } else {
      _markAnalyticsConflict(
        record,
        tier,
        tier == selectedTier
            ? 'selected tier did not restart from an empty baseline'
            : 'hourly analytics checkpoint remains invalid',
      );
    }
  }
  return record;
}

Map<String, dynamic> _analyticsMigrationRecoveryGuard(
  String provider,
  String account,
  String selectedTier,
  Set<String> activeTiers,
  Map<String, dynamic>? previous,
) {
  final record = _newAnalyticsMigrationRecord(provider, account);
  _copyAnalyticsRecoveryReceipts(record, previous);
  _copyAnalyticsIncidentMetadata(record, previous);
  final accountDigest = accountIdentityDigest(account);
  final previousOwner = previous?[_analyticsLegacyBucketOwnerDigestKey];
  final legacyBuckets = _legacyBucketsFile(provider, account: account);
  if (previousOwner == accountDigest ||
      (legacyBuckets.existsSync() &&
          _legacyBucketOwnerAllows(provider, account, claim: false))) {
    record[_analyticsLegacyBucketOwnerDigestKey] = accountDigest;
  }
  for (final tier in _analyticsRecoveryTiers) {
    final previousCheckpoint = previous?[tier];
    if (previousCheckpoint is Map) {
      record[tier] = Map<String, dynamic>.from(previousCheckpoint);
    } else if (!activeTiers.contains(tier)) {
      if (tier == 'history') {
        record[tier] = _historyCheckpoint(provider, account);
      } else {
        final legacy = _legacyBucketsFile(provider, account: account);
        final owned = !legacy.existsSync() ||
            _legacyBucketOwnerAllows(provider, account, claim: false);
        final checkpoint = owned ? _bucketCheckpoint(legacy) : null;
        if (checkpoint != null) record[tier] = checkpoint;
      }
    }
    if (!activeTiers.contains(tier)) continue;
    final previousReason = previous?['${tier}_reason'];
    _markAnalyticsConflict(
      record,
      tier,
      previousReason is String
          ? previousReason
          : tier == selectedTier
              ? 'scoped analytics recovery in progress'
              : 'unresolved during scoped analytics recovery',
    );
  }
  return record;
}

AnalyticsStorageRecoveryResult? _completedAnalyticsStorageRecovery(
  String provider,
  String account,
  String tier, {
  List<String> activeTiers = const [],
}) {
  try {
    final record = _readAnalyticsMigrationRecord(provider, account);
    final receipt = record?[_analyticsRecoveryReceiptKey(tier)];
    if (receipt is! Map || receipt['bundle_id'] is! String) return null;
    final bundleId = receipt['bundle_id'] as String;
    if (!RegExp(r'^[a-zA-Z0-9._-]{1,220}$').hasMatch(bundleId)) return null;
    final root = Directory('${cacheDir().parent.path}/analytics-recovery');
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final bundle = Directory('${root.path}/$bundleId');
    if (FileSystemEntity.typeSync(bundle.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final manifest = File('${bundle.path}/manifest.json');
    if (FileSystemEntity.typeSync(manifest.path, followLinks: false) !=
            FileSystemEntityType.file ||
        manifest.lengthSync() > _maxDriftBytes) {
      return null;
    }
    final decoded = jsonDecode(manifest.readAsStringSync());
    if (decoded is! Map ||
        decoded['schema'] != _analyticsRecoveryEvidenceSchema ||
        (decoded['state'] != 'complete' &&
            decoded['state'] != 'checkpoint_pending' &&
            decoded['state'] != 'archiving') ||
        decoded['provider'] != provider ||
        decoded['account_digest'] != accountIdentityDigest(account) ||
        decoded['tier'] != tier ||
        decoded['files'] is! List) {
      return null;
    }
    final roles = <String>[];
    for (final entry in decoded['files'] as List) {
      if (entry is Map &&
          entry['archived'] == true &&
          entry['role'] is String) {
        roles.add(entry['role'] as String);
      }
    }
    final complete = decoded['state'] == 'complete';
    return _analyticsRecoveryResult(
      mode: 'recover',
      provider: provider,
      account: account,
      tier: tier,
      activeTiers: activeTiers,
      ready: false,
      recovered: true,
      status: complete ? 'already_recovered' : 'recovered_receipt_incomplete',
      detail: complete
          ? 'A prior completed scoped recovery already archived this tier.'
          : 'The selected tier restarted empty, but its evidence manifest '
              'was interrupted before finalization.',
      evidenceBundle: bundle.path,
      archivedRoles: roles,
    );
  } catch (_) {
    return null;
  }
}

AnalyticsStorageRecoveryResult _recoveryFailureFromInspection(
  AnalyticsStorageRecoveryResult inspection,
) =>
    _analyticsRecoveryResult(
      mode: 'recover',
      provider: inspection.provider,
      account: inspection.account,
      tier: inspection.tier,
      activeTiers: inspection.activeTiers,
      ready: false,
      recovered: false,
      status: inspection.status,
      detail: inspection.detail,
    );

/// Archives and clears one exact quarantined analytics tier.
///
/// This is intentionally not a merge. Every selected canonical and legacy
/// regular file is moved into an owner-only evidence bundle before an empty
/// checkpoint is admitted. An explicit recovery guard replaces the old marker
/// before selected files move, so interruption fails closed.
AnalyticsStorageRecoveryResult recoverAnalyticsStorage(
  String provider,
  String account,
  String tier,
) {
  final canonicalProvider =
      canonicalizeProviderId(provider.trim().toLowerCase());
  final selectedTier = tier.trim().toLowerCase();
  try {
    final preliminary = inspectAnalyticsStorageRecovery(
      canonicalProvider,
      account,
      selectedTier,
    );
    if (!preliminary.ready) {
      if (preliminary.status == 'no_active_conflict' ||
          preliminary.status == 'tier_not_conflicted') {
        final completed = _completedAnalyticsStorageRecovery(
          canonicalProvider,
          account,
          selectedTier,
          activeTiers: preliminary.activeTiers,
        );
        if (completed != null) return completed;
      }
      return _recoveryFailureFromInspection(preliminary);
    }
  } catch (_) {
    return _analyticsRecoveryResult(
      mode: 'recover',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: const [],
      ready: false,
      recovered: false,
      status: 'recovery_unavailable',
      detail: 'The exact analytics recovery target could not be inspected.',
    );
  }
  try {
    return _withEvidenceLock(canonicalProvider, account, () {
      final inspection = inspectAnalyticsStorageRecovery(
        canonicalProvider,
        account,
        selectedTier,
      );
      if (!inspection.ready) return _recoveryFailureFromInspection(inspection);

      final scanned = _analyticsRecoveryEvidence(
        canonicalProvider,
        account,
        selectedTier,
      );
      if (scanned.failure != null) {
        return _analyticsRecoveryResult(
          mode: 'recover',
          provider: canonicalProvider,
          account: account,
          tier: selectedTier,
          activeTiers: inspection.activeTiers,
          ready: false,
          recovered: false,
          status: scanned.failure!,
          detail: scanned.failure == 'evidence_too_large'
              ? 'Selected recovery evidence exceeds the 16 MiB safety limit.'
              : scanned.failure == 'shared_legacy_evidence'
                  ? 'The legacy analytics file is not exclusive to this exact '
                      'account. No scoped recovery files were changed.'
                  : 'Recovery evidence changed after confirmation. Stop every '
                      'older quotabot process and inspect again.',
        );
      }
      final evidence = scanned.evidence;
      final previous = _readAnalyticsMigrationRecord(
        canonicalProvider,
        account,
      );
      final unresolvedTiers = inspection.activeTiers.toSet()
        ..remove(selectedTier);
      Directory bundle;
      try {
        bundle = _createAnalyticsRecoveryBundle(
          canonicalProvider,
          account,
          selectedTier,
        );
      } catch (_) {
        return _analyticsRecoveryResult(
          mode: 'recover',
          provider: canonicalProvider,
          account: account,
          tier: selectedTier,
          activeTiers: inspection.activeTiers,
          ready: false,
          recovered: false,
          status: 'archive_failed',
          detail: 'The evidence bundle could not be created. No recovery '
              'files were changed.',
        );
      }

      final archivedRoles = <String>{};
      void finishManifest(String state, [String? failure]) {
        _writeAnalyticsRecoveryManifest(
          bundle,
          provider: canonicalProvider,
          account: account,
          tier: selectedTier,
          state: state,
          evidence: evidence,
          archivedRoles: archivedRoles,
          failure: failure,
        );
      }

      try {
        finishManifest('archiving');
        for (final item in evidence) {
          if (FileSystemEntity.typeSync(
                item.source.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.file) {
            finishManifest('failed', 'evidence_changed');
            return _analyticsRecoveryResult(
              mode: 'recover',
              provider: canonicalProvider,
              account: account,
              tier: selectedTier,
              activeTiers: inspection.activeTiers,
              ready: false,
              recovered: false,
              status: 'evidence_changed',
              detail: 'Recovery evidence changed after inspection. Stop every '
                  'older quotabot process and inspect again.',
              evidenceBundle: bundle.path,
              archivedRoles: archivedRoles.toList(),
            );
          }
          final currentBytes = item.source.readAsBytesSync();
          if (sha256.convert(currentBytes).toString() != item.precheckDigest) {
            finishManifest('failed', 'evidence_changed');
            return _analyticsRecoveryResult(
              mode: 'recover',
              provider: canonicalProvider,
              account: account,
              tier: selectedTier,
              activeTiers: inspection.activeTiers,
              ready: false,
              recovered: false,
              status: 'evidence_changed',
              detail: 'Recovery evidence changed after inspection. Stop every '
                  'older quotabot process and inspect again.',
              evidenceBundle: bundle.path,
              archivedRoles: archivedRoles.toList(),
            );
          }
        }

        bool archiveEvidence(_AnalyticsRecoveryEvidence item) {
          final archived = File(
            '${bundle.path}/${item.role}${item.extension}',
          );
          if (item.moveOriginal) {
            item.source.renameSync(archived.path);
          } else {
            _atomicWriteBytes(archived, item.precheckBytes);
          }
          archivedRoles.add(item.role);
          enforceOwnerOnlyFile(archived);
          return sha256.convert(archived.readAsBytesSync()).toString() ==
              item.precheckDigest;
        }

        for (final item in evidence.where((item) => !item.moveOriginal)) {
          if (archiveEvidence(item)) continue;
          finishManifest('failed', 'archive_verification_failed');
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: inspection.activeTiers,
            ready: false,
            recovered: false,
            status: 'archive_failed',
            detail: 'Archived evidence failed its integrity check. No '
                'selected analytics files were moved.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }

        final guard = _analyticsMigrationRecoveryGuard(
          canonicalProvider,
          account,
          selectedTier,
          inspection.activeTiers.toSet(),
          previous,
        );
        if (!_writeAnalyticsMigrationRecord(
          canonicalProvider,
          account,
          guard,
        )) {
          finishManifest('failed', 'recovery_guard_write_failed');
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: inspection.activeTiers,
            ready: false,
            recovered: false,
            status: 'marker_write_failed',
            detail: 'The fail-closed recovery guard could not be stored. No '
                'selected analytics files were moved.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }
        final marker = _analyticsMigrationFile(canonicalProvider, account);
        final guardDigest = sha256.convert(marker.readAsBytesSync()).toString();

        for (final item in evidence.where((item) => item.moveOriginal)) {
          if (archiveEvidence(item)) continue;
          finishManifest('failed', 'archive_verification_failed');
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: inspection.activeTiers,
            ready: false,
            recovered: false,
            status: 'archive_failed',
            detail: 'Archived evidence failed its integrity check. The '
                'recovery guard keeps the quarantine active.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }

        final selectedSources = _analyticsRecoveryTierFiles(
          canonicalProvider,
          account,
          selectedTier,
        );
        if (selectedSources.any(
          (file) =>
              FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.notFound,
        )) {
          finishManifest('failed', 'evidence_recreated');
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: inspection.activeTiers,
            ready: false,
            recovered: false,
            status: 'evidence_changed',
            detail: 'An older process recreated selected analytics during '
                'recovery. The recovery guard keeps the quarantine active.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }
        final guardUnchanged = marker.existsSync() &&
            sha256.convert(marker.readAsBytesSync()).toString() == guardDigest;
        if (!guardUnchanged) {
          finishManifest('failed', 'recovery_guard_changed');
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: inspection.activeTiers,
            ready: false,
            recovered: false,
            status: 'evidence_changed',
            detail: 'The fail-closed recovery guard changed during archive. '
                'Stop every older quotabot process before retrying.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }

        finishManifest('checkpoint_pending');

        final replacement = _analyticsMigrationRecordAfterRecovery(
          canonicalProvider,
          account,
          selectedTier,
          unresolvedTiers,
          guard,
        );
        replacement[_analyticsRecoveryReceiptKey(selectedTier)] = {
          'bundle_id': bundle.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .last,
          'observed_at': nowEpoch(),
        };
        if (!_writeAnalyticsMigrationRecord(
          canonicalProvider,
          account,
          replacement,
        )) {
          finishManifest('failed', 'migration_marker_write_failed');
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: inspection.activeTiers,
            ready: false,
            recovered: false,
            status: 'marker_write_failed',
            detail: 'The empty analytics checkpoint could not be stored. The '
                'quarantine remains active.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }

        final remaining = analyticsStorageNotice(
          canonicalProvider,
          account: account,
        );
        if (remaining?.tiers.contains(selectedTier) == true) {
          finishManifest('failed', 'selected_tier_rediverged');
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: remaining?.tiers ?? const [],
            ready: false,
            recovered: false,
            status: 'rediverged',
            detail: 'The selected tier changed again before verification. '
                'Its quarantine remains active.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }

        try {
          finishManifest('complete');
        } catch (_) {
          return _analyticsRecoveryResult(
            mode: 'recover',
            provider: canonicalProvider,
            account: account,
            tier: selectedTier,
            activeTiers: remaining?.tiers ?? const [],
            ready: false,
            recovered: true,
            status: 'recovered_receipt_incomplete',
            detail: 'The selected tier restarted empty, but its evidence '
                'manifest could not be finalized.',
            evidenceBundle: bundle.path,
            archivedRoles: archivedRoles.toList(),
          );
        }
        return _analyticsRecoveryResult(
          mode: 'recover',
          provider: canonicalProvider,
          account: account,
          tier: selectedTier,
          activeTiers: remaining?.tiers ?? const [],
          ready: false,
          recovered: true,
          status: 'recovered',
          detail: 'Selected analytics were archived and restarted empty. '
              'Exact merge was not performed.',
          evidenceBundle: bundle.path,
          archivedRoles: archivedRoles.toList(),
        );
      } catch (_) {
        try {
          finishManifest('failed', 'archive_failed');
        } catch (_) {}
        return _analyticsRecoveryResult(
          mode: 'recover',
          provider: canonicalProvider,
          account: account,
          tier: selectedTier,
          activeTiers: inspection.activeTiers,
          ready: false,
          recovered: false,
          status: 'archive_failed',
          detail: 'Recovery stopped before an empty checkpoint was admitted. '
              'The quarantine remains active.',
          evidenceBundle: bundle.path,
          archivedRoles: archivedRoles.toList(),
        );
      }
    }, includeLegacy: true);
  } catch (_) {
    return _analyticsRecoveryResult(
      mode: 'recover',
      provider: canonicalProvider,
      account: account,
      tier: selectedTier,
      activeTiers: const [],
      ready: false,
      recovered: false,
      status: 'recovery_unavailable',
      detail: 'The exact analytics recovery lock could not be acquired.',
    );
  }
}

List<AnalyticsStorageNotice> analyticsStorageNoticesForQuotas(
  Iterable<ProviderQuota> quotas,
) {
  final notices = <AnalyticsStorageNotice>[];
  final seen = <String>{};
  for (final quota in quotas) {
    final key = quotaIdentityKeyFor(quota);
    if (!seen.add(key)) continue;
    final notice = analyticsStorageNotice(
      quota.provider,
      account: quota.account,
    );
    if (notice != null) notices.add(notice);
  }
  return notices;
}

String _analyticsIncidentKey(String provider, String accountDigest) =>
    '$provider\u0000$accountDigest';

_AnalyticsIncidentEntry? _analyticsIncidentEntry(
  Map<String, dynamic> record,
  String provider,
  String accountDigest, {
  required int? providerRowIndex,
}) {
  final tiers = <String>[
    for (final tier in _analyticsRecoveryTiers)
      if (record['${tier}_conflict'] == true) tier,
  ];
  if (tiers.isEmpty) return null;
  final incidentId = record['incident_id'];
  final recordedAt = record['incident_observed_at'];
  final fallbackRecordedAt = record['observed_at'];
  return _AnalyticsIncidentEntry(
    AnalyticsStorageIncident(
      provider: provider,
      tiers: List.unmodifiable(tiers),
      recordedAt: _validAnalyticsIncidentTimestamp(recordedAt)
          ? recordedAt as int
          : fallbackRecordedAt as int,
      providerRowIndex: providerRowIndex,
      incidentId:
          _validAnalyticsIncidentId(incidentId) ? incidentId as String : null,
    ),
    accountDigest,
  );
}

bool _validAnalyticsIncidentMarkerRecord(
  File marker,
  Map<String, dynamic> record,
  int now,
) {
  final provider = record['provider'];
  final digest = record['account_digest'];
  final observedAt = record['observed_at'];
  return record['schema'] == _analyticsMigrationSchema &&
      provider is String &&
      provider == canonicalizeProviderId(provider) &&
      providerAdapterById(provider) != null &&
      digest is String &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) &&
      observedAt is int &&
      observedAt > 0 &&
      observedAt <= now + kQuotaEvidenceClockSkewSeconds &&
      marker.uri.pathSegments.last ==
          _analyticsMigrationFileNameForDigest(provider, digest);
}

Map<String, dynamic>? _readAnalyticsIncidentMarkerSync(
  File marker,
  int now,
) {
  try {
    if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
            FileSystemEntityType.file ||
        marker.lengthSync() > _maxAnalyticsMigrationBytes) {
      return null;
    }
    final decoded = jsonDecode(marker.readAsStringSync());
    if (decoded is! Map) return null;
    final record = decoded.cast<String, dynamic>();
    return _validAnalyticsIncidentMarkerRecord(marker, record, now)
        ? record
        : null;
  } catch (_) {
    return null;
  }
}

T? _tryWithAnalyticsDigestLock<T>(
  String provider,
  String accountDigest,
  T Function() run,
) {
  RandomAccessFile? lock;
  var locked = false;
  try {
    final lockFile = File(
      '${cacheDir().path}/evidence_${_safeProviderStem(provider)}_account_$accountDigest.lock',
    );
    if (Directory(lockFile.path).existsSync() ||
        Link(lockFile.path).existsSync()) {
      return null;
    }
    final existingType = FileSystemEntity.typeSync(
      lockFile.path,
      followLinks: false,
    );
    if (existingType != FileSystemEntityType.notFound &&
        existingType != FileSystemEntityType.file) {
      return null;
    }
    restrictOwnerOnlyDirectory(lockFile.parent);
    if (!lockFile.existsSync()) lockFile.createSync(recursive: true);
    restrictOwnerOnlyFile(lockFile);
    lock = lockFile.openSync(mode: FileMode.write);
    lock.lockSync(FileLock.exclusive);
    locked = true;
    return run();
  } catch (_) {
    return null;
  } finally {
    if (locked) {
      try {
        lock?.unlockSync();
      } catch (_) {}
    }
    try {
      lock?.closeSync();
    } catch (_) {}
  }
}

_AnalyticsIncidentResolution _upgradeAnalyticsIncidentMarker(
  File marker,
  String provider,
  String accountDigest,
  int now, {
  required int? providerRowIndex,
}) =>
    _tryWithAnalyticsDigestLock(provider, accountDigest, () {
      final record = _readAnalyticsIncidentMarkerSync(marker, now);
      if (record == null) {
        return const _AnalyticsIncidentResolution(null, complete: false);
      }
      final before = jsonEncode(record);
      if (!_validAnalyticsIncidentId(record['incident_id'])) {
        record['incident_id'] = _newAnalyticsIncidentId();
        if (!_validAnalyticsIncidentTimestamp(
          record['incident_observed_at'],
        )) {
          record['incident_observed_at'] = record['observed_at'];
        }
      }
      if (jsonEncode(record) != before) {
        try {
          _atomicWrite(marker, jsonEncode(record));
        } catch (_) {
          final original = jsonDecode(before) as Map<String, dynamic>;
          return _AnalyticsIncidentResolution(
            _analyticsIncidentEntry(
              original,
              provider,
              accountDigest,
              providerRowIndex: providerRowIndex,
            ),
            complete: false,
          );
        }
      }
      return _AnalyticsIncidentResolution(
        _analyticsIncidentEntry(
          record,
          provider,
          accountDigest,
          providerRowIndex: providerRowIndex,
        ),
        complete: true,
      );
    }) ??
    const _AnalyticsIncidentResolution(null, complete: false);

_AnalyticsIncidentResolution _persistAnalyticsIncidentForExactAccount(
  String provider,
  String account, {
  required int? providerRowIndex,
}) {
  AnalyticsStorageNotice? initialNotice;
  Map<String, dynamic>? initialRecord;
  try {
    initialRecord = _readAnalyticsMigrationRecord(provider, account);
    initialNotice = analyticsStorageNotice(provider, account: account);
  } catch (_) {
    return const _AnalyticsIncidentResolution(null, complete: false);
  }
  if (initialNotice == null) {
    return const _AnalyticsIncidentResolution(null, complete: true);
  }
  final digest = accountIdentityDigest(account);
  final resolved = _tryWithAnalyticsDigestLock(provider, digest, () {
    final record = _readAnalyticsMigrationRecord(provider, account);
    final markerChanged = (initialRecord == null) != (record == null) ||
        (initialRecord != null &&
            record != null &&
            jsonEncode(record) != jsonEncode(initialRecord));
    final notice = markerChanged
        ? analyticsStorageNotice(provider, account: account)
        : initialNotice;
    if (notice == null) {
      return const _AnalyticsIncidentResolution(null, complete: true);
    }
    if (record == null) {
      return _AnalyticsIncidentResolution(
        _AnalyticsIncidentEntry(
          AnalyticsStorageIncident(
            provider: provider,
            tiers: notice.tiers,
            recordedAt: notice.observedAt,
            providerRowIndex: providerRowIndex,
          ),
          digest,
        ),
        complete: false,
      );
    }
    final before = jsonEncode(record);
    for (final tier in notice.tiers) {
      final reason = record['${tier}_reason'];
      _markAnalyticsConflict(
        record,
        tier,
        reason is String
            ? reason
            : tier == 'history'
                ? 'legacy history differs from its migration checkpoint'
                : 'legacy hourly analytics differ from their migration checkpoint',
      );
    }
    var complete = true;
    if (jsonEncode(record) != before &&
        !_writeAnalyticsMigrationRecord(provider, account, record)) {
      complete = false;
    }
    final persisted =
        complete ? record : jsonDecode(before) as Map<String, dynamic>;
    final entry = _analyticsIncidentEntry(
      persisted,
      provider,
      digest,
      providerRowIndex: providerRowIndex,
    );
    if (entry != null) {
      return _AnalyticsIncidentResolution(entry, complete: complete);
    }
    return _AnalyticsIncidentResolution(
      _AnalyticsIncidentEntry(
        AnalyticsStorageIncident(
          provider: provider,
          tiers: notice.tiers,
          recordedAt: notice.observedAt,
          providerRowIndex: providerRowIndex,
        ),
        digest,
      ),
      complete: false,
    );
  });
  if (resolved != null) return resolved;
  return _AnalyticsIncidentResolution(
    _AnalyticsIncidentEntry(
      AnalyticsStorageIncident(
        provider: provider,
        tiers: initialNotice.tiers,
        recordedAt: initialNotice.observedAt,
        providerRowIndex: providerRowIndex,
      ),
      digest,
    ),
    complete: false,
  );
}

String? _analyticsIncidentAccountFromCache(
  String provider,
  String accountDigest,
  int now,
) {
  final file = File(
    '${cacheDir().path}/${_safeProviderStem(provider)}_account_$accountDigest.json',
  );
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.lengthSync() > _maxAnalyticsIdentityBytes) {
      return null;
    }
    final quota = _readSnapshotEvidence(file);
    if (quota == null ||
        quota.provider != provider ||
        !_hasAccount(quota.account) ||
        accountIdentityDigest(quota.account) != accountDigest ||
        !_isRegisteredCacheEvidence(quota) ||
        quota.asOf <= 0 ||
        quota.asOf > now + kQuotaEvidenceClockSkewSeconds) {
      return null;
    }
    return quota.account;
  } catch (_) {
    return null;
  }
}

/// Returns a resource-bounded local inventory of mixed-version analytics
/// incidents. When [includeUnavailable] is false, only exact identities already
/// visible in [quotas] are inspected, so profiles and exclusions cannot reveal
/// out-of-scope local metadata.
///
/// Full scans validate canonical regular markers, cap directory entries,
/// candidate markers, and total bytes, and report partial evidence explicitly.
/// No incident contains a raw account, digest, path, or recovery authority.
Future<AnalyticsIncidentInventory> analyticsStorageIncidentInventory(
  Iterable<ProviderQuota> quotas, {
  bool includeUnavailable = true,
  int? now,
}) async {
  final quotaList = quotas.toList(growable: false);
  final detectedAt = now ?? nowEpoch();
  final scanClock = Stopwatch()..start();
  final visibleRows = <String, int>{};
  for (var index = 0; index < quotaList.length; index++) {
    final quota = quotaList[index];
    if (!_hasAccount(quota.account)) continue;
    visibleRows[_analyticsIncidentKey(
      quota.provider,
      accountIdentityDigest(quota.account),
    )] = index;
  }
  final entries = <String, _AnalyticsIncidentEntry>{};
  var partial = false;
  var scannedMarkers = 0;
  var unverifiableMarkers = 0;
  var invalidMarkers = 0;
  var truncated = false;
  final uncertainProviders = <String>{};
  var globalUncertainty = false;

  for (var index = 0; index < quotaList.length; index++) {
    if (index >= _maxAnalyticsIncidents ||
        scanClock.elapsed >= _maxAnalyticsIncidentScanDuration) {
      truncated = true;
      partial = true;
      globalUncertainty = true;
      break;
    }
    final quota = quotaList[index];
    if (!_hasAccount(quota.account)) continue;
    final resolution = _persistAnalyticsIncidentForExactAccount(
      quota.provider,
      quota.account,
      providerRowIndex: index,
    );
    if (!resolution.complete) {
      partial = true;
      uncertainProviders.add(quota.provider);
    }
    final entry = resolution.entry;
    if (entry != null) {
      entries[_analyticsIncidentKey(quota.provider, entry.accountDigest)] =
          entry;
    }
  }

  if (includeUnavailable && !truncated) {
    var directoryEntries = 0;
    var scannedBytes = 0;
    try {
      await for (final entity in cacheDir().list(followLinks: false)) {
        if (scanClock.elapsed >= _maxAnalyticsIncidentScanDuration) {
          truncated = true;
          globalUncertainty = true;
          break;
        }
        directoryEntries++;
        if (directoryEntries > _maxAnalyticsIncidentDirectoryEntries) {
          truncated = true;
          globalUncertainty = true;
          break;
        }
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('analytics_migration_') ||
            !name.endsWith('.json')) {
          continue;
        }
        if (scannedMarkers >= _maxAnalyticsIncidents) {
          truncated = true;
          break;
        }
        scannedMarkers++;
        final marker = File(entity.path);
        int length;
        try {
          if (await FileSystemEntity.type(
                marker.path,
                followLinks: false,
              ).timeout(_maxAnalyticsIncidentScanDuration) !=
              FileSystemEntityType.file) {
            invalidMarkers++;
            partial = true;
            globalUncertainty = true;
            continue;
          }
          length = await marker.length().timeout(
                _maxAnalyticsIncidentScanDuration,
              );
        } catch (_) {
          invalidMarkers++;
          partial = true;
          globalUncertainty = true;
          continue;
        }
        if (length > _maxAnalyticsMigrationBytes) {
          invalidMarkers++;
          partial = true;
          globalUncertainty = true;
          continue;
        }
        if (scannedBytes + length > _maxAnalyticsIncidentScanBytes) {
          truncated = true;
          globalUncertainty = true;
          break;
        }
        scannedBytes += length;
        final record = _readAnalyticsIncidentMarkerSync(marker, detectedAt);
        if (record == null) {
          invalidMarkers++;
          partial = true;
          globalUncertainty = true;
          continue;
        }
        final provider = record['provider'] as String;
        final digest = record['account_digest'] as String;
        final key = _analyticsIncidentKey(provider, digest);
        if (entries.containsKey(key)) continue;
        final rowIndex = visibleRows[key];
        final explicitEntry = _analyticsIncidentEntry(
          record,
          provider,
          digest,
          providerRowIndex: rowIndex,
        );
        var resolution = explicitEntry == null
            ? const _AnalyticsIncidentResolution(null, complete: true)
            : _validAnalyticsIncidentId(record['incident_id'])
                ? _AnalyticsIncidentResolution(explicitEntry, complete: true)
                : _upgradeAnalyticsIncidentMarker(
                    marker,
                    provider,
                    digest,
                    detectedAt,
                    providerRowIndex: rowIndex,
                  );
        if (explicitEntry != null && resolution.entry == null) {
          resolution = _AnalyticsIncidentResolution(
            explicitEntry,
            complete: false,
          );
        }
        if (resolution.entry == null) {
          final account = _analyticsIncidentAccountFromCache(
            provider,
            digest,
            detectedAt,
          );
          if (account == null) {
            unverifiableMarkers++;
            partial = true;
            uncertainProviders.add(provider);
            continue;
          }
          resolution = _persistAnalyticsIncidentForExactAccount(
            provider,
            account,
            providerRowIndex: rowIndex,
          );
        }
        if (!resolution.complete) {
          partial = true;
          uncertainProviders.add(provider);
        }
        final entry = resolution.entry;
        if (entry != null) entries[key] = entry;
      }
    } catch (_) {
      partial = true;
      globalUncertainty = true;
    }
  }

  final result = entries.values.toList()
    ..sort((left, right) {
      if (left.incident.exactAccountInSnapshot !=
          right.incident.exactAccountInSnapshot) {
        return left.incident.exactAccountInSnapshot ? -1 : 1;
      }
      final provider =
          left.incident.provider.compareTo(right.incident.provider);
      if (provider != 0) return provider;
      return left.accountDigest.compareTo(right.accountDigest);
    });
  if (result.length > _maxAnalyticsIncidents) truncated = true;
  if (truncated) {
    partial = true;
    globalUncertainty = true;
  }
  return AnalyticsIncidentInventory(
    incidents: List.unmodifiable(
      result.take(_maxAnalyticsIncidents).map((entry) => entry.incident),
    ),
    state: partial ? 'partial' : 'complete',
    scope: includeUnavailable ? 'all_local' : 'visible_snapshot',
    scannedMarkers: scannedMarkers,
    unverifiableMarkers: unverifiableMarkers,
    invalidMarkers: invalidMarkers,
    truncated: truncated,
    uncertainProviders: Set.unmodifiable(uncertainProviders),
    globalUncertainty: globalUncertainty,
  );
}

File _legacyBucketOwnerFile(String provider, String account) => File(
    '${cacheDir().path}/legacy_bucket_owner_${_safeProviderStem(provider)}_${accountStorageStem(_safeProviderStem(account))}.json');

Set<String> _legacyHistoryAccounts(String provider, String account) {
  final file = _legacyHistoryFile(provider, account: account);
  if (!file.existsSync() || file.lengthSync() > _maxHistoryBytes) {
    return const {};
  }
  final accounts = <String>{};
  try {
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map &&
            decoded['provider'] == provider &&
            decoded['account'] is String) {
          accounts.add(decoded['account'] as String);
        }
      } catch (_) {}
    }
  } catch (_) {}
  return accounts;
}

bool _legacyBucketEvidenceMatches(String provider, String account) {
  final accountScoped =
      _accountScopedProviders.contains(provider) && _hasAccount(account);
  final snapshotFile =
      accountScoped ? _legacyAccountedPath(provider, account) : _file(provider);
  var snapshotMatches = false;
  if (snapshotFile.existsSync()) {
    snapshotMatches = _readCanonicalSnapshotEvidence(
          snapshotFile,
          provider: provider,
          account: account,
          newestAllowedAsOf: nowEpoch() + kQuotaEvidenceClockSkewSeconds,
          requireExactAccount: true,
        ) !=
        null;
    if (!snapshotMatches) return false;
  }
  final historyAccounts = _legacyHistoryAccounts(provider, account);
  if (historyAccounts.any((candidate) => candidate != account)) return false;
  return snapshotMatches || historyAccounts.contains(account);
}

bool _legacyBucketOwnerAllows(
  String provider,
  String account, {
  required bool claim,
}) {
  final marker = _legacyBucketOwnerFile(provider, account);
  final digest = accountIdentityDigest(account);
  if (marker.existsSync()) {
    try {
      if (marker.lengthSync() > _maxDriftBytes) return false;
      final decoded = jsonDecode(marker.readAsStringSync());
      return decoded is Map &&
          decoded['schema'] == _legacyBucketOwnerSchema &&
          decoded['provider'] == provider &&
          decoded['account_digest'] == digest;
    } catch (_) {
      return false;
    }
  }
  if (!_legacyBucketEvidenceMatches(provider, account)) return false;
  if (claim) {
    _atomicWrite(
      marker,
      jsonEncode({
        'schema': _legacyBucketOwnerSchema,
        'provider': provider,
        'account_digest': digest,
      }),
    );
  }
  return true;
}

bool _legacyBucketRecoveryOwned(String provider, String account) {
  if (_legacyBucketOwnerAllows(provider, account, claim: false)) return true;
  final record = _readAnalyticsMigrationRecord(provider, account);
  return record?[_analyticsLegacyBucketOwnerDigestKey] ==
      accountIdentityDigest(account);
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
    // Serialize the read-modify-write under the same interprocess lock the
    // snapshot/history paths use, keyed by provider/account. Without it, the app
    // and CLI folding a sample into the same hour bucket at once would each
    // read, add, and write, and the second rename would silently drop the
    // first's sample (or a concurrent prune would drop a re-added bucket) - a
    // lost update on the most expensive local data to lose.
    _withEvidenceLock(provider, account ?? '', () {
      final target = _bucketsFile(provider, account: account);
      if (account != null &&
          _hasAccount(account) &&
          !_ensureBucketMigrationBaseline(
            provider,
            account,
            canonicalExisted: target.existsSync(),
          )) {
        return;
      }
      final buckets = _loadBuckets(
        provider,
        account: account,
        fallbackToProvider: false,
        claimLegacyOwner: true,
      );
      final start = bucketStart(now);
      final cutoff = now - kRetentionDays * 86400;
      buckets.removeWhere((b) => b.start < cutoff);
      var current = buckets.isNotEmpty && buckets.last.start == start
          ? buckets.last
          : null;
      if (current == null) {
        current = HeadroomBucket(start: start);
        buckets.add(current);
      }
      current.add(headroom);
      _atomicWrite(
        _bucketsFile(provider, account: account),
        jsonEncode(buckets.map((b) => b.toJson()).toList()),
      );
    });
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
  int now, {
  int? lookbackHours,
}) {
  final list = providers.where((q) => !q.isLocal).toList();
  final measuredCounts = <String, int>{};
  for (final q in list) {
    if (q.isManual || !q.hasWindows) continue;
    measuredCounts[q.provider] = (measuredCounts[q.provider] ?? 0) + 1;
  }
  final out = <String, BurnStat>{};
  final conflictCandidates =
      <String, ({BurnStat onBoundary, BurnStat afterBoundary})>{};
  for (final q in list) {
    if (q.isManual || !q.hasWindows) continue;
    final key = quotaIdentityKeyFor(q);
    final accountScoped = hasSpecificQuotaAccount(q.account);
    final accountBucketsConflicted =
        accountScoped && _bucketMigrationConflict(q.provider, q.account);
    var buckets = accountBucketsConflicted
        ? _trustedBucketsDuringConflict(q.provider, q.account)
        : accountScoped
            ? loadBuckets(
                q.provider,
                account: q.account,
                fallbackToProvider: false,
              )
            : loadBuckets(q.provider);
    if (buckets.isEmpty && (measuredCounts[q.provider] ?? 0) == 1) {
      buckets = loadBuckets(q.provider);
    }
    if (accountBucketsConflicted) {
      final candidates = _conflictBurnCandidates(
        buckets,
        lookbackHours: lookbackHours,
      );
      conflictCandidates[key] = candidates;
      out[key] = _conservativeBurnStat(
        candidates.onBoundary,
        candidates.afterBoundary,
      );
    } else {
      out[key] = lookbackHours == null
          ? burnRateWithError(buckets, now)
          : burnRateWithError(
              buckets,
              now,
              lookbackHours: lookbackHours,
            );
    }
  }
  if (conflictCandidates.isEmpty) return shrinkBurnStats(out);

  // All hourly buckets share the same clock boundaries, so the unknown healthy
  // sub-hour offset has exactly two global cases: on the boundary or after it.
  // Shrink both complete maps. Healthy identities use the result matching the
  // actual current offset, while conflicted identities take the envelope. This
  // prevents conflict uncertainty from weakening its burn or penalizing a
  // healthy route competitor through the shared pool.
  final onBoundary = Map<String, BurnStat>.of(out);
  final afterBoundary = Map<String, BurnStat>.of(out);
  for (final entry in conflictCandidates.entries) {
    onBoundary[entry.key] = entry.value.onBoundary;
    afterBoundary[entry.key] = entry.value.afterBoundary;
  }
  final shrunkOnBoundary = shrinkBurnStats(onBoundary);
  final shrunkAfterBoundary = shrinkBurnStats(afterBoundary);
  final result = Map<String, BurnStat>.of(
    bucketStart(now) == now ? shrunkOnBoundary : shrunkAfterBoundary,
  );
  for (final key in conflictCandidates.keys) {
    result[key] = _conservativeBurnStat(
      shrunkOnBoundary[key]!,
      shrunkAfterBoundary[key]!,
    );
  }
  return result;
}

/// Loads a provider/account hourly bucket series, oldest first. Empty when
/// absent. When [fallbackToProvider] is true, account reads can fall back to the
/// legacy provider-only bucket file.
List<HeadroomBucket> loadBuckets(
  String provider, {
  String? account,
  bool fallbackToProvider = true,
}) =>
    _loadBuckets(
      provider,
      account: account,
      fallbackToProvider: fallbackToProvider,
      claimLegacyOwner: false,
    );

List<HeadroomBucket> _loadBuckets(
  String provider, {
  String? account,
  required bool fallbackToProvider,
  required bool claimLegacyOwner,
}) {
  try {
    final exactAccount =
        account != null && _hasAccount(account) ? account : null;
    if (exactAccount != null &&
        _bucketMigrationConflict(provider, exactAccount)) {
      return [];
    }
    var f = _bucketsFile(provider, account: exactAccount);
    if (!f.existsSync() && exactAccount != null) {
      final legacy = _legacyBucketsFile(provider, account: exactAccount);
      if (legacy.existsSync() &&
          _legacyBucketOwnerAllows(
            provider,
            exactAccount,
            claim: claimLegacyOwner,
          )) {
        f = legacy;
      } else if (fallbackToProvider) {
        f = _bucketsFile(provider);
      }
    }
    return List<HeadroomBucket>.of(_readBucketFile(f).buckets);
  } catch (_) {
    return [];
  }
}

List<String> _historyLinesForIdentity(
  File file,
  String provider,
  String account,
) {
  if (!_hasAccount(account)) return [];
  if (!file.existsSync() || file.lengthSync() > _maxHistoryBytes) return [];
  final lines = <String>[];
  try {
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final quota = ProviderQuota.fromJson(
          jsonDecode(line) as Map<String, dynamic>,
        );
        if (quota.provider == provider &&
            quota.account == account &&
            _isRegisteredCacheEvidence(quota)) {
          lines.add(line);
        }
      } catch (_) {}
    }
  } catch (_) {}
  return lines;
}

List<String> _legacyHistoryLinesForIdentity(
  String provider,
  String account,
) =>
    _historyLinesForIdentity(
      _legacyHistoryFile(provider, account: account),
      provider,
      account,
    );

List<ProviderQuota> _loadHistoryFile(
  File file,
  String provider, {
  String? exactAccount,
}) {
  final results = <ProviderQuota>[];
  if (!file.existsSync() || file.lengthSync() > _maxHistoryBytes) {
    return results;
  }
  try {
    final lines = file.readAsLinesSync();
    final observedAt = nowEpoch();
    // Last 48 raw checks: enough for a readable sparkline and a stable average.
    for (final line in lines.reversed.take(48)) {
      if (line.trim().isEmpty) continue;
      final content = jsonDecode(line) as Map<String, dynamic>;
      final quota = ProviderQuota.fromJson(content);
      if (quota.provider == provider &&
          (exactAccount == null || quota.account == exactAccount) &&
          _isRegisteredCacheEvidence(quota) &&
          quota.asOf <= observedAt + kQuotaEvidenceClockSkewSeconds &&
          isTrustedQuotaEvidenceAtCapture(quota)) {
        results.add(quota);
      }
    }
  } catch (_) {}
  return results.reversed.toList();
}

List<ProviderQuota> loadHistory(String provider, {String? account}) {
  final exactAccount = account != null && _hasAccount(account) ? account : null;
  if (exactAccount != null &&
      _historyMigrationConflict(provider, exactAccount)) {
    return [];
  }
  final canonical = _historyFile(provider, account: exactAccount);
  if (canonical.existsSync()) {
    return _loadHistoryFile(
      canonical,
      provider,
      exactAccount: exactAccount,
    );
  }
  if (exactAccount != null) {
    final legacy = _legacyHistoryFile(provider, account: exactAccount);
    final legacyRows = _loadHistoryFile(
      legacy,
      provider,
      exactAccount: exactAccount,
    );
    if (legacyRows.isNotEmpty) return legacyRows;
    return _loadHistoryFile(
      _historyFile(provider),
      provider,
      exactAccount: exactAccount,
    );
  }
  return _loadHistoryFile(canonical, provider);
}
