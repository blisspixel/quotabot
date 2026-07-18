/// The silent-drift admission boundary: compares a fresh provider reading
/// against the last trusted one and rejects implausible evidence.
///
/// 1.0 acceptance criterion 1 is that every provider either reads correctly or
/// fails with a plain message. Static bounds and staleness cover the "fails"
/// half, but a read that is *wrong yet does not fail* - a repurposed field, an
/// inverted value, a fuzzy-key match that grabs an unrelated number - slips
/// through. Rejected values never replace trusted cache or analytics evidence.
/// Callers instead receive the prior trusted snapshot marked stale with an
/// explicit additive drift diagnostic.
library;

import 'models.dart';
import 'provider_ids.dart';

/// Maximum tolerated provider snapshot clock lead. Cache validation and live
/// admission share this bound so neither path can bless evidence the other
/// rejects.
const int kQuotaEvidenceClockSkewSeconds = 60;

/// A reset may jitter by this many seconds before a backwards move counts as a
/// regression, absorbing minor clock and reporting noise.
const int _resetRegressToleranceSeconds = 300;

/// Used-percent must fall by more than this many points, within an unreset
/// window, before it counts as an implausible headroom gain (absorbs rounding).
const double _headroomGainTolerancePoints = 2.0;

/// Maximum public diagnostic length. Provider window/model labels are
/// untrusted metadata and must not be able to inflate CLI, MCP, desktop, or
/// persisted diagnostic output without bound.
const int kMaxQuotaDriftReasonCharacters = 512;
const int _maxQuotaDriftDimensionCharacters = 96;

/// Providers whose single window is not a plain consume-then-reset pool, so the
/// monotonicity checks do not apply. Antigravity's lone window is a max over a
/// changing per-model set, so its headroom and reset can both move
/// non-monotonically; its real signal is per-model quota, checked elsewhere.
const _syntheticWindowProviders = {antigravityProviderId};

/// Providers whose model quotas are optional overlays on shared provider
/// windows rather than an exhaustive list of independent model pools. Claude
/// can add or remove a promotional or plan-specific scoped limit without
/// invalidating the account-wide session and weekly evidence.
const _optionalModelQuotaProviders = {claudeProviderId};

/// Claude Code briefly exposed scoped family caps in response shapes that older
/// quotabot builds normalized as provider-wide windows. Those labels are not
/// shared provider constraints. Let them leave the window set during migration
/// even when the current account no longer reports the optional scoped cap.
/// The shared `5h` and `weekly` windows keep the normal disappearance checks.
const _legacyClaudeScopedWindowLabels = {
  'fable',
  'opus',
  'sonnet',
  'haiku',
};

bool _isLegacyClaudeScopedWindow(ProviderQuota quota, QuotaWindow window) =>
    quota.provider == claudeProviderId &&
    _legacyClaudeScopedWindowLabels.contains(
      window.label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ''),
    );

/// Providers whose every window can be re-rated downward mid-window, so a
/// used-percent drop is expected rather than drift and the fresh (lower) number
/// is the latest truth to show. xAI does this to the whole Grok credit pool
/// (observed 100 -> 73 under an unchanged reset).
const _reRatingProviders = {grokProviderId};

/// Specific windows that can legitimately fall without a reset even though the
/// provider's other windows are normal consume-then-reset pools. Codex's weekly
/// window is non-monotonic (its used-percent is observed to fall without a hard
/// reset, consistent with a rolling window or a re-rated allowance), so holding a
/// stale higher value there would defeat the goal of showing current quota; its
/// 5 hour window stays a normal window whose unexplained drop is genuine drift.
const _reRatingWindows = <String, Set<String>>{
  codexProviderId: {'weekly'},
};

/// Whether the vanished [gone] window is explained by the account folding into a
/// longer cap: some surviving [fresh] window has a reset at least as far out as
/// [gone]'s (within tolerance). This distinguishes a legitimate collapse to a
/// longer window (the observed Codex 5h+weekly to single-weekly restructure)
/// from losing the longest cap, which stays drift. Conservative on missing reset
/// times: without a comparable reset on both sides it returns false, so the
/// disappearance is flagged rather than quietly accepted.
bool _collapsedIntoLongerWindow(QuotaWindow gone, ProviderQuota fresh) {
  final goneReset = gone.resetsAt;
  if (goneReset == null) return false;
  for (final w in fresh.windows) {
    final r = w.resetsAt;
    if (r != null && r >= goneReset - _resetRegressToleranceSeconds) {
      return true;
    }
  }
  return false;
}

