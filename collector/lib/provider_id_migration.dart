import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'drift.dart';
import 'file_guard.dart';
import 'insights.dart';
import 'models.dart';
import 'provider_adapters.dart';
import 'provider_ids.dart';
import 'storage_keys.dart';
import 'util.dart';

const providerIdMigrationReceiptSchema = 'quotabot.provider-id-migration.v1';
const providerIdMigrationReportSchema =
    'quotabot.provider-id-migration-report.v1';

const _maxReceiptBytes = 1024 * 1024;
const _maxMigrationTargetComponentBytes = 250;
const _maxConfiguredAliases = 32;
const _maxConfiguredRootEntries = 4096;
const _maxConfiguredRecords = 512;
const _maxConfiguredTotalBytes = 32 * 1024 * 1024;
const _maxConfiguredRecordBytes = 5 * 1024 * 1024;
const _maxConfiguredDuration = Duration(minutes: 1);
const _maxConfiguredLockTimeout = Duration(seconds: 30);
const _historyRecordLimit = 200;
const _bucketRecordLimit = 90 * 24 + 2;
const _providerIdPattern = r'^[a-z0-9][a-z0-9._-]{0,63}$';
const _digestPattern = r'^[a-f0-9]{64}$';

Future<ProviderIdMigrationReport>? _defaultCoordinatorFlight;
void Function(String phase)? _migrationObserverForTesting;

/// Observes production coordinator flights in tests. Release builds reject the
/// override so callers cannot intercept startup migration behavior.
void setProviderIdMigrationObserverForTesting(
  void Function(String phase)? observer,
) {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw UnsupportedError('provider migration observer is unavailable');
  }
  _migrationObserverForTesting = observer;
}

/// Hard limits for the provider-id storage coordinator.
///
/// The defaults hard-bound directory traversal, retained receipt size, bytes
/// read, and lock acquisition. Cooperative wall-time checks run between
/// bounded filesystem operations. Tests can supply smaller limits to prove
/// resumable partial progress without creating large fixtures.
class ProviderIdMigrationLimits {
  final int maxAliases;
  final int maxRootEntries;
  final int maxRecords;
  final int maxTotalBytes;
  final int maxRecordBytes;
  final Duration maxDuration;
  final Duration lockTimeout;

  const ProviderIdMigrationLimits({
    this.maxAliases = 32,
    this.maxRootEntries = 4096,
    this.maxRecords = 512,
    this.maxTotalBytes = 32 * 1024 * 1024,
    this.maxRecordBytes = 5 * 1024 * 1024,
    this.maxDuration = const Duration(seconds: 15),
    this.lockTimeout = const Duration(seconds: 5),
  });

  bool get valid =>
      maxAliases > 0 &&
      maxAliases <= _maxConfiguredAliases &&
      maxRootEntries > 0 &&
      maxRootEntries <= _maxConfiguredRootEntries &&
      maxRecords > 0 &&
      maxRecords <= _maxConfiguredRecords &&
      maxTotalBytes > 0 &&
      maxTotalBytes <= _maxConfiguredTotalBytes &&
      maxRecordBytes > 0 &&
      maxRecordBytes <= _maxConfiguredRecordBytes &&
      maxDuration > Duration.zero &&
      maxDuration <= _maxConfiguredDuration &&
      lockTimeout > Duration.zero &&
      lockTimeout <= _maxConfiguredLockTimeout;
}

/// Bounded startup result. The durable per-alias receipts remain the source of
/// truth for late-writer detection; this report is safe to discard.
class ProviderIdMigrationReport {
  final String state;
  final int scannedEntries;
  final int processedRecords;
  final int carriedRecords;
  final int quarantinedRecords;
  final int invalidRecords;
  final bool truncated;
  final List<Map<String, dynamic>> aliases;

  const ProviderIdMigrationReport({
    required this.state,
    required this.scannedEntries,
    required this.processedRecords,
    required this.carriedRecords,
    required this.quarantinedRecords,
    required this.invalidRecords,
    required this.truncated,
    required this.aliases,
  });

  const ProviderIdMigrationReport.empty()
      : state = 'complete',
        scannedEntries = 0,
        processedRecords = 0,
        carriedRecords = 0,
        quarantinedRecords = 0,
        invalidRecords = 0,
        truncated = false,
        aliases = const [];

  Map<String, dynamic> toJson() => {
        'schema': providerIdMigrationReportSchema,
        'state': state,
        'scanned_entries': scannedEntries,
        'processed_records': processedRecords,
        'carried_records': carriedRecords,
        'quarantined_records': quarantinedRecords,
        'invalid_records': invalidRecords,
        'truncated': truncated,
        'aliases': aliases,
      };
}

class _MigrationCandidate {
  final String oldProvider;
  final String newProvider;
  final File source;
  final File target;
  final String role;
  final String tier;
  final String scope;
  final String? accountDigest;
  final String? legacyAccountStem;
  final String recordId;

  const _MigrationCandidate({
    required this.oldProvider,
    required this.newProvider,
    required this.source,
    required this.target,
    required this.role,
    required this.tier,
    required this.scope,
    required this.accountDigest,
    this.legacyAccountStem,
    required this.recordId,
  });
}

class _ProcessedRecord {
  final Map<String, dynamic> receipt;
  final int bytesRead;
  final bool targetMutated;

  const _ProcessedRecord(
    this.receipt,
    this.bytesRead, {
    this.targetMutated = false,
  });
}

/// Runs the cache-root migration for every registered one-way provider alias.
///
/// Old evidence is copied byte-for-byte, not rewritten. Cache readers
/// canonicalize the embedded provider id in memory, which keeps raw-history and
/// analytics checkpoint digests stable. The old branch remains in place so a
/// released legacy writer is detectable. A later run copies a one-sided legacy
/// advance, but quarantines the exact identity and tier when both branches
/// changed independently.
Future<ProviderIdMigrationReport> coordinateProviderIdCacheMigration({
  Map<String, String>? aliases,
  Directory? root,
  ProviderIdMigrationLimits limits = const ProviderIdMigrationLimits(),
}) {
  if (aliases == null && root == null) {
    final active = _defaultCoordinatorFlight;
    if (active != null) return active;
    late Future<ProviderIdMigrationReport> flight;
    flight = () async {
      _migrationObserverForTesting?.call('start');
      try {
        return await _coordinateProviderIdCacheMigration(limits: limits);
      } finally {
        _migrationObserverForTesting?.call('complete');
        if (identical(_defaultCoordinatorFlight, flight)) {
          _defaultCoordinatorFlight = null;
        }
      }
    }();
    _defaultCoordinatorFlight = flight;
    return flight;
  }
  return _coordinateProviderIdCacheMigration(
    aliases: aliases,
    root: root,
    limits: limits,
  );
}

