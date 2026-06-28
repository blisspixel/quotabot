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

/// Builds the registry from a snapshot. For each provider, local models come from
/// `q.models` (live) and cloud models from `catalog[provider]`; every model
/// inherits its provider's binding-window budget. Sorted so the most routable
/// models lead: available first, cloud before local (local is the fallback), then
/// by most headroom.
List<ModelEntry> buildModelRegistry(
  List<ProviderQuota> snapshot,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
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

  entries.sort((x, y) {
    if (x.available != y.available) return x.available ? -1 : 1;
    if (x.local != y.local) return x.local ? 1 : -1; // cloud before local
    final hx = x.headroomPercent ?? (x.local ? 100.0 : -1.0);
    final hy = y.headroomPercent ?? (y.local ? 100.0 : -1.0);
    if (hx != hy) return hy.compareTo(hx);
    return x.model.id.compareTo(y.model.id);
  });
  return entries;
}

/// The registry as the `quotabot.models.v1` JSON envelope, shared by the CLI
/// `models` command and the MCP `list_models` tool so both speak one shape.
Map<String, dynamic> modelRegistryJson(
  List<ProviderQuota> providers,
  int now, {
  Map<String, List<ModelInfo>> catalog = const {},
}) =>
    {
      'schema': 'quotabot.models.v1',
      'generated_at': now,
      'catalog_updated': kCatalogUpdated,
      'models': buildModelRegistry(providers, now, catalog: catalog)
          .map((e) => e.toJson())
          .toList(),
    };
