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
    required this.resetsAt,
    required this.stale,
    required this.available,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'account': account,
        if (plan != null) 'plan': plan,
        'local': isLocal,
        'headroom_percent': headroom,
        if (resetsAt != null) 'resets_at': resetsAt,
        'stale': stale,
        'available': available,
      };
}

/// A routing recommendation: which provider to use next, ranked alternatives,
/// and a short human reason. Pure result of [suggestRoute].
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

  const RouteSuggestion({
    required this.recommended,
    required this.ranked,
    required this.reason,
    required this.usingLocalFallback,
  });

  Map<String, dynamic> toJson() => {
        'recommended': recommended?.toJson(),
        'reason': reason,
        'using_local_fallback': usingLocalFallback,
        'ranked': ranked.map((c) => c.toJson()).toList(),
      };
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
/// Local runtimes never "win" on headroom (they would always read 100%); they
/// are only chosen when the paid budget is too tight to be comfortable.
RouteSuggestion suggestRoute(
  List<ProviderQuota> quotas,
  int now, {
  double comfortThreshold = 15,
}) {
  RouteCandidate toCandidate(ProviderQuota q) {
    final a = providerAvailability(q, now);
    return RouteCandidate(
      provider: q.provider,
      account: q.account,
      plan: q.plan,
      isLocal: q.isLocal,
      headroom: q.isLocal ? 100.0 : a.headroom,
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
      return (b.headroom ?? -1).compareTo(a.headroom ?? -1);
    });
  final locals = usable.where((c) => c.isLocal).toList();

  // Ranked view: best subscription first, then locals as the tail fallback.
  final ranked = [...subs, ...locals];

  if (usable.isEmpty) {
    return const RouteSuggestion(
      recommended: null,
      ranked: [],
      reason:
          'No live quota data. Open a provider app or run a login to refresh.',
      usingLocalFallback: false,
    );
  }

  final liveSubs = subs.where((c) => !c.stale).toList();
  final comfy =
      liveSubs.where((c) => (c.headroom ?? 0) >= comfortThreshold).toList();
  if (comfy.isNotEmpty) {
    final best = comfy.first;
    final note = best.stale ? ' (cached)' : '';
    return RouteSuggestion(
      recommended: best,
      ranked: ranked,
      reason:
          'Use ${best.provider}$note - most headroom (${best.headroom!.round()}% free).',
      usingLocalFallback: false,
    );
  }

  // No subscription is comfortable. Prefer a free local runtime if present.
  if (locals.isNotEmpty) {
    final best = locals.first;
    final tightest = subs.isNotEmpty ? subs.first : null;
    final subNote = tightest == null
        ? ''
        : ' (best subscription ${tightest.provider} only ${(tightest.headroom ?? 0).round()}% free)';
    return RouteSuggestion(
      recommended: best,
      ranked: ranked,
      reason:
          'Subscriptions are low - fall back to local ${best.provider}$subNote.',
      usingLocalFallback: true,
    );
  }

  // No local fallback. Recommend the subscription with any headroom left.
  final withAny = liveSubs.where((c) => (c.headroom ?? 0) > 0.5).toList();
  if (withAny.isNotEmpty) {
    final best = withAny.first;
    return RouteSuggestion(
      recommended: best,
      ranked: ranked,
      reason:
          'All subscriptions are low; ${best.provider} has the most left (${best.headroom!.round()}% free).',
      usingLocalFallback: false,
    );
  }

  final staleWithAny =
      subs.where((c) => c.stale && (c.headroom ?? 0) > 0.5).toList();
  if (staleWithAny.isNotEmpty) {
    final best = staleWithAny.first;
    return RouteSuggestion(
      recommended: best,
      ranked: ranked,
      reason:
          'Only cached quota is available; ${best.provider} last had ${best.headroom!.round()}% free.',
      usingLocalFallback: false,
    );
  }

  // Everything is spent. Point at whatever resets soonest.
  final resetting = subs.where((c) => c.resetsAt != null).toList()
    ..sort((a, b) => a.resetsAt!.compareTo(b.resetsAt!));
  if (resetting.isNotEmpty) {
    final soonest = resetting.first;
    return RouteSuggestion(
      recommended: null,
      ranked: ranked,
      reason:
          'Everything is spent. ${soonest.provider} resets soonest - wait for it.',
      usingLocalFallback: false,
    );
  }

  return RouteSuggestion(
    recommended: null,
    ranked: ranked,
    reason: 'Everything is spent and no reset time is known.',
    usingLocalFallback: false,
  );
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