Future<ProviderIdMigrationReport> _coordinateProviderIdCacheMigration({
  Map<String, String>? aliases,
  Directory? root,
  required ProviderIdMigrationLimits limits,
}) async {
  final selectedAliases = aliases ?? providerIdAliases;
  if (selectedAliases.isEmpty) {
    return const ProviderIdMigrationReport.empty();
  }
  if (!limits.valid) {
    return const ProviderIdMigrationReport(
      state: 'partial',
      scannedEntries: 0,
      processedRecords: 0,
      carriedRecords: 0,
      quarantinedRecords: 0,
      invalidRecords: 1,
      truncated: true,
      aliases: [],
    );
  }

  final migrationRoot = root ?? quotabotDir('cache');
  if (!_safeMigrationRoot(migrationRoot)) {
    return const ProviderIdMigrationReport(
      state: 'partial',
      scannedEntries: 0,
      processedRecords: 0,
      carriedRecords: 0,
      quarantinedRecords: 0,
      invalidRecords: 1,
      truncated: false,
      aliases: [],
    );
  }

  final normalizedAliases = _validAliases(selectedAliases, limits.maxAliases);
  if (normalizedAliases == null) {
    return const ProviderIdMigrationReport(
      state: 'partial',
      scannedEntries: 0,
      processedRecords: 0,
      carriedRecords: 0,
      quarantinedRecords: 0,
      invalidRecords: 1,
      truncated: true,
      aliases: [],
    );
  }

  final overall = Stopwatch()..start();
  final coordinatorLock =
      File('${migrationRoot.path}/provider_id_migration.lock');
  InterprocessFileGuard? coordinatorGuard;
  try {
    _prepareMigrationLock(coordinatorLock, migrationRoot);
    coordinatorGuard = await acquireInterprocessFileGuard(
      coordinatorLock,
      hardenClaim: restrictOwnerOnlyFile,
      acquisitionTimeout: _remainingTimeout(
        overall,
        limits.maxDuration,
        limits.lockTimeout,
      ),
      reclaimSameProcessClaims: false,
    );
  } catch (_) {
    return const ProviderIdMigrationReport(
      state: 'partial',
      scannedEntries: 0,
      processedRecords: 0,
      carriedRecords: 0,
      quarantinedRecords: 0,
      invalidRecords: 1,
      truncated: true,
      aliases: [],
    );
  }

  try {
    if (!_safeMigrationRoot(migrationRoot)) {
      return const ProviderIdMigrationReport(
        state: 'partial',
        scannedEntries: 0,
        processedRecords: 0,
        carriedRecords: 0,
        quarantinedRecords: 0,
        invalidRecords: 1,
        truncated: false,
        aliases: [],
      );
    }

    _migrationObserverForTesting?.call('coordinator_locked');

    final scan = await _scanMigrationRoot(
      migrationRoot,
      normalizedAliases,
      limits,
      overall,
    );
    var processed = 0;
    var carried = 0;
    var quarantined = 0;
    var invalid = scan.invalidEntries;
    var bytesRead = scan.planningBytes;
    var truncated = scan.truncated;
    final aliasReports = <Map<String, dynamic>>[];

    for (final alias in normalizedAliases.entries) {
      final prior = _readAliasReceipt(
        migrationRoot,
        alias.key,
        alias.value,
      );
      final previousRecords = _receiptRecordsById(prior);
      final nextRecords = <Map<String, dynamic>>[];
      final candidates = scan.candidates
          .where((candidate) => candidate.oldProvider == alias.key)
          .toList();
      final candidateGroups = <String, List<_MigrationCandidate>>{};
      for (final candidate in candidates) {
        candidateGroups
            .putIfAbsent(_candidateGuardKey(candidate), () => [])
            .add(candidate);
      }
      final groupKeys = candidateGroups.keys.toList()..sort();
      for (final group in candidateGroups.values) {
        group.sort(
            (left, right) => left.source.path.compareTo(right.source.path));
      }
      var aliasTruncated = false;
      var receiptUnavailable = false;

      bool persistProgress(Map<String, dynamic> record) {
        final byId = <String, Map<String, dynamic>>{
          ...previousRecords,
          for (final current in nextRecords)
            current['record_id'] as String: current,
          record['record_id'] as String: record,
        };
        if (byId.length > limits.maxRecords) return false;
        final records = byId.entries.toList()
          ..sort((left, right) => left.key.compareTo(right.key));
        return _writeAliasReceipt(
          migrationRoot,
          _aliasReceiptPayload(
            oldProvider: alias.key,
            newProvider: alias.value,
            state: 'partial',
            scannedEntries: scan.scannedEntries,
            truncated: false,
            globalUncertainty: true,
            records: [for (final entry in records) entry.value],
          ),
        );
      }

      candidateLoop:
      for (final groupKey in groupKeys) {
        final group = candidateGroups[groupKey]!;
        List<InterprocessFileGuard> guards;
        try {
          guards = await _acquireCandidateGuards(
            group.first,
            migrationRoot,
            limits,
            overall,
          );
        } catch (_) {
          for (final candidate in group) {
            if (processed >= limits.maxRecords ||
                overall.elapsed >= limits.maxDuration) {
              aliasTruncated = true;
              truncated = true;
              break candidateLoop;
            }
            processed++;
            invalid++;
            nextRecords.add({
              ..._candidateReceiptBase(candidate),
              'state': 'invalid',
              'reason': 'migration_unavailable',
            });
          }
          continue;
        }
        try {
          for (final candidate in group) {
            if (processed >= limits.maxRecords ||
                bytesRead >= limits.maxTotalBytes ||
                overall.elapsed >= limits.maxDuration) {
              aliasTruncated = true;
              truncated = true;
              break candidateLoop;
            }
            final result = await _processCandidate(
              candidate,
              previousRecords[candidate.recordId],
              migrationRoot,
              limits,
              overall,
              remainingBytes: limits.maxTotalBytes - bytesRead,
              locksHeld: true,
              persistPrepared: persistProgress,
            );
            processed++;
            bytesRead += result.bytesRead;
            if (result.targetMutated && result.receipt['state'] == 'invalid') {
              invalid++;
              truncated = true;
              aliasTruncated = true;
              receiptUnavailable = true;
              break candidateLoop;
            }
            nextRecords.add(result.receipt);
            if (!persistProgress(result.receipt)) {
              invalid++;
              truncated = true;
              aliasTruncated = true;
              receiptUnavailable = true;
              break candidateLoop;
            }
            switch (result.receipt['state']) {
              case 'carried':
              case 'current':
                carried++;
              case 'quarantined':
                quarantined++;
              default:
                invalid++;
            }
          }
        } finally {
          for (final guard in guards.reversed) {
            guard.release();
          }
        }
      }

      final seen = {for (final record in nextRecords) record['record_id']};
      final unseenPrevious = previousRecords.entries
          .where((entry) => !seen.contains(entry.key))
          .toList()
        ..sort((left, right) => left.key.compareTo(right.key));
      for (final entry in unseenPrevious) {
        if (nextRecords.length >= limits.maxRecords) {
          aliasTruncated = true;
          truncated = true;
          break;
        }
        nextRecords.add(entry.value);
      }

      final globalUncertainty =
          aliasTruncated || scan.truncated || scan.invalidEntries > 0;
      final aliasState = receiptUnavailable ||
              globalUncertainty ||
              nextRecords.any((record) =>
                  record['state'] != 'carried' && record['state'] != 'current')
          ? 'partial'
          : 'complete';
      final receipt = _aliasReceiptPayload(
        oldProvider: alias.key,
        newProvider: alias.value,
        state: aliasState,
        scannedEntries: scan.scannedEntries,
        truncated: aliasTruncated || scan.truncated,
        globalUncertainty: globalUncertainty,
        records: nextRecords,
      );
      if (!receiptUnavailable && !_writeAliasReceipt(migrationRoot, receipt)) {
        invalid++;
        truncated = true;
      }
      aliasReports.add({
        'old_provider': alias.key,
        'new_provider': alias.value,
        'state': aliasState,
        'records': nextRecords.length,
      });
    }

    final partial = truncated || quarantined > 0 || invalid > 0;
    return ProviderIdMigrationReport(
      state: partial ? 'partial' : 'complete',
      scannedEntries: scan.scannedEntries,
      processedRecords: processed,
      carriedRecords: carried,
      quarantinedRecords: quarantined,
      invalidRecords: invalid,
      truncated: truncated,
      aliases: aliasReports,
    );
  } finally {
    coordinatorGuard.release();
  }
}

/// True when a durable provider-id migration receipt quarantines this exact
/// provider identity and storage tier.
///
/// This is deliberately a bounded local read. A missing, malformed, or
/// unreadable receipt cannot grant migration continuity for a registered alias,
/// so the affected canonical provider fails closed until the coordinator can
/// persist a trustworthy receipt.
bool providerIdMigrationTierQuarantined(
  String provider,
  String account,
  String tier, {
  Map<String, String>? aliases,
  Directory? root,
}) {
  final selectedAliases = aliases ?? providerIdAliases;
  if (selectedAliases.isEmpty ||
      !const {'quota', 'history', 'buckets'}.contains(tier)) {
    return false;
  }
  final canonical = canonicalizeProviderId(provider, selectedAliases);
  final migrationRoot = root ?? quotabotDir('cache');
  final relevantAliases = selectedAliases.entries
      .where((alias) => alias.value == canonical)
      .take(32)
      .toList();
  if (relevantAliases.isEmpty) return false;
  if (!_safeMigrationRoot(migrationRoot)) return true;
  final accountDigest =
      hasSpecificQuotaAccount(account) ? accountIdentityDigest(account) : null;
  for (final alias in relevantAliases) {
    final receipt = _readAliasReceipt(
      migrationRoot,
      alias.key,
      alias.value,
    );
    if (receipt == null) return true;
    final records = receipt['records'];
    if (records is! List || records.length > 512) return true;
    if (!const {'complete', 'partial'}.contains(receipt['state'])) return true;
    if (receipt['state'] == 'partial' &&
        receipt['global_uncertainty'] == true) {
      return true;
    }
    for (final raw in records) {
      if (raw is! Map) continue;
      final record = raw.cast<String, dynamic>();
      if (record['state'] != 'quarantined' &&
          record['state'] != 'invalid' &&
          record['state'] != 'prepared') {
        continue;
      }
      final recordTier = record['tier'];
      if (recordTier == 'analytics') {
        final affected = record['affected_tiers'];
        if (affected is! List || !affected.contains(tier)) continue;
      } else if (recordTier != tier) {
        continue;
      }
      final scope = record['scope'];
      if ((scope == 'provider' && accountDigest == null) ||
          (scope == 'account' &&
              accountDigest != null &&
              record['account_digest'] == accountDigest)) {
        return true;
      }
    }
    if (_retiredTierChanged(
      migrationRoot,
      alias.key,
      alias.value,
      account,
      tier,
      _receiptRecordsById(receipt),
    )) {
      return true;
    }
  }
  return false;
}

