/// The one engine: a single pure entry point that turns observations at an
/// instant into one decision object, and a replay harness that folds it over
/// recorded history.
///
/// quotabot's product is one forecast of each resource's availability over time.
/// SEE (the glance) is that forecast at now, ROUTE (the suggestion) is the
/// argmax over it, and ALERT is a threshold crossing on it. The routing core
/// already computes the whole forecast - every [RouteCandidate] carries its
/// forward headroom, recent burn and its standard error, strand probability, and
/// confidence - so this file does not recompute anything. It gives that one
/// engine a named, bounded front door ([decide]) so every surface is provably a
/// view of the same object, and a [replay] over recorded frames so the same core
/// can be graded against what actually happened (the calibration substrate) and
/// driven from fixtures with no network.
library;

import 'analysis.dart';
import 'models.dart';

double _zeroLease(String provider, String account) => 0;

/// The bounded caller context for a routing decision: everything the pure core
/// needs beyond the raw observations and the clock. Bundling these into one
/// value, rather than a long argument list, is what lets a decision be recorded,
/// replayed, and simulated as a single object. Defaults match [suggestRoute].
class DecisionContext {
  final double comfortThreshold;
  final Map<String, double?> burnByProvider;
  final double leadHours;
  final Map<String, BurnStat> burnStatsByProvider;
  final double riskZ;
  final LeaseDiscountProvider leaseDiscountFor;
  final bool preferLocal;
  final double wasteWeight;
  final double wasteThresholdPercent;
  final int wasteMaxHours;
  final Map<String, double> costPenaltyByProvider;
  final double costWeight;
  final Map<String, double> pipePenaltyByProvider;
  final Set<String>? capabilityKnownQuotaKeys;
  final Set<String>? capabilityAvailableQuotaKeys;
  final Map<String, int> capabilityBudgetResetByQuotaKey;
  final Map<String, double> capabilityHeadroomByQuotaKey;
  final String snapshotSource;
  final int? snapshotAsOf;
  final bool? snapshotStale;

  /// The user's explicit provider preference, most-preferred first. Applied only
  /// among already-viable candidates; empty means no preference.
  final List<String> preferenceOrder;

  const DecisionContext({
    this.comfortThreshold = 15,
    this.burnByProvider = const {},
    this.leadHours = 1.0,
    this.burnStatsByProvider = const {},
    this.riskZ = 0,
    this.leaseDiscountFor = _zeroLease,
    this.preferLocal = false,
    this.wasteWeight = kDefaultRoutingWasteWeight,
    this.wasteThresholdPercent = kDefaultExpiringQuotaWasteThreshold,
    this.wasteMaxHours = kDefaultExpiringQuotaMaxHours,
    this.costPenaltyByProvider = const {},
    this.costWeight = kDefaultRoutingCostWeight,
    this.pipePenaltyByProvider = const {},
    this.capabilityKnownQuotaKeys,
    this.capabilityAvailableQuotaKeys,
    this.capabilityBudgetResetByQuotaKey = const {},
    this.capabilityHeadroomByQuotaKey = const {},
    this.preferenceOrder = const [],
    this.snapshotSource = 'live',
    this.snapshotAsOf,
    this.snapshotStale,
  });
}

/// One decision from one set of observations at one instant - the single object
/// every surface is a view of. SEE reads [forecasts], ROUTE reads [recommended],
/// ALERT thresholds on the same [forecasts]. One engine, three views.
class Decision {
  final int now;

  /// The routing decision and its ranked candidates. Each candidate already
  /// carries its full forward forecast with uncertainty (headroom, burn and its
  /// standard error, strand probability, confidence), so the SEE and ALERT views
  /// below are projections of this one object, never separately computed.
  final RouteSuggestion route;

  const Decision({required this.now, required this.route});

  /// The SEE view: every observed provider's forward forecast, ranked best
  /// first. The desktop glance and `top` render these.
  List<RouteCandidate> get forecasts => route.ranked;

  /// The ROUTE view: the recommended provider, or null when nothing is usable.
  RouteCandidate? get recommended => route.recommended;

  /// The ALERT view: the forecasts at or below [thresholdPercent] remaining
  /// headroom (a fresh, usable-or-spent metered provider crossing a caller's
  /// alert line). Local runtimes have no spendable headroom and are excluded, as
  /// are stale and drifted candidates - `ranked` retains those as last-trusted
  /// evidence, but alerting on hours-old or rejected data would misfire, so the
  /// ALERT view stays on fresh readings only (matching computeAlerts).
  Iterable<RouteCandidate> alertsBelow(double thresholdPercent) =>
      forecasts.where((c) =>
          !c.isLocal &&
          !c.stale &&
          c.driftReason == null &&
          c.headroom != null &&
          c.headroom! <= thresholdPercent);
}

/// The single pure entry point: turn a set of [observations] at [now] into one
/// [Decision]. No I/O - the caller's impure shell reads live or cached quotas,
/// history-derived burn, and leases, bundles them into [context], and hands them
/// here. Routing every surface through this is what keeps SEE, ROUTE, and ALERT
/// from drifting into separate logic. Behaviourally identical to calling
/// [suggestRoute] directly; the value is that the inputs and outputs are now one
/// named, replayable object.
Decision decide(
  List<ProviderQuota> observations,
  int now, {
  DecisionContext context = const DecisionContext(),
}) =>
    Decision(
      now: now,
      route: suggestRoute(
        observations,
        now,
        comfortThreshold: context.comfortThreshold,
        burnByProvider: context.burnByProvider,
        leadHours: context.leadHours,
        burnStatsByProvider: context.burnStatsByProvider,
        riskZ: context.riskZ,
        leaseDiscountFor: context.leaseDiscountFor,
        preferLocal: context.preferLocal,
        wasteWeight: context.wasteWeight,
        wasteThresholdPercent: context.wasteThresholdPercent,
        wasteMaxHours: context.wasteMaxHours,
        costPenaltyByProvider: context.costPenaltyByProvider,
        costWeight: context.costWeight,
        pipePenaltyByProvider: context.pipePenaltyByProvider,
        capabilityKnownQuotaKeys: context.capabilityKnownQuotaKeys,
        capabilityAvailableQuotaKeys: context.capabilityAvailableQuotaKeys,
        capabilityBudgetResetByQuotaKey:
            context.capabilityBudgetResetByQuotaKey,
        capabilityHeadroomByQuotaKey: context.capabilityHeadroomByQuotaKey,
        preferenceOrder: context.preferenceOrder,
        snapshotSource: context.snapshotSource,
        snapshotAsOf: context.snapshotAsOf,
        snapshotStale: context.snapshotStale,
      ),
    );

/// One observation frame for [replay]: the observations and the clock at a past
/// instant, with the decision context that applied then.
typedef DecisionFrame = ({
  List<ProviderQuota> observations,
  int now,
  DecisionContext context,
});

/// Replays the decision core over a sequence of recorded observation [frames],
/// deterministically: the same frames always yield the same decisions. This is
/// what makes calibration (each frame's forecast graded against the outcome the
/// next frames reveal) and the oracle benchmark possible, and what lets a
/// simulated fleet drive the whole pipeline with no network. Pure.
List<Decision> replay(List<DecisionFrame> frames) =>
    [for (final f in frames) decide(f.observations, f.now, context: f.context)];
