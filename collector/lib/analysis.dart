import 'dart:math' as math;

import 'drift.dart';
import 'insights.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'route_receipt.dart';

export 'route_receipt.dart';

/// Routing helpers over a set of provider snapshots. Pure and side-effect free.

/// Provenance discount for measured quota derived from one machine rather than
/// an authoritative account-wide endpoint. The value is intentionally shared
/// by passive IDE state and explicit local fallback evidence.
const double kMachineScopedEvidenceConfidenceFactor = 0.7;

/// Whether a quota window has reached its reset boundary.
bool windowHasRolledOver(QuotaWindow w, int now) =>
    w.resetsAt != null && w.resetsAt! <= now;

/// Effective used percent for a context-free window. A reset timestamp alone
/// never proves the new account-wide balance, so preserve the reported value
/// until a provider observation supplies a new window.
double windowUsedPercent(QuotaWindow w, int now) =>
    (w.percent ?? 0).clamp(0, 100).toDouble();

/// Effective remaining percent for a single quota window.
double windowHeadroom(QuotaWindow w, int now) =>
    100.0 - windowUsedPercent(w, now);

/// Whether [w] can be treated as reset for this exact quota observation.
///
/// Reset metadata identifies the end of the observed pool, but it does not say
/// what happened afterward on this or another device. A provider quota is only
/// current again once a new observation supplies its next window, so quota-aware
/// display and routing never synthesize zero usage at the boundary.
bool quotaWindowHasRolledOver(
  ProviderQuota quota,
  QuotaWindow w,
  int now,
) =>
    false;

/// Used percent for [w], preserving the last observed value when [quota] is
/// stale or otherwise untrusted.
double quotaWindowUsedPercent(
  ProviderQuota quota,
  QuotaWindow w,
  int now,
) =>
    quotaWindowHasRolledOver(quota, w, now)
        ? 0.0
        : (w.percent ?? 0).clamp(0, 100).toDouble();

/// Remaining percent for [w] under [quota]'s evidence trust state.
double quotaWindowHeadroom(
  ProviderQuota quota,
  QuotaWindow w,
  int now,
) =>
    100.0 - quotaWindowUsedPercent(quota, w, now);

/// A passive-local metered read (Kiro, Cursor, Windsurf state files) whose window
/// has already passed its reset cannot be trusted as a fresh full balance. The
/// local file predates the reset and quotabot never observed the refresh, so the
/// post-reset usage is unknown; presenting it as a confident 100% free asserts
/// more than the evidence supports. Such a read is marked stale with a caveat, so
/// routing declines to rely on it and the glance shows it as a last-known value
/// rather than a live one. Authoritative and this-machine reads are not changed
/// by this passive-specific helper: the shared trust boundary already makes any
/// observation with a passed reset unavailable until a fresh response names the
/// current pool.
ProviderQuota flagStalePassiveRolloverEvidence(ProviderQuota q, int now) {
  if (q.sourceClass != ProviderSourceClass.passiveLocalEvidence) return q;
  if (!q.ok || q.stale || q.windows.isEmpty) return q;
  int? lastPassedReset;
  for (final w in q.windows) {
    final r = w.resetsAt;
    if (r != null &&
        r <= now &&
        (lastPassedReset == null || r > lastPassedReset)) {
      lastPassedReset = r;
    }
  }
  if (lastPassedReset == null) return q;
  return q.asStale(
    'local usage predates its reset (${_passiveRolloverAgeLabel(lastPassedReset, now)}); '
    'open ${q.displayName} to confirm current headroom',
  );
}

String _passiveRolloverAgeLabel(int then, int now) {
  final secs = now - then;
  if (secs < 3600) return 'under 1h ago';
  final hours = secs ~/ 3600;
  if (hours < 24) return '${hours}h ago';
  return '${secs ~/ 86400}d ago';
}

/// The windows worth showing at a glance: those with real usage. A fully
/// available short window (a 5-hour rate limit sitting at 0% used) carries no
/// information next to the longer window that is the actual binding constraint,
/// so it is hidden until it has been drawn on. When nothing has been used yet,
/// all windows are returned, so an all-fresh account still shows its picture
/// rather than nothing.
List<QuotaWindow> visibleWindows(List<QuotaWindow> windows, int now) {
  final used = windows.where((w) => windowUsedPercent(w, now) > 0.5).toList();
  return used.isEmpty ? windows : used;
}

/// Returns the currently active reservation discount for a provider account.
typedef LeaseDiscountProvider = double Function(
    String provider, String account);

double _noLeaseDiscount(String provider, String account) => 0;

/// Remaining headroom for a provider as a percent (0..100), governed by its
/// most constrained window. A passed reset preserves the last observed value
/// until a new provider observation names the next window. Returns null when
/// the provider has no usable windows.
double? providerHeadroom(ProviderQuota q, int now) {
  if (q.windows.isEmpty) return null;
  double minRemaining = 100;
  for (final w in q.windows) {
    final percent = w.percent;
    if (percent == null || !percent.isFinite || percent < 0 || percent > 100) {
      return null;
    }
    final remaining = quotaWindowHeadroom(q, w, now);
    if (remaining < minRemaining) minRemaining = remaining;
  }
  return minRemaining;
}

/// The provider with the most remaining headroom, for choosing where to route
/// work. Local runtimes are excluded (they read 100% and would always win; use
/// [suggestRoute] for fallback logic). Stale or integrity-rejected snapshots
/// and providers at or below the spent floor are excluded: they are evidence,
/// not current usable capacity.
ProviderQuota? providerWithMostHeadroom(List<ProviderQuota> quotas, int now) {
  ProviderQuota? best;
  double bestHeadroom = -1;
  for (final q in quotas) {
    if (q.isLocal || !isTrustedQuotaEvidenceAt(q, now)) continue;
    final h = providerHeadroom(q, now);
    if (h != null && h > kSpentHeadroomFloor && h > bestHeadroom) {
      bestHeadroom = h;
      best = q;
    }
  }
  return best;
}

/// Availability of a single provider: usable when a fresh snapshot has more
/// than [kSpentHeadroomFloor] headroom left. Stale cached windows still return
/// their last-known headroom and reset for display, but they are not reported
/// as currently available.
/// When spent, `resetsAt` is when it becomes usable again, which is the reset of
/// the window that clears last, not the soonest (see [bindingWindow]).
({bool available, double? headroom, int? resetsAt}) providerAvailability(
  ProviderQuota q,
  int now,
) {
  final h = providerHeadroom(q, now);
  if (h == null) return (available: false, headroom: null, resetsAt: null);
  return (
    available: isTrustedQuotaEvidenceAt(q, now) && h > kSpentHeadroomFloor,
    headroom: h,
    resetsAt: bindingWindow(q, now)?.resetsAt,
  );
}

/// Selects one account for a provider-name availability check. An exact
/// [account] keeps the caller's existing account-specific behavior. Without an
/// account, current usable evidence wins, then current but unavailable evidence,
/// then remaining headroom, with the account key as the stable tie-breaker.
/// This keeps CLI, MCP, and loopback HTTP checks deterministic and prevents a
/// spent first account from hiding a later healthy account.
ProviderQuota? bestProviderAccountForCheck(
  Iterable<ProviderQuota> matches,
  int now, {
  String? account,
}) {
  final candidates = matches.toList();
  if (account != null) {
    for (final candidate in candidates) {
      if (candidate.account == account) return candidate;
    }
    return null;
  }
  if (candidates.isEmpty) return null;

  bool available(ProviderQuota quota) => quota.isLocal
      ? isLocalRuntimeAvailableAt(quota, now)
      : providerAvailability(quota, now).available;
  bool current(ProviderQuota quota) => quota.isLocal
      ? isLocalRuntimeReachableAt(quota, now)
      : isTrustedQuotaEvidenceAt(quota, now);
  double headroom(ProviderQuota quota) => quota.isLocal && available(quota)
      ? 100
      : providerHeadroom(quota, now) ?? -1;

  candidates.sort((a, b) {
    final aAvailable = available(a);
    final bAvailable = available(b);
    if (aAvailable != bAvailable) return aAvailable ? -1 : 1;
    final aCurrent = current(a);
    final bCurrent = current(b);
    if (aCurrent != bCurrent) return aCurrent ? -1 : 1;
    final byHeadroom = headroom(b).compareTo(headroom(a));
    if (byHeadroom != 0) return byHeadroom;
    final byAccount = a.account.compareTo(b.account);
    if (byAccount != 0) return byAccount;
    final byCapture = b.asOf.compareTo(a.asOf);
    if (byCapture != 0) return byCapture;
    return a.sourceClass.wireName.compareTo(b.sourceClass.wireName);
  });
  return candidates.first;
}

/// Whether a local-runtime observation proves that its daemon is reachable now.
/// This says nothing about where a represented model executes: an Ollama
/// `-cloud` model is reachable through the daemon but is not on-device capacity.
bool isLocalRuntimeReachableAt(ProviderQuota quota, int now) =>
    quota.isLocal &&
    quota.ok &&
    !quota.stale &&
    quota.asOf > 0 &&
    quota.asOf <= now + kQuotaEvidenceClockSkewSeconds &&
    quota.sourceClassViolation == null;