bool _retiredTierChanged(
  Directory root,
  String oldProvider,
  String newProvider,
  String account,
  String tier,
  Map<String, Map<String, dynamic>> records,
) {
  try {
    final specificAccount = hasSpecificQuotaAccount(account);
    final accountDigest = accountIdentityDigest(account);
    final rawAccount = _rawStorageStem(account);
    var bytesRead = 0;
    for (final source in _identityRetiredSources(
      root,
      oldProvider,
      accountDigest,
      rawAccount,
      specificAccount: specificAccount,
    )) {
      final name = source.uri.pathSegments.last;
      final expectedTier = _retiredEvidenceTier(name, oldProvider);
      if (expectedTier == null) return true;
      final candidate = _classifyCandidate(
        root,
        source,
        name,
        oldProvider,
        newProvider,
      );
      if (candidate == null || candidate.tier != expectedTier) return true;
      final recordId = sha256.convert(utf8.encode(name)).toString();
      final record = records[recordId];
      final affectedTiers = record?['affected_tiers'];
      final affectsTier = expectedTier == tier ||
          (expectedTier == 'analytics' &&
              (affectedTiers is List
                  ? affectedTiers.contains(tier)
                  : tier == 'history' || tier == 'buckets'));
      if (!affectsTier) continue;
      if (record != null) {
        if (record['role'] != candidate.role ||
            record['tier'] != candidate.tier) {
          return true;
        }
      }

      final sourceType =
          FileSystemEntity.typeSync(source.path, followLinks: false);
      String? resolvedAccountDigest = candidate.accountDigest;
      var observedSourceDigest = record?['source_sha256'] as String?;
      if (sourceType != FileSystemEntityType.notFound) {
        if (sourceType != FileSystemEntityType.file || record == null) {
          return true;
        }
        final length = source.lengthSync();
        if (length < 0 ||
            length > 5 * 1024 * 1024 ||
            bytesRead + length > 32 * 1024 * 1024) {
          return true;
        }
        final bytes = source.readAsBytesSync();
        bytesRead += bytes.length;
        observedSourceDigest = sha256.convert(bytes).toString();
        if (candidate.legacyAccountStem != null) {
          final resolution = _resolvedCandidateAccountDigest(
            candidate,
            bytes,
            root,
            remainingBytes: 32 * 1024 * 1024 - bytesRead,
          );
          bytesRead += resolution.bytesRead;
          resolvedAccountDigest = resolution.digest;
          if (resolvedAccountDigest == null) {
            if (record['scope'] == 'unresolved') continue;
            return true;
          }
          if (record['scope'] != 'account' ||
              record['account_digest'] != resolvedAccountDigest) {
            return true;
          }
          if (specificAccount && resolvedAccountDigest != accountDigest) {
            continue;
          }
        }
        if (record['source_sha256'] != observedSourceDigest) {
          return true;
        }
      } else if (record == null) {
        continue;
      }

      if (candidate.accountDigest != null) {
        if (record['scope'] != 'account' ||
            record['account_digest'] != candidate.accountDigest) {
          return true;
        }
      } else if (candidate.legacyAccountStem == null) {
        if (record['scope'] != 'provider') return true;
      } else if (sourceType == FileSystemEntityType.notFound) {
        if (record['scope'] == 'unresolved') continue;
        if (record['scope'] != 'account') return true;
        resolvedAccountDigest = record['account_digest'] as String?;
        if (specificAccount && resolvedAccountDigest != accountDigest) {
          continue;
        }
      }

      final target = _canonicalCandidateTarget(
        candidate,
        resolvedAccountDigest,
        root,
      );
      final targetType =
          FileSystemEntity.typeSync(target.path, followLinks: false);
      if (targetType == FileSystemEntityType.notFound) {
        if (candidate.legacyAccountStem != null &&
            candidate.target.absolute.path != target.absolute.path &&
            FileSystemEntity.typeSync(
                  candidate.target.path,
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound) {
          // A canonical tombstone must also suppress the released raw
          // compatibility branch, or fallback readers could resurrect it.
          return true;
        }
        if (record['target_absent'] == true) continue;
        // Current drift diagnostics and migration metadata can be cleared
        // without exposing retired evidence through a canonical data reader.
        if (const {'drift', 'analytics_marker', 'bucket_owner'}
            .contains(candidate.role)) {
          continue;
        }
        return true;
      }
      final targetDigest = record['target_sha256'];
      if (targetType != FileSystemEntityType.file) {
        return true;
      }
      final targetLength = target.lengthSync();
      if (targetLength < 0 ||
          targetLength > 5 * 1024 * 1024 ||
          bytesRead + targetLength > 32 * 1024 * 1024) {
        return true;
      }
      final targetBytes = target.readAsBytesSync();
      bytesRead += targetBytes.length;
      final observedTargetDigest = sha256.convert(targetBytes).toString();
      if (targetDigest != observedTargetDigest) {
        // A current writer can advance the canonical branch while the retired
        // source remains at the recorded baseline. Admit only a semantically
        // valid canonical generation. A later retired advance still changes
        // source_sha256 and fails closed as a two-branch conflict.
        if (_validateCandidate(
              candidate,
              targetBytes,
              resolvedAccountDigest,
              canonicalTarget: true,
            ) !=
            null) {
          return true;
        }
      }
      if (candidate.legacyAccountStem != null &&
          candidate.target.absolute.path != target.absolute.path) {
        final compatibilityType = FileSystemEntity.typeSync(
          candidate.target.path,
          followLinks: false,
        );
        if (compatibilityType != FileSystemEntityType.notFound) {
          if (compatibilityType != FileSystemEntityType.file) return true;
          final compatibilityLength = candidate.target.lengthSync();
          if (compatibilityLength < 0 ||
              compatibilityLength > 5 * 1024 * 1024 ||
              bytesRead + compatibilityLength > 32 * 1024 * 1024) {
            return true;
          }
          final compatibilityBytes = candidate.target.readAsBytesSync();
          bytesRead += compatibilityBytes.length;
          if (_validateCandidate(
                candidate,
                compatibilityBytes,
                resolvedAccountDigest,
                canonicalTarget: true,
              ) !=
              null) {
            return true;
          }
          final compatibilityDigest =
              sha256.convert(compatibilityBytes).toString();
          if (compatibilityDigest != observedSourceDigest &&
              compatibilityDigest != observedTargetDigest) {
            return true;
          }
        }
      }
    }
    return false;
  } catch (_) {
    return true;
  }
}

String? _retiredEvidenceTier(String name, String oldProvider) {
  if (name == '$oldProvider.json' ||
      name.startsWith('${oldProvider}_') ||
      name.startsWith('drift_${oldProvider}_')) {
    return 'quota';
  }
  if (name == 'history_$oldProvider.jsonl' ||
      name.startsWith('history_${oldProvider}_')) {
    return 'history';
  }
  if (name == 'buckets_$oldProvider.json' ||
      name.startsWith('buckets_${oldProvider}_') ||
      name.startsWith('legacy_bucket_owner_${oldProvider}_')) {
    return 'buckets';
  }
  if (name.startsWith('analytics_migration_${oldProvider}_')) {
    return 'analytics';
  }
  return null;
}

/// Detects a retired-provider write while the caller holds every old and new
/// evidence guard for one provider identity. A true result means the mutation
/// must stop and let the startup coordinator reconcile the branches first.
bool providerIdMigrationIdentityChanged(
  String provider,
  String account, {
  Map<String, String>? aliases,
  Directory? root,
  Set<String> tiers = const {'quota', 'history', 'buckets'},
}) {
  final selectedAliases = aliases ?? providerIdAliases;
  final selectedTiers = tiers.intersection(
    const {'quota', 'history', 'buckets'},
  );
  if (selectedAliases.isEmpty || selectedTiers.isEmpty) return false;
  final canonical = canonicalizeProviderId(provider, selectedAliases);
  final relevant = selectedAliases.entries
      .where((alias) => alias.value == canonical)
      .take(32)
      .toList();
  if (relevant.isEmpty) return false;
  final migrationRoot = root ?? quotabotDir('cache');
  if (!_safeMigrationRoot(migrationRoot)) return true;
  for (final alias in relevant) {
    final receipt = _readAliasReceipt(
      migrationRoot,
      alias.key,
      alias.value,
    );
    if (receipt == null || receipt['global_uncertainty'] == true) return true;
    final records = _receiptRecordsById(receipt);
    final specificAccount = hasSpecificQuotaAccount(account);
    final accountDigest = accountIdentityDigest(account);
    for (final record in records.values) {
      if (!const {'quarantined', 'invalid', 'prepared'}
          .contains(record['state'])) {
        continue;
      }
      final recordTier = record['tier'];
      final affectsSelectedTier = recordTier == 'analytics'
          ? record['affected_tiers'] is List &&
              (record['affected_tiers'] as List).any(selectedTiers.contains)
          : selectedTiers.contains(recordTier);
      if (!affectsSelectedTier) continue;
      final scope = record['scope'];
      if ((scope == 'account' &&
              specificAccount &&
              record['account_digest'] == accountDigest) ||
          (scope == 'provider' && !specificAccount)) {
        return true;
      }
    }
    for (final tier in selectedTiers) {
      if (_retiredTierChanged(
        migrationRoot,
        alias.key,
        alias.value,
        account,
        tier,
        records,
      )) {
        return true;
      }
    }
  }
  return false;
}

List<File> _identityRetiredSources(
  Directory root,
  String oldProvider,
  String accountDigest,
  String rawAccount, {
  required bool specificAccount,
}) {
  final names = <String>{
    '${oldProvider}_account_$accountDigest.json',
    'drift_${oldProvider}_account_$accountDigest.json',
    'history_${oldProvider}_account_$accountDigest.jsonl',
    'buckets_${oldProvider}_account_$accountDigest.json',
    'analytics_migration_${oldProvider}_account_$accountDigest.json',
    'legacy_bucket_owner_${oldProvider}_account_$accountDigest.json',
    if (specificAccount &&
        utf8.encode(rawAccount).length <=
            _maxMigrationTargetComponentBytes) ...{
      '${oldProvider}_$rawAccount.json',
      'drift_${oldProvider}_$rawAccount.json',
      'history_${oldProvider}_$rawAccount.jsonl',
      'buckets_${oldProvider}_$rawAccount.json',
    },
    if (specificAccount)
      'legacy_bucket_owner_${oldProvider}_${accountStorageStem(rawAccount)}.json'
    else ...{
      '$oldProvider.json',
      'history_$oldProvider.jsonl',
      'buckets_$oldProvider.json',
    },
  };
  return [
    for (final name in names)
      if (utf8.encode(name).length <= _maxMigrationTargetComponentBytes)
        File('${root.path}/$name'),
  ];
}

Map<String, String>? _validAliases(
  Map<String, String> aliases,
  int maxAliases,
) {
  if (aliases.length > maxAliases) return null;
  final validId = RegExp(_providerIdPattern);
  final normalized = <String, String>{};
  for (final entry in aliases.entries) {
    final oldProvider = entry.key.trim().toLowerCase();
    final newProvider = entry.value.trim().toLowerCase();
    if (oldProvider != entry.key ||
        newProvider != entry.value ||
        oldProvider == newProvider ||
        !validId.hasMatch(oldProvider) ||
        !validId.hasMatch(newProvider) ||
        kCurrentProviderIds.contains(oldProvider) ||
        !kCurrentProviderIds.contains(newProvider) ||
        aliases.containsKey(newProvider)) {
      return null;
    }
    normalized[oldProvider] = newProvider;
  }
  return Map.unmodifiable(normalized);
}

bool _safeMigrationRoot(Directory root) {
  try {
    return FileSystemEntity.typeSync(root.path, followLinks: false) ==
        FileSystemEntityType.directory;
  } catch (_) {
    return false;
  }
}

Duration _remainingTimeout(
  Stopwatch elapsed,
  Duration total,
  Duration perLock,
) {
  final remaining = total - elapsed.elapsed;
  if (remaining <= Duration.zero) return Duration.zero;
  return remaining < perLock ? remaining : perLock;
}

void _prepareMigrationLock(File file, Directory root) {
  if (!_safeMigrationRoot(root) ||
      file.parent.absolute.path != root.absolute.path) {
    throw FileSystemException('unsafe provider migration lock', file.path);
  }
  var type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    try {
      file.createSync(exclusive: true);
    } on FileSystemException {
      type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.file) rethrow;
    }
    type = FileSystemEntity.typeSync(file.path, followLinks: false);
  }
  if (type != FileSystemEntityType.file) {
    throw FileSystemException('invalid provider migration lock', file.path);
  }
  restrictOwnerOnlyFile(file);
}

