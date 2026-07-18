/// Mechanical honesty checks over a collected snapshot, for the 1.0
/// release-candidate provider verification matrix.
///
/// `quotabot verify` answers one question per provider: is this snapshot
/// either reading correctly or failing with a plain, truthful reason? The
/// checks here are the part of that question a machine can answer: bounds,
/// timestamps, staleness honesty, reset plausibility, account identity, and
/// conformance of the emitted snapshot to the frozen `quotabot.v1` contract.
/// Whether the numbers match the provider's own view stays a human step; each
/// record names the provider's own usage surface to cross-check against.
///
/// Pure and side-effect free: callers pass the snapshot, the clock, and the
/// host OS label, so the same report is unit-testable and reproducible.
library;

import 'analysis.dart';
import 'drift.dart';
import 'models.dart';
import 'provider_adapters.dart';
import 'provider_ids.dart';
import 'runtime_audit.dart';
import 'schema_contracts.dart';

const quotabotVerifyV1SchemaId = 'quotabot.verify.v1';

/// Clock skew tolerated before an `as_of` timestamp counts as in the future.
const int kVerifyClockSkewSeconds = 300;

/// A reset further out than this is implausible for a rolling quota window and
/// flags provider drift (the longest real windows are monthly).
const int kVerifyMaxResetHorizonSeconds = 400 * 86400;

/// Where to confirm each provider's numbers by hand, per docs/PROVIDER_CLIS.md.
const kProviderCrossChecks = <String, String>{
  claudeProviderId: 'run /usage in a Claude Code session',
  codexProviderId: 'run /status in a Codex CLI session',
  antigravityProviderId: 'open the Models & Quota panel in the agy TUI',
  grokProviderId: 'run /usage in the Grok TUI, or open console.x.ai',
  cursorProviderId: 'open the usage view in Cursor settings',
  windsurfProviderId: 'open the plan/usage view in Devin Desktop',
  kiroProviderId: 'open the usage view in Kiro',
  ollamaProviderId: 'run "ollama ls" and "ollama ps"',
  lmStudioProviderId: 'run "lms ps" or open the LM Studio server tab',
  lemonadeProviderId: 'open the Lemonade server model list',
};

enum VerifyStatus { pass, fail, info }

/// One named honesty check with a plain-language outcome.
class VerifyCheck {
  final String id;
  final VerifyStatus status;
  final String detail;

  const VerifyCheck(this.id, this.status, this.detail);

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status.name,
        'detail': detail,
      };
}

/// The verification record for one provider account in the snapshot, or for a
/// claimed provider that did not appear in it.
class ProviderVerification {
  final String provider;
  final String displayName;
  final String account;

  /// Stable read state: live, cached, out_of_quota, no_data, error, local,
  /// or undetected (a claimed provider absent from this read). Provider drift
  /// remains `cached` when stale trusted windows exist; a migrated legacy
  /// quarantine with no trusted windows is `error`. The additive [driftReason]
  /// and failed `provider_drift` check distinguish both cases.
  final String state;

  final String? plan;
  final String? source;
  final ProviderSourceClass? sourceClass;
  final int? asOf;
  final int? stalenessSeconds;
  final bool stale;
  final String? driftReason;
  final int? driftObservedAt;
  final List<Map<String, dynamic>> windows;
  final List<VerifyCheck> checks;

  /// The provider's own usage surface to confirm the numbers against.
  final String? crossCheck;

  const ProviderVerification({
    required this.provider,
    required this.displayName,
    required this.account,
    required this.state,
    required this.checks,
    this.plan,
    this.source,
    this.sourceClass,
    this.asOf,
    this.stalenessSeconds,
    this.stale = false,
    this.driftReason,
    this.driftObservedAt,
    this.windows = const [],
    this.crossCheck,
  });