/// Whether a used-percent drop in [label] for [provider] is expected re-rating
/// rather than drift.
bool _isReRatingWindow(String provider, String? label) =>
    _reRatingProviders.contains(provider) ||
    (label != null && (_reRatingWindows[provider]?.contains(label) ?? false));

/// Providers whose set of quota windows is defined by the provider and can
/// legitimately change shape - a window bucket appearing or disappearing as the
/// provider restructures its plan - rather than a fixed schema. Codex qualifies:
/// OpenAI has been observed collapsing the separate 5 hour and weekly buckets
/// into a single weekly window on the Pro plan, so a window vanishing is a
/// provider restructure, not a parser regression. Holding the pre-restructure
/// snapshot would then keep reporting a spent old window as current and hide the
/// real headroom the account now has (for example a fresh weekly at 4% used
/// after an off-cycle reset would read as the stale 93% used it held before).
/// This exemption only relaxes the window-disappeared check; a surviving
/// window's own value still passes the monotonicity and re-rating checks, so a
/// genuinely implausible number is still caught.
const _variableWindowSetProviders = {codexProviderId};

/// Whether [quota]'s status and window shape are structurally eligible for
/// trusted evidence. Time-aware persistence and routing must use
/// [isTrustedQuotaEvidenceAt] so missing or future capture provenance cannot
/// bypass this structural check.
bool isTrustedQuotaEvidence(ProviderQuota quota) =>
    quota.ok &&
    quota.hasWindows &&
    quota.sourceClassViolation == null &&
    quota.windows.every((window) {
      final percent = window.percent;
      return percent != null &&
          percent.isFinite &&
          percent >= 0 &&
          percent <= 100;
    }) &&
    !quota.stale &&
    quota.suspect == null &&
    quota.driftReason == null;

/// Timestamp-aware trust boundary for routing, analytics, and direct cache
/// writes. [isTrustedQuotaEvidence] validates the evidence shape; this variant
/// also rejects missing epoch provenance and material clock lead.
bool isTrustedQuotaEvidenceAt(ProviderQuota quota, int observedAt) =>
    isTrustedQuotaEvidence(quota) &&
    quota.asOf > 0 &&
    quota.asOf <= observedAt + kQuotaEvidenceClockSkewSeconds;

/// Returns a bounded drift diagnostic when an otherwise successful fresh read
/// contains a quota window that cannot produce a finite percent in 0..100.
///
/// A window with unknown evidence is materially different from a failed or
/// windowless read: the provider claimed to return quota, but that quota cannot
/// safely govern routing. Treating it as an ordinary cache fallback would hide
/// a parser or upstream-shape regression.
String? unusableQuotaEvidenceDriftReason(
  ProviderQuota quota, {
  int? observedAt,
}) {
  if (!quota.ok ||
      quota.stale ||
      quota.suspect != null ||
      quota.driftReason != null ||
      !quota.hasWindows) {
    return null;
  }
  final sourceClassViolation = quota.sourceClassViolation;
  if (sourceClassViolation != null) {
    return boundedQuotaDriftReason(sourceClassViolation);
  }
  if (observedAt != null) {
    if (quota.asOf <= 0) {
      return 'quota snapshot timestamp is non-positive';
    }
    if (quota.asOf > observedAt + kQuotaEvidenceClockSkewSeconds) {
      return 'quota snapshot timestamp is materially in the future';
    }
  }
  for (final window in quota.windows) {
    final rawLabel = stripTerminalControl(window.label).trim();
    final label = rawLabel.length <= _maxQuotaDriftDimensionCharacters
        ? rawLabel
        : '${rawLabel.substring(0, _maxQuotaDriftDimensionCharacters - 3)}...';
    final namedWindow =
        label.isEmpty ? 'unnamed quota window' : '$label quota window';
    final percent = window.percent;
    if (percent == null) {
      return boundedQuotaDriftReason(
        '$namedWindow has no usable percent or used/limit ratio',
      );
    }
    if (!percent.isFinite || percent < 0 || percent > 100) {
      return boundedQuotaDriftReason(
        '$namedWindow produced a percent outside 0..100',
      );
    }
  }
  return null;
}

/// A cache shape written by the pre-quarantine drift canary. Its windows were
/// annotated as suspect but not kept apart from last-known-good evidence, so an
/// upgrade must retain it only as a comparison baseline, never as routable
/// quota or history.
bool isLegacySuspectQuotaEvidence(ProviderQuota quota) =>
    quota.ok &&
    quota.hasWindows &&
    !quota.stale &&
    quota.suspect != null &&
    quota.driftReason == null;