Future<
    ({
      List<_MigrationCandidate> candidates,
      int scannedEntries,
      int invalidEntries,
      int planningBytes,
      bool truncated,
    })> _scanMigrationRoot(
  Directory root,
  Map<String, String> aliases,
  ProviderIdMigrationLimits limits,
  Stopwatch elapsed,
) async {
  final candidates = <_MigrationCandidate>[];
  var scanned = 0;
  var invalid = 0;
  var planningBytes = 0;
  var truncated = false;
  try {
    scanLoop:
    await for (final entity in root.list(followLinks: false)) {
      if (scanned >= limits.maxRootEntries ||
          elapsed.elapsed >= limits.maxDuration) {
        truncated = true;
        break;
      }
      scanned++;
      final name = entity.uri.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
        orElse: () => '',
      );
      for (final alias in aliases.entries) {
        if (name.startsWith('legacy_bucket_owner_${alias.key}_') &&
            FileSystemEntity.typeSync(entity.path, followLinks: false) ==
                FileSystemEntityType.file) {
          final length = File(entity.path).lengthSync();
          if (length > 16 * 1024 ||
              planningBytes + length > limits.maxTotalBytes) {
            truncated = true;
            break scanLoop;
          }
          planningBytes += length;
        }
        final candidate = _classifyCandidate(
          root,
          entity,
          name,
          alias.key,
          alias.value,
        );
        if (candidate != null) {
          candidates.add(candidate);
          break;
        }
        if (_looksLikeRetiredEvidenceName(name, alias.key)) {
          invalid++;
          break;
        }
      }
    }
  } catch (_) {
    invalid++;
    truncated = true;
  }
  return (
    candidates: candidates,
    scannedEntries: scanned,
    invalidEntries: invalid,
    planningBytes: planningBytes,
    truncated: truncated,
  );
}

bool _safeMigrationTargetComponent(File target) {
  final name = target.uri.pathSegments.last;
  return name.isNotEmpty &&
      utf8.encode(name).length <= _maxMigrationTargetComponentBytes;
}

bool _looksLikeRetiredEvidenceName(String name, String oldProvider) {
  final exact = name == '$oldProvider.json';
  final prefixed = <({String prefix, String suffix})>[
    (prefix: '${oldProvider}_', suffix: '.json'),
    (prefix: 'drift_${oldProvider}_', suffix: '.json'),
    (prefix: 'history_${oldProvider}_', suffix: '.jsonl'),
    (prefix: 'buckets_${oldProvider}_', suffix: '.json'),
    (prefix: 'analytics_migration_${oldProvider}_', suffix: '.json'),
    (prefix: 'legacy_bucket_owner_${oldProvider}_', suffix: '.json'),
  ];
  return exact ||
      prefixed.any(
        (pattern) =>
            name.startsWith(pattern.prefix) && name.endsWith(pattern.suffix),
      );
}

_MigrationCandidate? _classifyCandidate(
  Directory root,
  FileSystemEntity entity,
  String name,
  String oldProvider,
  String newProvider,
) {
  final old = RegExp.escape(oldProvider);
  final patterns = <({RegExp pattern, String role, String tier})>[
    (
      pattern: RegExp('^$old\\.json\$'),
      role: 'snapshot',
      tier: 'quota',
    ),
    (
      pattern: RegExp('^${old}_(account_([a-f0-9]{64}))\\.json\$'),
      role: 'snapshot',
      tier: 'quota',
    ),
    (
      pattern: RegExp('^drift_${old}_(account_([a-f0-9]{64}))\\.json\$'),
      role: 'drift',
      tier: 'quota',
    ),
    (
      pattern: RegExp('^history_$old(?:_(account_([a-f0-9]{64})))?\\.jsonl\$'),
      role: 'history',
      tier: 'history',
    ),
    (
      pattern: RegExp('^buckets_$old(?:_(account_([a-f0-9]{64})))?\\.json\$'),
      role: 'buckets',
      tier: 'buckets',
    ),
    (
      pattern: RegExp(
          '^analytics_migration_${old}_(account_([a-f0-9]{64}))\\.json\$'),
      role: 'analytics_marker',
      tier: 'analytics',
    ),
    (
      pattern: RegExp(
          '^legacy_bucket_owner_${old}_(account_([a-f0-9]{64}))\\.json\$'),
      role: 'bucket_owner',
      tier: 'buckets',
    ),
  ];
  for (final descriptor in patterns) {
    final match = descriptor.pattern.firstMatch(name);
    if (match == null) continue;
    String? digest;
    for (var group = match.groupCount; group >= 1; group--) {
      final value = match.group(group);
      if (value != null && RegExp(_digestPattern).hasMatch(value)) {
        digest = value;
        break;
      }
    }
    final prefix = switch (descriptor.role) {
      'drift' => 'drift_',
      'history' => 'history_',
      'buckets' => 'buckets_',
      'analytics_marker' => 'analytics_migration_',
      'bucket_owner' => 'legacy_bucket_owner_',
      _ => '',
    };
    final targetName = name.replaceFirst(
      '$prefix$oldProvider',
      '$prefix$newProvider',
    );
    final recordId = sha256.convert(utf8.encode(name)).toString();
    if (descriptor.role == 'bucket_owner') {
      final planned =
          _plannedOwnerAccountDigest(File(entity.path), oldProvider);
      if (planned != null) digest = planned;
    }
    return _MigrationCandidate(
      oldProvider: oldProvider,
      newProvider: newProvider,
      source: File(entity.path),
      target: File('${root.path}/$targetName'),
      role: descriptor.role,
      tier: descriptor.tier,
      scope: digest == null
          ? descriptor.role == 'bucket_owner'
              ? 'unresolved'
              : 'provider'
          : 'account',
      accountDigest: digest,
      recordId: recordId,
    );
  }
  final legacyPatterns = <({
    RegExp pattern,
    String role,
    String tier,
    String prefix,
  })>[
    (
      pattern: RegExp('^${old}_([a-zA-Z0-9._-]{1,220})\\.json\$'),
      role: 'snapshot',
      tier: 'quota',
      prefix: '',
    ),
    (
      pattern: RegExp('^drift_${old}_([a-zA-Z0-9._-]{1,220})\\.json\$'),
      role: 'drift',
      tier: 'quota',
      prefix: 'drift_',
    ),
    (
      pattern: RegExp('^history_${old}_([a-zA-Z0-9._-]{1,220})\\.jsonl\$'),
      role: 'history',
      tier: 'history',
      prefix: 'history_',
    ),
    (
      pattern: RegExp('^buckets_${old}_([a-zA-Z0-9._-]{1,220})\\.json\$'),
      role: 'buckets',
      tier: 'buckets',
      prefix: 'buckets_',
    ),
  ];
  for (final descriptor in legacyPatterns) {
    final match = descriptor.pattern.firstMatch(name);
    if (match == null) continue;
    final legacyStem = match.group(1)!;
    final targetName = name.replaceFirst(
      '${descriptor.prefix}$oldProvider',
      '${descriptor.prefix}$newProvider',
    );
    return _MigrationCandidate(
      oldProvider: oldProvider,
      newProvider: newProvider,
      source: File(entity.path),
      target: File('${root.path}/$targetName'),
      role: descriptor.role,
      tier: descriptor.tier,
      scope: 'legacy',
      accountDigest: null,
      legacyAccountStem: legacyStem,
      recordId: sha256.convert(utf8.encode(name)).toString(),
    );
  }
  return null;
}