/// Whether a local runtime supplies usable on-device capacity for provider
/// routing. A runtime whose represented models are all cloud-offloaded must not
/// satisfy local-first or local-fallback policy. Reachability without at least
/// one represented on-device model proves only that the daemon answered, not
/// that it can execute the next request.
bool isLocalRuntimeAvailableAt(ProviderQuota quota, int now) =>
    isLocalRuntimeReachableAt(quota, now) &&
    quota.error == null &&
    quota.models.any((model) => !model.cloudOffloaded);

/// Whether any provider can take work right now: a running local runtime, or a
/// metered subscription with headroom left. Lets a shell or agent branch on "is
/// there anywhere to route?" through the CLI exit code.
bool anyProviderUsable(List<ProviderQuota> quotas, int now) {
  for (final q in quotas) {
    if (q.isLocal) {
      if (isLocalRuntimeAvailableAt(q, now)) return true;
    } else if (providerAvailability(q, now).available) {
      return true;
    }
  }
  return false;
}

/// Returns the window that is currently the binding constraint, and whose reset
/// the display and "available again" logic should show.
///
/// While the provider still has headroom, that is the tightest (lowest-headroom)
/// window. Once it is spent, the binding constraint is instead the spent window
/// that resets *last*: the provider is not usable again until every spent window
/// has rolled over, so returning the soonest reset would understate the wait and
/// could name the wrong provider to wait for. A spent window with an unknown
/// reset is treated as furthest out, since its clear time is genuinely unknown.
QuotaWindow? bindingWindow(ProviderQuota q, int now) {
  if (q.windows.isEmpty) return null;
  final headroom = providerHeadroom(q, now);
  if (headroom == null) return null;
  final spent = headroom <= kSpentHeadroomFloor;
  if (spent) {
    QuotaWindow? latest;
    for (final w in q.windows) {
      if (quotaWindowHeadroom(q, w, now) > kSpentHeadroomFloor) continue;
      if (latest == null) {
        latest = w;
        continue;
      }
      final lr = latest.resetsAt;
      if (lr == null) continue; // current pick already unknown, i.e. furthest
      final wr = w.resetsAt;
      if (wr == null || wr > lr) latest = w;
    }
    return latest;
  }
  QuotaWindow? worst;
  double minRem = 100;
  for (final w in q.windows) {
    final remaining = quotaWindowHeadroom(q, w, now);
    if (remaining < minRem) {
      minRem = remaining;
      worst = w;
    }
  }
  return worst;
}

/// When a provider has collapsed to a spent binding window, the still-usable
/// longer window whose status the user still needs, or null.
///
/// A spent *short* window (a 5-hour cap) clears soon, so the real question is
/// whether a *longer* window (the weekly cap) still has room after it resets.
/// Returning that window lets the display show "5h spent, resets 3h" alongside
/// "weekly 42% used" instead of hiding the weekly entirely. The reverse case - a
/// spent weekly with a healthy 5-hour - returns null, because a green short
/// window under a spent long one is unusable and must stay hidden (the same
/// reason [bindingWindow] collapses it).
///
/// "Longer" is judged by reset time, and requires *both* resets to be known:
/// the candidate must be non-spent and reset strictly later than the spent
/// binding window. An unknown reset is not evidence of a longer period (unlike
/// in [bindingWindow], where an unknown clear time is conservatively the longest
/// wait), so a null-reset healthy window is never resurfaced under a spent one.
/// When several qualify, the latest-resetting one wins.
QuotaWindow? secondaryVisibleWindow(ProviderQuota q, int now) {
  final binding = bindingWindow(q, now);
  final bindingReset = binding?.resetsAt;
  if (binding == null || bindingReset == null) return null;
  final headroom = providerHeadroom(q, now);
  if (headroom == null || headroom > kSpentHeadroomFloor) return null;
  QuotaWindow? best;
  for (final w in q.windows) {
    if (identical(w, binding)) continue;
    if (quotaWindowHeadroom(q, w, now) <= kSpentHeadroomFloor) continue;
    final wr = w.resetsAt;
    if (wr == null || wr <= bindingReset) continue;
    if (best == null || wr > best.resetsAt!) best = w;
  }
  return best;
}

/// A ranked candidate in a routing suggestion.
class RouteCandidate {
  final String provider;
  final String account;
  final String? plan;
  final String? source;
  final ProviderSourceClass sourceClass;
  final bool isLocal;
  final int asOf;
  final bool perMachine;

  /// Remaining headroom percent (0..100). Local runtimes report 100.
  final double? headroom;

  /// Forward-looking headroom after discounting recent burn over the routing
  /// lead time: `clamp(headroom - max(0, burnPerHour) * leadHours, 0, 100)`.
  /// Equals [headroom] when no burn signal is available. Ranking and the comfort
  /// gate use this; [available] still reflects present [headroom].
  final double? effectiveHeadroom;

  /// Recent burn in percent of quota per hour used to discount [headroom], when
  /// history was available. Null when unknown; never set for local runtimes.
  final double? burnPerHour;

  /// Temporary routing reservation discount applied to [effectiveHeadroom].
  /// Reservations do not mutate provider data; they only nudge parallel callers
  /// away from the same currently attractive account.
  final double leaseDiscount;

  /// Recent provider/account pipe-health discount applied to
  /// [effectiveHeadroom], derived from local LiteLLM failure/throttle metadata
  /// or native provider metadata diagnostics. It is additive and fail-soft: raw
  /// [headroom] and [available] still reflect quota truth, while ranking
  /// accounts for likely request success.
  final double pipeDiscount;

  /// Standard error of [burnPerHour], when estimable. Null for local runtimes or
  /// when there were too few history points to estimate it.
  final double? burnSe;

  /// Probability the binding window is spent before it resets (0..1), from a
  /// first-passage forecast. Null when burn, its error, or the reset are unknown.
  final double? strandProbability;

  /// How much to trust this candidate's numbers, in (0, 1]: a blend of freshness
  /// (cached reads count less) and burn-estimate sample adequacy.
  final double? confidence;

  /// Confidence-weighted runway score used to rank metered subscriptions. Higher
  /// means a better risk-adjusted candidate. Null for local runtimes, which are
  /// handled by the explicit fallback and local-first policy instead of this
  /// subscription score.
  final double? routingScore;

  /// Risk-adjusted runway in hours before confidence is applied. This is the
  /// direct optimizer quantity behind [routingScore]; exposing it keeps the
  /// public score auditable instead of opaque.
  final double? runwayHours;

  /// Projected included quota percent that would expire unused at reset, when
  /// recent burn and a future reset make that measurable.
  final double? projectedWastePercent;

  /// Multiplier applied to the runway score to lean into measured quota that is
  /// likely to expire unused. Omitted when no boost applies.
  final double? wasteBoost;

  /// Caller-supplied relative cost penalty for this metered subscription. This
  /// is not inferred by quotabot and is omitted unless an explicit caller policy
  /// provides it.
  final double? costPenalty;

  /// Multiplier applied to discount costly routes when an explicit cost policy
  /// is active. Omitted when no discount applies.
  final double? costDiscount;

  /// Reset epoch of the binding window, when known.
  final int? resetsAt;

  /// Stable label of the quota pool that constrained this candidate.
  final String? bindingPool;

  /// True when the default provider-route capability floor has no matching
  /// catalog model for this provider/account.
  final bool capabilityLimited;

  /// True when a matching capable model exists, but its model-specific budget
  /// gate is not usable now.
  final bool capabilityBudgetLimited;

  final bool stale;

  /// Why fresh provider evidence was rejected. Headroom is last-trusted and
  /// stale when available, or null for a migrated legacy quarantine.
  final String? driftReason;

  /// Epoch seconds when [driftReason] was observed.
  final int? driftObservedAt;

  /// True when usable right now: local, or fresh cloud headroom above the
  /// "spent" floor. Stale cached cloud quotas are last-known evidence and are
  /// not available.
  final bool available;

