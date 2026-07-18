/// The model registry: normalized candidates for providers represented in the
/// current snapshot, each tagged with the known budget gate that controls it.
/// It is not an exhaustive catalog: non-local providers without quota windows
/// and providers without catalog models are omitted.
///
/// [buildModelRegistry] is pure. Local-runtime models come from the snapshot
/// (filled live by the adapters); cloud models come from an injected [catalog]
/// (a committed, refreshable capability table - see `model_catalog.dart` and the
/// refresh tool), so runtime stays zero-extra-network and local-first. Each entry
/// carries the quota that gates that model: provider binding-window headroom for
/// most providers, and model-specific headroom when the provider exposes it.
library;

import 'dart:math' as math;

import 'analysis.dart';
import 'insights.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'parsing.dart' show resetLabel;
import 'util.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * 1024 * 1024;

/// Advisory fit state for an on-device local model. Fit never changes runtime
/// availability: runtimes may split a model across RAM and VRAM, and model
/// format or context overhead can differ from this conservative estimate.
enum LocalHardwareFitStatus {
  loaded('loaded'),
  comfortable('comfortable'),
  tight('tight'),
  constrained('constrained'),
  unknown('unknown');

  const LocalHardwareFitStatus(this.wireName);

  final String wireName;

  static const wireValues = [
    'loaded',
    'comfortable',
    'tight',
    'constrained',
    'unknown',
  ];
}

/// The evidence behind one local model's passive hardware-fit estimate.
class LocalModelHardwareFit {
  final LocalHardwareFitStatus status;
  final String basis;
  final int? estimatedMemoryBytes;
  final int? availableBytes;
  final int? totalBytes;
  final int? observedAt;

  const LocalModelHardwareFit({
    required this.status,
    required this.basis,
    this.estimatedMemoryBytes,
    this.availableBytes,
    this.totalBytes,
    this.observedAt,
  });

  Map<String, dynamic> toJson() => {
        'hardware_fit': status.wireName,
        'hardware_fit_basis': basis,
        if (estimatedMemoryBytes != null)
          'estimated_memory_bytes': estimatedMemoryBytes,
        if (availableBytes != null) 'fit_available_bytes': availableBytes,
        if (totalBytes != null) 'fit_total_bytes': totalBytes,
        if (observedAt != null) 'hardware_observed_at': observedAt,
      };
}

/// One routable model plus the live budget of the provider that gates it.
class ModelEntry {
  final ModelInfo model;
  final String provider;
  final String account;
  final bool local;
  final String? source;
  final ProviderSourceClass sourceClass;
  final bool quotaBacked;

  /// Passive fit evidence for an on-device local model. Null for cloud models
  /// and cloud-offloaded entries reached through a local daemon.
  final LocalModelHardwareFit? hardwareFit;

  /// Remaining headroom percent of the gating quota (null for local runtimes or
  /// when unknown). Providers with per-model quota expose model-specific
  /// headroom here; other cloud providers expose provider binding-window
  /// headroom.
  final double? headroomPercent;

  /// Reset epoch of the model's gating quota, when known.
  final int? resetsAt;

  /// Label of the gating quota window (e.g. "weekly"), when metered.
  final String? gatingWindow;

  /// True when the model is usable right now (provider has headroom, or local).
  final bool available;

  /// True when the gating provider's data is cached/stale.
  final bool stale;

  /// Why fresh provider evidence was rejected, when this model is gated by a
  /// stale last-trusted provider snapshot.
  final String? driftReason;

  /// Epoch seconds when [driftReason] was observed.
  final int? driftObservedAt;

  /// Unix epoch seconds when the gating provider snapshot was captured.
  final int asOf;

  /// True when the gating provider's quota is known to be machine-local state.
  final bool perMachine;

  const ModelEntry({
    required this.model,
    required this.provider,
    required this.account,
    required this.local,
    required this.source,
    required this.sourceClass,
    required this.quotaBacked,
    this.hardwareFit,
    required this.headroomPercent,
    required this.resetsAt,
    required this.gatingWindow,
    required this.available,
    required this.stale,
    required this.asOf,
    required this.perMachine,
    this.driftReason,
    this.driftObservedAt,
  });

  String? get localReadiness =>
      local ? (model.loaded ? 'loaded' : 'cold') : null;

