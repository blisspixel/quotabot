/// The model registry: a normalized, cross-provider list of the models you can
/// route to right now, each tagged with the live budget that gates it.
///
/// [buildModelRegistry] is pure. Local-runtime models come from the snapshot
/// (filled live by the adapters); cloud models come from an injected [catalog]
/// (a committed, refreshable capability table - see `model_catalog.dart` and the
/// refresh tool), so runtime stays zero-extra-network and local-first. Each entry
/// carries its provider's binding-window headroom and reset, so an agent sees
/// budget per model, not just per provider.
library;

import 'analysis.dart';
import 'model_catalog.dart';
import 'models.dart';

/// One routable model plus the live budget of the provider that gates it.
class ModelEntry {
  final ModelInfo model;
  final String provider;
  final String account;
  final bool local;

  /// Remaining headroom percent of the gating provider (null for local runtimes
  /// or when unknown).
  final double? headroomPercent;

  /// Reset epoch of the gating (binding) window, when known.
  final int? resetsAt;

  /// Label of the gating window (e.g. "weekly"), when metered.
  final String? gatingWindow;

  /// True when the model is usable right now (provider has headroom, or local).
  final bool available;

  /// True when the gating provider's data is cached/stale.
  final bool stale;

  const ModelEntry({
    required this.model,
    required this.provider,
    required this.account,
    required this.local,
    required this.headroomPercent,
    required this.resetsAt,
    required this.gatingWindow,
    required this.available,
    required this.stale,
  });

  Map<String, dynamic> toJson() => {
        ...model.toJson(),
        'provider': provider,
        'account': account,
        'local': local,
        'available': available,
        'stale': stale,
        if (headroomPercent != null) 'headroom_percent': headroomPercent,
        if (resetsAt != null) 'resets_at': resetsAt,
        if (gatingWindow != null) 'gating_window': gatingWindow,
      };
}

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

  const ModelRequirements({
    this.minContextTokens,
    this.requireTools = false,
    this.requireVision = false,
    this.requireReasoning = false,
    this.tierFloor,
    this.tierCeiling,
  });

  bool get isEmpty =>
      minContextTokens == null &&
      !requireTools &&
      !requireVision &&
      !requireReasoning &&
      tierFloor == null &&
      tierCeiling == null;

  /// Overlays [o] onto this: [o]'s set fields win, booleans OR together. Used to
  /// layer explicit flags on top of a coarse task profile.
  ModelRequirements merge(ModelRequirements o) => ModelRequirements(
        minContextTokens: o.minContextTokens ?? minContextTokens,
        requireTools: requireTools || o.requireTools,
        requireVision: requireVision || o.requireVision,
        requireReasoning: requireReasoning || o.requireReasoning,
        tierFloor: o.tierFloor ?? tierFloor,
        tierCeiling: o.tierCeiling ?? tierCeiling,
      );
}

/// Maps a coarse task label to a default requirement set: a documented heuristic,
/// fully overridable by explicit requirements. Unknown labels add nothing, so a
/// typo never silently filters everything out.
ModelRequirements taskProfile(String? task) {
  switch (task?.toLowerCase()) {
    case 'simple':
      return const ModelRequirements(tierCeiling: 'standard');
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

/// Builds the registry from a snapshot. For each provider, local models come from
/// `q.models` (live) and cloud models from `catalog[provider]`; every model
/// inherits its provider's binding-window budget. Optionally filtered to models
/// meeting [requirements]. Sorted so the most routable models lead: available
/// first, cloud before local (local is the fallback), then by most headroom.
List<ModelEntry> buildModelRegistry(
  List<ProviderQuota> snapshot,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
  ModelRequirements requirements = const ModelRequirements(),
}) {
  final entries = <ModelEntry>[];
  for (final q in snapshot) {
    final models = q.isLocal ? q.models : (catalog[q.provider] ?? const []);
    if (models.isEmpty) continue;
    final a = providerAvailability(q, now);
    final binding = bindingWindow(q, now);
    for (final m in models) {
      entries.add(ModelEntry(
        model: m,
        provider: q.provider,
        account: q.account,
        local: q.isLocal,
        headroomPercent: q.isLocal ? null : a.headroom,
        resetsAt: q.isLocal ? null : a.resetsAt,
        gatingWindow: q.isLocal ? null : binding?.label,
        available: q.isLocal ? q.ok : a.available,
        stale: q.stale,
      ));
    }
  }

  final filtered = requirements.isEmpty
      ? entries
      : entries.where((e) => meetsRequirements(e, requirements)).toList();
  filtered.sort((x, y) {
    if (x.available != y.available) return x.available ? -1 : 1;
    if (x.local != y.local) return x.local ? 1 : -1; // cloud before local
    final hx = x.headroomPercent ?? (x.local ? 100.0 : -1.0);
    final hy = y.headroomPercent ?? (y.local ? 100.0 : -1.0);
    if (hx != hy) return hy.compareTo(hx);
    return x.model.id.compareTo(y.model.id);
  });
  return filtered;
}

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
      'models': buildModelRegistry(providers, now,
              catalog: catalog, requirements: requirements)
          .map((e) => e.toJson())
          .toList(),
    };