  bool get passed => checks.every((c) => c.status != VerifyStatus.fail);

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'display_name': displayName,
        'account': account,
        'state': state,
        if (plan != null) 'plan': plan,
        if (source != null) 'source': source,
        if (sourceClass != null) 'source_class': sourceClass!.wireName,
        if (asOf != null) 'as_of': asOf,
        if (stalenessSeconds != null) 'staleness_seconds': stalenessSeconds,
        'stale': stale,
        if (driftReason != null) 'drift_reason': driftReason,
        if (driftObservedAt != null) 'drift_observed_at': driftObservedAt,
        if (windows.isNotEmpty) 'windows': windows,
        'passed': passed,
        'checks': checks.map((c) => c.toJson()).toList(),
        if (crossCheck != null) 'cross_check': crossCheck,
      };
}

/// The full verification report: one record per provider account plus
/// fleet-level checks (contract conformance, identity uniqueness, coverage).
class VerificationReport {
  final int generatedAt;
  final String os;
  final List<ProviderVerification> providers;
  final List<VerifyCheck> fleetChecks;
  final RuntimeAccessReport? runtimeAccess;

  const VerificationReport({
    required this.generatedAt,
    required this.os,
    required this.providers,
    required this.fleetChecks,
    this.runtimeAccess,
  });

  bool get passed =>
      providers.every((p) => p.passed) &&
      fleetChecks.every((c) => c.status != VerifyStatus.fail);

  int get failCount =>
      providers.where((p) => !p.passed).length +
      fleetChecks.where((c) => c.status == VerifyStatus.fail).length;

  Map<String, dynamic> toJson() => {
        'schema': quotabotVerifyV1SchemaId,
        'generated_at': generatedAt,
        'os': os,
        'passed': passed,
        'providers': providers.map((p) => p.toJson()).toList(),
        if (runtimeAccess != null) 'runtime_access': runtimeAccess!.toJson(),
        'fleet_checks': fleetChecks.map((c) => c.toJson()).toList(),
      };
}

/// Builds the verification report for [results] as of [now] on host [os].
///
/// [filtered] must be true when a profile or exclusion narrowed [results], so
/// the claimed-provider coverage check reports itself skipped instead of
/// misreading a deliberate filter as a missing provider.
VerificationReport buildVerificationReport(
  List<ProviderQuota> results,
  int now, {
  required String os,
  bool filtered = false,
  List<ProviderAdapterRegistration> registry = kProviderAdapterRegistry,
  RuntimeAccessReport? runtimeAccess,
}) {
  final providers = <ProviderVerification>[
    for (final q in results)
      _verifyProvider(
        q,
        now,
        registry.where((entry) => entry.id == q.provider).firstOrNull,
      ),
  ];
  if (!filtered) {
    final present = results.map((q) => q.provider).toSet();
    for (final entry in registry) {
      if (present.contains(entry.id)) continue;
      providers.add(_undetected(entry));
    }
  }
  return VerificationReport(
    generatedAt: now,
    os: os,
    providers: providers,
    fleetChecks: _fleetChecks(results, now,
        filtered: filtered, runtimeAccess: runtimeAccess),
    runtimeAccess: runtimeAccess,
  );
}

ProviderVerification _undetected(ProviderAdapterRegistration entry) {
  final detail = entry.localRuntime
      ? 'local runtime not running on this host; absence is the truthful state'
      : 'claimed provider produced no snapshot; expected only when the '
          'adapter is filtered out or the host has never seen it';
  return ProviderVerification(
    provider: entry.id,
    displayName: entry.displayName,
    account: 'none',
    state: 'undetected',
    checks: [
      VerifyCheck(
        'source_class',
        entry.sourceClasses.isEmpty ? VerifyStatus.fail : VerifyStatus.pass,
        entry.sourceClasses.isEmpty
            ? 'adapter registry declares no allowed source class'
            : 'adapter allows ${entry.sourceClasses.map((value) => value.label).join(' or ')}',
      ),
      VerifyCheck(
        'claimed_coverage',
        entry.localRuntime ? VerifyStatus.info : VerifyStatus.fail,
        detail,
      ),
    ],
    crossCheck: kProviderCrossChecks[entry.id],
  );
}