  Map<String, dynamic> toJson() => {
        ...model.toJson(),
        'provider': provider,
        'account': account,
        'local': local,
        'available': available,
        'stale': stale,
        if (driftReason != null) 'drift_reason': driftReason,
        if (driftObservedAt != null) 'drift_observed_at': driftObservedAt,
        'quota_backed': quotaBacked,
        if (localReadiness != null) 'local_readiness': localReadiness,
        if (hardwareFit != null) ...hardwareFit!.toJson(),
        if (source != null) 'source': source,
        'source_class': sourceClass.wireName,
        if (headroomPercent != null) 'headroom_percent': headroomPercent,
        if (resetsAt != null) 'resets_at': resetsAt,
        if (gatingWindow != null) 'gating_window': gatingWindow,
      };
}

/// Computes a conservative metadata-only hardware-fit estimate for a local
/// model. It does not load the model, reserve memory, or run inference.
LocalModelHardwareFit localModelHardwareFit(
  ModelInfo model,
  LocalHardwareInfo? hardware,
) {
  if (model.loaded) {
    return LocalModelHardwareFit(
      status: LocalHardwareFitStatus.loaded,
      basis: 'runtime_loaded',
      observedAt: hardware?.asOf,
    );
  }
  final size = model.sizeBytes;
  final int? estimate = size == null || size <= 0
      ? null
      : size + math.max(512 * _mib, (size + 3) ~/ 4);
  if (estimate == null || hardware == null || !hardware.hasMemoryEvidence) {
    return LocalModelHardwareFit(
      status: LocalHardwareFitStatus.unknown,
      basis: 'insufficient_evidence',
      estimatedMemoryBytes: estimate,
      observedAt: hardware?.asOf,
    );
  }

  final pools = <_FitPool>[];
  final systemTotal = hardware.systemMemoryTotalBytes;
  if (systemTotal != null && systemTotal > 0) {
    pools.add(_evaluateFitPool(
      estimate: estimate,
      total: systemTotal,
      available: hardware.systemMemoryAvailableBytes,
      reserveFloor: 2 * _gib,
      basis: 'system_memory',
    ));
  }
  final gpuTotal = hardware.gpuMemoryTotalBytes;
  if (gpuTotal != null && gpuTotal > 0) {
    pools.add(_evaluateFitPool(
      estimate: estimate,
      total: gpuTotal,
      available: hardware.gpuMemoryAvailableBytes,
      reserveFloor: _gib,
      basis: 'gpu_memory',
    ));
  }
  if (pools.isEmpty) {
    return LocalModelHardwareFit(
      status: LocalHardwareFitStatus.unknown,
      basis: 'insufficient_evidence',
      estimatedMemoryBytes: estimate,
      observedAt: hardware.asOf,
    );
  }
  pools.sort(_fitPoolCompare);
  final best = pools.first;
  return LocalModelHardwareFit(
    status: best.status,
    basis: best.basis,
    estimatedMemoryBytes: estimate,
    availableBytes: best.available,
    totalBytes: best.total,
    observedAt: hardware.asOf,
  );
}

typedef _FitPool = ({
  LocalHardwareFitStatus status,
  String basis,
  int total,
  int? available,
  int comparisonCapacity,
});

_FitPool _evaluateFitPool({
  required int estimate,
  required int total,
  required int? available,
  required int reserveFloor,
  required String basis,
}) {
  final reserve = math.max(reserveFloor, (total + 9) ~/ 10);
  final tightCapacity = math.max(0, total - reserve);
  final boundedAvailable = available?.clamp(0, total).toInt();
  final comfortableCapacity = boundedAvailable == null
      ? 0
      : math.max(0, math.min(boundedAvailable, total) - reserve);
  final status = estimate <= comfortableCapacity
      ? LocalHardwareFitStatus.comfortable
      : estimate <= tightCapacity
          ? LocalHardwareFitStatus.tight
          : LocalHardwareFitStatus.constrained;
  return (
    status: status,
    basis: basis,
    total: total,
    available: boundedAvailable,
    comparisonCapacity: status == LocalHardwareFitStatus.comfortable
        ? comfortableCapacity
        : tightCapacity,
  );
}

int _fitPoolCompare(_FitPool a, _FitPool b) {
  final status = _hardwareFitRank(a.status).compareTo(
    _hardwareFitRank(b.status),
  );
  if (status != 0) return status;
  final capacity = b.comparisonCapacity.compareTo(a.comparisonCapacity);
  if (capacity != 0) return capacity;
  if (a.basis != b.basis) return a.basis == 'gpu_memory' ? -1 : 1;
  return 0;
}

