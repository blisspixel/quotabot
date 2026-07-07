/// Compile-time registry for every built-in provider adapter.
///
/// quotabot deliberately does not support runtime plugin discovery: the desktop
/// app is ahead-of-time compiled, and provider adapters touch security-sensitive
/// local metadata. Adding a provider means adding one audited adapter and one
/// registry row here, including its sanitized parser fixture.
library;

import 'models.dart';
import 'provider_ids.dart';

const kProviderFixtureRoot = 'test/fixtures/provider_shapes';

enum ProviderAdapterClass {
  subscription(ProviderQuotaKind.subscription),
  localRuntime(ProviderQuotaKind.local);

  const ProviderAdapterClass(this.quotaKind);

  final ProviderQuotaKind quotaKind;
}

enum ProviderFixtureKind {
  codexRateLimits,
  claudeUsage,
  antigravityQuota,
  grokGrpcBytes,
  kiroUsageState,
  cursorState,
  windsurfState,
  ollamaTags,
  lmStudioNativeModels,
  lemonadeModels,
  nvidiaModels,
}

class ProviderAdapterRegistration {
  final String id;
  final String displayName;
  final ProviderAdapterClass adapterClass;
  final bool multiAccount;
  final bool cached;
  final ProviderFixtureKind fixtureKind;
  final String fixtureFile;

  const ProviderAdapterRegistration({
    required this.id,
    required this.displayName,
    required this.adapterClass,
    required this.fixtureKind,
    required this.fixtureFile,
    this.multiAccount = false,
    this.cached = true,
  });

  bool get localRuntime => adapterClass.quotaKind.isLocal;
}

const kProviderAdapterRegistry = <ProviderAdapterRegistration>[
  ProviderAdapterRegistration(
    id: claudeProviderId,
    displayName: claudeProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    fixtureKind: ProviderFixtureKind.claudeUsage,
    fixtureFile: 'claude_usage.json',
  ),
  ProviderAdapterRegistration(
    id: codexProviderId,
    displayName: codexProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    fixtureKind: ProviderFixtureKind.codexRateLimits,
    fixtureFile: 'codex_rate_limits.json',
  ),
  ProviderAdapterRegistration(
    id: cursorProviderId,
    displayName: cursorProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    fixtureKind: ProviderFixtureKind.cursorState,
    fixtureFile: 'cursor_state.json',
  ),
  ProviderAdapterRegistration(
    id: windsurfProviderId,
    displayName: windsurfProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    fixtureKind: ProviderFixtureKind.windsurfState,
    fixtureFile: 'windsurf_state.json',
  ),
  ProviderAdapterRegistration(
    id: kiroProviderId,
    displayName: kiroProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    fixtureKind: ProviderFixtureKind.kiroUsageState,
    fixtureFile: 'kiro_usage_state.json',
  ),
  ProviderAdapterRegistration(
    id: grokProviderId,
    displayName: grokProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    multiAccount: true,
    fixtureKind: ProviderFixtureKind.grokGrpcBytes,
    fixtureFile: 'grok_message_bytes.json',
  ),
  ProviderAdapterRegistration(
    id: antigravityProviderId,
    displayName: antigravityProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    multiAccount: true,
    fixtureKind: ProviderFixtureKind.antigravityQuota,
    fixtureFile: 'antigravity_quota.json',
  ),
  ProviderAdapterRegistration(
    id: ollamaProviderId,
    displayName: ollamaProviderName,
    adapterClass: ProviderAdapterClass.localRuntime,
    cached: false,
    fixtureKind: ProviderFixtureKind.ollamaTags,
    fixtureFile: 'ollama_tags.json',
  ),
  ProviderAdapterRegistration(
    id: lmStudioProviderId,
    displayName: lmStudioProviderName,
    adapterClass: ProviderAdapterClass.localRuntime,
    cached: false,
    fixtureKind: ProviderFixtureKind.lmStudioNativeModels,
    fixtureFile: 'lmstudio_native.json',
  ),
  ProviderAdapterRegistration(
    id: lemonadeProviderId,
    displayName: lemonadeProviderName,
    adapterClass: ProviderAdapterClass.localRuntime,
    cached: false,
    fixtureKind: ProviderFixtureKind.lemonadeModels,
    fixtureFile: 'lemonade_models.json',
  ),
  ProviderAdapterRegistration(
    id: nvidiaProviderId,
    displayName: nvidiaProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    cached: false,
    fixtureKind: ProviderFixtureKind.nvidiaModels,
    fixtureFile: 'nvidia_models.json',
  ),
];

ProviderAdapterRegistration? providerAdapterById(String id) {
  final normalized = id.trim().toLowerCase();
  for (final entry in kProviderAdapterRegistry) {
    if (entry.id == normalized) return entry;
  }
  return null;
}
