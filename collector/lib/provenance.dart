/// Shared provider-provenance classifiers: the "where did this number come from
/// and what kind of budget is it" logic that the CLI, the terminal `top` view,
/// and the report all render. Kept in one place so the surfaces cannot drift
/// apart (they previously each held a copy, and one already had).
library;

import 'model_catalog.dart';
import 'models.dart';

/// How to describe a provider's spend for the trust tag, or null when a spend
/// class does not apply (manual entries, status-only providers, and cloud reads
/// with no measured window):
/// - `loaded` / `cold`: a local runtime, by whether a model is loaded.
/// - `quota plan`: a plan-quota provider (Claude, Codex, ...), including one that
///   is unavailable, so the plan is still named.
/// - `metered plan`: any other provider with a measured window.
String? providerSpendClass(ProviderQuota q) {
  if (q.isLocal) return q.active ? 'loaded' : 'cold';
  if (q.isManual || q.sourceClass == ProviderSourceClass.statusOnly) {
    return null;
  }
  if (!q.ok && kQuotaPlanProviders.contains(q.provider)) return 'quota plan';
  if (q.windows.isEmpty) return null;
  return kQuotaPlanProviders.contains(q.provider)
      ? 'quota plan'
      : 'metered plan';
}
