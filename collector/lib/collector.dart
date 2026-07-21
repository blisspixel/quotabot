import 'dart:async';
import 'dart:io';

import 'analysis.dart';
import 'cache.dart';
import 'demo.dart';
import 'drift.dart';
import 'local_hardware.dart';
import 'manual_quota.dart';
import 'models.dart';
import 'provider_adapters.dart';
import 'runtime_audit.dart';
import 'util.dart';
import 'verification.dart';

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
export 'decision.dart';
export 'insights.dart';
export 'leases.dart';
export 'litellm_metrics.dart';
export 'local_hardware.dart';
export 'manual_quota.dart';
export 'model_catalog.dart';
export 'models.dart';
export 'palette.dart';
export 'plan_evidence.dart';
export 'profiles.dart';
export 'provider_adapters.dart';
export 'provider_filters.dart';
export 'provider_ids.dart';
export 'registry.dart';
export 'report.dart';
export 'routing_context.dart';
export 'runtime_audit.dart';
export 'schema_contracts.dart';
export 'simulation.dart';
export 'top_refresh.dart';
export 'verification.dart';

/// Whether the one-time temp-file sweep has run this process.
bool _sweptTemp = false;

/// Hard deadline for one adapter's full collect, beyond its own per-request
/// HTTP timeouts. A hung provider (accepted TCP, no bytes; stacked retries)
/// degrades to a truthful timeout error for that provider instead of wedging
/// the whole fleet, the desktop refresh loop, and MCP snapshot calls.
const Duration kAdapterDeadline = Duration(seconds: 30);

class CollectedQuotaSnapshot {
  final List<ProviderQuota> providers;
  final RuntimeAccessReport runtimeAccess;

  const CollectedQuotaSnapshot({
    required this.providers,
    required this.runtimeAccess,
  });
}

const quotabotDriftRecoveryV1SchemaId = 'quotabot.drift-recovery.v1';

/// Result of one explicit, targeted live verification and drift-baseline
/// recovery attempt. It contains quota metadata only.
class ProviderDriftRecoveryReport {
  final int generatedAt;
  final String provider;
  final String displayName;
  final String account;
  final bool recovered;
  final String status;
  final String detail;
  final ProviderVerification? verification;
  final RuntimeAccessReport? runtimeAccess;

  const ProviderDriftRecoveryReport({
    required this.generatedAt,
    required this.provider,
    required this.displayName,
    required this.account,
    required this.recovered,
    required this.status,
    required this.detail,
    this.verification,
    this.runtimeAccess,
  });

  Map<String, dynamic> toJson() => {
        'schema': quotabotDriftRecoveryV1SchemaId,
        'generated_at': generatedAt,
        'provider': provider,
        'display_name': displayName,
        'account': account,
        'recovered': recovered,
        'status': status,
        'detail': detail,
        if (verification != null) 'verification': verification!.toJson(),
        if (runtimeAccess != null) 'runtime_access': runtimeAccess!.toJson(),
      };
}

ProviderDriftRecoveryReport _driftRecoveryFailure({
  required int generatedAt,
  required String provider,
  required String displayName,
  required String account,
  required String status,
  required String detail,
  ProviderVerification? verification,
  RuntimeAccessReport? runtimeAccess,
}) =>
    ProviderDriftRecoveryReport(
      generatedAt: generatedAt,
      provider: provider,
      displayName: displayName,
      account: account,
      recovered: false,
      status: status,
      detail: detail,
      verification: verification,
      runtimeAccess: runtimeAccess,
    );

ProviderQuota? _driftRecoveryBaseline(
  ProviderAdapterRegistration entry,
  String account,
) =>
    entry.accountScopedCache
        ? loadAccountSnapshotForAdmission(entry.id, account)
        : loadSnapshotForAdmission(entry.id);