int _hardwareFitRank(LocalHardwareFitStatus? status) => switch (status) {
      LocalHardwareFitStatus.loaded => 0,
      LocalHardwareFitStatus.comfortable => 1,
      LocalHardwareFitStatus.tight => 2,
      LocalHardwareFitStatus.unknown => 3,
      LocalHardwareFitStatus.constrained => 4,
      null => 5,
    };

/// Tier ordering for floor/ceiling comparisons. Unknown and local tiers rank
/// lowest, so a tier floor excludes them and a tier ceiling always admits them.
int _tierRank(String? tier) {
  switch (tier) {
    case 'flagship':
      return 2;
    case 'standard':
      return 1;
    default: // 'light', null, local runtimes
      return 0;
  }
}

/// Caller-selected budget envelope for concrete-model routing.
///
/// `any` preserves the historic registry behavior. `local` keeps entries
/// classified as local runtimes, but current Ollama inventory cannot prove that
/// a reachable model is not cloud-offloaded. `quota` allows local-runtime entries
/// and measured built-in quota plans, but rejects self-reported manual quotas
/// because quotabot cannot verify that those plans have overages disabled.
enum ModelBudgetPolicy {
  any('any'),
  quota('quota'),
  local('local');

  final String wireName;
  const ModelBudgetPolicy(this.wireName);
}

/// Evidence that a measured quota-backed provider is likely to leave included
/// quota unused at its imminent reset. This never applies to local runtimes,
/// manual quota entries, or request-metered paid APIs.
class ExpiringQuotaSignal {
  final String provider;
  final String account;
  final double wastedAtReset;
  final int resetsAt;
  final double burnPerHour;

  const ExpiringQuotaSignal({
    required this.provider,
    required this.account,
    required this.wastedAtReset,
    required this.resetsAt,
    required this.burnPerHour,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'account': account,
        'projected_waste_percent':
            double.parse(wastedAtReset.toStringAsFixed(1)),
        'resets_at': resetsAt,
        'burn_percent_per_hour': double.parse(burnPerHour.toStringAsFixed(2)),
      };
}

/// Computes opt-in expiring-quota signals from the live snapshot and already
/// local burn statistics. A signal means the provider is measured, quota-backed,
/// available now, close to reset, and on pace to leave at least [thresholdPercent]
/// of included quota unused. Multi-account providers require account-scoped burn
/// evidence; a provider-level burn estimate is allowed only when the current
/// snapshot has a single measured account for that provider. Pure, so CLI/MCP
/// callers share the same boundary.
Map<String, ExpiringQuotaSignal> expiringQuotaSignals(
  List<ProviderQuota> providers,
  int now, {
  Map<String, BurnStat> burnStatsByProvider = const {},
  double thresholdPercent = kDefaultExpiringQuotaWasteThreshold,
  int maxHoursToReset = kDefaultExpiringQuotaMaxHours,
}) {
  final threshold = thresholdPercent.clamp(0.0, 100.0).toDouble();
  final maxSeconds = maxHoursToReset.clamp(0, 24 * 14).toInt() * 3600;
  final measuredProviderCounts = <String, int>{};
  for (final q in providers) {
    if (q.isLocal || q.isManual || q.windows.isEmpty) continue;
    measuredProviderCounts[q.provider] =
        (measuredProviderCounts[q.provider] ?? 0) + 1;
  }
  final out = <String, ExpiringQuotaSignal>{};
  for (final q in providers) {
    if (q.isLocal || q.isManual || q.stale || q.windows.isEmpty) {
      continue;
    }
    final availability = providerAvailability(q, now);
    final headroom = availability.headroom;
    final reset = availability.resetsAt;
    if (!availability.available || headroom == null || reset == null) continue;
    final secondsToReset = reset - now;
    if (secondsToReset <= 0 || secondsToReset > maxSeconds) continue;
    final accountBurn = burnStatsByProvider[quotaIdentityKeyFor(q)];
    final providerBurn = (measuredProviderCounts[q.provider] ?? 0) == 1
        ? burnStatsByProvider[q.provider]
        : null;
    final burn = (accountBurn ?? providerBurn)?.perHour;
    final pace = computePace(
      headroom: headroom,
      resetsAt: reset,
      burnPerHour: burn,
      now: now,
    );
    final waste = pace?.wastedAtReset;
    if (waste == null || waste < threshold) continue;
    out[_quotaSignalKey(q.provider, q.account)] = ExpiringQuotaSignal(
      provider: q.provider,
      account: q.account,
      wastedAtReset: waste,
      resetsAt: reset,
      burnPerHour: pace!.burnPerHour,
    );
  }
  return out;
}

const String modelBudgetPolicyChoices = 'any, quota, local';

ModelBudgetPolicy? modelBudgetPolicyFromName(String? name) {
  final normalized = name?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return ModelBudgetPolicy.any;
  return switch (normalized) {
    'any' => ModelBudgetPolicy.any,
    'quota' ||
    'subscription' ||
    'subscriptions' ||
    'included' =>
      ModelBudgetPolicy.quota,
    'local' || 'free' => ModelBudgetPolicy.local,
    _ => null,
  };
}

/// A caller-supplied task profile: the objective capabilities a task needs. It is
/// never derived from the task itself, because quotabot does not read prompts; the
/// caller, which legitimately knows the task, supplies it.
class ModelRequirements {
  final int? minContextTokens;
  final bool requireTools;
  final bool requireVision;
  final bool requireReasoning;
  final String? tierFloor;
  final String? tierCeiling;
  final ModelBudgetPolicy budgetPolicy;