Future<_ProcessedRecord> _processCandidate(
  _MigrationCandidate candidate,
  Map<String, dynamic>? previous,
  Directory root,
  ProviderIdMigrationLimits limits,
  Stopwatch elapsed, {
  required int remainingBytes,
  bool locksHeld = false,
  bool Function(Map<String, dynamic> prepared)? persistPrepared,
}) async {
  var base = _candidateReceiptBase(candidate);
  final guards = <InterprocessFileGuard>[];
  var bytesRead = 0;
  var targetMutationPrepared = false;
  var target = candidate.target;
  try {
    if (!locksHeld) {
      guards.addAll(await _acquireCandidateGuards(
        candidate,
        root,
        limits,
        elapsed,
      ));
    }
    if (!_safeMigrationRoot(root) ||
        candidate.source.parent.absolute.path != root.absolute.path ||
        candidate.target.parent.absolute.path != root.absolute.path) {
      return _ProcessedRecord(
        {...base, 'state': 'invalid', 'reason': 'unsafe_path'},
        bytesRead,
      );
    }
    if (FileSystemEntity.typeSync(candidate.source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return _ProcessedRecord(
        {...base, 'state': 'invalid', 'reason': 'unsafe_source'},
        bytesRead,
      );
    }
    final sourceLength = candidate.source.lengthSync();
    final roleLimit = _roleByteLimit(candidate.role, limits.maxRecordBytes);
    if (sourceLength < 0 ||
        sourceLength > roleLimit ||
        sourceLength > remainingBytes) {
      return _ProcessedRecord(
        {
          ...base,
          'state': 'invalid',
          'reason': sourceLength > remainingBytes
              ? 'total_byte_limit'
              : 'record_byte_limit',
          'bytes': max(0, sourceLength),
        },
        bytesRead,
      );
    }
    final sourceBytes = candidate.source.readAsBytesSync();
    bytesRead += sourceBytes.length;
    final sourceDigest = sha256.convert(sourceBytes).toString();
    final resolution = _resolvedCandidateAccountDigest(
      candidate,
      sourceBytes,
      root,
      remainingBytes: remainingBytes - bytesRead,
    );
    bytesRead += resolution.bytesRead;
    final resolvedAccountDigest = resolution.digest;
    if (resolvedAccountDigest != null) {
      base = _candidateReceiptBase(
        candidate,
        accountDigest: resolvedAccountDigest,
      );
      target = _canonicalCandidateTarget(
        candidate,
        resolvedAccountDigest,
        root,
      );
    }
    final validation = _validateCandidate(
      candidate,
      sourceBytes,
      resolvedAccountDigest,
      canonicalTarget: false,
    );
    if (validation != null) {
      return _ProcessedRecord(
        {
          ...base,
          'state': 'invalid',
          'reason': validation,
          if (candidate.role == 'analytics_marker')
            'affected_tiers': _analyticsAffectedTiers(sourceBytes, validation),
          'bytes': sourceBytes.length,
          'source_sha256': sourceDigest,
        },
        bytesRead,
      );
    }
    if (!_safeMigrationTargetComponent(target)) {
      return _ProcessedRecord(
        {
          ...base,
          'state': 'invalid',
          'reason': 'unsafe_target_name',
          'bytes': sourceBytes.length,
          'source_sha256': sourceDigest,
        },
        bytesRead,
      );
    }

    List<int>? targetBytes;
    String? targetDigest;
    final targetType = FileSystemEntity.typeSync(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.file) {
      final targetLength = target.lengthSync();
      if (targetLength < 0 ||
          targetLength > roleLimit ||
          targetLength > remainingBytes - bytesRead) {
        return _ProcessedRecord(
          {
            ...base,
            'state': 'invalid',
            'reason': 'target_byte_limit',
            'bytes': sourceBytes.length,
            'source_sha256': sourceDigest,
          },
          bytesRead,
        );
      }
      targetBytes = target.readAsBytesSync();
      bytesRead += targetBytes.length;
      targetDigest = sha256.convert(targetBytes).toString();
    } else if (targetType != FileSystemEntityType.notFound) {
      return _ProcessedRecord(
        {
          ...base,
          'state': 'invalid',
          'reason': 'unsafe_target',
          'bytes': sourceBytes.length,
          'source_sha256': sourceDigest,
        },
        bytesRead,
      );
    }

    if (candidate.legacyAccountStem != null &&
        candidate.target.absolute.path != target.absolute.path) {
      final compatibilityType = FileSystemEntity.typeSync(
        candidate.target.path,
        followLinks: false,
      );
      if (compatibilityType != FileSystemEntityType.notFound) {
        if (compatibilityType != FileSystemEntityType.file) {
          return _ProcessedRecord(
            {
              ...base,
              'state': 'quarantined',
              'reason': 'unsafe_compatibility_target',
              'bytes': sourceBytes.length,
              'source_sha256': sourceDigest,
              if (targetDigest != null) 'target_sha256': targetDigest,
              if (targetDigest == null) 'target_absent': true,
            },
            bytesRead,
          );
        }
        final compatibilityLength = candidate.target.lengthSync();
        if (compatibilityLength < 0 ||
            compatibilityLength > roleLimit ||
            compatibilityLength > remainingBytes - bytesRead) {
          return _ProcessedRecord(
            {
              ...base,
              'state': 'invalid',
              'reason': 'compatibility_target_byte_limit',
              'bytes': sourceBytes.length,
              'source_sha256': sourceDigest,
            },
            bytesRead,
          );
        }
        final compatibilityBytes = candidate.target.readAsBytesSync();
        bytesRead += compatibilityBytes.length;
        final compatibilityValidation = _validateCandidate(
          candidate,
          compatibilityBytes,
          resolvedAccountDigest,
          canonicalTarget: true,
        );
        final compatibilityDigest =
            sha256.convert(compatibilityBytes).toString();
        final priorCanonicalTombstone = previous?['state'] == 'current' &&
            previous?['target_absent'] == true &&
            targetDigest == null;
        if (priorCanonicalTombstone ||
            compatibilityValidation != null ||
            (compatibilityDigest != sourceDigest &&
                compatibilityDigest != targetDigest)) {
          return _ProcessedRecord(
            {
              ...base,
              'state': 'quarantined',
              'reason': compatibilityValidation == null
                  ? priorCanonicalTombstone
                      ? 'compatibility_after_canonical_deletion'
                      : 'compatibility_branch_conflict'
                  : 'invalid_compatibility_target',
              'bytes': sourceBytes.length,
              'source_sha256': sourceDigest,
              if (targetDigest != null) 'target_sha256': targetDigest,
              if (targetDigest == null) 'target_absent': true,
            },
            bytesRead,
          );
        }
      }
    }

    final previousState = previous?['state'];
    final previousBaseline = const {
      'carried',
      'current',
      'prepared',
    }.contains(previousState)
        ? previous!['baseline_sha256']
        : null;
    var baselineDigest = previousBaseline is String &&
            RegExp(_digestPattern).hasMatch(previousBaseline)
        ? previousBaseline
        : null;
    if (targetBytes != null) {
      final targetValidation = _validateCandidate(
        candidate,
        targetBytes,
        resolvedAccountDigest,
        canonicalTarget: true,
      );
      if (targetValidation != null) {
        return _ProcessedRecord(
          {
            ...base,
            'state': 'quarantined',
            'reason': 'invalid_canonical_target',
            'bytes': sourceBytes.length,
            if (baselineDigest != null) 'baseline_sha256': baselineDigest,
            'source_sha256': sourceDigest,
            'target_sha256': targetDigest,
            if (candidate.role == 'analytics_marker')
              'affected_tiers':
                  _analyticsAffectedTiers(targetBytes, targetValidation),
          },
          bytesRead,
        );
      }
    }

    final previousIntended =
        previousState == 'prepared' && previous?['intended_sha256'] is String
            ? previous!['intended_sha256'] as String
            : null;
    if (previousIntended != null) {
      if (targetDigest == previousIntended) {
        // The prepared target rename committed before the interruption. Treat
        // that intended content as the common baseline, then reconcile any
        // later legacy-only advance normally.
        baselineDigest = previousIntended;
      } else if (targetDigest == null) {
        // For an initial copy, target absence cannot distinguish a crash before
        // rename from a canonical deletion after rename. Never resurrect the
        // branch in that ambiguous state. Existing-target preparations also
        // treat absence as a canonical deletion.
        return _ProcessedRecord(
          {
            ...base,
            'state': 'quarantined',
            'reason': 'prepared_target_absent',
            'bytes': sourceBytes.length,
            if (baselineDigest != null) 'baseline_sha256': baselineDigest,
            'source_sha256': sourceDigest,
            'target_absent': true,
          },
          bytesRead,
        );
      }
    }

    // Equal branches establish (or re-establish) a common baseline. This also
    // makes a target written immediately before a crash resumable even when no
    // receipt was committed.
    if (targetDigest == sourceDigest) {
      return _ProcessedRecord(
        {
          ...base,
          'state': 'current',
          'bytes': sourceBytes.length,
          'baseline_sha256': sourceDigest,
          'source_sha256': sourceDigest,
          'target_sha256': targetDigest,
        },
        bytesRead,
      );
    }

    // A missing target is an initial copy only before any durable baseline
    // exists. Once both branches were known equal, target absence is a
    // canonical deletion and must not resurrect retired evidence.
    if (baselineDigest != null && sourceDigest == baselineDigest) {
      return _ProcessedRecord(
        {
          ...base,
          'state': 'current',
          'bytes': sourceBytes.length,
          'baseline_sha256': baselineDigest,
          'source_sha256': sourceDigest,
          if (targetDigest != null) 'target_sha256': targetDigest,
          if (targetDigest == null) 'target_absent': true,
        },
        bytesRead,
      );
    }

    final preparedPreconditionMatches = previousState == 'prepared' &&
        previous?['source_sha256'] == sourceDigest &&
        previous?['intended_sha256'] == sourceDigest &&
        ((previous?['target_absent'] == true && targetDigest == null) ||
            previous?['target_sha256'] == targetDigest);
    final initialCopy = baselineDigest == null &&
        (previous == null || preparedPreconditionMatches) &&
        targetDigest == null;
    final legacyOnlyAdvance = baselineDigest != null &&
        (targetDigest == baselineDigest || preparedPreconditionMatches);
    if (!initialCopy && !legacyOnlyAdvance) {
      return _ProcessedRecord(
        {
          ...base,
          'state': 'quarantined',
          'reason': baselineDigest == null
              ? 'preexisting_target_conflict'
              : 'both_branches_advanced',
          'bytes': sourceBytes.length,
          if (baselineDigest != null) 'baseline_sha256': baselineDigest,
          'source_sha256': sourceDigest,
          if (targetDigest != null) 'target_sha256': targetDigest,
          if (targetDigest == null) 'target_absent': true,
        },
        bytesRead,
      );
    }

    if (targetDigest != sourceDigest) {
      final verificationBytes = targetBytes?.length ?? 0;
      if (verificationBytes > remainingBytes - bytesRead) {
        return _ProcessedRecord(
          {
            ...base,
            'state': 'invalid',
            'reason': 'total_byte_limit',
            'bytes': sourceBytes.length,
            'source_sha256': sourceDigest,
          },
          bytesRead,
        );
      }
      final prepared = <String, dynamic>{
        ...base,
        'state': 'prepared',
        'bytes': sourceBytes.length,
        if (baselineDigest != null) 'baseline_sha256': baselineDigest,
        'source_sha256': sourceDigest,
        if (targetDigest != null) 'target_sha256': targetDigest,
        if (targetDigest == null) 'target_absent': true,
        'intended_sha256': sourceDigest,
        if (candidate.role == 'analytics_marker')
          'affected_tiers': const ['history', 'buckets'],
      };
      if (persistPrepared == null || !persistPrepared(prepared)) {
        return _ProcessedRecord(
          {
            ...base,
            'state': 'invalid',
            'reason': 'receipt_unavailable',
            'bytes': sourceBytes.length,
            'source_sha256': sourceDigest,
          },
          bytesRead,
        );
      }
      targetMutationPrepared = true;
      bytesRead += _atomicMigrationWrite(
        target,
        sourceBytes,
        root,
        expectedTargetDigest: targetDigest,
        maxVerificationBytes: verificationBytes,
      );
      targetDigest = sourceDigest;
      try {
        target.setLastModifiedSync(
          candidate.source.lastModifiedSync(),
        );
      } catch (_) {}
    }
    return _ProcessedRecord(
      {
        ...base,
        'state': targetBytes == null ? 'carried' : 'current',
        'bytes': sourceBytes.length,
        'baseline_sha256': sourceDigest,
        'source_sha256': sourceDigest,
        'target_sha256': sourceDigest,
      },
      bytesRead,
      targetMutated: targetMutationPrepared,
    );
  } catch (_) {
    return _ProcessedRecord(
      {...base, 'state': 'invalid', 'reason': 'migration_unavailable'},
      bytesRead,
      targetMutated: targetMutationPrepared,
    );
  } finally {
    if (!locksHeld) {
      for (final guard in guards.reversed) {
        guard.release();
      }
    }
  }
}

File _canonicalCandidateTarget(
  _MigrationCandidate candidate,
  String? accountDigest,
  Directory root,
) {
  if (candidate.legacyAccountStem == null || accountDigest == null) {
    return candidate.target;
  }
  final prefix = switch (candidate.role) {
    'drift' => 'drift_',
    'history' => 'history_',
    'buckets' => 'buckets_',
    _ => '',
  };
  final suffix = candidate.role == 'history' ? '.jsonl' : '.json';
  return File(
    '${root.path}/$prefix${candidate.newProvider}_account_'
    '$accountDigest$suffix',
  );
}

Map<String, dynamic> _candidateReceiptBase(
  _MigrationCandidate candidate, {
  String? accountDigest,
}) =>
    {
      'record_id': candidate.recordId,
      'role': candidate.role,
      'tier': candidate.tier,
      'scope': accountDigest != null || candidate.accountDigest != null
          ? 'account'
          : candidate.scope == 'legacy' || candidate.scope == 'unresolved'
              ? 'unresolved'
              : 'provider',
      if (accountDigest ?? candidate.accountDigest case final digest?)
        'account_digest': digest,
    };

String _candidateGuardKey(_MigrationCandidate candidate) =>
    '${candidate.oldProvider}\u0000${candidate.newProvider}\u0000'
    '${candidate.legacyAccountStem ?? candidate.accountDigest ?? 'provider'}';

Future<List<InterprocessFileGuard>> _acquireCandidateGuards(
  _MigrationCandidate candidate,
  Directory root,
  ProviderIdMigrationLimits limits,
  Stopwatch elapsed,
) async {
  final guards = <InterprocessFileGuard>[];
  try {
    for (final lock in _candidateLocks(candidate, root)) {
      _prepareMigrationLock(lock, root);
      final timeout = _remainingTimeout(
        elapsed,
        limits.maxDuration,
        limits.lockTimeout,
      );
      if (timeout <= Duration.zero) {
        throw const FileSystemException('provider migration timed out');
      }
      guards.add(await acquireInterprocessFileGuard(
        lock,
        hardenClaim: restrictOwnerOnlyFile,
        acquisitionTimeout: timeout,
        reclaimSameProcessClaims: false,
      ));
    }
    return guards;
  } catch (_) {
    for (final guard in guards.reversed) {
      guard.release();
    }
    rethrow;
  }
}

List<File> _candidateLocks(_MigrationCandidate candidate, Directory root) {
  final scope = candidate.legacyAccountStem ??
      (candidate.accountDigest == null
          ? 'provider'
          : 'account_${candidate.accountDigest}');
  return [
    File('${root.path}/evidence_${candidate.oldProvider}_$scope.lock'),
    File('${root.path}/evidence_${candidate.newProvider}_$scope.lock'),
  ];
}

int _roleByteLimit(String role, int configured) {
  final native = switch (role) {
    'drift' || 'bucket_owner' => 16 * 1024,
    'analytics_marker' => 1024 * 1024,
    'snapshot' || 'buckets' => 2 * 1024 * 1024,
    _ => 5 * 1024 * 1024,
  };
  return min(native, configured);
}

String? _validateCandidate(
  _MigrationCandidate candidate,
  List<int> bytes,
  String? resolvedAccountDigest, {
  required bool canonicalTarget,
}) {
  String content;
  try {
    content = utf8.decode(bytes);
  } catch (_) {
    return 'invalid_utf8';
  }
  try {
    switch (candidate.role) {
      case 'snapshot':
        final decoded = jsonDecode(content);
        if (decoded is! Map ||
            _validatedMigratedQuota(
                  candidate,
                  decoded,
                  canonicalTarget: canonicalTarget,
                ) ==
                null ||
            (candidate.legacyAccountStem != null &&
                resolvedAccountDigest == null)) {
          return 'identity_mismatch';
        }
      case 'drift':
        final decoded = jsonDecode(content);
        if (decoded is! Map ||
            !_candidateProviderMatches(
              candidate,
              decoded['provider'],
              canonicalTarget: canonicalTarget,
            )) {
          return 'identity_mismatch';
        }
        final account = decoded['account'];
        if (candidate.accountDigest != null &&
            (account is! String ||
                accountIdentityDigest(account) != candidate.accountDigest)) {
          return 'identity_mismatch';
        }
        if (candidate.legacyAccountStem != null &&
            (account is! String ||
                _rawStorageStem(account) != candidate.legacyAccountStem ||
                resolvedAccountDigest == null)) {
          return 'identity_mismatch';
        }
        final observedAt = decoded['observed_at'];
        final observedAtMicros = decoded['observed_at_micros'];
        final reason = decoded['reason'];
        if (decoded['schema'] != 'quotabot.provider-drift.v1' ||
            observedAt is! int ||
            observedAt < 0 ||
            observedAt > nowEpoch() + kQuotaEvidenceClockSkewSeconds ||
            reason is! String ||
            reason.trim().isEmpty ||
            (observedAtMicros != null &&
                (observedAtMicros is! int ||
                    observedAtMicros < 0 ||
                    observedAtMicros >
                        (nowEpoch() + kQuotaEvidenceClockSkewSeconds) *
                            1000000))) {
          return 'schema_mismatch';
        }
      case 'history':
        final lines = const LineSplitter()
            .convert(content)
            .where((line) => line.trim().isNotEmpty)
            .toList();
        if (lines.length > _historyRecordLimit) return 'record_count_limit';
        if (candidate.legacyAccountStem != null &&
            resolvedAccountDigest == null) {
          return 'identity_mismatch';
        }
        var previousAsOf = -1;
        for (final line in lines) {
          final decoded = jsonDecode(line);
          if (decoded is! Map) return 'malformed_record';
          final quota = _validatedMigratedQuota(
            candidate,
            decoded,
            canonicalTarget: canonicalTarget,
          );
          if (quota == null) {
            return 'identity_mismatch';
          }
          if (quota.asOf < previousAsOf) return 'nonmonotonic_history';
          previousAsOf = quota.asOf;
        }
      case 'buckets':
        if (candidate.legacyAccountStem != null &&
            resolvedAccountDigest == null) {
          return 'unresolved_legacy_owner';
        }
        final decoded = jsonDecode(content);
        if (decoded is! List || decoded.length > _bucketRecordLimit) {
          return 'schema_mismatch';
        }
        var previousStart = -1;
        for (final entry in decoded) {
          if (entry is! Map || !_validBucketRecord(entry)) {
            return 'invalid_bucket';
          }
          final start = entry['s'] as int;
          if (start <= previousStart) return 'nonmonotonic_buckets';
          previousStart = start;
        }
      case 'analytics_marker':
        final decoded = jsonDecode(content);
        if (decoded is! Map ||
            decoded['schema'] != 'quotabot.analytics-migration.v1' ||
            !_candidateProviderMatches(
              candidate,
              decoded['provider'],
              canonicalTarget: canonicalTarget,
            ) ||
            decoded['account_digest'] != candidate.accountDigest) {
          return 'identity_mismatch';
        }
        if (!_validAnalyticsCheckpoint(decoded['history'], history: true) ||
            !_validAnalyticsCheckpoint(decoded['buckets'], history: false)) {
          return 'checkpoint_mismatch';
        }
        final incidentId = decoded['incident_id'];
        final incidentAt = decoded['incident_observed_at'];
        if ((incidentId != null &&
                (incidentId is! String ||
                    !RegExp(r'^[a-f0-9]{32}$').hasMatch(incidentId))) ||
            (incidentAt != null && (incidentAt is! int || incidentAt <= 0))) {
          return 'schema_mismatch';
        }
      case 'bucket_owner':
        final decoded = jsonDecode(content);
        if (decoded is! Map ||
            decoded['schema'] != 'quotabot.legacy-bucket-owner.v1' ||
            !_candidateProviderMatches(
              candidate,
              decoded['provider'],
              canonicalTarget: canonicalTarget,
            ) ||
            decoded['account_digest'] is! String ||
            !RegExp(_digestPattern)
                .hasMatch(decoded['account_digest'] as String) ||
            candidate.accountDigest == null ||
            decoded['account_digest'] != candidate.accountDigest) {
          return 'identity_mismatch';
        }
      default:
        return 'unknown_role';
    }
  } catch (_) {
    return 'malformed_record';
  }
  return null;
}

ProviderQuota? _validatedMigratedQuota(
  _MigrationCandidate candidate,
  Map<dynamic, dynamic> decoded, {
  required bool canonicalTarget,
}) {
  if (!_candidateProviderMatches(
    candidate,
    decoded['provider'],
    canonicalTarget: canonicalTarget,
  )) {
    return null;
  }
  final account = decoded['account'];
  if (account is! String ||
      (candidate.accountDigest != null &&
          accountIdentityDigest(account) != candidate.accountDigest) ||
      (candidate.legacyAccountStem != null &&
          _rawStorageStem(account) != candidate.legacyAccountStem)) {
    return null;
  }
  try {
    final quota = ProviderQuota.fromJson({
      ...decoded.cast<String, dynamic>(),
      'provider': candidate.newProvider,
    });
    if (quota.provider != candidate.newProvider ||
        quota.account != account ||
        quota.asOf <= 0 ||
        quota.asOf > nowEpoch() + kQuotaEvidenceClockSkewSeconds ||
        registeredSourceClassViolation(
              quota,
              providerAdapterById(candidate.newProvider),
              allowManual: false,
            ) !=
            null ||
        !isTrustedQuotaEvidenceAtCapture(quota)) {
      return null;
    }
    return quota;
  } catch (_) {
    return null;
  }
}

bool _candidateProviderMatches(
  _MigrationCandidate candidate,
  Object? provider, {
  required bool canonicalTarget,
}) =>
    provider == candidate.oldProvider ||
    (canonicalTarget && provider == candidate.newProvider);

List<String> _analyticsAffectedTiers(
  List<int> bytes,
  String validation,
) {
  if (validation != 'checkpoint_mismatch') {
    return const ['history', 'buckets'];
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) return const ['history', 'buckets'];
    final affected = <String>[
      if (!_validAnalyticsCheckpoint(decoded['history'], history: true))
        'history',
      if (!_validAnalyticsCheckpoint(decoded['buckets'], history: false))
        'buckets',
    ];
    return affected.isEmpty ? const ['history', 'buckets'] : affected;
  } catch (_) {
    return const ['history', 'buckets'];
  }
}