/// Performs the only supported explicit drift-baseline recovery flow.
///
/// A recoverable exact baseline is required before any provider call. The
/// adapter is then invoked once under the ordinary collection deadline. One
/// exact provider/account row must pass the registered source contract, the
/// full targeted verification report, and the stricter cache trust boundary.
/// Only then may [recoverProviderDriftBaseline] replace that identity's local
/// baseline. No model endpoint is called by this flow.
Future<ProviderDriftRecoveryReport> verifyAndRecoverProviderDriftBaseline({
  required String provider,
  required String account,
  ProviderAdapterRegistration? registration,
  int? observedAt,
  int? observedAtMicros,
  Duration deadline = kAdapterDeadline,
}) async {
  final resolved = providerAdapterById(provider);
  final entry = registration ?? resolved;
  final wallClockAtStart = nowEpoch();
  final inspectedAt = observedAt ?? wallClockAtStart;
  final observationTimeIsSafe = observedAt == null ||
      (observedAt >= wallClockAtStart - kQuotaEvidenceClockSkewSeconds &&
          observedAt <= wallClockAtStart + kQuotaEvidenceClockSkewSeconds);
  final cleanProvider = stripTerminalControl(provider.trim().toLowerCase());
  final targetProvider = entry?.id ??
      (cleanProvider.length <= 64
          ? cleanProvider
          : cleanProvider.substring(0, 64));
  final targetDisplayName = entry?.displayName ?? targetProvider;
  final accountIsSafe = account.trim().isNotEmpty &&
      account.length <= 512 &&
      stripTerminalControl(account) == account;
  final reportAccount = accountIsSafe ? account : 'invalid';
  if (!observationTimeIsSafe) {
    return _driftRecoveryFailure(
      generatedAt: wallClockAtStart,
      provider: targetProvider,
      displayName: targetDisplayName,
      account: reportAccount,
      status: 'invalid_live_evidence',
      detail: 'recovery observation time is outside the real-clock trust '
          'boundary',
    );
  }
  if (entry == null ||
      resolved == null ||
      resolved.id != entry.id ||
      !entry.cached ||
      entry.localRuntime ||
      !accountIsSafe ||
      deadline <= Duration.zero) {
    return _driftRecoveryFailure(
      generatedAt: inspectedAt,
      provider: targetProvider,
      displayName: targetDisplayName,
      account: reportAccount,
      status: 'unsupported_target',
      detail:
          'recovery requires one registered cached provider and exact account',
    );
  }

  final baseline = _driftRecoveryBaseline(entry, account);
  if (baseline == null ||
      baseline.provider != entry.id ||
      baseline.account != account) {
    return _driftRecoveryFailure(
      generatedAt: inspectedAt,
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: 'baseline_not_found',
      detail: 'no recoverable baseline exists for the exact provider account',
    );
  }
  if (!isLegacySuspectQuotaEvidence(baseline) &&
      attachProviderDriftObservation(baseline, now: inspectedAt).driftReason ==
          null) {
    return _driftRecoveryFailure(
      generatedAt: inspectedAt,
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: 'no_active_drift',
      detail: 'the exact provider account has no active drift quarantine',
    );
  }

  final generationMicros =
      observedAtMicros ?? DateTime.now().microsecondsSinceEpoch;
  RuntimeAccessReport attemptedRuntimeAccess(int generatedAt) =>
      buildRuntimeAccessReport(
        generatedAt: generatedAt,
        includeReads: true,
        includeNetwork: true,
        observedProviderIds: {entry.id},
        collectionExecuted: true,
      );
  late List<ProviderQuota> collected;
  try {
    collected = await entry.collect().timeout(deadline);
  } on TimeoutException {
    final failedAt = observedAt ?? nowEpoch();
    return _driftRecoveryFailure(
      generatedAt: failedAt,
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: 'live_read_failed',
      detail: 'provider metadata read timed out before verification',
      runtimeAccess: attemptedRuntimeAccess(failedAt),
    );
  } catch (_) {
    final failedAt = observedAt ?? nowEpoch();
    return _driftRecoveryFailure(
      generatedAt: failedAt,
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: 'live_read_failed',
      detail: 'provider metadata read failed before verification',
      runtimeAccess: attemptedRuntimeAccess(failedAt),
    );
  }

  final verifiedAt = observedAt ?? nowEpoch();
  final runtimeAccess = attemptedRuntimeAccess(verifiedAt);
  final accountMatches = [
    for (final quota in collected)
      if (quota.account == account) quota,
  ];
  if (accountMatches.isEmpty) {
    return _driftRecoveryFailure(
      generatedAt: observedAt ?? nowEpoch(),
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: 'target_not_returned',
      detail: 'the live provider read did not return the exact account',
      runtimeAccess: runtimeAccess,
    );
  }
  if (accountMatches.length != 1) {
    return _driftRecoveryFailure(
      generatedAt: observedAt ?? nowEpoch(),
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: 'ambiguous_live_read',
      detail:
          'the live provider read returned the exact account more than once',
      runtimeAccess: runtimeAccess,
    );
  }

  final rawFresh = flagStalePassiveRolloverEvidence(
    accountMatches.single,
    verifiedAt,
  );
  final fresh = sanitizeProviderQuota(rawFresh);
  final verificationReport = buildVerificationReport(
    [fresh],
    verifiedAt,
    os: Platform.operatingSystem,
    filtered: true,
    requireLive: true,
    registry: [entry],
    runtimeAccess: runtimeAccess,
  );
  final verification = verificationReport.providers.single;
  final sourceViolation = registeredSourceClassViolation(
    rawFresh,
    entry,
    allowManual: false,
  );
  if (rawFresh.provider != entry.id ||
      rawFresh.account != account ||
      sourceViolation != null ||
      !isTrustedQuotaEvidenceAt(rawFresh, verifiedAt) ||
      !isTrustedQuotaEvidenceAt(fresh, verifiedAt) ||
      !verificationReport.passed ||
      !verification.liveReadSucceeded) {
    return _driftRecoveryFailure(
      generatedAt: verifiedAt,
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: 'live_verification_failed',
      detail: 'fresh provider evidence did not pass every recovery gate',
      verification: verification,
      runtimeAccess: runtimeAccess,
    );
  }

  final recovery = recoverProviderDriftBaseline(
    fresh,
    observedAt: verifiedAt,
    observedAtMicros: generationMicros,
  );
  if (!recovery.recovered) {
    return _driftRecoveryFailure(
      generatedAt: verifiedAt,
      provider: entry.id,
      displayName: entry.displayName,
      account: account,
      status: recovery.status,
      detail: recovery.detail,
      verification: verification,
      runtimeAccess: runtimeAccess,
    );
  }
  return ProviderDriftRecoveryReport(
    generatedAt: verifiedAt,
    provider: entry.id,
    displayName: entry.displayName,
    account: account,
    recovered: true,
    status: recovery.status,
    detail: recovery.detail,
    verification: verification,
    runtimeAccess: runtimeAccess,
  );
}