  const ModelRequirements({
    this.minContextTokens,
    this.requireTools = false,
    this.requireVision = false,
    this.requireReasoning = false,
    this.tierFloor,
    this.tierCeiling,
    this.budgetPolicy = ModelBudgetPolicy.any,
  });

  bool get isEmpty =>
      minContextTokens == null &&
      !requireTools &&
      !requireVision &&
      !requireReasoning &&
      tierFloor == null &&
      tierCeiling == null &&
      budgetPolicy == ModelBudgetPolicy.any;

  /// Overlays [o] onto this: [o]'s set fields win, booleans OR together. Used to
  /// layer explicit flags on top of a coarse task profile.
  ModelRequirements merge(ModelRequirements o) => ModelRequirements(
        minContextTokens: o.minContextTokens ?? minContextTokens,
        requireTools: requireTools || o.requireTools,
        requireVision: requireVision || o.requireVision,
        requireReasoning: requireReasoning || o.requireReasoning,
        tierFloor: o.tierFloor ?? tierFloor,
        tierCeiling: o.tierCeiling ?? tierCeiling,
        budgetPolicy: o.budgetPolicy == ModelBudgetPolicy.any
            ? budgetPolicy
            : o.budgetPolicy,
      );
}

/// Maps a coarse task label to a default requirement set: a documented heuristic,
/// fully overridable by explicit requirements. Unknown labels add nothing, so a
/// typo never silently filters everything out.
ModelRequirements taskProfile(String? task) {
  switch (task?.toLowerCase()) {
    case 'simple':
      return const ModelRequirements(tierCeiling: 'standard');
    case 'standard':
      return const ModelRequirements(
          tierFloor: 'standard', tierCeiling: 'standard');
    case 'hard':
    case 'complex':
      return const ModelRequirements(
          requireReasoning: true, tierFloor: 'standard');
    case 'reasoning':
      return const ModelRequirements(requireReasoning: true);
    default:
      return const ModelRequirements();
  }
}

/// Whether [e] satisfies [r]. A capability the model does not declare fails a
/// requirement for it: we never assume an unstated capability.
bool meetsRequirements(ModelEntry e, ModelRequirements r) {
  final m = e.model;
  if (!meetsBudgetPolicy(e, r.budgetPolicy)) return false;
  if (r.minContextTokens != null &&
      (m.contextTokens == null || m.contextTokens! < r.minContextTokens!)) {
    return false;
  }
  if (r.requireTools && m.tools != true) return false;
  if (r.requireVision && m.vision != true) return false;
  if (r.requireReasoning && m.reasoning == null) return false;
  if (r.tierFloor != null && _tierRank(m.tier) < _tierRank(r.tierFloor)) {
    return false;
  }
  if (r.tierCeiling != null && _tierRank(m.tier) > _tierRank(r.tierCeiling)) {
    return false;
  }
  return true;
}

bool meetsBudgetPolicy(ModelEntry e, ModelBudgetPolicy policy) {
  // A model reached through a local daemon but executed in the provider's cloud
  // is neither on-device nor free, so it cannot satisfy a local-only or a
  // free-or-metered budget promise even though it is nominally local.
  final localFree = e.local && !e.model.cloudOffloaded;
  return switch (policy) {
    ModelBudgetPolicy.any => true,
    ModelBudgetPolicy.local => localFree,
    ModelBudgetPolicy.quota => localFree || e.quotaBacked,
  };
}

/// Default capability floor for provider-level route surfaces. It reflects the
/// common agentic coding case without reading the task: require a measured
/// included-quota provider to have at least one standard-or-better reasoning
/// model with budget before that provider can win the default route.
const kDefaultProviderRouteRequirements = ModelRequirements(
  requireReasoning: true,
  tierFloor: 'standard',
  budgetPolicy: ModelBudgetPolicy.quota,
);

class ModelCapabilityGates {
  /// Provider/account keys with at least one catalog model that satisfies the
  /// capability floor, regardless of whether its quota gate currently has
  /// headroom.
  final Set<String> knownQuotaKeys;