/// Sanitizes and bounds a provider-drift diagnostic for every output surface.
String boundedQuotaDriftReason(String reason) {
  final clean = stripTerminalControl(reason).trim();
  if (clean.length <= kMaxQuotaDriftReasonCharacters) return clean;
  return '${clean.substring(0, kMaxQuotaDriftReasonCharacters - 3)}...';
}

/// Whether two snapshots describe the same evidence class closely enough for
/// monotonic drift checks. Identity, plan, or source transitions establish a
/// new baseline rather than producing a false drift warning.
bool isComparableQuotaEvidence(
  ProviderQuota fresh,
  ProviderQuota previous,
) =>
    fresh.provider == previous.provider &&
    fresh.account == previous.account &&
    fresh.kind == previous.kind &&
    fresh.plan == previous.plan &&
    fresh.source == previous.source &&
    fresh.sourceClass == previous.sourceClass &&
    fresh.perMachine == previous.perMachine;

/// Pure result of applying the quota-evidence admission policy.
class QuotaEvidenceAdmission {
  final ProviderQuota snapshot;
  final bool shouldPersist;
  final String? driftReason;

  const QuotaEvidenceAdmission({
    required this.snapshot,
    required this.shouldPersist,
    this.driftReason,
  });
}

/// Admits a trustworthy fresh baseline, or returns the prior trusted evidence
/// as a stale drift result. Untrusted fresh inputs are never made cacheable.
QuotaEvidenceAdmission admitQuotaEvidence(
  ProviderQuota fresh,
  ProviderQuota? previous, {
  required int observedAt,
  String? rejectionReason,
}) {
  final forcedRejection = rejectionReason != null;
  final unusableReason = forcedRejection
      ? boundedQuotaDriftReason(rejectionReason)
      : unusableQuotaEvidenceDriftReason(
          fresh,
          observedAt: observedAt,
        );
  if (unusableReason != null) {
    if (previous != null &&
        isTrustedQuotaEvidenceAt(previous, observedAt) &&
        (forcedRejection || isComparableQuotaEvidence(fresh, previous))) {
      return QuotaEvidenceAdmission(
        snapshot: previous.withProviderDrift(unusableReason, observedAt),
        shouldPersist: false,
        driftReason: unusableReason,
      );
    }
    if (previous != null &&
        isLegacySuspectQuotaEvidence(previous) &&
        (forcedRejection || isComparableQuotaEvidence(fresh, previous))) {
      final quarantine = quarantineLegacyQuotaEvidence(
        previous,
        observedAt: observedAt,
        metadataFrom: fresh,
      );
      return QuotaEvidenceAdmission(
        snapshot: quarantine,
        shouldPersist: false,
        driftReason: quarantine.driftReason,
      );
    }
    return QuotaEvidenceAdmission(
      snapshot: quarantineUnusableQuotaEvidence(
        fresh,
        unusableReason,
        observedAt,
      ),
      shouldPersist: false,
      driftReason: unusableReason,
    );
  }
  if (!isTrustedQuotaEvidenceAt(fresh, observedAt)) {
    final reason = fresh.suspect ?? fresh.driftReason;
    return QuotaEvidenceAdmission(
      snapshot: fresh,
      shouldPersist: false,
      driftReason: reason == null ? null : boundedQuotaDriftReason(reason),
    );
  }
  if (previous == null) {
    return QuotaEvidenceAdmission(snapshot: fresh, shouldPersist: true);
  }
  if (isLegacySuspectQuotaEvidence(previous)) {
    if (!isComparableQuotaEvidence(fresh, previous) ||
        _hasAdvancedResetEvidence(fresh, previous, observedAt)) {
      return QuotaEvidenceAdmission(snapshot: fresh, shouldPersist: true);
    }
    final quarantine = quarantineLegacyQuotaEvidence(
      previous,
      observedAt: observedAt,
      metadataFrom: fresh,
    );
    return QuotaEvidenceAdmission(
      snapshot: quarantine,
      shouldPersist: false,
      driftReason: quarantine.driftReason,
    );
  }
  if (!isTrustedQuotaEvidenceAt(previous, observedAt) ||
      !isComparableQuotaEvidence(fresh, previous)) {
    return QuotaEvidenceAdmission(snapshot: fresh, shouldPersist: true);
  }
  final detected = detectQuotaDrift(
    fresh,
    previous,
    observedAt: observedAt,
  );
  final reason = detected == null ? null : boundedQuotaDriftReason(detected);
  if (reason == null) {
    return QuotaEvidenceAdmission(snapshot: fresh, shouldPersist: true);
  }
  return QuotaEvidenceAdmission(
    snapshot: previous.withProviderDrift(reason, observedAt),
    shouldPersist: false,
    driftReason: reason,
  );
}