  const RouteCandidate({
    required this.provider,
    required this.account,
    required this.plan,
    required this.source,
    required this.sourceClass,
    required this.isLocal,
    required this.asOf,
    required this.perMachine,
    required this.headroom,
    required this.effectiveHeadroom,
    required this.resetsAt,
    required this.stale,
    required this.available,
    this.bindingPool,
    this.driftReason,
    this.driftObservedAt,
    this.leaseDiscount = 0,
    this.pipeDiscount = 0,
    this.burnPerHour,
    this.burnSe,
    this.strandProbability,
    this.confidence,
    this.routingScore,
    this.runwayHours,
    this.projectedWastePercent,
    this.wasteBoost,
    this.costPenalty,
    this.costDiscount,
    this.capabilityLimited = false,
    this.capabilityBudgetLimited = false,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'account': account,
        if (plan != null) 'plan': plan,
        'source_class': sourceClass.wireName,
        'local': isLocal,
        'headroom_percent': headroom,
        'effective_headroom_percent': effectiveHeadroom,
        if (leaseDiscount > 0) 'lease_discount_percent': leaseDiscount,
        if (pipeDiscount > 0) 'pipe_discount_percent': pipeDiscount,
        if (burnPerHour != null) 'burn_percent_per_hour': burnPerHour,
        if (burnSe != null) 'burn_se_percent_per_hour': burnSe,
        if (strandProbability != null) 'strand_probability': strandProbability,
        if (confidence != null) 'confidence': confidence,
        if (routingScore != null) 'routing_score': routingScore,
        if (runwayHours != null) 'runway_hours': runwayHours,
        if (projectedWastePercent != null)
          'projected_waste_percent':
              double.parse(projectedWastePercent!.toStringAsFixed(1)),
        if (wasteBoost != null)
          'waste_boost': double.parse(wasteBoost!.toStringAsFixed(4)),
        if (costPenalty != null)
          'cost_penalty': double.parse(costPenalty!.toStringAsFixed(4)),
        if (costDiscount != null)
          'cost_discount': double.parse(costDiscount!.toStringAsFixed(4)),
        if (capabilityLimited) 'capability_limited': true,
        if (capabilityBudgetLimited) 'capability_budget_limited': true,
        if (bindingPool != null) 'binding_pool': bindingPool,
        if (resetsAt != null) 'resets_at': resetsAt,
        'stale': stale,
        if (driftReason != null) 'drift_reason': driftReason,
        if (driftObservedAt != null) 'drift_observed_at': driftObservedAt,
        'available': available,
      };

  bool get isManual => source == providerQuotaManualSource;

  String get spendClass => isLocal
      ? 'local'
      : isManual
          ? 'manual'
          : kQuotaPlanProviders.contains(provider)
              ? 'quota plan'
              : 'metered plan';

  String get spendClassWire => spendClass.replaceAll(' ', '_');

  String get spendRisk => switch (spendClassWire) {
        'local' => 'runtime_unverified',
        'manual' => 'self_reported',
        'quota_plan' => 'quota_plan',
        _ => 'metered',
      };
}

/// The closed set of fail-soft fallback actions quotabot can recommend.
enum RouteFallbackKind {
  local('local'),
  soonestReset('soonest_reset'),
  passthrough('passthrough');

  final String wireName;

  const RouteFallbackKind(this.wireName);
}

/// The fail-soft next step in a [RouteSuggestion]: what to do if the caller
/// skips the recommendation, or there is no usable recommendation at all. Always
/// present, so quotabot never leaves a caller without an actionable answer.
class RouteFallback {
  final RouteFallbackKind kind;

  /// The local runtime, or the soonest-resetting provider, when applicable.
  final String? provider;

  /// Reset epoch of [provider], for the 'soonest_reset' kind.
  final int? resetsAt;

  /// One-line human explanation.
  final String reason;

  const RouteFallback({
    required this.kind,
    this.provider,
    this.resetsAt,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        if (provider != null) 'provider': provider,
        if (resetsAt != null) 'resets_at': resetsAt,
        'reason': reason,
      };
}

/// A routing recommendation: which provider to use next, ranked alternatives,
/// a short human reason, and a guaranteed fail-soft [fallback]. Pure result of
/// [suggestRoute].
class RouteSuggestion {
  /// The recommended provider, or null when nothing is usable.
  final RouteCandidate? recommended;

  /// All candidates, best first. Subscriptions ranked by headroom, then locals.
  final List<RouteCandidate> ranked;

  /// One-line human explanation of the recommendation.
  final String reason;

  /// Stable, low-cardinality outcome that explains which policy branch won.
  final RouteDecisionCode decisionCode;

  /// True when the recommendation is a local fallback because every metered
  /// subscription is spent or below the comfort threshold.
  final bool usingLocalFallback;

  /// Always-present next step if the recommendation is skipped or null.
  final RouteFallback fallback;

  /// Epoch seconds the decision was made, for provenance (callers can age it).
  final int asOf;

  /// The risk aversion used: 0 ranks on mean headroom, higher discounts
  /// uncertain (high burn-error) providers more. Echoed so callers know the mode.
  final double riskZ;

  /// The routing policy used for this decision. `balanced` preserves the normal
  /// paid-headroom-first behavior; `local_first` is an explicit caller request
  /// to use a local runtime before spending subscription quota.
  final String routingPolicy;

  /// Weight applied to the projected-waste multiplier in the routing score.
  final double wasteWeight;

  /// Projected-waste floor required before a route gets a waste boost.
  final double wasteThresholdPercent;

  /// Reset horizon, in hours, for projected-waste route boosting.
  final int wasteMaxHours;

  /// Weight applied to caller-supplied cost penalties in the routing score.
  final double costWeight;

  /// Effective-headroom floor required for the normal comfortable route.
  final double comfortThreshold;

  /// Planning horizon used for the burn and risk adjustment.
  final double leadHours;

  /// Provenance of the snapshot evaluated by this decision.
  final String snapshotSource;
  final int? snapshotAsOf;
  final bool snapshotStale;

  const RouteSuggestion({
    required this.recommended,
    required this.ranked,
    required this.reason,
    required this.decisionCode,
    required this.usingLocalFallback,
    required this.fallback,
    required this.asOf,
    required this.riskZ,
    this.routingPolicy = 'balanced',
    this.wasteWeight = kDefaultRoutingWasteWeight,
    this.wasteThresholdPercent = kDefaultExpiringQuotaWasteThreshold,
    this.wasteMaxHours = kDefaultExpiringQuotaMaxHours,
    this.costWeight = kDefaultRoutingCostWeight,
    this.comfortThreshold = 15,
    this.leadHours = 1,
    this.snapshotSource = 'live',
    this.snapshotAsOf,
    this.snapshotStale = false,
  });

  /// A shared plain-language answer to what won, why, evidence trust and age,
  /// spend classification, and the fail-soft fallback.
  String get explanation {
    final parts = <String>[reason];
    final winner = recommended;
    if (winner != null) {
      final age = (asOf - winner.asOf).clamp(0, 1 << 31).toInt();
      final state = switch (snapshotSource) {
        'disk' => 'cached disk',
        'memory' => 'cached memory',
        'simulation' => 'simulation',
        _ => winner.driftReason != null
            ? 'provider drift'
            : winner.stale
                ? 'cached'
                : 'live',
      };
      final ageLabel = age < 1 ? 'just now' : 'captured ${age}s ago';
      parts.add(
        'Evidence: $state ${winner.sourceClass.label}, $ageLabel.',
      );
      if (winner.bindingPool != null) {
        parts.add('Binding pool: ${winner.bindingPool}.');
      }
      parts.add(switch (winner.spendRisk) {
        'runtime_unverified' =>
          'Spend: runtime classified; execution location and cost are not independently verified.',
        'self_reported' => 'Spend: self-reported manual budget.',
        'quota_plan' => 'Spend: measured quota-plan budget.',
        _ => 'Spend: metered plan; this route may create metered spend.',
      });
    }
    parts.add('Fallback: ${fallback.reason}');
    return parts.join(' ');
  }

  RouteDecisionReceipt get receipt => _decisionReceiptFor(this);