  /// Provider/account keys with at least one satisfying model whose own budget
  /// gate is available now.
  final Set<String> availableQuotaKeys;

  /// Provider/account keys with known matching capability but no available
  /// model budget, mapped to the earliest known reset of a matching model gate.
  final Map<String, int> budgetResetByQuotaKey;

  const ModelCapabilityGates({
    required this.knownQuotaKeys,
    required this.availableQuotaKeys,
    this.budgetResetByQuotaKey = const {},
  });
}

ModelCapabilityGates modelCapabilityGates(
  List<ProviderQuota> snapshot,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
  ModelRequirements requirements = kDefaultProviderRouteRequirements,
}) {
  final known = <String>{};
  final available = <String>{};
  final budgetResets = <String, int>{};
  for (final entry in buildModelRegistry(snapshot, now, catalog: catalog)) {
    if (entry.local || !meetsRequirements(entry, requirements)) continue;
    final key = quotaIdentityKey(entry.provider, entry.account);
    known.add(key);
    if (entry.available) {
      available.add(key);
    } else {
      final reset = entry.resetsAt;
      if (reset != null) {
        budgetResets.update(
          key,
          (previous) => previous <= reset ? previous : reset,
          ifAbsent: () => reset,
        );
      }
    }
  }
  return ModelCapabilityGates(
    knownQuotaKeys: known,
    availableQuotaKeys: available,
    budgetResetByQuotaKey: budgetResets,
  );
}

ModelCapabilityGates providerRouteCapabilityGates(
  List<ProviderQuota> snapshot,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
  ModelRequirements? requirements,
}) =>
    modelCapabilityGates(
      snapshot,
      now,
      catalog: catalog,
      requirements: requirements ?? kDefaultProviderRouteRequirements,
    );

/// Builds the registry from a snapshot. For each provider, local models come from
/// `q.models` (live) and cloud models from `catalog[provider]`; every model
/// gets the provider-wide, model-specific, or provider-family budget gate that
/// controls it. Optionally filtered to models meeting [requirements]. Sorted so
/// the most routable models lead: available first, cloud before local (local is
/// the fallback), then by most headroom.
List<ModelEntry> buildModelRegistry(
  List<ProviderQuota> snapshot,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
  ModelRequirements requirements = const ModelRequirements(),
}) {
  final entries = <ModelEntry>[];
  for (final q in snapshot) {
    if (!q.isLocal && q.windows.isEmpty) continue;
    final models = q.isLocal ? q.models : (catalog[q.provider] ?? const []);
    if (models.isEmpty) continue;
    final a = providerAvailability(q, now);
    final binding = bindingWindow(q, now);
    final providerQuotaBacked = !q.isLocal &&
        !q.isManual &&
        q.windows.isNotEmpty &&
        kQuotaPlanProviders.contains(q.provider);
    for (final m in models) {
      final budget = q.isLocal
          ? null
          : _modelBudgetFor(
              q,
              m,
              providerHeadroom: a.headroom,
              providerAvailable: a.available,
              providerResetsAt: a.resetsAt,
              bindingLabel: binding?.label,
            );
      final quotaBacked = providerQuotaBacked &&
          (m.quotaIncludedUntil == null || now < m.quotaIncludedUntil!);
      entries.add(ModelEntry(
        model: m,
        provider: q.provider,
        account: q.account,
        local: q.isLocal,
        source: q.source,
        sourceClass: q.sourceClass,
        quotaBacked: quotaBacked,
        hardwareFit: q.isLocal && !m.cloudOffloaded
            ? localModelHardwareFit(m, q.localHardware)
            : null,
        headroomPercent: budget?.headroomPercent,
        resetsAt: budget?.resetsAt,
        gatingWindow: budget?.gatingWindow,
        available: q.isLocal
            ? isLocalRuntimeAvailableAt(q, now)
            : budget?.available ?? false,
        stale: q.stale,
        driftReason: q.driftReason,
        driftObservedAt: q.driftObservedAt,
        asOf: q.asOf,
        perMachine: q.perMachine,
      ));
    }
  }

  final filtered = requirements.isEmpty
      ? entries
      : entries.where((e) => meetsRequirements(e, requirements)).toList();
  filtered.sort((x, y) {
    if (x.available != y.available) return x.available ? -1 : 1;
    if (x.local != y.local) return x.local ? 1 : -1; // cloud before local
    if (x.local &&
        y.local &&
        x.model.cloudOffloaded != y.model.cloudOffloaded) {
      return x.model.cloudOffloaded ? 1 : -1;
    }
    if (x.local && y.local && x.model.loaded != y.model.loaded) {
      return x.model.loaded ? -1 : 1;
    }
    if (x.local && y.local) {
      final fit = _hardwareFitRank(x.hardwareFit?.status)
          .compareTo(_hardwareFitRank(y.hardwareFit?.status));
      if (fit != 0) return fit;
    }
    final hx = x.headroomPercent ?? (x.local ? 100.0 : -1.0);
    final hy = y.headroomPercent ?? (y.local ? 100.0 : -1.0);
    if (hx != hy) return hy.compareTo(hx);
    return x.model.id.compareTo(y.model.id);
  });
  return filtered;
}