String _rawStorageStem(String value) {
  final safe = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return safe.isEmpty ? 'unknown' : safe;
}

String? _plannedOwnerAccountDigest(File source, String oldProvider) {
  try {
    if (FileSystemEntity.typeSync(source.path, followLinks: false) !=
            FileSystemEntityType.file ||
        source.lengthSync() > 16 * 1024) {
      return null;
    }
    final decoded = jsonDecode(source.readAsStringSync());
    final digest = decoded is Map ? decoded['account_digest'] : null;
    if (decoded is Map &&
        decoded['schema'] == 'quotabot.legacy-bucket-owner.v1' &&
        decoded['provider'] == oldProvider &&
        digest is String &&
        RegExp(_digestPattern).hasMatch(digest)) {
      return digest;
    }
  } catch (_) {}
  return null;
}

({String? digest, int bytesRead}) _resolvedCandidateAccountDigest(
  _MigrationCandidate candidate,
  List<int> sourceBytes,
  Directory root, {
  required int remainingBytes,
}) {
  if (candidate.accountDigest != null) {
    return (digest: candidate.accountDigest, bytesRead: 0);
  }
  final legacyStem = candidate.legacyAccountStem;
  if (legacyStem == null) return (digest: null, bytesRead: 0);
  try {
    if (candidate.role == 'snapshot' || candidate.role == 'drift') {
      final decoded = jsonDecode(utf8.decode(sourceBytes));
      final account = decoded is Map ? decoded['account'] : null;
      return (
        digest: account is String && _rawStorageStem(account) == legacyStem
            ? accountIdentityDigest(account)
            : null,
        bytesRead: 0,
      );
    }
    if (candidate.role == 'history') {
      final accounts = <String>{};
      for (final line
          in const LineSplitter().convert(utf8.decode(sourceBytes))) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        final account = decoded is Map ? decoded['account'] : null;
        if (account is! String || _rawStorageStem(account) != legacyStem) {
          return (digest: null, bytesRead: 0);
        }
        accounts.add(account);
      }
      return (
        digest: accounts.length == 1
            ? accountIdentityDigest(accounts.single)
            : null,
        bytesRead: 0,
      );
    }
    if (candidate.role == 'buckets') {
      return _legacyBucketAccountDigest(
        candidate,
        root,
        remainingBytes: remainingBytes,
      );
    }
  } catch (_) {}
  return (digest: null, bytesRead: 0);
}

