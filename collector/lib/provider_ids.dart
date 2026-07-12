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

/// Retired provider ids mapped to their current canonical id, so a provider
/// rename does not silently orphan a user's profiles, hidden-provider choices,
/// manual entries, provider filters, leases, or routing resolution.
///
/// Empty until a real rename ships. Adding one entry here makes every identity
/// seam that funnels through [canonicalizeProviderId] resolve the old id to the
/// new one. The map is strictly one-way (old id -> current id): never add a
/// current, registered id as a key, and never point two current ids at each
/// other. A rename should also update the provider's own id constant above and
/// its adapter registration so fresh reads emit the new id; this map covers the
/// persisted references that predate the rename. (Cached snapshots, history, and
/// analytics buckets written under the old id regenerate from live reads after a
/// rename; the durable user state - profiles, leases, manual entries - is what
/// the alias preserves.)
const Map<String, String> kProviderIdAliases = <String, String>{};

/// Resolves a syntactically normalized provider id to its current canonical id,
/// applying any rename in [aliases] (the shipped [kProviderIdAliases] by
/// default, which is empty, so this is identity for every shipped provider until
/// a rename is registered). The [aliases] parameter exists so the resolution can
/// be exercised end to end with a synthetic rename in tests.
String canonicalizeProviderId(
  String id, [
  Map<String, String> aliases = kProviderIdAliases,
]) =>
    aliases[id] ?? id;