({
  double? headroomPercent,
  int? resetsAt,
  String? gatingWindow,
  bool available,
}) _modelBudgetFor(
  ProviderQuota q,
  ModelInfo model, {
  required double? providerHeadroom,
  required bool providerAvailable,
  required int? providerResetsAt,
  required String? bindingLabel,
}) {
  if (q.modelQuotas.isEmpty) {
    return (
      headroomPercent: providerHeadroom,
      resetsAt: providerResetsAt,
      gatingWindow: bindingLabel,
      available: providerAvailable,
    );
  }
  final quota = _matchingModelQuota(q.modelQuotas, model);
  final headroom = quota?.remainingPercent;
  final reset = quota?.resetsAt;
  return (
    headroomPercent: headroom,
    resetsAt: reset,
    gatingWindow: reset == null ? null : resetLabel(reset, q.asOf),
    available:
        providerAvailable && headroom != null && headroom > kSpentHeadroomFloor,
  );
}

ModelQuota? _matchingModelQuota(List<ModelQuota> quotas, ModelInfo model) {
  final modelKeys = _modelIdentityKeys(model.id, model.displayName);
  ModelQuota? best;
  var bestScore = 0;
  for (final quota in quotas) {
    final score = _modelQuotaMatchScore(_modelQuotaKey(quota.model), modelKeys);
    if (score > bestScore) {
      best = quota;
      bestScore = score;
    }
  }
  return best;
}

int _modelQuotaMatchScore(String quotaKey, Set<String> modelKeys) {
  if (modelKeys.contains(quotaKey)) return 3;
  if (modelKeys.any((modelKey) => quotaKey.startsWith(modelKey))) return 2;
  if (_isProviderFamilyQuotaKey(quotaKey) &&
      modelKeys.any((modelKey) => modelKey.startsWith(quotaKey))) {
    return 1;
  }
  return 0;
}

Set<String> _modelIdentityKeys(String id, String? displayName) => {
      _modelQuotaKey(id),
      if (displayName != null) _modelQuotaKey(displayName),
    };

String _modelQuotaKey(String label) =>
    label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

bool _isProviderFamilyQuotaKey(String key) =>
    key == 'gemini' || key == 'claude' || key == 'gptoss';

/// The registry as the `quotabot.models.v1` JSON envelope, shared by the CLI
/// `models` command and the MCP `list_models` tool so both speak one shape.
Map<String, dynamic> modelRegistryJson(
  List<ProviderQuota> providers,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
  ModelRequirements requirements = const ModelRequirements(),
}) =>
    {
      'schema': 'quotabot.models.v1',
      'generated_at': now,
      'catalog_updated': kCatalogUpdated,
      'budget_policy': requirements.budgetPolicy.wireName,
      'models': buildModelRegistry(providers, now,
              catalog: catalog, requirements: requirements)
          .map((e) => e.toJson())
          .toList(),
    };

ExpiringQuotaSignal? _entryExpiringSignal(
  ModelEntry e,
  Map<String, ExpiringQuotaSignal> signals,
) =>
    !e.local && e.quotaBacked && e.available
        ? signals[_quotaSignalKey(e.provider, e.account)]
        : null;

String _quotaSignalKey(String provider, String account) =>
    '$provider\u0000$account';