({String? digest, int bytesRead}) _legacyBucketAccountDigest(
  _MigrationCandidate candidate,
  Directory root, {
  required int remainingBytes,
}) {
  final legacyStem = candidate.legacyAccountStem;
  if (legacyStem == null) return (digest: null, bytesRead: 0);
  final candidates = <String>{};
  var bytesRead = 0;
  bool canRead(File file, int roleLimit) {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final length = file.lengthSync();
    return length >= 0 &&
        length <= roleLimit &&
        bytesRead + length <= remainingBytes;
  }

  final ownerStem = accountStorageStem(legacyStem);
  final owner = File(
    '${root.path}/legacy_bucket_owner_${candidate.oldProvider}_$ownerStem.json',
  );
  if (canRead(owner, 16 * 1024)) {
    final length = owner.lengthSync();
    final ownerDigest =
        _plannedOwnerAccountDigest(owner, candidate.oldProvider);
    bytesRead += length;
    if (ownerDigest != null) candidates.add(ownerDigest);
  }

  final snapshot = File(
    '${root.path}/${candidate.oldProvider}_$legacyStem.json',
  );
  try {
    if (canRead(snapshot, 2 * 1024 * 1024)) {
      final length = snapshot.lengthSync();
      final decoded = jsonDecode(snapshot.readAsStringSync());
      bytesRead += length;
      final account = decoded is Map ? decoded['account'] : null;
      if (decoded is Map &&
          decoded['provider'] == candidate.oldProvider &&
          account is String &&
          _rawStorageStem(account) == legacyStem) {
        candidates.add(accountIdentityDigest(account));
      }
    }
  } catch (_) {
    return (digest: null, bytesRead: bytesRead);
  }

  final history = File(
    '${root.path}/history_${candidate.oldProvider}_$legacyStem.jsonl',
  );
  try {
    if (canRead(history, 5 * 1024 * 1024)) {
      final length = history.lengthSync();
      final accounts = <String>{};
      for (final line in history.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        final account = decoded is Map ? decoded['account'] : null;
        if (decoded is! Map ||
            decoded['provider'] != candidate.oldProvider ||
            account is! String ||
            _rawStorageStem(account) != legacyStem) {
          return (digest: null, bytesRead: bytesRead + length);
        }
        accounts.add(account);
      }
      bytesRead += length;
      if (accounts.length == 1) {
        candidates.add(accountIdentityDigest(accounts.single));
      } else if (accounts.length > 1) {
        return (digest: null, bytesRead: bytesRead);
      }
    }
  } catch (_) {
    return (digest: null, bytesRead: bytesRead);
  }
  return (
    digest: candidates.length == 1 ? candidates.single : null,
    bytesRead: bytesRead,
  );
}

bool _validBucketRecord(Map<dynamic, dynamic> record) {
  HeadroomBucket bucket;
  try {
    bucket = HeadroomBucket.fromJson(record.cast<String, dynamic>());
  } catch (_) {
    return false;
  }
  const maxSamples = 0x7fffffff;
  if (bucket.start < 0 ||
      bucket.start % kBucketSpan != 0 ||
      bucket.count <= 0 ||
      bucket.count > maxSamples ||
      bucket.exhausted < 0 ||
      bucket.exhausted > bucket.count ||
      !bucket.sum.isFinite ||
      !bucket.sumSq.isFinite ||
      bucket.sum < 0 ||
      bucket.sumSq < 0 ||
      bucket.hist.length != kHistBins ||
      !bucket.min.isFinite ||
      !bucket.max.isFinite ||
      bucket.min < 0 ||
      bucket.max > 100 ||
      bucket.min > bucket.max) {
    return false;
  }
  var histCount = 0;
  var minimumSum = 0.0;
  var maximumSum = 0.0;
  var minimumSumSq = 0.0;
  var maximumSumSq = 0.0;
  const binWidth = 100 / kHistBins;
  for (var index = 0; index < bucket.hist.length; index++) {
    final binCount = bucket.hist[index];
    if (binCount < 0 || binCount > maxSamples - histCount) return false;
    histCount += binCount;
    final lower = index * binWidth;
    final upper = index == kHistBins - 1 ? 100.0 : (index + 1) * binWidth;
    minimumSum += binCount * lower;
    maximumSum += binCount * upper;
    minimumSumSq += binCount * lower * lower;
    maximumSumSq += binCount * upper * upper;
  }
  if (histCount != bucket.count || bucket.exhausted > bucket.hist.first) {
    return false;
  }
  if (!_migrationInRange(bucket.sum, minimumSum, maximumSum) ||
      !_migrationInRange(bucket.sumSq, minimumSumSq, maximumSumSq) ||
      !_migrationInRange(bucket.sum, 0, bucket.count * 100.0) ||
      !_migrationInRange(bucket.sumSq, 0, bucket.count * 10000.0) ||
      !_migrationInRange(bucket.sumSq, 0, 100 * bucket.sum)) {
    return false;
  }
  if (bucket.count == 1) {
    if (!_migrationNear(bucket.min, bucket.max) ||
        !_migrationNear(bucket.sum, bucket.min) ||
        !_migrationNear(bucket.sumSq, bucket.min * bucket.min)) {
      return false;
    }
  } else {
    final minimumExtremaSum = bucket.max + (bucket.count - 1) * bucket.min;
    final maximumExtremaSum = bucket.min + (bucket.count - 1) * bucket.max;
    final minimumExtremaSumSq =
        bucket.max * bucket.max + (bucket.count - 1) * bucket.min * bucket.min;
    final maximumExtremaSumSq =
        bucket.min * bucket.min + (bucket.count - 1) * bucket.max * bucket.max;
    if (!_migrationInRange(
          bucket.sum,
          minimumExtremaSum,
          maximumExtremaSum,
        ) ||
        !_migrationInRange(
          bucket.sumSq,
          minimumExtremaSumSq,
          maximumExtremaSumSq,
        )) {
      return false;
    }
  }
  final minimumMoment = bucket.sum * bucket.sum / bucket.count;
  return _migrationInRange(
        bucket.sum,
        bucket.count * bucket.min,
        bucket.count * bucket.max,
      ) &&
      _migrationInRange(
        bucket.sumSq,
        bucket.count * bucket.min * bucket.min,
        bucket.count * bucket.max * bucket.max,
      ) &&
      bucket.sumSq + _migrationTolerance([bucket.sumSq, minimumMoment]) >=
          minimumMoment;
}

double _migrationTolerance(Iterable<double> values) {
  var scale = 1.0;
  for (final value in values) {
    scale = max(scale, value.abs());
  }
  return 0.0000001 + scale * 0.000000000001;
}

bool _migrationNear(double left, double right) =>
    (left - right).abs() <= _migrationTolerance([left, right]);

bool _migrationInRange(double value, double lower, double upper) {
  final tolerance = _migrationTolerance([value, lower, upper]);
  return value >= lower - tolerance && value <= upper + tolerance;
}

bool _validAnalyticsCheckpoint(Object? raw, {required bool history}) {
  if (raw == null) return true;
  if (raw is! Map) return false;
  final digest = raw['digest'];
  final count = raw['count'];
  if (digest is! String ||
      !RegExp(_digestPattern).hasMatch(digest) ||
      count is! int ||
      count < 0) {
    return false;
  }
  if (history) {
    final rowDigests = raw['row_digests'];
    if (rowDigests is! List ||
        rowDigests.length != count ||
        rowDigests.length > _historyRecordLimit ||
        rowDigests.any((value) =>
            value is! String || !RegExp(_digestPattern).hasMatch(value))) {
      return false;
    }
    return sha256
            .convert(utf8.encode(rowDigests.cast<String>().join('\n')))
            .toString() ==
        digest;
  }
  final buckets = raw['buckets'];
  if (buckets is! List ||
      buckets.length != count ||
      buckets.length > _bucketRecordLimit ||
      buckets.any((entry) => entry is! Map || !_validBucketRecord(entry))) {
    return false;
  }
  return sha256.convert(utf8.encode(jsonEncode(buckets))).toString() == digest;
}