/// Produces a visible, non-routable result when a fresh successful read carries
/// unusable quota windows and no comparable trusted baseline can be shown.
ProviderQuota quarantineUnusableQuotaEvidence(
  ProviderQuota fresh,
  String reason,
  int observedAt,
) {
  final validTimestamp = fresh.asOf > 0 &&
      fresh.asOf <= observedAt + kQuotaEvidenceClockSkewSeconds;
  return ProviderQuota(
    provider: fresh.provider,
    displayName: fresh.displayName,
    account: fresh.account,
    asOf: validTimestamp ? fresh.asOf : observedAt,
    plan: fresh.plan,
    source: fresh.source,
    sourceClass: fresh.sourceClass,
    ok: false,
    error: 'provider drift detected; fresh quota evidence is unusable and '
        'no trusted snapshot is available',
    stale: true,
    kind: fresh.kind,
    status: fresh.status,
    active: fresh.active,
    details: fresh.details,
    models: fresh.models,
    driftReason: boundedQuotaDriftReason(reason),
    driftObservedAt: observedAt,
    perMachine: fresh.perMachine,
    pipeHealth: fresh.pipeHealth,
    httpStatus: fresh.httpStatus,
    retryAfterSeconds: fresh.retryAfterSeconds,
  );
}

/// Produces a visible, non-routable migration result from legacy suspect cache
/// evidence. No quota windows survive because the old format cannot prove which
/// values, if any, were last known good.
ProviderQuota quarantineLegacyQuotaEvidence(
  ProviderQuota legacy, {
  required int observedAt,
  ProviderQuota? metadataFrom,
}) {
  final detail = boundedQuotaDriftReason(
    'unresolved legacy provider drift: '
    '${legacy.suspect ?? 'suspect quota evidence'}',
  );
  return legacy.asProviderDriftQuarantine(
    detail,
    observedAt,
    metadataFrom: metadataFrom,
  );
}

/// Legacy suspect evidence is allowed to establish a new trusted baseline only
/// after every retained quota dimension has unambiguously rolled forward.
/// Merely repeating the same suspicious values must never launder them.
bool _hasAdvancedResetEvidence(
  ProviderQuota fresh,
  ProviderQuota legacy,
  int observedAt,
) {
  var compared = false;
  final freshWindows = {
    for (final window in fresh.windows) window.label: window
  };
  for (final previous in legacy.windows) {
    if (_isLegacyClaudeScopedWindow(legacy, previous)) continue;
    final current = freshWindows[previous.label];
    final previousReset = previous.resetsAt;
    final freshReset = current?.resetsAt;
    if (previousReset == null ||
        freshReset == null ||
        observedAt < previousReset - _resetRegressToleranceSeconds ||
        freshReset <= previousReset + _resetRegressToleranceSeconds) {
      return false;
    }
    compared = true;
  }
  final freshModels = {
    for (final model in fresh.modelQuotas) model.model: model
  };
  for (final previous in legacy.modelQuotas) {
    final current = freshModels[previous.model];
    if (current == null &&
        _optionalModelQuotaProviders.contains(fresh.provider)) {
      continue;
    }
    final previousReset = previous.resetsAt;
    final freshReset = current?.resetsAt;
    if (previousReset == null ||
        freshReset == null ||
        observedAt < previousReset - _resetRegressToleranceSeconds ||
        freshReset <= previousReset + _resetRegressToleranceSeconds) {
      return false;
    }
    compared = true;
  }
  return compared;
}