/// Recommendation order for picking one model: usable now first, then optionally
/// soon-expiring included quota, then local-runtime before cloud, then loaded
/// local readiness, the lightest provider-declared tier, and remaining headroom.
int _recommendCompare(
  ModelEntry a,
  ModelEntry b, {
  Map<String, ExpiringQuotaSignal> expiringQuotaByProvider = const {},
}) {
  if (a.available != b.available) return a.available ? -1 : 1;
  if (expiringQuotaByProvider.isNotEmpty) {
    final aw = _entryExpiringSignal(a, expiringQuotaByProvider);
    final bw = _entryExpiringSignal(b, expiringQuotaByProvider);
    if ((aw != null) != (bw != null)) return aw != null ? -1 : 1;
    if (aw != null && bw != null) {
      final tier = _tierRank(a.model.tier).compareTo(_tierRank(b.model.tier));
      if (tier != 0) return tier;
      final waste = bw.wastedAtReset.compareTo(aw.wastedAtReset);
      if (waste != 0) return waste;
    }
  }
  if (a.local != b.local) return a.local ? -1 : 1;
  if (a.local && b.local && a.model.cloudOffloaded != b.model.cloudOffloaded) {
    return a.model.cloudOffloaded ? 1 : -1;
  }
  if (a.local && b.local && a.model.loaded != b.model.loaded) {
    return a.model.loaded ? -1 : 1;
  }
  if (a.local && b.local) {
    final fit = _hardwareFitRank(a.hardwareFit?.status)
        .compareTo(_hardwareFitRank(b.hardwareFit?.status));
    if (fit != 0) return fit;
  }
  final tier = _tierRank(a.model.tier).compareTo(_tierRank(b.model.tier));
  if (tier != 0) return tier;
  final ha = a.headroomPercent ?? 100.0;
  final hb = b.headroomPercent ?? 100.0;
  return hb.compareTo(ha);
}

String _recommendReason(
  ModelEntry e, {
  ExpiringQuotaSignal? expiringQuota,
}) {
  if (e.local) {
    final readiness = e.model.loaded
        ? 'loaded and ready now'
        : 'installed locally; cold start may be required';
    final evidence = _localModelEvidence(e.model);
    final fit = _localHardwareFitReason(e.hardwareFit);
    return '${e.model.id} (local-runtime entry) is $readiness'
        '${evidence.isEmpty ? '' : ' (${evidence.join(', ')})'}'
        '${fit == null ? '' : '; $fit'} '
        'and has no tracked subscription window; verify execution location and '
        'cost separately.';
  }
  final h = e.headroomPercent?.round();
  final tier = e.model.tier ?? 'available';
  if (expiringQuota != null) {
    return '${e.model.id} on ${e.provider} uses included quota projected to '
        'expire ${expiringQuota.wastedAtReset.round()}% unused at reset'
        '${h == null ? '' : ' ($h% free)'}.';
  }
  return '${e.model.id} on ${e.provider} - lightest $tier tier with budget'
      '${h == null ? '' : ' ($h% free)'}.';
}

List<String> _localModelEvidence(ModelInfo model) {
  final evidence = <String>[];
  if (model.loaded && model.vramBytes != null) {
    evidence.add('${formatCompactBytes(model.vramBytes!)} VRAM');
  } else if (!model.loaded && model.sizeBytes != null) {
    evidence.add('${formatCompactBytes(model.sizeBytes!)} on disk');
  }
  if (model.contextTokens != null) {
    evidence.add('${formatContextTokens(model.contextTokens!)} ctx');
  }
  if (model.quant != null) evidence.add(model.quant!);
  return evidence;
}

String? _localHardwareFitReason(LocalModelHardwareFit? fit) {
  if (fit == null || fit.status == LocalHardwareFitStatus.loaded) return null;
  final estimate = fit.estimatedMemoryBytes;
  if (fit.status == LocalHardwareFitStatus.unknown) {
    return estimate == null
        ? 'hardware fit is unknown because model size is unavailable'
        : 'hardware fit is unknown because machine capacity is unavailable '
            '(${formatCompactBytes(estimate)} estimated)';
  }
  final pool = fit.basis == 'gpu_memory' ? 'GPU memory' : 'system RAM';
  final capacity = fit.availableBytes == null
      ? '${formatCompactBytes(fit.totalBytes!)} total'
      : '${formatCompactBytes(fit.availableBytes!)} available of '
          '${formatCompactBytes(fit.totalBytes!)}';
  final label = switch (fit.status) {
    LocalHardwareFitStatus.comfortable => 'comfortable',
    LocalHardwareFitStatus.tight => 'tight',
    LocalHardwareFitStatus.constrained => 'constrained',
    _ => fit.status.wireName,
  };
  return '$label metadata-only hardware fit '
      '(${formatCompactBytes(estimate!)} estimated against $capacity $pool)';
}

