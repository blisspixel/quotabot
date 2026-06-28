import 'dart:math' as math;

import 'models.dart';

/// Routing helpers over a set of provider snapshots. Pure and side-effect free.

/// Remaining headroom for a provider as a percent (0..100), governed by its
/// most constrained window. A window whose reset time has passed is treated as
/// fresh. Returns null when the provider has no usable windows.
double? providerHeadroom(ProviderQuota q, int now) {
  if (q.windows.isEmpty) return null;
  double minRemaining = 100;
  for (final w in q.windows) {
    final rolledOver = w.resetsAt != null && w.resetsAt! < now;
    final remaining =
        rolledOver ? 100.0 : (100 - (w.percent ?? 0)).clamp(0, 100).toDouble();
    if (remaining < minRemaining) minRemaining = remaining;
  }
  return minRemaining;
}

/// The provider with the most remaining headroom, for choosing where to route
/// work. Local runtimes are excluded (they read 100% and would always win; use
/// [suggestRoute] for fallback logic). Fresh snapshots are preferred over stale
/// cached ones: a stale provider is only returned when nothing live qualifies,
/// so a hours-old 99% cache never beats a live 80%. Null when none qualify.
ProviderQuota? providerWithMostHeadroom(List<ProviderQuota> quotas, int now) {
  ProviderQuota? best;
  double bestHeadroom = -1;
  for (final live in [true, false]) {
    for (final q in quotas) {
      if (q.isLocal || q.stale != !live) continue;
      final h = providerHeadroom(q, now);
      if (h != null && h > bestHeadroom) {
        bestHeadroom = h;
        best = q;
      }
    }
    if (best != null) return best; // a live winner wins outright
  }
  return best;
}

/// Availability of a single provider: usable when it has any headroom left.
({bool available, double? headroom, int? resetsAt}) providerAvailability(
  ProviderQuota q,
  int now,
) {
  final h = providerHeadroom(q, now);
  if (h == null) return (available: false, headroom: null, resetsAt: null);
  // Reset time of the most constrained window, for "available again at".
  int? bindingReset;
  double minRemaining = 100;
  for (final w in q.windows) {
    final rolledOver = w.resetsAt != null && w.resetsAt! < now;
    final remaining =
        rolledOver ? 100.0 : (100 - (w.percent ?? 0)).clamp(0, 100).toDouble();
    if (remaining < minRemaining) {
      minRemaining = remaining;
      bindingReset = w.resetsAt;
    }
  }
  return (available: h > 0.5, headroom: h, resetsAt: bindingReset);
}

/// Returns the window that is currently the binding constraint (lowest headroom).
/// Used by display to decide collapse and which reset to show.
QuotaWindow? bindingWindow(ProviderQuota q, int now) {
  if (q.windows.isEmpty) return null;
  QuotaWindow? worst;
  double minRem = 100;
  for (final w in q.windows) {
    final rolledOver = w.resetsAt != null && w.resetsAt! < now;
    final remaining =
        rolledOver ? 100.0 : (100 - (w.percent ?? 0)).clamp(0, 100).toDouble();
    if (remaining < minRem) {
      minRem = remaining;
      worst = w;
    }
  }
  return worst;
}

/// A ranked candidate in a routing suggestion.
class RouteCandidate {
  final String provider;
  final String account;
  final String? plan;
  final bool isLocal;

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

  /// Standard error of [burnPerHour], when estimable. Null for local runtimes or
  /// when there were too few history points to estimate it.
  final double? burnSe;

  /// Probability the binding window is spent before it resets (0..1), from a
  /// first-passage forecast. Null when burn, its error, or the reset are unknown.
  final double? strandProbability;

  /// How much to trust this candidate's numbers, in (0, 1]: a blend of freshness
  /// (cached reads count less) and burn-estimate sample adequacy.
  final double? confidence;

  /// Reset epoch of the binding window, when known.
  final int? resetsAt;

  final bool stale;

  /// True when usable right now (headroom above the "spent" floor, or local).
  final bool available;

  const RouteCandidate({
    required this.provider,
    required this.account,
    required this.plan,
    required this.isLocal,
    required this.headroom,
    required this.effectiveHeadroom,
    required this.resetsAt,
    required this.stale,
    required this.available,
    this.burnPerHour,
    this.burnSe,
    this.strandProbability,
    this.confidence,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'account': account,
        if (plan != null) 'plan': plan,
        'local': isLocal,
        'headroom_percent': headroom,
        'effective_headroom_percent': effectiveHeadroom,
        if (burnPerHour != null) 'burn_percent_per_hour': burnPerHour,
        if (burnSe != null) 'burn_se_percent_per_hour': burnSe,
        if (strandProbability != null) 'strand_probability': strandProbability,
        if (confidence != null) 'confidence': confidence,
        if (resetsAt != null) 'resets_at': resetsAt,
        'stale': stale,
        'available': available,
      };
}

/// The fail-soft next step in a [RouteSuggestion]: what to do if the caller
/// skips the recommendation, or there is no usable recommendation at all. Always
/// present, so quotabot never leaves a caller without an actionable answer.
class RouteFallback {
  /// One of 'local' (use a local runtime), 'soonest_reset' (wait for the named
  /// provider to reset), or 'passthrough' (no signal; use the requested model).
  final String kind;

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
        'kind': kind,
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