ProviderVerification _verifyProvider(
  ProviderQuota q,
  int now,
  ProviderAdapterRegistration? registration,
) {
  final checks = <VerifyCheck>[
    _identityCheck(q),
    _sourceClassCheck(q, registration),
    _providerDriftCheck(q, now),
    _readOrReasonCheck(q),
    _percentBoundsCheck(q),
    _asOfCheck(q, now),
    _staleHonestyCheck(q, now),
    ..._resetChecks(q, now),
  ];
  return ProviderVerification(
    provider: q.provider,
    displayName: q.displayName,
    account: q.account,
    state: verifyState(q, now),
    plan: q.plan,
    source: q.source,
    sourceClass: q.sourceClass,
    asOf: q.asOf,
    stalenessSeconds: q.asOf > 0 ? (q.asOf > now ? 0 : now - q.asOf) : null,
    stale: q.stale,
    driftReason: q.driftReason,
    driftObservedAt: q.driftObservedAt,
    windows: [
      for (final w in q.windows)
        {
          'label': w.label,
          if (w.percent != null) 'used_percent': w.percent,
          'effective_used_percent': quotaWindowUsedPercent(q, w, now),
          if (w.resetsAt != null) 'resets_at': w.resetsAt,
          if (w.resetsAt != null) 'resets_in_seconds': w.resetsAt! - now,
        },
    ],
    checks: checks,
    crossCheck: kProviderCrossChecks[q.provider],
  );
}

VerifyCheck _sourceClassCheck(
  ProviderQuota q,
  ProviderAdapterRegistration? registration,
) {
  final violation = registeredSourceClassViolation(q, registration);
  if (violation != null) {
    return VerifyCheck('source_class', VerifyStatus.fail, violation);
  }
  if (q.sourceClass == ProviderSourceClass.manual) {
    return const VerifyCheck(
      'source_class',
      VerifyStatus.pass,
      'manual quota is explicitly labeled self-reported',
    );
  }
  return VerifyCheck(
    'source_class',
    VerifyStatus.pass,
    '${q.sourceClass.label} provenance matches the adapter and data shape',
  );
}

VerifyCheck _providerDriftCheck(ProviderQuota q, int now) {
  final rawReason = q.driftReason;
  if (rawReason == null) {
    return const VerifyCheck(
      'provider_drift',
      VerifyStatus.pass,
      'no rejected provider-drift observation is active',
    );
  }
  final reason = rawReason.trim();
  if (reason.isEmpty) {
    return const VerifyCheck(
      'provider_drift',
      VerifyStatus.fail,
      'provider drift is active but its reason is blank',
    );
  }
  final observedAt = q.driftObservedAt;
  final timing = observedAt == null
      ? 'detection time unavailable'
      : observedAt > now + kVerifyClockSkewSeconds
          ? 'detection time is implausibly in the future'
          : 'detected ${now - observedAt < 0 ? 0 : now - observedAt}s ago';
  final evidence = q.windows.isEmpty
      ? 'legacy evidence is quarantined and no trusted snapshot is available'
      : 'showing the last trusted snapshot, which is not routable';
  return VerifyCheck(
    'provider_drift',
    VerifyStatus.fail,
    'rejected fresh provider evidence: $reason; $timing; $evidence',
  );
}

/// Stable machine-readable read state, matching the doctor view's semantics.
String verifyState(ProviderQuota q, int now) {
  if (q.isLocal) return 'local';
  if (!q.ok) return 'error';
  if (q.windows.isEmpty) return 'no_data';
  if (q.stale) return 'cached';
  final headroom = providerHeadroom(q, now) ?? 100;
  return headroom <= kSpentHeadroomFloor ? 'out_of_quota' : 'live';
}

VerifyCheck _identityCheck(ProviderQuota q) {
  final missing = <String>[
    if (q.provider.trim().isEmpty) 'provider id',
    if (q.displayName.trim().isEmpty) 'display name',
    if (q.account.trim().isEmpty) 'account',
  ];
  return missing.isEmpty
      ? const VerifyCheck('identity', VerifyStatus.pass,
          'provider, display name, and account are all present')
      : VerifyCheck(
          'identity', VerifyStatus.fail, 'missing ${missing.join(', ')}');
}