/// A concrete-model recommendation for a task profile.
class ModelSuggestion {
  /// The recommended model, or null when none with budget meets the profile.
  final ModelEntry? recommended;

  /// All qualifying models in recommendation order (best first).
  final List<ModelEntry> ranked;

  /// Budget envelope applied before ranking.
  final ModelBudgetPolicy budgetPolicy;

  /// One-line human explanation.
  final String reason;

  /// True when the recommendation was allowed to prefer soon-expiring included
  /// quota over a local model.
  final bool useExpiringQuota;

  /// The waste floor used for opt-in expiring-quota preference.
  final double expiringQuotaThresholdPercent;

  /// The reset horizon used for opt-in expiring-quota preference.
  final int expiringQuotaMaxHours;

  /// Evidence used when the recommendation preferred expiring included quota.
  final ExpiringQuotaSignal? expiringQuotaUsed;

  const ModelSuggestion(
    this.recommended,
    this.ranked,
    this.reason, {
    this.budgetPolicy = ModelBudgetPolicy.any,
    this.useExpiringQuota = false,
    this.expiringQuotaThresholdPercent = kDefaultExpiringQuotaWasteThreshold,
    this.expiringQuotaMaxHours = kDefaultExpiringQuotaMaxHours,
    this.expiringQuotaUsed,
  });

  Map<String, dynamic> toJson(int now) => {
        'schema': 'quotabot.suggest_model.v1',
        'generated_at': now,
        'budget_policy': budgetPolicy.wireName,
        if (useExpiringQuota) ...{
          'use_expiring_quota': true,
          'expiring_quota_threshold_percent': expiringQuotaThresholdPercent,
          'expiring_quota_max_hours': expiringQuotaMaxHours,
        },
        'recommended': recommended?.toJson(),
        if (expiringQuotaUsed != null)
          'expiring_quota': expiringQuotaUsed!.toJson(),
        'reason': reason,
        'ranked': ranked.map((e) => e.toJson()).toList(),
      };
}

/// Recommends one concrete model for a task: available first, optional expiring
/// included quota, local-runtime readiness, provider-declared tier, then
/// headroom. Pure.
ModelSuggestion suggestModel(
  List<ProviderQuota> snapshot,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
  ModelRequirements requirements = const ModelRequirements(),
  bool useExpiringQuota = false,
  Map<String, ExpiringQuotaSignal> expiringQuotaByProvider = const {},
  double expiringQuotaThresholdPercent = kDefaultExpiringQuotaWasteThreshold,
  int expiringQuotaMaxHours = kDefaultExpiringQuotaMaxHours,
}) {
  final ranked = buildModelRegistry(snapshot, now,
      catalog: catalog, requirements: requirements)
    ..sort((a, b) => _recommendCompare(
          a,
          b,
          expiringQuotaByProvider: expiringQuotaByProvider,
        ));
  ModelEntry? pick;
  for (final e in ranked) {
    if (e.available) {
      pick = e;
      break;
    }
  }
  final reason = pick == null
      ? (ranked.isEmpty
          ? snapshot.any((quota) => quota.driftReason != null)
              ? 'Provider drift leaves no trusted model-budget evidence; run '
                  'quotabot verify before routing.'
              : 'No model meets the requirements; relax them or connect a provider.'
          : ranked.every((entry) => entry.driftReason != null)
              ? 'Models match, but provider drift leaves only stale '
                  'last-trusted quota evidence; run quotabot verify before '
                  'routing.'
              : 'Models match but none has budget right now; wait for a reset.')
      : _recommendReason(
          pick,
          expiringQuota: _entryExpiringSignal(
            pick,
            expiringQuotaByProvider,
          ),
        );
  return ModelSuggestion(
    pick,
    ranked,
    reason,
    budgetPolicy: requirements.budgetPolicy,
    useExpiringQuota: useExpiringQuota,
    expiringQuotaThresholdPercent: expiringQuotaThresholdPercent,
    expiringQuotaMaxHours: expiringQuotaMaxHours,
    expiringQuotaUsed: pick == null
        ? null
        : _entryExpiringSignal(pick, expiringQuotaByProvider),
  );
}