  Map<String, dynamic> toJson() => {
        'schema': 'quotabot.suggest.v1',
        'as_of': asOf,
        'decision_code': decisionCode.wireName,
        'risk_z': riskZ,
        'routing_policy': routingPolicy,
        'waste_weight': wasteWeight,
        'waste_threshold_percent': wasteThresholdPercent,
        'waste_max_hours': wasteMaxHours,
        'cost_weight': costWeight,
        'recommended': recommended?.toJson(),
        'reason': reason,
        'explanation': explanation,
        'using_local_fallback': usingLocalFallback,
        'fallback': fallback.toJson(),
        'ranked': ranked.map((c) => c.toJson()).toList(),
        'receipt': receipt.toJson(),
      };
}

RouteDecisionReceipt _decisionReceiptFor(RouteSuggestion suggestion) {
  RouteCandidateReceipt candidateReceipt(RouteCandidate candidate) {
    final raw = candidate.headroom;
    final effective = candidate.effectiveHeadroom;
    final adjustments = <RouteAdjustmentReceipt>[];
    if (raw != null && effective != null) {
      final burnRisk =
          raw - effective - candidate.leaseDiscount - candidate.pipeDiscount;
      if (burnRisk > 0.0001) {
        adjustments.add(RouteAdjustmentReceipt(
          kind: RouteAdjustmentKind.burnRisk,
          value: burnRisk,
        ));
      }
    }
    if (candidate.leaseDiscount > 0) {
      adjustments.add(RouteAdjustmentReceipt(
        kind: RouteAdjustmentKind.lease,
        value: candidate.leaseDiscount,
      ));
    }
    if (candidate.pipeDiscount > 0) {
      adjustments.add(RouteAdjustmentReceipt(
        kind: RouteAdjustmentKind.pipeHealth,
        value: candidate.pipeDiscount,
      ));
    }
    final confidence = candidate.confidence;
    if (confidence != null && confidence < 0.9999) {
      adjustments.add(RouteAdjustmentReceipt(
        kind: RouteAdjustmentKind.confidence,
        value: confidence,
      ));
    }
    final wasteBoost = candidate.wasteBoost;
    if (wasteBoost != null && wasteBoost > 1) {
      adjustments.add(RouteAdjustmentReceipt(
        kind: RouteAdjustmentKind.projectedWaste,
        value: wasteBoost,
      ));
    }
    final costDiscount = candidate.costDiscount;
    if (costDiscount != null && costDiscount < 1) {
      adjustments.add(RouteAdjustmentReceipt(
        kind: RouteAdjustmentKind.cost,
        value: costDiscount,
      ));
    }

    final confidenceReasons = <String>[];
    if (candidate.driftReason != null) {
      confidenceReasons.add('provider_drift');
    }
    if (candidate.stale) confidenceReasons.add('stale_evidence');
    if (candidate.perMachine) confidenceReasons.add('machine_scoped');
    if (candidate.isManual) confidenceReasons.add('self_reported');
    if (confidence != null &&
        confidence < 0.9999 &&
        confidenceReasons.isEmpty) {
      confidenceReasons.add('limited_history_or_age');
    }
    if (confidenceReasons.isEmpty) confidenceReasons.add('no_discount');

    return RouteCandidateReceipt(
      provider: candidate.provider,
      account: candidate.account,
      sourceClass: candidate.sourceClass.wireName,
      spendClass: candidate.spendClassWire,
      spendRisk: candidate.spendRisk,
      bindingPool: candidate.bindingPool,
      rawHeadroomPercent: candidate.headroom,
      effectiveHeadroomPercent: candidate.effectiveHeadroom,
      evidenceAsOf: candidate.asOf,
      evidenceAgeSeconds:
          (suggestion.asOf - candidate.asOf).clamp(0, 1 << 31).toInt(),
      resetsAt: candidate.resetsAt,
      available: candidate.available,
      stale: candidate.stale,
      confidence: candidate.confidence,
      confidenceReasons: confidenceReasons,
      verdict: _receiptVerdict(candidate, suggestion),
      adjustments: adjustments,
    );
  }

  RouteCandidateReceipt? winner;
  final alternatives = <RouteCandidateReceipt>[];
  for (final candidate in suggestion.ranked) {
    final receipt = candidateReceipt(candidate);
    if (identical(candidate, suggestion.recommended)) {
      winner = receipt;
    } else {
      alternatives.add(receipt);
    }
  }
  final snapshotAsOf = suggestion.snapshotAsOf;
  return RouteDecisionReceipt.create(
    asOf: suggestion.asOf,
    outcome: suggestion.decisionCode,
    explanation: suggestion.explanation,
    snapshot: RouteSnapshotReceipt(
      source: suggestion.snapshotSource,
      asOf: snapshotAsOf,
      ageSeconds: snapshotAsOf == null
          ? null
          : (suggestion.asOf - snapshotAsOf).clamp(0, 1 << 31).toInt(),
      stale: suggestion.snapshotStale,
    ),
    policy: RoutePolicyReceipt(
      routing: suggestion.routingPolicy,
      spendOrder: suggestion.routingPolicy == 'local_first'
          ? const ['local', 'subscription']
          : const ['subscription', 'local_fallback'],
      comfortThresholdPercent: suggestion.comfortThreshold,
      leadHours: suggestion.leadHours,
      riskZ: suggestion.riskZ,
    ),
    winner: winner,
    alternatives: alternatives,
    fallback: RouteFallbackReceipt(
      kind: suggestion.fallback.kind.wireName,
      provider: suggestion.fallback.provider,
      resetsAt: suggestion.fallback.resetsAt,
      reason: suggestion.fallback.reason,
    ),
  );
}

RouteCandidateVerdict _receiptVerdict(
  RouteCandidate candidate,
  RouteSuggestion suggestion,
) {
  if (identical(candidate, suggestion.recommended)) {
    return RouteCandidateVerdict.selected;
  }
  if (candidate.driftReason != null) {
    return RouteCandidateVerdict.providerDrift;
  }
  if (candidate.stale) return RouteCandidateVerdict.stale;
  if (candidate.capabilityLimited) {
    return RouteCandidateVerdict.noCapableModel;
  }
  if (candidate.capabilityBudgetLimited) {
    return RouteCandidateVerdict.modelBudgetSpent;
  }
  if (!candidate.available) {
    return (candidate.headroom ?? 0) <= kSpentHeadroomFloor
        ? RouteCandidateVerdict.spent
        : RouteCandidateVerdict.unavailable;
  }
  if (!candidate.isLocal &&
      (candidate.headroom ?? 0) > kSpentHeadroomFloor &&
      (candidate.effectiveHeadroom ?? 0) <= kSpentHeadroomFloor) {
    return RouteCandidateVerdict.adjustedHeadroomDepleted;
  }
  if (candidate.isLocal && suggestion.recommended?.isLocal != true) {
    return RouteCandidateVerdict.localFallbackOnly;
  }
  if (!candidate.isLocal &&
      (candidate.effectiveHeadroom ?? 0) < suggestion.comfortThreshold) {
    return RouteCandidateVerdict.belowComfort;
  }
  if (suggestion.decisionCode == RouteDecisionCode.preferredProvider) {
    return RouteCandidateVerdict.lowerPreference;
  }
  return RouteCandidateVerdict.lowerRunway;
}

/// Builds the always-present fail-soft fallback from the available candidates:
/// a running local runtime if present, else the soonest-resetting subscription
/// with a known matching capability, else a passthrough to the model the caller
/// requested.
RouteFallback _fallbackFor(
  List<RouteCandidate> subs,
  List<RouteCandidate> locals,
) {
  if (locals.isNotEmpty) {
    final l = locals.first;
    return RouteFallback(
      kind: RouteFallbackKind.local,
      provider: l.provider,
      reason: 'Skip the pick? ${l.provider} is reachable through a '
          'local-runtime adapter; execution location and cost are not '
          'independently verified.',
    );
  }
  final resetting = subs
      .where((c) => !c.stale && !c.capabilityLimited && c.resetsAt != null)
      .toList()
    ..sort((a, b) => a.resetsAt!.compareTo(b.resetsAt!));
  if (resetting.isNotEmpty) {
    final s = resetting.first;
    return RouteFallback(
      kind: RouteFallbackKind.soonestReset,
      provider: s.provider,
      resetsAt: s.resetsAt,
      reason: '${s.provider} resets soonest - wait for it.',
    );
  }
  return const RouteFallback(
    kind: RouteFallbackKind.passthrough,
    reason: 'No quota signal - use the model you requested.',
  );
}

/// A short ", ~N% after burn" note when recent burn materially discounts a
/// candidate's headroom (by at least one point), else an empty string.
String _effectiveHeadroomNote(RouteCandidate c) {
  final h = c.headroom, e = c.effectiveHeadroom;
  if (h == null || e == null) return '';
  if ((c.burnPerHour == null || c.burnPerHour! <= 0) &&
      c.leaseDiscount <= 0 &&
      c.pipeDiscount <= 0) {
    return '';
  }
  if (h - e < 1) return '';
  final causes = _effectiveHeadroomCauses(c);
  return ', ~${e.round()}% after ${causes.join('/')}';
}

List<String> _effectiveHeadroomCauses(RouteCandidate c) => <String>[
      if (c.burnPerHour != null && c.burnPerHour! > 0) 'burn',
      if (c.leaseDiscount > 0) 'leases',
      if (c.pipeDiscount > 0) 'pipe',
    ];

String _localFallbackSubscriptionNote(RouteCandidate? candidate) {
  if (candidate == null) return '';
  final headroom = candidate.headroom?.round();
  if (candidate.driftReason != null) {
    return headroom == null
        ? ' (${candidate.provider} provider drift has no trusted headroom)'
        : ' (${candidate.provider} provider drift; last-trusted headroom '
            '$headroom%)';
  }
  if (candidate.stale) {
    return ' (best subscription ${candidate.provider} has cached last-known '
        'headroom ${headroom ?? 0}%)';
  }
  return ' (best subscription ${candidate.provider} only '
      '${headroom ?? 0}% free)';
}

/// Floor burn, in percent of quota per hour, used to convert headroom into a
/// finite runway score when burn is unknown or effectively flat.
const double _burnFloorPercentPerHour = 1.0;

/// Default use-it-or-lose-it route boost. A full projected-waste fraction raises
/// the score by 25%, enough to break ties without overriding safety gates.
const double kDefaultRoutingWasteWeight = 0.25;

/// Default caller-supplied cost penalty weight. Zero means quotabot never
/// invents cost preferences; callers must opt into cost-aware ranking.
const double kDefaultRoutingCostWeight = 0.0;

/// Maximum accepted caller-supplied cost penalty weight.
const double kMaxRoutingCostWeight = 10.0;

/// The optimizer provenance behind a metered subscription's route score.
class RoutingScoreBreakdown {
  /// Risk-adjusted runway before trust is applied.
  final double runwayHours;

  /// Trust multiplier applied to [runwayHours].
  final double confidence;

  /// Projected-waste fraction of remaining headroom, 0..1.
  final double wasteFraction;

  /// Use-it-or-lose-it multiplier applied after confidence.
  final double wasteBoost;

  /// Caller-supplied relative cost penalty.
  final double costPenalty;

  /// Discount multiplier applied after waste when an explicit cost policy is
  /// active. 1 means no cost discount.
  final double costDiscount;

  /// Final score used for subscription ranking.
  final double score;