/// A single fail-soft error quota for [entry], shaped like a real read so
/// verify, routing, and display treat it consistently. Used for both a deadline
/// timeout and an unexpected throw in a provider's pipeline.
ProviderQuota _adapterErrorQuota(
  ProviderAdapterRegistration entry,
  String error,
) =>
    ProviderQuota(
      provider: entry.id,
      displayName: entry.displayName,
      account: 'unknown',
      asOf: nowEpoch(),
      ok: false,
      error: error,
      kind: entry.adapterClass.quotaKind,
      sourceClass: entry.sourceClasses.first,
    );

Future<List<ProviderQuota>> _listWithDeadline(
  ProviderAdapterRegistration entry,
) =>
    entry.collect().timeout(
          kAdapterDeadline,
          onTimeout: () => [
            _adapterErrorQuota(
              entry,
              'timed out after ${kAdapterDeadline.inSeconds}s',
            ),
          ],
        );

/// Runs every provider adapter concurrently and returns their snapshots.
/// Shared by the CLI (bin/collect.dart) and the desktop app.
Future<List<ProviderQuota>> collectAll() => _collectAllProviders();

/// Runs a normal collection and also returns the audited runtime access surface
/// for the adapters that were invoked. The access records intentionally come
/// from the same static map as `quotabot explain`; the observation is which
/// adapters participated in this run.
Future<CollectedQuotaSnapshot> collectAllWithRuntimeAccess() async {
  if (Platform.environment['QUOTABOT_DEMO'] == '1') {
    final asOf = nowEpoch();
    return CollectedQuotaSnapshot(
      providers: demoProviders(asOf),
      runtimeAccess: buildRuntimeAccessReport(
        generatedAt: asOf,
        includeReads: true,
        includeNetwork: true,
        providers: const [],
      ),
    );
  }
  final results = await _collectAllProviders(skipDemoCheck: true);
  return CollectedQuotaSnapshot(
    providers: results,
    runtimeAccess: buildRuntimeAccessReport(
      generatedAt: nowEpoch(),
      includeReads: true,
      includeNetwork: true,
      observedProviderIds: {
        for (final entry in kProviderAdapterRegistry) entry.id,
      },
      collectionExecuted: true,
    ),
  );
}

