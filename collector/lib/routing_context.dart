/// Shared construction of the complete provider-routing context.
///
/// Every user-facing route surface should enter the pure decision engine with
/// this builder. It keeps model capability gates, scoped model headroom, active
/// cross-process leases, burn forecasts, routed-request pressure, and profile
/// preferences from drifting between CLI, desktop, HTTP, and MCP views.
library;

import 'analysis.dart';
import 'decision.dart';
import 'leases.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'registry.dart';

DecisionContext providerRouteDecisionContext(
  List<ProviderQuota> providers,
  int now, {
  double comfortThreshold = 15,
  Map<String, double?> burnByProvider = const {},
  double leadHours = 1.0,
  Map<String, BurnStat> burnStatsByProvider = const {},
  double riskZ = 0,
  Iterable<RouteLease> activeLeases = const <RouteLease>[],
  bool preferLocal = false,
  double wasteWeight = kDefaultRoutingWasteWeight,
  double wasteThresholdPercent = kDefaultExpiringQuotaWasteThreshold,
  int wasteMaxHours = kDefaultExpiringQuotaMaxHours,
  Map<String, double> costPenaltyByProvider = const {},
  double costWeight = kDefaultRoutingCostWeight,
  Map<String, double> pipePenaltyByProvider = const {},
  Map<String, List<ModelInfo>> catalog = kModelCatalog,
  ModelRequirements? routeRequirements,
  List<String> preferenceOrder = const [],
  String snapshotSource = 'live',
  int? snapshotAsOf,
  bool? snapshotStale,
}) {
  final gates = providerRouteCapabilityGates(
    providers,
    now,
    catalog: catalog,
    requirements: routeRequirements,
  );
  final leases = List<RouteLease>.unmodifiable(activeLeases);
  return DecisionContext(
    comfortThreshold: comfortThreshold,
    burnByProvider: burnByProvider,
    leadHours: leadHours,
    burnStatsByProvider: burnStatsByProvider,
    riskZ: riskZ,
    leaseDiscountFor: (provider, account) =>
        leaseDiscountFor(leases, provider, account),
    preferLocal: preferLocal,
    wasteWeight: wasteWeight,
    wasteThresholdPercent: wasteThresholdPercent,
    wasteMaxHours: wasteMaxHours,
    costPenaltyByProvider: costPenaltyByProvider,
    costWeight: costWeight,
    pipePenaltyByProvider: pipePenaltyByProvider,
    capabilityKnownQuotaKeys: gates.knownQuotaKeys,
    capabilityAvailableQuotaKeys: gates.availableQuotaKeys,
    capabilityBudgetResetByQuotaKey: gates.budgetResetByQuotaKey,
    capabilityHeadroomByQuotaKey: gates.headroomByQuotaKey,
    preferenceOrder: preferenceOrder,
    snapshotSource: snapshotSource,
    snapshotAsOf: snapshotAsOf,
    snapshotStale: snapshotStale,
  );
}