/// Returns a short reason when [fresh] is implausible versus [previous] - the
/// signature of a silently drifted read rather than normal consumption or a
/// reset - or null when the reading is consistent. Windows are matched by label
/// and per-model pools by model name, so only like is compared with like.
String? detectQuotaDrift(
  ProviderQuota fresh,
  ProviderQuota previous, {
  int? observedAt,
}) {
  final observation = observedAt ?? fresh.asOf;
  // Windows: skipped for providers whose single window is a synthetic
  // max-over-models artifact (Antigravity); their real signal is per-model.
  if (!_syntheticWindowProviders.contains(fresh.provider)) {
    final prev = {for (final w in previous.windows) w.label: w};
    final freshLabels = {for (final w in fresh.windows) w.label};
    final windowSetIsVariable =
        _variableWindowSetProviders.contains(fresh.provider);
    for (final prior in previous.windows) {
      if (freshLabels.contains(prior.label)) continue;
      if (_isLegacyClaudeScopedWindow(previous, prior)) continue;
      // A window vanished. For a provider whose window set can restructure
      // (Codex), that is a legitimate collapse only when a window reaching at
      // least as far as the vanished one survives - the account folded into its
      // longer cap, as when the 5h and weekly buckets became a single weekly.
      // If instead the longest cap vanished, the binding constraint (or a parser
      // that dropped it) is lost, so it is still flagged. A blanket exemption
      // would silently accept losing the weekly cap.
      if (windowSetIsVariable && _collapsedIntoLongerWindow(prior, fresh)) {
        continue;
      }
      return boundedQuotaDriftReason(
        '${prior.label} quota window disappeared',
      );
    }
    for (final w in fresh.windows) {
      final p = prev[w.label];
      if (p == null) continue;
      final reason = _pairDrift(
        fresh.provider,
        w.percent,
        w.resetsAt,
        p.percent,
        p.resetsAt,
        observation,
        windowLabel: w.label,
      );
      if (reason != null) {
        return boundedQuotaDriftReason('${w.label} $reason');
      }
    }
  }
  // Per-model pools keep the same monotonicity checks when a model survives in
  // both snapshots. Antigravity's list is exhaustive, so disappearance is also
  // drift. Claude's scoped list is optional, so addition or removal can reflect
  // a legitimate plan-policy change without invalidating shared windows.
  final prevModels = {for (final m in previous.modelQuotas) m.model: m};
  final freshModelNames = {for (final m in fresh.modelQuotas) m.model};
  for (final prior in previous.modelQuotas) {
    if (!freshModelNames.contains(prior.model) &&
        !_optionalModelQuotaProviders.contains(fresh.provider)) {
      return boundedQuotaDriftReason(
        '${prior.model} model quota disappeared',
      );
    }
  }
  for (final m in fresh.modelQuotas) {
    final p = prevModels[m.model];
    if (p == null) continue;
    final reason = _pairDrift(
      fresh.provider,
      m.usedPercent,
      m.resetsAt,
      p.usedPercent,
      p.resetsAt,
      observation,
    );
    if (reason != null) {
      return boundedQuotaDriftReason('${m.model} $reason');
    }
  }
  return null;
}

/// The monotonicity checks shared by windows and per-model pools, given a fresh
/// and previous `(usedPercent, resetsAt)` pair.
String? _pairDrift(
  String provider,
  double? freshUsed,
  int? freshReset,
  double? prevUsed,
  int? prevReset,
  int observedAt, {
  String? windowLabel,
}) {
  final reRating = _isReRatingWindow(provider, windowLabel);
  final fr = freshReset;
  final pr = prevReset;
  // (1) A reset only ever advances or holds; one that moved earlier by more
  // than the tolerance is implausible for any provider.
  if (fr != null && pr != null && fr < pr - _resetRegressToleranceSeconds) {
    return 'reset moved earlier';
  }
  if (fr == null && pr != null) return 'reset disappeared';
  // (2) Within one window instance (same reset, none passed) usage can only
  // rise: you consume, you do not regain - unless the provider re-rates its
  // pool, which is accepted, not drift.
  if (!reRating &&
      ((fr == null && pr == null) ||
          (fr != null &&
              pr != null &&
              (fr - pr).abs() <= _resetRegressToleranceSeconds))) {
    if (freshUsed != null &&
        prevUsed != null &&
        freshUsed < prevUsed - _headroomGainTolerancePoints) {
      return 'usage fell ${prevUsed.round()}% to ${freshUsed.round()}% '
          'with no reset';
    }
  }
  if (!reRating &&
      fr != null &&
      pr != null &&
      fr > pr + _resetRegressToleranceSeconds &&
      observedAt < pr - _resetRegressToleranceSeconds &&
      freshUsed != null &&
      prevUsed != null &&
      freshUsed < prevUsed - _headroomGainTolerancePoints) {
    return 'usage fell ${prevUsed.round()}% to ${freshUsed.round()}% before '
        'the prior reset';
  }
  return null;
}