Future<List<ProviderQuota>> _collectAllProviders({
  bool skipDemoCheck = false,
}) async {
  // Demo mode: synthetic data for previews and screenshots. Returns before any
  // adapter call or analytics write, so it touches no account and no history.
  if (!skipDemoCheck && Platform.environment['QUOTABOT_DEMO'] == '1') {
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
  final retained = [
    for (final group in collected) ...group,
    ...manual,
  ].where(retainCollectedProviderQuota).toList();
  LocalHardwareInfo? hardware;
  if (retained.any((quota) =>
      quota.isLocal &&
      quota.ok &&
      quota.models.any((model) => !model.cloudOffloaded))) {
    try {
      hardware = await readLocalHardware();
    } catch (_) {
      // Hardware fit is advisory. A failed metadata probe must never hide an
      // otherwise healthy local runtime or delay normal routing.
    }
  }
  final results = [
    for (final quota in retained)
      sanitizeProviderQuota(
        quota.isLocal && hardware != null
            ? quota.withLocalHardware(
                hardware,
                detail: _localHardwareDetail(hardware),
              )
            : quota,
      ),
  ];
  _recordAnalytics(results);
  return results;
}

String _localHardwareDetail(LocalHardwareInfo hardware) {
  final parts = <String>[];
  final systemTotal = hardware.systemMemoryTotalBytes;
  final systemAvailable = hardware.systemMemoryAvailableBytes;
  if (systemTotal != null) {
    parts.add(systemAvailable == null
        ? '${formatCompactBytes(systemTotal)} RAM total'
        : '${formatCompactBytes(systemAvailable)} of '
            '${formatCompactBytes(systemTotal)} RAM available');
  }
  final gpuTotal = hardware.gpuMemoryTotalBytes;
  final gpuAvailable = hardware.gpuMemoryAvailableBytes;
  if (gpuTotal != null) {
    parts.add(gpuAvailable == null
        ? '${formatCompactBytes(gpuTotal)} largest GPU'
        : '${formatCompactBytes(gpuAvailable)} of '
            '${formatCompactBytes(gpuTotal)} GPU free');
  }
  return parts.join(' . ');
}

/// Folds the current binding headroom of each live subscription into the
/// long-term analytics buckets. Local runtimes are skipped (their headroom is a
/// constant), and so are providers with no usable windows.
void _recordAnalytics(List<ProviderQuota> results) {
  final now = nowEpoch();
  final seen = <String>{};
  for (final q in results) {
    if (q.isLocal || !isTrustedQuotaEvidenceAt(q, now)) continue;
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
  try {
    // This generation identifies when collection began, not when a provider
    // eventually returned. Otherwise an earlier slow request can finish after a
    // later fast request and overwrite the genuinely newer observation.
    final evidenceGenerationMicros = DateTime.now().microsecondsSinceEpoch;
    final now = nowEpoch();
    final collected = await _listWithDeadline(entry);
    final results = <ProviderQuota>[];
    for (final q in collected) {
      // Passive-local reads whose window predates its own reset are stale, not a
      // fresh full balance; mark them so before admission, so the fabricated
      // rolled-over headroom never enters the trusted cache or routing.
      results.add(
        admitRegisteredProviderObservation(
          entry,
          flagStalePassiveRolloverEvidence(q, now),
          evidenceGenerationMicros: evidenceGenerationMicros,
        ),
      );
    }
    if (entry.accountScopedCache) {
      results.addAll(currentAccountFallbacks(
        liveResults: results,
        cachedSnapshots: loadAccountSnapshots(entry.id),
        currentAccounts: entry.currentAccounts!(),
      ));
    }
    return results;
  } catch (_) {
    // Per-provider isolation: an unexpected throw anywhere in this provider's
    // collect, admission, or account-fallback pipeline must not fail the whole
    // Future.wait fleet read. Adapters already return error quotas rather than
    // throwing, so this is defense in depth against a future regression.
    return [_adapterErrorQuota(entry, 'read failed')];
  }
}

/// Applies one adapter registration's identity and provenance contract before
/// evidence can touch cache, history, analytics, or routing.
///
/// An adapter that emits another provider id is represented under the expected
/// registration identity. This makes the failure visible without allowing the
/// untrusted id to read or poison an unrelated provider's cache.
ProviderQuota admitRegisteredProviderObservation(
  ProviderAdapterRegistration entry,
  ProviderQuota quota, {
  required int evidenceGenerationMicros,
  int? observedAt,
}) {
  final violation = registeredSourceClassViolation(
    quota,
    entry,
    allowManual: false,
  );
  final rejectionReason =
      violation == null ? null : 'invalid provider source class: $violation';
  final evidence = quota.provider == entry.id
      ? quota
      : _expectedAdapterIdentityFailure(entry, quota, observedAt ?? nowEpoch());
  if (entry.cached) {
    return _cacheResult(
      evidence,
      evidenceGenerationMicros: evidenceGenerationMicros,
      rejectionReason: rejectionReason,
      observedAt: observedAt,
    );
  }
  if (rejectionReason == null) return evidence;
  return quarantineUnusableQuotaEvidence(
    evidence,
    rejectionReason,
    observedAt ?? nowEpoch(),
  );
}

ProviderQuota _expectedAdapterIdentityFailure(
  ProviderAdapterRegistration entry,
  ProviderQuota emitted,
  int observedAt,
) {
  final account = entry.accountScopedCache &&
          entry.currentAccounts!().contains(emitted.account)
      ? emitted.account
      : 'unknown';
  return ProviderQuota(
    provider: entry.id,
    displayName: entry.displayName,
    account: account,
    asOf: emitted.asOf > 0 ? emitted.asOf : observedAt,
    ok: false,
    error: 'adapter returned a noncanonical provider identity',
    kind: entry.adapterClass.quotaKind,
    sourceClass: entry.sourceClasses.first,
  );
}

ProviderQuota _cacheResult(
  ProviderQuota result, {
  required int evidenceGenerationMicros,
  String? rejectionReason,
  int? observedAt,
}) {
  if (rejectionReason != null ||
      isTrustedQuotaEvidence(result) ||
      unusableQuotaEvidenceDriftReason(result) != null) {
    // Only admitted fresh evidence may replace last-known-good cache or enter
    // burn history. A drifted read returns the prior trusted snapshot stale and
    // records its diagnostic separately without storing rejected quota values.
    return admitAndCacheQuotaEvidence(
      result,
      observedAt: observedAt ?? nowEpoch(),
      observedAtMicros: evidenceGenerationMicros,
      rejectionReason: rejectionReason,
    );
  }
  // Read failed, returned no windows, or supplied already-stale/untrusted
  // evidence. Serve only a trusted last-known snapshot when one exists.
  final cached = _loadCachedSnapshot(result);
  if (cached != null && cached.hasWindows) {
    final entry = providerAdapterById(result.provider);
    if (entry?.accountScopedCache == true &&
        !entry!.currentAccounts!().contains(cached.account)) {
      return result;
    }
    final withDrift = attachProviderDriftObservation(cached);
    if (withDrift.driftReason != null) return withDrift;
    return cached.asStale(result.error ?? 'cached', metadataFrom: result);
  }
  final legacy = _loadCachedAdmissionBaseline(result);
  if (legacy != null && isLegacySuspectQuotaEvidence(legacy)) {
    final entry = providerAdapterById(result.provider);
    if (entry?.accountScopedCache == true &&
        !entry!.currentAccounts!().contains(legacy.account)) {
      return result;
    }
    return quarantineLegacyQuotaEvidence(
      legacy,
      observedAt: nowEpoch(),
      metadataFrom: result,
    );
  }
  return result;
}

/// Keeps actionable provenance failures visible while hiding ordinary offline
/// local runtimes from the product surface.
bool retainCollectedProviderQuota(ProviderQuota quota) =>
    !quota.isLocal || quota.ok || quota.sourceClassViolation != null;

/// Loads the last-known snapshot for [result]'s provider and account.
/// Account-scoped providers are loaded by account rather than from the generic
/// provider file, because one machine can hold several provider logins.
ProviderQuota? _loadCachedSnapshot(ProviderQuota result) =>
    providerAdapterById(result.provider)?.accountScopedCache == true
        ? loadAccountSnapshot(result.provider, result.account)
        : loadSnapshot(result.provider);

/// Admission-only loader that preserves legacy suspect cache as a quarantine
/// baseline. Its windows never escape [_cacheResult] as usable evidence.
ProviderQuota? _loadCachedAdmissionBaseline(ProviderQuota result) =>
    providerAdapterById(result.provider)?.accountScopedCache == true
        ? loadAccountSnapshotForAdmission(result.provider, result.account)
        : loadSnapshotForAdmission(result.provider);