  const RoutingScoreBreakdown({
    required this.runwayHours,
    required this.confidence,
    required this.wasteFraction,
    required this.wasteBoost,
    required this.costPenalty,
    required this.costDiscount,
    required this.score,
  });
}

/// Headroom discounted by the expected burn over [leadHours] and, when [z] > 0
/// and a burn standard error [burnSe] is known, by [z] standard deviations of
/// forecast uncertainty (`z * burnSe * leadHours`). At `z = 0` this is exactly
/// `headroom - burn * leadHours`, the risk-neutral effective headroom we already
/// ship, so a caller that does not opt into risk sees identical numbers.
double riskAdjustedHeadroom(
  double headroom,
  double? burn,
  double? burnSe,
  double leadHours,
  double z,
) {
  final b = (burn != null && burn > 0) ? burn : 0.0;
  final risk = (z > 0 && burnSe != null) ? z * burnSe * leadHours : 0.0;
  return (headroom - b * leadHours - risk).clamp(0.0, 100.0);
}

/// Confidence-weighted runway score for ranking metered subscriptions.
///
/// The numerator is already the risk-adjusted effective headroom after burn,
/// forecast uncertainty, and active local lease discounts. The denominator is
/// recent burn, floored so calm or unknown burn stays finite and comparable.
/// The confidence factor folds in stale reads, manual entries, and thin burn
/// estimates. Local runtimes return null because balanced routing treats them
/// as a fallback, not as metered subscriptions competing on quota runway.
double? routingScore({
  required bool isLocal,
  double? headroom,
  required double? effectiveHeadroom,
  required double? burnPerHour,
  required double? confidence,
  double? projectedWastePercent,
  double wasteWeight = kDefaultRoutingWasteWeight,
  double costPenalty = 0,
  double costWeight = kDefaultRoutingCostWeight,
}) =>
    routingScoreBreakdown(
      isLocal: isLocal,
      headroom: headroom,
      effectiveHeadroom: effectiveHeadroom,
      burnPerHour: burnPerHour,
      confidence: confidence,
      projectedWastePercent: projectedWastePercent,
      wasteWeight: wasteWeight,
      costPenalty: costPenalty,
      costWeight: costWeight,
    )?.score;

/// Returns the route score and its first optimizer components for metered
/// subscriptions. Local runtimes return null because they are handled by the
/// explicit fallback or local-first policy, not the subscription index.
RoutingScoreBreakdown? routingScoreBreakdown({
  required bool isLocal,
  double? headroom,
  required double? effectiveHeadroom,
  required double? burnPerHour,
  required double? confidence,
  double? projectedWastePercent,
  double wasteWeight = kDefaultRoutingWasteWeight,
  double costPenalty = 0,
  double costWeight = kDefaultRoutingCostWeight,
}) {
  if (isLocal || effectiveHeadroom == null) return null;
  final effective = effectiveHeadroom.clamp(0.0, 100.0).toDouble();
  final rawHeadroom = (headroom ?? effectiveHeadroom).clamp(0.0, 100.0);
  final burn = burnPerHour != null && burnPerHour > 0
      ? burnPerHour
      : _burnFloorPercentPerHour;
  final runwayHours = effective / math.max(burn, _burnFloorPercentPerHour);
  final trust = (confidence ?? 0.6).clamp(0.0, 1.0).toDouble();
  final waste = (projectedWastePercent ?? 0).clamp(0.0, 100.0).toDouble();
  final wasteFraction =
      rawHeadroom <= 0 ? 0.0 : (waste / rawHeadroom).clamp(0.0, 1.0).toDouble();
  final wasteBoost = 1 + math.max(0.0, wasteWeight) * wasteFraction;
  final penalty =
      costPenalty.isFinite ? costPenalty.clamp(0.0, 100.0).toDouble() : 0.0;
  final weight = costWeight.isFinite
      ? costWeight.clamp(0.0, kMaxRoutingCostWeight).toDouble()
      : 0.0;
  final costDiscount = 1 / (1 + weight * penalty);
  return RoutingScoreBreakdown(
    runwayHours: runwayHours,
    confidence: trust,
    wasteFraction: wasteFraction,
    wasteBoost: wasteBoost,
    costPenalty: penalty,
    costDiscount: costDiscount,
    score: runwayHours * trust * wasteBoost * costDiscount,
  );
}

/// Probability the binding window is spent before it resets, from a Gaussian
/// first-passage approximation: `Phi((burn * T - headroom) / (burnSe * T))` with
/// `T` the hours to reset. Null when burn, its error, or the reset are unknown,
/// or when there is no burn (nothing to deplete it).
double? strandProbability(
  double headroom,
  double? burn,
  double? burnSe,
  int? resetsAt,
  int now,
) {
  if (burn == null || burn <= 0 || burnSe == null || resetsAt == null) {
    return null;
  }
  final tHours = (resetsAt - now) / 3600.0;
  if (tHours <= 0) return null;
  final sd = burnSe * tHours;
  if (sd <= 0) return burn * tHours >= headroom ? 1.0 : 0.0;
  return _normalCdf((burn * tHours - headroom) / sd);
}

/// A strand probability must reach this before it leads a forecast; below it the
/// risk is too faint to state plainly.
const double _strandMateriality = 0.15;

/// At or above this strand probability a window is judged more likely than not
/// to be spent before it resets, which is the most urgent forecast severity.
const double _strandLikely = 0.5;

/// Minimum burn (percent of quota per hour) for a runway estimate to be worth
/// stating; a window draining slower than this is effectively calm.
const double _visibleBurnPerHour = 0.5;

/// The kind of forward-looking statement a window's forecast makes.
enum ForecastKind {
  /// At material risk of being spent before it resets; the lead number is a
  /// probability.
  strand,

  /// Visibly draining but not at strand risk; the lead number is an estimated
  /// runway (hours of usage left at the current burn).
  timeToEmpty,
}

/// One window's forward-looking forecast: the shared decision behind every
/// surface's forecast note (the `top` dashboard and the desktop widget). It
/// carries the classification and the lead number, not the wording, so each
/// surface phrases it in its own register from a single source of truth. Built
/// by [classifyForecast]; null there means there is no signal to forecast.
class WindowForecast {
  final ForecastKind kind;

  /// Set when [kind] is [ForecastKind.strand]: the chance (0..1) the window is
  /// spent before it resets.
  final double? strandProbability;

  /// Set when [kind] is [ForecastKind.timeToEmpty]: estimated hours of usage
  /// left at the current burn.
  final double? hoursToEmpty;

  /// Urgency for coloring: 0 informational, 1 worth watching, 2 likely to strand.
  final int severity;