/// The 1.0 promise in one check: a snapshot either carries data or says
/// plainly why it does not.
VerifyCheck _readOrReasonCheck(ProviderQuota q) {
  if (!q.ok) {
    final reason = q.error?.trim() ?? '';
    return reason.isEmpty
        ? const VerifyCheck('read_or_reason', VerifyStatus.fail,
            'read failed with no error note; failures must say why')
        : VerifyCheck(
            'read_or_reason', VerifyStatus.pass, 'failed truthfully: $reason');
  }
  if (q.isLocal) {
    return const VerifyCheck(
        'read_or_reason', VerifyStatus.pass, 'local runtime read successfully');
  }
  if (q.windows.isEmpty) {
    final note = (q.error ?? q.status)?.trim() ?? '';
    return note.isEmpty
        ? const VerifyCheck('read_or_reason', VerifyStatus.fail,
            'no quota windows and no reason given; silence is not honest')
        : VerifyCheck('read_or_reason', VerifyStatus.pass,
            'no quota windows, with reason: $note');
  }
  return VerifyCheck('read_or_reason', VerifyStatus.pass,
      'read ${q.windows.length} quota window(s)');
}

VerifyCheck _percentBoundsCheck(ProviderQuota q) {
  final problems = <String>[];
  for (final w in q.windows) {
    final pct = w.percent;
    if (pct == null) {
      problems.add('${w.label} has no usable percent or used/limit ratio');
    } else if (!pct.isFinite || pct < 0 || pct > 100) {
      problems.add('${w.label} percent $pct out of 0..100');
    }
    final used = w.used;
    if (used != null && (!used.isFinite || used < 0)) {
      problems.add('${w.label} used $used negative or non-finite');
    }
    final limit = w.limit;
    if (limit != null && (!limit.isFinite || limit <= 0)) {
      problems.add('${w.label} limit $limit not a positive finite number');
    }
  }
  return problems.isEmpty
      ? const VerifyCheck('percent_bounds', VerifyStatus.pass,
          'all window percentages and counts are finite and in bounds')
      : VerifyCheck('percent_bounds', VerifyStatus.fail, problems.join('; '));
}

VerifyCheck _asOfCheck(ProviderQuota q, int now) {
  if (q.asOf <= 0) {
    return const VerifyCheck('as_of_sane', VerifyStatus.fail,
        'as_of is missing or zero; every snapshot must carry its capture time');
  }
  if (q.asOf > now + kVerifyClockSkewSeconds) {
    return VerifyCheck('as_of_sane', VerifyStatus.fail,
        'as_of is ${q.asOf - now}s in the future; clock or provider drift');
  }
  return VerifyCheck(
      'as_of_sane', VerifyStatus.pass, 'captured ${now - q.asOf}s ago');
}

VerifyCheck _staleHonestyCheck(ProviderQuota q, int now) {
  if (!q.stale) {
    return const VerifyCheck('stale_honesty', VerifyStatus.pass,
        'snapshot is fresh, not served from cache');
  }
  final note = q.error?.trim() ?? '';
  if (note.isEmpty) {
    return const VerifyCheck('stale_honesty', VerifyStatus.fail,
        'stale snapshot carries no note saying why the live read failed');
  }
  return VerifyCheck('stale_honesty', VerifyStatus.pass,
      'cached data is labeled stale with reason: $note');
}

List<VerifyCheck> _resetChecks(ProviderQuota q, int now) {
  final checks = <VerifyCheck>[];
  for (final w in q.windows) {
    final resetsAt = w.resetsAt;
    if (resetsAt == null) continue;
    if (resetsAt < 0) {
      checks.add(VerifyCheck('reset_sanity', VerifyStatus.fail,
          '${w.label} reset time $resetsAt is negative'));
    } else if (resetsAt > now + kVerifyMaxResetHorizonSeconds) {
      checks.add(VerifyCheck(
          'reset_sanity',
          VerifyStatus.fail,
          '${w.label} resets ${(resetsAt - now) ~/ 86400}d out; implausible '
              'for a rolling window and likely provider drift'));
    } else if (resetsAt <= now) {
      final trusted = isTrustedQuotaEvidenceAt(q, now);
      checks.add(VerifyCheck(
          'reset_sanity',
          VerifyStatus.info,
          trusted
              ? '${w.label} reset boundary has passed; trusted fresh evidence '
                  'is treated as a reset-edge rollover until the next read'
              : '${w.label} reset boundary has passed, but cached or untrusted '
                  'evidence keeps its last observed usage and remains '
                  'non-routable until a fresh read'));
    }
  }
  if (checks.isEmpty && q.windows.any((w) => w.resetsAt != null)) {
    checks.add(const VerifyCheck('reset_sanity', VerifyStatus.pass,
        'all reset times are plausible and in the future'));
  }
  return checks;
}