int _atomicMigrationWrite(
  File target,
  List<int> bytes,
  Directory root, {
  String? expectedTargetDigest,
  required int maxVerificationBytes,
}) {
  if (!_safeMigrationRoot(root) ||
      target.parent.absolute.path != root.absolute.path) {
    throw FileSystemException('unsafe provider migration target', target.path);
  }
  final targetType = FileSystemEntity.typeSync(target.path, followLinks: false);
  if (targetType == FileSystemEntityType.file) {
    if (expectedTargetDigest == null) {
      throw FileSystemException(
          'provider migration target changed', target.path);
    }
  } else if (targetType != FileSystemEntityType.notFound ||
      expectedTargetDigest != null) {
    throw FileSystemException('unsafe provider migration target', target.path);
  }
  final random = Random.secure();
  final suffix = List<int>.generate(8, (_) => random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  final temporaryId = sha256
      .convert(utf8.encode('${target.absolute.path}\u0000$pid\u0000$suffix'))
      .toString()
      .substring(0, 32);
  final temporary = File(
    '${target.parent.path}/.provider-migration-$temporaryId.tmp',
  );
  var verificationBytes = 0;
  try {
    temporary.createSync(exclusive: true);
    restrictOwnerOnlyFile(temporary);
    temporary.writeAsBytesSync(bytes, flush: true);
    _migrationObserverForTesting?.call('target_temp_written');
    final currentType =
        FileSystemEntity.typeSync(target.path, followLinks: false);
    if (expectedTargetDigest == null) {
      if (currentType != FileSystemEntityType.notFound) {
        throw FileSystemException(
          'provider migration target appeared',
          target.path,
        );
      }
    } else {
      if (currentType != FileSystemEntityType.file) {
        throw FileSystemException(
            'provider migration target changed', target.path);
      }
      final currentLength = target.lengthSync();
      if (currentLength < 0 || currentLength > maxVerificationBytes) {
        throw FileSystemException(
            'provider migration target changed', target.path);
      }
      final currentBytes = target.readAsBytesSync();
      verificationBytes = currentBytes.length;
      if (sha256.convert(currentBytes).toString() != expectedTargetDigest) {
        throw FileSystemException(
            'provider migration target changed', target.path);
      }
    }
    temporary.renameSync(target.path);
    _migrationObserverForTesting?.call('target_renamed');
    return verificationBytes;
  } finally {
    try {
      if (temporary.existsSync()) temporary.deleteSync();
    } catch (_) {}
  }
}

Map<String, dynamic> _aliasReceiptPayload({
  required String oldProvider,
  required String newProvider,
  required String state,
  required int scannedEntries,
  required bool truncated,
  required bool globalUncertainty,
  required List<Map<String, dynamic>> records,
}) =>
    {
      'schema': providerIdMigrationReceiptSchema,
      'old_provider': oldProvider,
      'new_provider': newProvider,
      'state': state,
      'observed_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'scanned_entries': scannedEntries,
      'truncated': truncated,
      'global_uncertainty': globalUncertainty,
      'records': records,
    };

String _receiptFileName(String oldProvider, String newProvider) =>
    'provider_id_migration_${oldProvider}_to_$newProvider.json';

Map<String, dynamic>? _readAliasReceipt(
  Directory root,
  String oldProvider,
  String newProvider,
) {
  final file = File(
    '${root.path}/${_receiptFileName(oldProvider, newProvider)}',
  );
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.lengthSync() > _maxReceiptBytes) {
      return null;
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map ||
        decoded['schema'] != providerIdMigrationReceiptSchema ||
        decoded['old_provider'] != oldProvider ||
        decoded['new_provider'] != newProvider ||
        !const {'complete', 'partial'}.contains(decoded['state']) ||
        decoded['observed_at'] is! int ||
        (decoded['observed_at'] as int) <= 0 ||
        decoded['scanned_entries'] is! int ||
        (decoded['scanned_entries'] as int) < 0 ||
        (decoded['scanned_entries'] as int) > 4096 ||
        decoded['truncated'] is! bool ||
        decoded['global_uncertainty'] is! bool ||
        decoded['records'] is! List ||
        (decoded['records'] as List).length > 512 ||
        !(decoded['records'] as List).every(_validReceiptRecord) ||
        {
              for (final record in decoded['records'] as List)
                if (record is Map) record['record_id'],
            }.length !=
            (decoded['records'] as List).length) {
      return null;
    }
    final state = decoded['state'];
    final truncated = decoded['truncated'] as bool;
    final globalUncertainty = decoded['global_uncertainty'] as bool;
    final records = decoded['records'] as List;
    final hasNonCurrent = records.any(
      (record) =>
          record is Map &&
          record['state'] != 'carried' &&
          record['state'] != 'current',
    );
    if ((state == 'complete' &&
            (truncated || globalUncertainty || hasNonCurrent)) ||
        (truncated && (state != 'partial' || !globalUncertainty)) ||
        (globalUncertainty && state != 'partial') ||
        (state == 'partial' && !globalUncertainty && !hasNonCurrent)) {
      return null;
    }
    return decoded.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

bool _validReceiptRecord(Object? raw) {
  if (raw is! Map) return false;
  final record = raw.cast<dynamic, dynamic>();
  final id = record['record_id'];
  final role = record['role'];
  final tier = record['tier'];
  final scope = record['scope'];
  final state = record['state'];
  const roleTiers = {
    'snapshot': 'quota',
    'drift': 'quota',
    'history': 'history',
    'buckets': 'buckets',
    'analytics_marker': 'analytics',
    'bucket_owner': 'buckets',
  };
  if (id is! String ||
      !RegExp(_digestPattern).hasMatch(id) ||
      role is! String ||
      roleTiers[role] != tier ||
      !const {'provider', 'account', 'unresolved'}.contains(scope) ||
      !const {'carried', 'current', 'quarantined', 'invalid', 'prepared'}
          .contains(state)) {
    return false;
  }
  final accountDigest = record['account_digest'];
  if ((scope == 'account' &&
          (accountDigest is! String ||
              !RegExp(_digestPattern).hasMatch(accountDigest))) ||
      (scope != 'account' && accountDigest != null)) {
    return false;
  }
  final bytes = record['bytes'];
  if (bytes != null &&
      (bytes is! int || bytes < 0 || bytes > 5 * 1024 * 1024)) {
    return false;
  }
  bool validOptionalDigest(String key) {
    final value = record[key];
    return value == null ||
        (value is String && RegExp(_digestPattern).hasMatch(value));
  }

  if (!validOptionalDigest('baseline_sha256') ||
      !validOptionalDigest('source_sha256') ||
      !validOptionalDigest('target_sha256') ||
      !validOptionalDigest('intended_sha256')) {
    return false;
  }
  final targetAbsent = record['target_absent'];
  if (targetAbsent != null && targetAbsent != true) return false;
  if (targetAbsent == true && record['target_sha256'] != null) return false;
  if (state == 'carried' || state == 'current') {
    if (record['baseline_sha256'] is! String ||
        record['source_sha256'] is! String ||
        (record['target_sha256'] is! String && targetAbsent != true)) {
      return false;
    }
    if (record['baseline_sha256'] != record['source_sha256']) return false;
  }
  if (state == 'quarantined' &&
      (record['source_sha256'] is! String ||
          (record['target_sha256'] is! String && targetAbsent != true))) {
    return false;
  }
  if (state == 'invalid' && record['baseline_sha256'] != null) return false;
  if (state == 'prepared' &&
      (record['source_sha256'] is! String ||
          record['intended_sha256'] != record['source_sha256'] ||
          (record['target_sha256'] is! String && targetAbsent != true) ||
          (record['baseline_sha256'] == null && targetAbsent != true) ||
          (record['baseline_sha256'] != null &&
              record['target_sha256'] != record['baseline_sha256']))) {
    return false;
  }
  if (state != 'prepared' && record['intended_sha256'] != null) return false;
  final affectedTiers = record['affected_tiers'];
  if (role == 'analytics_marker' &&
      (state == 'invalid' || state == 'quarantined' || state == 'prepared')) {
    if (affectedTiers is! List ||
        affectedTiers.isEmpty ||
        affectedTiers.length > 2 ||
        affectedTiers.any(
          (value) => !const {'history', 'buckets'}.contains(value),
        ) ||
        affectedTiers.toSet().length != affectedTiers.length) {
      return false;
    }
  } else if (affectedTiers != null) {
    return false;
  }
  return true;
}

Map<String, Map<String, dynamic>> _receiptRecordsById(
  Map<String, dynamic>? receipt,
) {
  final byId = <String, Map<String, dynamic>>{};
  final records = receipt?['records'];
  if (records is! List) return byId;
  for (final raw in records) {
    if (raw is! Map) continue;
    final record = raw.cast<String, dynamic>();
    final id = record['record_id'];
    if (id is String && RegExp(_digestPattern).hasMatch(id)) {
      byId[id] = record;
    }
  }
  return byId;
}

bool _writeAliasReceipt(Directory root, Map<String, dynamic> receipt) {
  try {
    final oldProvider = receipt['old_provider'];
    final newProvider = receipt['new_provider'];
    if (oldProvider is! String || newProvider is! String) return false;
    final bytes = utf8.encode(jsonEncode(receipt));
    if (bytes.length > _maxReceiptBytes) return false;
    final target = File(
      '${root.path}/${_receiptFileName(oldProvider, newProvider)}',
    );
    final existingType =
        FileSystemEntity.typeSync(target.path, followLinks: false);
    if (existingType != FileSystemEntityType.notFound &&
        existingType != FileSystemEntityType.file) {
      return false;
    }
    final random = Random.secure();
    final suffix = List<int>.generate(8, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final temporary = File('${target.path}.$pid.$suffix.tmp');
    try {
      temporary.createSync(exclusive: true);
      restrictOwnerOnlyFile(temporary);
      temporary.writeAsBytesSync(bytes, flush: true);
      final records = receipt['records'];
      final prepared = records is List &&
          records
              .any((record) => record is Map && record['state'] == 'prepared');
      _migrationObserverForTesting?.call(
        prepared
            ? 'prepared_receipt_temp_written'
            : 'committed_receipt_temp_written',
      );
      temporary.renameSync(target.path);
      return true;
    } finally {
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (_) {}
    }
  } catch (_) {
    return false;
  }
}