  const RouteSuggestion({
    required this.recommended,
    required this.ranked,
    required this.reason,
    required this.usingLocalFallback,
    required this.fallback,
    required this.asOf,
    required this.riskZ,
  });

  Map<String, dynamic> toJson() => {
        'schema': 'quotabot.suggest.v1',
        'as_of': asOf,
        'risk_z': riskZ,
        'recommended': recommended?.toJson(),
        'reason': reason,
        'using_local_fallback': usingLocalFallback,
        'fallback': fallback.toJson(),
        'ranked': ranked.map((c) => c.toJson()).toList(),
      };
}

/// Builds the always-present fail-soft fallback from the available candidates:
/// a running local runtime if present, else the soonest-resetting subscription
/// to wait for, else a passthrough to the model the caller requested.
RouteFallback _fallbackFor(
  List<RouteCandidate> subs,
  List<RouteCandidate> locals,
) {
  if (locals.isNotEmpty) {
    final l = locals.first;
    return RouteFallback(
      kind: 'local',
      provider: l.provider,
      reason: 'Skip the pick? Use local ${l.provider} - free and always on.',
    );
  }
  final resetting = subs.where((c) => c.resetsAt != null).toList()
    ..sort((a, b) => a.resetsAt!.compareTo(b.resetsAt!));
  if (resetting.isNotEmpty) {
    final s = resetting.first;
    return RouteFallback(
      kind: 'soonest_reset',
      provider: s.provider,
      resetsAt: s.resetsAt,
      reason: '${s.provider} resets soonest - wait for it.',
    );
  }
  return const RouteFallback(
    kind: 'passthrough',
    reason: 'No quota signal - use the model you requested.',
  );
}

/// A short ", ~N% after burn" note when recent burn materially discounts a
/// candidate's headroom (by at least one point), else an empty string.
String _burnNote(RouteCandidate c) {
  final h = c.headroom, e = c.effectiveHeadroom;
  if (h == null || e == null) return '';
  if (c.burnPerHour == null || c.burnPerHour! <= 0) return '';
  if (h - e < 1) return '';
  return ', ~${e.round()}% after burn';
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

/// How much to trust a candidate's numbers, in (0, 1]: a stale (cached) read is
/// half-trusted, and a metered provider's burn estimate is weighted by sample
/// adequacy `n / (n + 4)` (a shrinkage prior, so a two-point fit is not trusted
/// like a twenty-point one). Local runtimes need no burn, so only freshness.
double _confidence(ProviderQuota q, double? burnSe, int samples) {
  final fresh = q.stale ? 0.5 : 1.0;
  if (q.isLocal) return fresh;
  final adequacy = burnSe == null ? 0.6 : samples / (samples + 4);
  return (fresh * adequacy).clamp(0.0, 1.0).toDouble();
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

/// Recommends where to route the next request.
///
/// Policy: prefer the metered subscription with the most remaining headroom,
/// as long as it clears [comfortThreshold] percent (so we don't burn the last
/// sliver of a cap). If no subscription clears the threshold, recommend any
/// available local runtime (Ollama/LM Studio) as a free, always-on fallback.
/// If there is no local fallback either, recommend the least-bad subscription
/// that still has *some* headroom; otherwise the one that resets soonest.
///
/// Ranking and the comfort gate use *effective* headroom: present headroom
/// discounted by each provider's recent burn over the [leadHours] planning
/// horizon ([burnByProvider], percent of quota per hour). A provider being drawn
/// down fast is therefore a less safe pick than its instantaneous headroom
/// suggests. Availability still reflects present headroom (a provider with quota
/// now is usable now, just ranked lower). With no burn data the behavior is
/// identical to ranking on raw headroom.
///
/// Local runtimes never "win" on headroom (they would always read 100%); they
/// are only chosen when the paid budget is too tight to be comfortable.
RouteSuggestion suggestRoute(
  List<ProviderQuota> quotas,
  int now, {
  double comfortThreshold = 15,
  Map<String, double?> burnByProvider = const {},
  double leadHours = 1.0,
  Map<String, BurnStat> burnStatsByProvider = const {},
  double riskZ = 0,
}) {
  RouteCandidate toCandidate(ProviderQuota q) {
    final a = providerAvailability(q, now);
    final headroom = q.isLocal ? 100.0 : a.headroom;
    final stat = q.isLocal ? null : burnStatsByProvider[q.provider];
    final burn =
        q.isLocal ? null : (stat?.perHour ?? burnByProvider[q.provider]);
    final burnSe = stat?.sePerHour;
    final samples = stat?.samples ?? 0;
    final effective = headroom == null
        ? null
        : riskAdjustedHeadroom(headroom, burn, burnSe, leadHours, riskZ);
    final strand = headroom == null
        ? null
        : strandProbability(headroom, burn, burnSe, a.resetsAt, now);
    return RouteCandidate(
      provider: q.provider,
      account: q.account,
      plan: q.plan,
      isLocal: q.isLocal,
      headroom: headroom,
      effectiveHeadroom: effective,
      burnPerHour: burn,
      burnSe: burnSe,
      strandProbability: strand,
      confidence: _confidence(q, burnSe, samples),
      resetsAt: a.resetsAt,
      stale: q.stale,
      available: q.isLocal || a.available,
    );
  }

  // Only providers that expose usable data (or are local) can be routed to.
  final usable = quotas
      .where((q) => q.isLocal || providerHeadroom(q, now) != null)
      .map(toCandidate)
      .toList();

  // Live snapshots rank ahead of stale ones; within each, more headroom first.
  // This stops an hours-old 99% cache from being recommended over a live 80%.
  final subs = usable.where((c) => !c.isLocal).toList()
    ..sort((a, b) {
      if (a.stale != b.stale) return a.stale ? 1 : -1;
      return (b.effectiveHeadroom ?? -1).compareTo(a.effectiveHeadroom ?? -1);
    });
  final locals = usable.where((c) => c.isLocal).toList();

  // Ranked view: best subscription first, then locals as the tail fallback.
  final ranked = [...subs, ...locals];

  // The fail-soft fallback is always present, so a caller that skips the pick
  // (or gets a null recommendation) still has an actionable next step. The
  // closure threads the shared [ranked] and [fallback] into every branch.
  final fallback = _fallbackFor(subs, locals);
  RouteSuggestion result(
    RouteCandidate? recommended,
    String reason, {
    bool usingLocalFallback = false,
  }) =>
      RouteSuggestion(
        recommended: recommended,
        ranked: ranked,
        reason: reason,
        usingLocalFallback: usingLocalFallback,
        fallback: fallback,
        asOf: now,
        riskZ: riskZ,
      );

  if (usable.isEmpty) {
    return result(
      null,
      'No live quota data. Open a provider app or run a login to refresh.',
    );
  }

  final liveSubs = subs.where((c) => !c.stale).toList();
  final comfy = liveSubs
      .where((c) => (c.effectiveHeadroom ?? 0) >= comfortThreshold)
      .toList();
  if (comfy.isNotEmpty) {
    final best = comfy.first;
    final note = best.stale ? ' (cached)' : '';
    final burnNote = _burnNote(best);
    return result(
      best,
      'Use ${best.provider}$note - most headroom (${best.headroom!.round()}% free$burnNote).',
    );
  }

  // No subscription is comfortable. Prefer a free local runtime if present.
  if (locals.isNotEmpty) {
    final best = locals.first;
    final tightest = subs.isNotEmpty ? subs.first : null;
    final subNote = tightest == null
        ? ''
        : ' (best subscription ${tightest.provider} only ${(tightest.headroom ?? 0).round()}% free)';
    return result(
      best,
      'Subscriptions are low - fall back to local ${best.provider}$subNote.',
      usingLocalFallback: true,
    );
  }

  // No local fallback. Recommend the subscription with any headroom left.
  final withAny = liveSubs.where((c) => (c.headroom ?? 0) > 0.5).toList();
  if (withAny.isNotEmpty) {
    final best = withAny.first;
    return result(
      best,
      'All subscriptions are low; ${best.provider} has the most left (${best.headroom!.round()}% free).',
    );
  }

  final staleWithAny =
      subs.where((c) => c.stale && (c.headroom ?? 0) > 0.5).toList();
  if (staleWithAny.isNotEmpty) {
    final best = staleWithAny.first;
    return result(
      best,
      'Only cached quota is available; ${best.provider} last had ${best.headroom!.round()}% free.',
    );
  }

  // Everything is spent. Point at whatever resets soonest.
  final resetting = subs.where((c) => c.resetsAt != null).toList()
    ..sort((a, b) => a.resetsAt!.compareTo(b.resetsAt!));
  if (resetting.isNotEmpty) {
    final soonest = resetting.first;
    return result(
      null,
      'Everything is spent. ${soonest.provider} resets soonest - wait for it.',
    );
  }

  return result(null, 'Everything is spent and no reset time is known.');
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