List<VerifyCheck> _fleetChecks(
  List<ProviderQuota> results,
  int now, {
  required bool filtered,
  RuntimeAccessReport? runtimeAccess,
}) {
  final checks = <VerifyCheck>[];

  // The emitted snapshot must conform to the frozen public contract on every
  // verify run, so contract drift is caught the day it happens.
  final snapshot = <String, dynamic>{
    'schema': quotabotV1SchemaId,
    'generated_at': now,
    'providers': results.map((q) => q.toJson()).toList(),
  };
  final contractErrors = validateQuotabotV1Snapshot(snapshot);
  checks.add(contractErrors.isEmpty
      ? const VerifyCheck('schema_contract', VerifyStatus.pass,
          'live snapshot conforms to the frozen quotabot.v1 contract')
      : VerifyCheck('schema_contract', VerifyStatus.fail,
          'quotabot.v1 violations: ${contractErrors.join('; ')}'));

  final seen = <String>{};
  final duplicates = <String>{};
  for (final q in results) {
    final key = '${q.provider}/${q.account}';
    if (!seen.add(key)) duplicates.add(key);
  }
  checks.add(duplicates.isEmpty
      ? const VerifyCheck('unique_accounts', VerifyStatus.pass,
          'every provider/account pair appears exactly once')
      : VerifyCheck('unique_accounts', VerifyStatus.fail,
          'duplicate provider/account pairs: ${duplicates.join(', ')}'));

  final manualCount = results.where((q) => q.isManual).length;
  if (manualCount > 0) {
    checks.add(VerifyCheck(
        'manual_entries',
        VerifyStatus.info,
        '$manualCount self-reported manual entr${manualCount == 1 ? 'y' : 'ies'} '
            'in view; manual numbers are only ever what the user typed'));
  }

  if (filtered) {
    checks.add(const VerifyCheck('claimed_coverage', VerifyStatus.info,
        'coverage check skipped: a profile or exclusion narrowed this read'));
  }
  final runtimeAccessCheck = _runtimeAccessBoundaryCheck(runtimeAccess);
  if (runtimeAccessCheck != null) checks.add(runtimeAccessCheck);
  return checks;
}

VerifyCheck? _runtimeAccessBoundaryCheck(RuntimeAccessReport? access) {
  if (access == null) return null;
  if (!access.collectionExecuted) {
    return const VerifyCheck(
      'runtime_access_boundary',
      VerifyStatus.info,
      'no provider collection was executed; runtime access is a manifest only',
    );
  }
  final violations = <String>[];
  for (final record in access.allRecords) {
    if (record.spendsTokens) {
      violations.add('${record.target} is marked as token-spending');
    }
    if (record.sendsPromptOrCode) {
      violations.add('${record.target} is marked as sending prompts or code');
    }
    if (_looksLikeGenerationEndpoint(record)) {
      violations.add('${record.target} looks like a generation endpoint');
    }
  }
  if (violations.isNotEmpty) {
    return VerifyCheck(
      'runtime_access_boundary',
      VerifyStatus.fail,
      violations.join('; '),
    );
  }
  return VerifyCheck(
    'runtime_access_boundary',
    VerifyStatus.pass,
    'runtime access observation attached for ${access.providers.length} '
        'invoked provider adapter(s); no prompts, source code, token spend, '
        'or generation endpoints observed',
  );
}

bool _looksLikeGenerationEndpoint(RuntimeAccessRecord record) {
  if (record.kind != RuntimeAccessKind.network) return false;
  final target = record.target.toLowerCase();
  return _generationEndpointMarkers.any(target.contains);
}

final _generationEndpointMarkers = <String>[
  '/chat/completions',
  '/v1' '/completions',
  '/v1' '/messages',
  '/responses',
  '/images',
  ':generate' 'content',
];