  const WindowForecast._({
    required this.kind,
    required this.severity,
    this.strandProbability,
    this.hoursToEmpty,
  });
}

/// Classifies a window's forward-looking forecast from its already-computed
/// [strandProbability] (see the function of the same name) and its current
/// [burnPerHour] and [headroom]. A material strand risk leads; otherwise a
/// visible burn gives a runway estimate; a calm window gets nothing (null), so
/// quotabot never invents a forecast where there is no signal. Pure, so the CLI
/// and the widget share one decision and differ only in how they word it.
WindowForecast? classifyForecast({
  required double? strandProbability,
  required double? burnPerHour,
  required double? headroom,
}) {
  final strand = strandProbability;
  if (strand != null && strand >= _strandMateriality) {
    return WindowForecast._(
      kind: ForecastKind.strand,
      strandProbability: strand,
      severity: strand >= _strandLikely ? 2 : 1,
    );
  }
  if (burnPerHour != null &&
      burnPerHour > _visibleBurnPerHour &&
      headroom != null &&
      headroom > 0) {
    return WindowForecast._(
      kind: ForecastKind.timeToEmpty,
      hoursToEmpty: headroom / burnPerHour,
      severity: 0,
    );
  }
  return null;
}

/// How much to trust a candidate's numbers, in (0, 1]: a stale (cached) read is
/// half-trusted, and a metered provider's burn estimate is weighted by sample
/// adequacy `n / (n + 4)` (a shrinkage prior, so a two-point fit is not trusted
/// like a twenty-point one). Local runtimes need no burn, so only freshness.
double _confidence(ProviderQuota q, double? burnSe, int samples, int now) {
  final fresh = q.isLocal || isTrustedQuotaEvidenceAt(q, now) ? 1.0 : 0.5;
  if (q.isLocal) return fresh;
  if (q.isManual) return fresh * 0.35;
  final adequacy = burnSe == null ? 0.6 : samples / (samples + 4);
  final provenance = q.sourceClass.isMachineScoped
      ? kMachineScopedEvidenceConfidenceFactor
      : 1.0;
  return (fresh * adequacy * provenance).clamp(0.0, 1.0).toDouble();
}

/// Standard normal CDF via the Abramowitz & Stegun 7.1.26 erf approximation
/// (max abs error ~1.5e-7), so routing needs no statistics dependency.
double _normalCdf(double x) => 0.5 * (1 + _erf(x / math.sqrt2));

double _erf(double x) {
  final sign = x < 0 ? -1.0 : 1.0;
  final ax = x.abs();
  final t = 1.0 / (1.0 + 0.3275911 * ax);
  final y = 1.0 -
      (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t -
                      0.284496736) *
                  t +
              0.254829592) *
          t *
          math.exp(-ax * ax);
  return sign * y;
}

int _compareSubscriptionCandidates(RouteCandidate a, RouteCandidate b) {
  if (a.stale != b.stale) return a.stale ? 1 : -1;
  if (a.available != b.available) return a.available ? -1 : 1;
  final score = (b.routingScore ?? -1).compareTo(a.routingScore ?? -1);
  if (score != 0) return score;
  final effective =
      (b.effectiveHeadroom ?? -1).compareTo(a.effectiveHeadroom ?? -1);
  if (effective != 0) return effective;
  final raw = (b.headroom ?? -1).compareTo(a.headroom ?? -1);
  if (raw != 0) return raw;
  final provider = a.provider.compareTo(b.provider);
  if (provider != 0) return provider;
  return a.account.compareTo(b.account);
}

/// Recommends where to route the next request.
///
/// Policy: prefer the metered subscription with the strongest risk-adjusted
/// runway score, as long as it clears [comfortThreshold] percent after burn and
/// leases (so we don't burn the last sliver of a cap). If no subscription clears
/// the threshold, recommend an available runtime-classified fallback. Adapter
/// reachability alone does not prove execution location or cost. If there is no
/// local fallback either, recommend the least-bad
/// fresh subscription that still has headroom above the spent floor; otherwise
/// the one that resets soonest. Cached stale windows remain visible in ranked
/// evidence but are never recommended as usable capacity.
///
/// The comfort gate uses *effective* headroom: present headroom
/// discounted by each provider's recent burn over the [leadHours] planning
/// horizon ([burnByProvider], percent of quota per hour). Account-scoped
/// [burnStatsByProvider] entries are preferred when present. A provider being
/// drawn down fast is therefore a less safe pick than its instantaneous headroom
/// suggests. Ranking uses [routingScore], a confidence-weighted runway derived
/// from that same effective headroom, with a modest projected-waste multiplier
/// when local burn evidence says included quota would otherwise expire unused.
/// Availability still reflects present headroom on a fresh read: a provider
/// with quota now is usable now, just ranked lower.
///
/// Local runtimes never "win" on headroom (they would always read 100%); they
/// are only chosen when the paid budget is too tight to be comfortable.
/// Among already-viable, score-ordered [viable] candidates, the one the user's
/// [preferenceOrder] ranks highest (earliest in the list wins). Returns null
/// when the preference is empty or names none of the viable providers, so the
/// caller keeps its score-based pick.
///
/// Preference reorders only genuinely viable options - the caller passes the
/// available, above-comfort set - so it can never revive an unavailable, spent,
/// or spend-blocked route; it just breaks the choice among ones already worth
/// picking. Iteration is stable and a rank must strictly improve to win, so
/// several accounts of one preferred provider keep their incoming score order.
RouteCandidate? preferredViableCandidate(
  List<RouteCandidate> viable,
  List<String> preferenceOrder,
) {
  if (preferenceOrder.isEmpty) return null;
  RouteCandidate? best;
  var bestRank = preferenceOrder.length;
  for (final c in viable) {
    final rank = preferenceOrder.indexOf(c.provider);
    if (rank >= 0 && rank < bestRank) {
      bestRank = rank;
      best = c;
    }
  }
  return best;
}

/// The capability-gate verdict for one routing candidate. A gate is only present
/// when the caller supplied capability key sets. [limited] means no catalog model
/// meets the requirement floor for this account (routed around entirely);
/// [budgetLimited] means a capable model exists but its model budget is spent.
/// [resetsAt] is the reset the candidate should surface: none while capability
/// limited, the model-budget reset while budget limited, else the normal
/// availability reset.
({bool limited, bool budgetLimited, bool blocked, int? resetsAt})
    capabilityVerdict(
  ProviderQuota q, {
  required String quotaKey,
  required Set<String>? knownQuotaKeys,
  required Set<String>? availableQuotaKeys,
  required Map<String, int> budgetResetByQuotaKey,
  required int? availabilityResetsAt,
}) {
  // Either set alone still defines the gate; fall back to the other when one is
  // absent so a caller may supply only "known" or only "available".
  final known = knownQuotaKeys ?? availableQuotaKeys;
  final available = availableQuotaKeys ?? knownQuotaKeys;
  final hasGate = !q.isLocal && (known != null || available != null);
  final limited = hasGate && !(known?.contains(quotaKey) ?? false);
  final budgetLimited =
      hasGate && !limited && !(available?.contains(quotaKey) ?? false);
  return (
    limited: limited,
    budgetLimited: budgetLimited,
    blocked: limited || budgetLimited,
    resetsAt: limited
        ? null
        : budgetLimited
            ? budgetResetByQuotaKey[quotaKey]
            : availabilityResetsAt,
  );
}

RouteSuggestion suggestRoute(
  List<ProviderQuota> quotas,
  int now, {
  double comfortThreshold = 15,
  Map<String, double?> burnByProvider = const {},
  double leadHours = 1.0,
  Map<String, BurnStat> burnStatsByProvider = const {},
  double riskZ = 0,
  LeaseDiscountProvider leaseDiscountFor = _noLeaseDiscount,
  bool preferLocal = false,
  double wasteWeight = kDefaultRoutingWasteWeight,
  double wasteThresholdPercent = kDefaultExpiringQuotaWasteThreshold,
  int wasteMaxHours = kDefaultExpiringQuotaMaxHours,
  Map<String, double> costPenaltyByProvider = const {},
  double costWeight = kDefaultRoutingCostWeight,
  Map<String, double> pipePenaltyByProvider = const {},
  Set<String>? capabilityKnownQuotaKeys,
  Set<String>? capabilityAvailableQuotaKeys,
  Map<String, int> capabilityBudgetResetByQuotaKey = const {},
  Map<String, double> capabilityHeadroomByQuotaKey = const {},
  List<String> preferenceOrder = const [],
  String snapshotSource = 'live',
  int? snapshotAsOf,
  bool? snapshotStale,
}) {
  final measuredProviderCounts = <String, int>{};
  for (final q in quotas) {
    if (q.isLocal || q.isManual || !isTrustedQuotaEvidenceAt(q, now)) {
      continue;
    }
    measuredProviderCounts[q.provider] =
        (measuredProviderCounts[q.provider] ?? 0) + 1;
  }

  RouteCandidate toCandidate(ProviderQuota q) {
    final a = providerAvailability(q, now);
    final binding = q.isLocal ? null : bindingWindow(q, now);
    final headroom = q.isLocal ? 100.0 : a.headroom;
    final quotaKey = quotaIdentityKeyFor(q);
    final cap = capabilityVerdict(
      q,
      quotaKey: quotaKey,
      knownQuotaKeys: capabilityKnownQuotaKeys,
      availableQuotaKeys: capabilityAvailableQuotaKeys,
      budgetResetByQuotaKey: capabilityBudgetResetByQuotaKey,
      availabilityResetsAt: a.resetsAt,
    );
    final capabilityLimited = cap.limited;
    final capabilityBudgetLimited = cap.budgetLimited;
    final capabilityBlocked = cap.blocked;
    final rawCapabilityHeadroom = capabilityHeadroomByQuotaKey[quotaKey];
    // Capability-scoped headroom is supplied only when the model registry has
    // proved an eligible current model pool. It may replace a provider's
    // synthetic worst-pool summary, but never revive stale, drifted, unknown, or
    // otherwise blocked evidence.
    final capabilityHeadroom = !q.isLocal &&
            !capabilityBlocked &&
            (capabilityAvailableQuotaKeys?.contains(quotaKey) ?? false) &&
            isTrustedQuotaEvidenceAt(q, now) &&
            rawCapabilityHeadroom != null &&
            rawCapabilityHeadroom.isFinite &&
            rawCapabilityHeadroom >= 0 &&
            rawCapabilityHeadroom <= 100
        ? rawCapabilityHeadroom
        : null;
    final routeHeadroom = capabilityHeadroom ?? headroom;
    final routeAvailable = capabilityHeadroom == null
        ? a.available
        : capabilityHeadroom > kSpentHeadroomFloor;
    // The synthetic provider reset can belong to the unrelated tightest model.
    // Until capability gates carry the selected pool's reset, omit it instead of
    // attaching false precision to the overridden model-budget headroom.
    final candidateResetsAt = capabilityHeadroom == null ? cap.resetsAt : null;
    final accountStat = q.isLocal ? null : burnStatsByProvider[quotaKey];
    final providerStat = q.isLocal ? null : burnStatsByProvider[q.provider];
    final stat = q.isLocal ? null : (accountStat ?? providerStat);
    final burn =
        q.isLocal ? null : (stat?.perHour ?? burnByProvider[q.provider]);
    final burnSe = stat?.sePerHour;
    final samples = stat?.samples ?? 0;
    final leaseDiscount = q.isLocal
        ? 0.0
        : leaseDiscountFor(q.provider, q.account).clamp(0.0, 100.0).toDouble();
    final pipeDiscount = q.isLocal
        ? 0.0
        : math.max(
            _pipePenaltyFor(q, pipePenaltyByProvider),
            _nativePipePenaltyFor(q),
          );
    final effective = capabilityBlocked || routeHeadroom == null
        ? null
        : (riskAdjustedHeadroom(
                  routeHeadroom,
                  burn,
                  burnSe,
                  leadHours,
                  riskZ,
                ) -
                leaseDiscount -
                pipeDiscount)
            .clamp(0.0, 100.0)
            .toDouble();
    final strand = routeHeadroom == null
        ? null
        : strandProbability(
            routeHeadroom,
            burn,
            burnSe,
            candidateResetsAt,
            now,
          );
    final confidence = _confidence(q, burnSe, samples, now);
    final wasteBurn = accountStat ??
        ((measuredProviderCounts[q.provider] ?? 0) == 1 ? providerStat : null);
    final projectedWaste = _projectedWastePercent(
      q,
      (
        available: routeAvailable && !capabilityBlocked,
        headroom: routeHeadroom,
        resetsAt: candidateResetsAt,
      ),
      routeHeadroom,
      wasteBurn?.perHour,
      now,
      thresholdPercent: wasteThresholdPercent,
      maxHoursToReset: wasteMaxHours,
    );
    final rawCostPenalty = q.isLocal
        ? 0.0
        : (costPenaltyByProvider[quotaIdentityKeyFor(q)] ??
            costPenaltyByProvider[q.provider] ??
            0.0);
    final costPenalty = rawCostPenalty.isFinite
        ? rawCostPenalty.clamp(0.0, 100.0).toDouble()
        : 0.0;
    final score = routingScoreBreakdown(
      isLocal: q.isLocal,
      headroom: routeHeadroom,
      effectiveHeadroom: effective,
      burnPerHour: burn,
      confidence: confidence,
      projectedWastePercent: projectedWaste,
      wasteWeight: wasteWeight,
      costPenalty: costPenalty,
      costWeight: costWeight,
    );
    return RouteCandidate(
      provider: q.provider,
      account: q.account,
      plan: q.plan,
      source: q.source,
      sourceClass: q.sourceClass,
      isLocal: q.isLocal,
      asOf: q.asOf,
      perMachine: q.perMachine,
      headroom: routeHeadroom,
      effectiveHeadroom: effective,
      burnPerHour: burn,
      burnSe: burnSe,
      strandProbability: strand,
      confidence: confidence,
      routingScore: score?.score,
      runwayHours: score?.runwayHours,
      projectedWastePercent: projectedWaste,
      wasteBoost:
          score == null || score.wasteBoost <= 1 ? null : score.wasteBoost,
      costPenalty: costPenalty > 0 ? costPenalty : null,
      costDiscount:
          score == null || score.costDiscount >= 1 ? null : score.costDiscount,
      bindingPool: q.isLocal
          ? 'runtime'
          : capabilityHeadroom != null
              ? 'model_budget'
              : capabilityBudgetLimited
                  ? 'model_budget'
                  : binding?.label,
      resetsAt: candidateResetsAt,
      stale: q.stale,
      driftReason: q.driftReason,
      driftObservedAt: q.driftObservedAt,
      available: q.isLocal
          ? isLocalRuntimeAvailableAt(q, now)
          : routeAvailable && !capabilityBlocked,
      leaseDiscount: leaseDiscount,
      pipeDiscount: pipeDiscount,
      capabilityLimited: capabilityLimited,
      capabilityBudgetLimited: capabilityBudgetLimited,
    );
  }

  // Include providers that expose quota evidence (or are local). Stale cached
  // providers stay in the ranked evidence with available=false, but later
  // recommendation branches only choose fresh candidates.
  final usable = quotas
      .where(
        (q) =>
            isLocalRuntimeAvailableAt(q, now) ||
            q.driftReason != null ||
            (q.suspect == null &&
                (q.stale || isTrustedQuotaEvidenceAt(q, now)) &&
                providerHeadroom(q, now) != null),
      )
      .map(toCandidate)
      .toList();

  // Live snapshots rank ahead of stale ones; within each, the unified runway
  // score wins. This stops an hours-old 99% cache from being recommended over a
  // live 80%, while letting a slow-burn provider beat a fast-draining one.
  final subs = usable.where((c) => !c.isLocal).toList()
    ..sort(_compareSubscriptionCandidates);
  final locals = usable.where((c) => c.isLocal).toList();

  // Ranked view: normal mode leads with subscriptions. Local-first mode is an
  // explicit cost-safety request, so locals lead when present.
  final ranked = preferLocal ? [...locals, ...subs] : [...subs, ...locals];

  // The fail-soft fallback is always present, so a caller that skips the pick
  // (or gets a null recommendation) still has an actionable next step. The
  // closure threads the shared [ranked] and [fallback] into every branch.
  final fallback = _fallbackFor(subs, locals);
  RouteSuggestion result(
    RouteCandidate? recommended,
    String reason, {
    required RouteDecisionCode decisionCode,
    bool usingLocalFallback = false,
  }) =>
      RouteSuggestion(
        recommended: recommended,
        ranked: ranked,
        reason: reason,
        decisionCode: decisionCode,
        usingLocalFallback: usingLocalFallback,
        fallback: fallback,
        asOf: now,
        riskZ: riskZ,
        routingPolicy: preferLocal ? 'local_first' : 'balanced',
        wasteWeight: wasteWeight,
        wasteThresholdPercent:
            wasteThresholdPercent.clamp(0.0, 100.0).toDouble(),
        wasteMaxHours: wasteMaxHours.clamp(0, 24 * 14).toInt(),
        costWeight: costWeight.isFinite
            ? costWeight.clamp(0.0, kMaxRoutingCostWeight).toDouble()
            : 0.0,
        comfortThreshold: comfortThreshold.clamp(0.0, 100.0).toDouble(),
        leadHours: leadHours.isFinite ? math.max(0.0, leadHours) : 0.0,
        snapshotSource: _receiptSnapshotSource(snapshotSource),
        snapshotAsOf: snapshotAsOf ?? (snapshotSource == 'live' ? now : null),
        snapshotStale: snapshotStale ??
            quotas.any((quota) =>
                quota.stale ||
                quota.driftReason != null ||
                quota.suspect != null),
      );

  if (usable.isEmpty) {
    return result(
      null,
      'No live quota data. Open the provider app, or use quotabot login for Grok/Antigravity.',
      decisionCode: RouteDecisionCode.noData,
    );
  }

  if (preferLocal) {
    RouteCandidate? localPick;
    for (final candidate in locals) {
      if (candidate.available) {
        localPick = candidate;
        break;
      }
    }
    if (localPick != null) {
      return result(
        localPick,
        'Local-first policy: use local ${localPick.provider} and keep subscription quota untouched.',
        decisionCode: RouteDecisionCode.localFirst,
        usingLocalFallback: true,
      );
    }
  }

  final liveSubs = subs.where((c) => !c.stale).toList();
  final comfy = liveSubs
      .where(
        (c) => c.available && (c.effectiveHeadroom ?? 0) >= comfortThreshold,
      )
      .toList();
  if (comfy.isNotEmpty) {
    // A user preference orders only genuinely viable candidates: [comfy] is
    // already the available, above-comfort set, so preferring within it never
    // revives an unavailable or spent route. When the preference names none of
    // them, the score-based pick stands.
    final preferred = preferredViableCandidate(comfy, preferenceOrder);
    final best = preferred ?? comfy.first;
    final note = best.stale ? ' (cached)' : '';
    final burnNote = _effectiveHeadroomNote(best);
    // Name the preference only when it actually changed the pick - when the
    // preferred candidate differs from the one the risk-adjusted score would
    // have chosen. If preference merely agreed with the top score, it decided
    // nothing, so do not claim it did.
    final byPreference =
        preferred != null && !identical(preferred, comfy.first);
    final lead = byPreference
        ? 'Use ${best.provider}$note - first by your preference'
        : 'Use ${best.provider}$note - best risk-adjusted runway';
    return result(
      best,
      '$lead (${best.headroom!.round()}% free$burnNote).',
      decisionCode: byPreference
          ? RouteDecisionCode.preferredProvider
          : RouteDecisionCode.bestRunway,
    );
  }

  // No subscription is comfortable. Prefer a free local runtime if present.
  if (locals.isNotEmpty) {
    final best = locals.first;
    final tightest = subs.isNotEmpty ? subs.first : null;
    final subNote = _localFallbackSubscriptionNote(tightest);
    return result(
      best,
      'Subscriptions are low - fall back to local ${best.provider}$subNote.',
      decisionCode: RouteDecisionCode.localFallback,
      usingLocalFallback: true,
    );
  }

  // No local fallback. Recommend the best subscription whose effective
  // headroom remains above the spent floor after burn, leases, and pipe health.
  final withAny = liveSubs
      .where(
        (c) => c.available && (c.effectiveHeadroom ?? 0) > kSpentHeadroomFloor,
      )
      .toList();
  if (withAny.isNotEmpty) {
    final best = withAny.first;
    final adjustmentNote = _effectiveHeadroomNote(best);
    return result(
      best,
      'All subscriptions are low; ${best.provider} has the best runway '
      '(${best.headroom!.round()}% free$adjustmentNote).',
      decisionCode: RouteDecisionCode.lowQuota,
    );
  }

  final adjustedDepleted = liveSubs
      .where(
        (c) =>
            c.available &&
            (c.headroom ?? 0) > kSpentHeadroomFloor &&
            (c.effectiveHeadroom ?? 0) <= kSpentHeadroomFloor,
      )
      .toList();
  if (adjustedDepleted.isNotEmpty) {
    final best = adjustedDepleted.first;
    final causes = _effectiveHeadroomCauses(best);
    final cause = causes.isEmpty ? 'routing adjustments' : causes.join('/');
    return result(
      null,
      'No subscription has usable effective headroom after routing '
      'adjustments; ${best.provider} has ${best.headroom!.round()}% raw but '
      '${best.effectiveHeadroom!.round()}% after $cause. Wait for those '
      'adjustments to clear before routing.',
      decisionCode: RouteDecisionCode.adjustedHeadroomDepleted,
    );
  }

  final capabilityBlocked = liveSubs
      .where((c) =>
          (c.capabilityLimited || c.capabilityBudgetLimited) &&
          (c.headroom ?? 0) > kSpentHeadroomFloor)
      .toList();
  if (capabilityBlocked.isNotEmpty) {
    final hasKnown = capabilityBlocked.any((c) => c.capabilityBudgetLimited);
    return result(
      null,
      hasKnown
          ? 'Providers have quota, but no default-capable model has budget right now; use quotabot models or wait for the model gate to reset.'
          : 'Providers have quota, but none has a catalog model that meets the default capability floor; use quotabot models or pass an explicit task profile.',
      decisionCode: hasKnown
          ? RouteDecisionCode.capabilityBudgetBlocked
          : RouteDecisionCode.capabilityBlocked,
    );
  }

  final drifted =
      subs.where((candidate) => candidate.driftReason != null).toList();
  final driftOnly = drifted.isNotEmpty && drifted.length == subs.length;
  if (driftOnly) {
    final best = drifted.first;
    final evidence = best.headroom == null
        ? 'legacy evidence is quarantined and no trusted quota snapshot is available'
        : 'last-trusted headroom is ${best.headroom!.round()}%';
    return result(
      null,
      'Provider drift rejected the only quota evidence; ${best.provider} is '
      'not routable because $evidence. Run quotabot verify and compare the '
      'provider view.',
      decisionCode: RouteDecisionCode.providerDrift,
    );
  }
  final staleWithLastKnown =
      subs.where((c) => c.stale && c.headroom != null).toList();
  if (staleWithLastKnown.isNotEmpty) {
    final best = staleWithLastKnown.first;
    return result(
      null,
      'Only cached quota evidence is present; ${best.provider} last-known headroom was ${best.headroom!.round()}%. Reconnect before routing from that number.',
      decisionCode: RouteDecisionCode.staleEvidence,
    );
  }

  // Everything is spent. Point at whatever resets soonest.
  final resetting = subs.where((c) => !c.stale && c.resetsAt != null).toList()
    ..sort((a, b) => a.resetsAt!.compareTo(b.resetsAt!));
  if (resetting.isNotEmpty) {
    final soonest = resetting.first;
    return result(
      null,
      'Everything is spent. ${soonest.provider} resets soonest - wait for it.',
      decisionCode: RouteDecisionCode.spentWait,
    );
  }

  return result(
    null,
    'Everything is spent and no reset time is known.',
    decisionCode: RouteDecisionCode.spentUnknownReset,
  );
}

String _receiptSnapshotSource(String source) => switch (source) {
      'live' || 'simulation' || 'disk' || 'memory' => source,
      _ => 'other',
    };

double _pipePenaltyFor(ProviderQuota q, Map<String, double> penalties) {
  double normalize(double? value) {
    if (value == null || !value.isFinite) return 0;
    return value.clamp(0.0, 100.0).toDouble();
  }

  final accountScoped = normalize(penalties[quotaIdentityKeyFor(q)]);
  if (accountScoped > 0) return accountScoped;
  return normalize(penalties[q.provider]);
}

double _nativePipePenaltyFor(ProviderQuota q) {
  if (q.isManual) return 0.0;
  return providerPipeHealthRoutingPenaltyPercent(
    q.pipeHealth,
    retryAfterSeconds: q.retryAfterSeconds,
  );
}

double? _projectedWastePercent(
  ProviderQuota q,
  ({bool available, double? headroom, int? resetsAt}) availability,
  double? headroom,
  double? burnPerHour,
  int now, {
  required double thresholdPercent,
  required int maxHoursToReset,
}) {
  if (q.isLocal || q.isManual || q.stale || q.windows.isEmpty) {
    return null;
  }
  final reset = availability.resetsAt;
  if (!availability.available || headroom == null || reset == null) {
    return null;
  }
  final maxSeconds = maxHoursToReset.clamp(0, 24 * 14).toInt() * 3600;
  final secondsToReset = reset - now;
  if (secondsToReset <= 0 || secondsToReset > maxSeconds) return null;
  final pace = computePace(
    headroom: headroom,
    resetsAt: reset,
    burnPerHour: burnPerHour,
    now: now,
  );
  final waste = pace?.wastedAtReset;
  final threshold = thresholdPercent.clamp(0.0, 100.0).toDouble();
  if (waste == null || waste < threshold) return null;
  return waste;
}

/// The adaptive refresh delay in seconds for a snapshot: fast when a reset is
/// imminent or a cap is nearly hit, relaxed when everything is healthy and resets
/// are far off, and backing off after [failStreak] cycles that returned nothing
/// live. Only trusted, automatically refreshable quota controls urgency: stale,
/// integrity-rejected, local-runtime, and manual entries remain visible but do
/// not force the whole fleet into a fast polling loop. Pure, so the desktop app
/// and `quotabot top` poll on identical logic rather than two drifting copies.
int nextRefreshSeconds(List<ProviderQuota> data, int now,
    {int failStreak = 0, int throttleStreak = 0}) {
  if (failStreak >= 2) return 6 * 3600;
  if (failStreak >= 1) return 3600;

  int? soonestReset;
  int? nearCapInterval;
  var throttled = false;
  var retryAfterFloor = 0;
  for (final q in data) {
    // A throttled or slow read means the provider is pushing back. Note it (and
    // any explicit retry-after) before the trusted filter, because a throttled
    // read is stale by definition, so the escalating back-off below applies.
    if (q.pipeHealth == providerPipeHealthThrottled ||
        q.pipeHealth == providerPipeHealthDegraded) {
      throttled = true;
    }
    final retryAfter = q.retryAfterSeconds;
    if (retryAfter != null && retryAfter > retryAfterFloor) {
      retryAfterFloor = retryAfter;
    }
    if (q.isLocal || q.isManual || !isTrustedQuotaEvidenceAt(q, now)) {
      continue;
    }
    for (final w in q.windows) {
      if (w.resetsAt != null && w.resetsAt! > now) {
        final dt = w.resetsAt! - now;
        soonestReset = soonestReset == null ? dt : math.min(soonestReset, dt);
      }
    }
    // Watching a low provider closely only pays off while its binding window's
    // own reset is near enough that the picture can still change soon. A window
    // that is spent (or nearly so) with a far-off reset just sits there until it
    // resets, so it must not pin the whole fleet to a fast poll and hammer the
    // provider for days.
    final binding = bindingWindow(q, now);
    final bindingReset = binding?.resetsAt;
    final rem = providerHeadroom(q, now);
    if (rem != null &&
        bindingReset != null &&
        bindingReset > now &&
        bindingReset - now < 6 * 3600) {
      final demand = rem <= 10 ? 600 : (rem <= 40 ? 1200 : null);
      if (demand != null) {
        nearCapInterval = nearCapInterval == null
            ? demand
            : math.min(nearCapInterval, demand);
      }
    }
  }
  // A reset about to flip the display: catch it promptly, even under throttle -
  // the flip is a brief, one-time event worth catching.
  if (soonestReset != null && soonestReset < 600) {
    return soonestReset < 120 ? 30 : 60;
  }
  // Escalating back-off while a provider keeps throttling us: stop checking so
  // much precisely when it keeps pushing back - twenty minutes, then forty, then
  // ninety per consecutive throttled cycle - and honor an explicit retry-after.
  if (throttled || throttleStreak > 0) {
    const steps = [1200, 2400, 5400];
    final idx = (throttleStreak - 1).clamp(0, steps.length - 1);
    return math.max(steps[idx], retryAfterFloor);
  }
  // Healthy or moderate: a gentle default so a slow-moving quota is not polled
  // hard enough to trip a rate limit; relax further as the nearest reset recedes.
  final base = nearCapInterval ??
      (soonestReset == null || soonestReset < 6 * 3600
          ? 1200
          : soonestReset < 24 * 3600
              ? 3600
              : 12 * 3600);
  return math.max(base, retryAfterFloor);
}

/// Computes simple average headroom from recent history snapshots.
/// Returns null if no usable data. Pure for testability.
double? averageRecentHeadroom(List<ProviderQuota> history, int now) {
  if (history.isEmpty) return null;
  double sum = 0;
  int count = 0;
  for (final q in history) {
    final h = providerHeadroom(q, now);
    if (h != null) {
      sum += h;
      count++;
    }
  }
  if (count == 0) return null;
  return sum / count;
}
