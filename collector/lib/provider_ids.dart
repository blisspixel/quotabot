/// Stable provider identifiers and display names shared by adapters, registries,
/// docs-facing contracts, and tests.
library;

const antigravityProviderId = 'antigravity';
const antigravityProviderName = 'Antigravity';

const claudeProviderId = 'claude';
const claudeProviderName = 'Claude';

const codexProviderId = 'codex';
const codexProviderName = 'Codex';

const cursorProviderId = 'cursor';
const cursorProviderName = 'Cursor';

const grokProviderId = 'grok';
const grokProviderName = 'Grok';

const kiroProviderId = 'kiro';
const kiroProviderName = 'Kiro';

const lemonadeProviderId = 'lemonade';
const lemonadeProviderName = 'Lemonade';

const lmStudioProviderId = 'lmstudio';
const lmStudioProviderName = 'LM Studio';

const ollamaProviderId = 'ollama';
const ollamaProviderName = 'Ollama';

const windsurfProviderId = 'windsurf';
const windsurfProviderName = 'Windsurf';

const nvidiaProviderId = 'nvidia';
const nvidiaProviderName = 'NVIDIA NIM';

const Set<String> kCurrentProviderIds = {
  antigravityProviderId,
  claudeProviderId,
  codexProviderId,
  cursorProviderId,
  grokProviderId,
  kiroProviderId,
  lemonadeProviderId,
  lmStudioProviderId,
  ollamaProviderId,
  windsurfProviderId,
  nvidiaProviderId,
};

/// Retired provider ids mapped to their current canonical id, so a provider
/// rename does not silently orphan a user's profiles, hidden-provider choices,
/// manual entries, provider filters, leases, or routing resolution.
///
/// Empty until a real rename ships. Adding one entry here makes every identity
/// seam that funnels through [canonicalizeProviderId] resolve the old id to the
/// new one. The map is strictly one-way (old id -> current id): never add a
/// current, registered id as a key, and never point two current ids at each
/// other. A rename should also update the provider's own id constant above and
/// its adapter registration so fresh reads emit the new id. The startup
/// provider-id coordinator preserves validated cached snapshots, drift records,
/// history, analytics buckets, and checkpoints under the canonical id. Other
/// persisted references resolve through [canonicalizeProviderId].
const Map<String, String> kProviderIdAliases = <String, String>{};

Map<String, String>? _providerIdAliasesOverrideForTesting;

/// Active one-way aliases. The override exists only for assertion-enabled
/// migration tests so a fictitious rename never enters the shipped map.
Map<String, String> get providerIdAliases =>
    _providerIdAliasesOverrideForTesting ?? kProviderIdAliases;

void setProviderIdAliasesForTesting(Map<String, String>? aliases) {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw UnsupportedError('provider alias test override is unavailable');
  }
  _providerIdAliasesOverrideForTesting =
      aliases == null ? null : Map<String, String>.unmodifiable(aliases);
}

/// Resolves a syntactically normalized provider id to its current canonical id,
/// applying any rename in [aliases] (the shipped [kProviderIdAliases] by
/// default, which is empty, so this is identity for every shipped provider until
/// a rename is registered). The [aliases] parameter exists so the resolution can
/// be exercised end to end with a synthetic rename in tests.
String canonicalizeProviderId(
  String id, [
  Map<String, String>? aliases,
]) =>
    (aliases ?? providerIdAliases)[id] ?? id;

/// Retired ids that resolve directly to [canonical], in deterministic order.
///
/// Cache migration and evidence locking use this reverse view to coordinate
/// released writers that still address the retired on-disk provider stem. It
/// deliberately accepts an injected map so migration tests never need to ship a
/// fictitious product alias.
List<String> retiredProviderIdsFor(
  String canonical, [
  Map<String, String>? aliases,
]) =>
    [
      for (final entry in (aliases ?? providerIdAliases).entries)
        if (entry.value == canonical) entry.key,
    ]..sort();
