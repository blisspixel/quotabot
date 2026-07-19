/// Compile-time registry for every built-in provider adapter.
///
/// quotabot deliberately does not support runtime plugin discovery: the desktop
/// app is ahead-of-time compiled, and provider adapters touch security-sensitive
/// local metadata. Adding a provider means adding one audited adapter and one
/// registry row here, including its sanitized parser fixture.
library;

import 'adapters/antigravity.dart';
import 'adapters/claude.dart';
import 'adapters/codex.dart';
import 'adapters/cursor.dart';
import 'adapters/grok.dart';
import 'adapters/kiro.dart';
import 'adapters/lemonade.dart';
import 'adapters/lmstudio.dart';
import 'adapters/nvidia.dart';
import 'adapters/ollama.dart';
import 'adapters/windsurf.dart';
import 'models.dart';
import 'provider_ids.dart';

const kProviderFixtureRoot = 'test/fixtures/provider_shapes';

typedef ProviderCollector = Future<List<ProviderQuota>> Function();
typedef CurrentAccountsReader = Set<String> Function();

enum ProviderAdapterClass {
  subscription(ProviderQuotaKind.subscription),
  localRuntime(ProviderQuotaKind.local);

  const ProviderAdapterClass(this.quotaKind);

  final ProviderQuotaKind quotaKind;
}

enum ProviderFixtureKind {
  codexUsage,
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
  final Set<ProviderSourceClass> sourceClasses;
  final ProviderCollector collect;
  final bool multiAccount;
  final bool cached;
  final CurrentAccountsReader? currentAccounts;
  final ProviderFixtureKind fixtureKind;
  final String fixtureFile;

  const ProviderAdapterRegistration({
    required this.id,
    required this.displayName,
    required this.adapterClass,
    required this.sourceClasses,
    required this.collect,
    required this.fixtureKind,
    required this.fixtureFile,
    this.multiAccount = false,
    this.cached = true,
    this.currentAccounts,
  });

  bool get localRuntime => adapterClass.quotaKind.isLocal;

  bool get accountScopedCache => multiAccount && currentAccounts != null;

  bool allowsSourceClass(ProviderSourceClass value) =>
      sourceClasses.contains(value);
}

const kProviderAdapterRegistry = <ProviderAdapterRegistration>[
  ProviderAdapterRegistration(
    id: claudeProviderId,
    displayName: claudeProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kAuthoritativeLiveSourceClasses,
    collect: _collectClaude,
    multiAccount: true,
    currentAccounts: _claudeCurrentAccounts,
    fixtureKind: ProviderFixtureKind.claudeUsage,
    fixtureFile: 'claude_usage.json',
  ),
  ProviderAdapterRegistration(
    id: codexProviderId,
    displayName: codexProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kAuthoritativeLiveSourceClasses,
    collect: _collectCodex,
    multiAccount: true,
    currentAccounts: _codexCurrentAccounts,
    fixtureKind: ProviderFixtureKind.codexUsage,
    fixtureFile: 'codex_usage.json',
  ),
  ProviderAdapterRegistration(
    id: cursorProviderId,
    displayName: cursorProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kPassiveLocalSourceClasses,
    collect: _collectCursor,
    fixtureKind: ProviderFixtureKind.cursorState,
    fixtureFile: 'cursor_state.json',
  ),
  ProviderAdapterRegistration(
    id: windsurfProviderId,
    displayName: windsurfProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kPassiveLocalSourceClasses,
    collect: _collectWindsurf,
    fixtureKind: ProviderFixtureKind.windsurfState,
    fixtureFile: 'windsurf_state.json',
  ),
  ProviderAdapterRegistration(
    id: kiroProviderId,
    displayName: kiroProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kPassiveLocalSourceClasses,
    collect: _collectKiro,
    fixtureKind: ProviderFixtureKind.kiroUsageState,
    fixtureFile: 'kiro_usage_state.json',
  ),
  ProviderAdapterRegistration(
    id: ollamaProviderId,
    displayName: ollamaProviderName,
    adapterClass: ProviderAdapterClass.localRuntime,
    sourceClasses: kLocalRuntimeSourceClasses,
    collect: _collectOllama,
    cached: false,
    fixtureKind: ProviderFixtureKind.ollamaTags,
    fixtureFile: 'ollama_tags.json',
  ),
  ProviderAdapterRegistration(
    id: lmStudioProviderId,
    displayName: lmStudioProviderName,
    adapterClass: ProviderAdapterClass.localRuntime,
    sourceClasses: kLocalRuntimeSourceClasses,
    collect: _collectLmStudio,
    cached: false,
    fixtureKind: ProviderFixtureKind.lmStudioNativeModels,
    fixtureFile: 'lmstudio_native.json',
  ),
  ProviderAdapterRegistration(
    id: lemonadeProviderId,
    displayName: lemonadeProviderName,
    adapterClass: ProviderAdapterClass.localRuntime,
    sourceClasses: kLocalRuntimeSourceClasses,
    collect: _collectLemonade,
    cached: false,
    fixtureKind: ProviderFixtureKind.lemonadeModels,
    fixtureFile: 'lemonade_models.json',
  ),
  ProviderAdapterRegistration(
    id: nvidiaProviderId,
    displayName: nvidiaProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kStatusOnlySourceClasses,
    collect: _collectNvidia,
    cached: false,
    fixtureKind: ProviderFixtureKind.nvidiaModels,
    fixtureFile: 'nvidia_models.json',
  ),
  ProviderAdapterRegistration(
    id: grokProviderId,
    displayName: grokProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kAuthoritativeLiveSourceClasses,
    collect: _collectGrok,
    multiAccount: true,
    currentAccounts: _grokCurrentAccounts,
    fixtureKind: ProviderFixtureKind.grokGrpcBytes,
    fixtureFile: 'grok_message_bytes.json',
  ),
  ProviderAdapterRegistration(
    id: antigravityProviderId,
    displayName: antigravityProviderName,
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kLiveOrMachineFallbackSourceClasses,
    collect: _collectAntigravity,
    multiAccount: true,
    currentAccounts: _antigravityCurrentAccounts,
    fixtureKind: ProviderFixtureKind.antigravityQuota,
    fixtureFile: 'antigravity_quota.json',
  ),
];

ProviderAdapterRegistration? providerAdapterById(String id) {
  // Canonicalize so a persisted record under a retired id still resolves to the
  // current adapter after a rename. Identity until a rename is registered.
  final normalized = canonicalizeProviderId(id.trim().toLowerCase());
  for (final entry in kProviderAdapterRegistry) {
    if (entry.id == normalized) return entry;
  }
  return null;
}

/// A plain reason when a provider observation is structurally invalid or not
/// admitted by its adapter registration. Manual user entries may be allowed by
/// verification callers, but built-in adapter collection must set
/// [allowManual] false.
String? registeredSourceClassViolation(
  ProviderQuota quota,
  ProviderAdapterRegistration? registration, {
  bool allowManual = true,
}) {
  if (registration != null && quota.provider != registration.id) {
    return 'provider ${quota.provider} does not match registered adapter '
        '${registration.id}';
  }
  final shapeViolation = quota.sourceClassViolation;
  if (shapeViolation != null) return shapeViolation;
  if (quota.sourceClass == ProviderSourceClass.manual) {
    return allowManual ? null : 'built-in adapters cannot emit manual quota';
  }
  if (registration == null) {
    return '${quota.sourceClass.label} is not backed by a registered provider adapter';
  }
  if (!registration.allowsSourceClass(quota.sourceClass)) {
    final allowed =
        registration.sourceClasses.map((value) => value.label).join(' or ');
    return '${quota.sourceClass.label} is not allowed for '
        '${registration.displayName}; expected $allowed';
  }
  return null;
}

Future<List<ProviderQuota>> _collectClaude() async =>
    [await ClaudeAdapter().collect()];

Future<List<ProviderQuota>> _collectCodex() async =>
    [await CodexAdapter().collect()];

Future<List<ProviderQuota>> _collectCursor() async =>
    [await CursorAdapter().collect()];

Future<List<ProviderQuota>> _collectWindsurf() async =>
    [await WindsurfAdapter().collect()];

Future<List<ProviderQuota>> _collectKiro() async =>
    [await KiroAdapter().collect()];

Future<List<ProviderQuota>> _collectOllama() async =>
    [await OllamaAdapter().collect()];

Future<List<ProviderQuota>> _collectLmStudio() async =>
    [await LmStudioAdapter().collect()];

Future<List<ProviderQuota>> _collectLemonade() async =>
    [await LemonadeAdapter().collect()];

Future<List<ProviderQuota>> _collectNvidia() async =>
    [await NvidiaAdapter().collect()];

Future<List<ProviderQuota>> _collectGrok() => GrokAdapter().collectAccounts();

Future<List<ProviderQuota>> _collectAntigravity() =>
    AntigravityAdapter().collectAccounts();

Set<String> _grokCurrentAccounts() => GrokAdapter.currentAccounts;

Set<String> _claudeCurrentAccounts() => ClaudeAdapter.currentAccounts;

Set<String> _codexCurrentAccounts() => CodexAdapter.currentAccounts;

Set<String> _antigravityCurrentAccounts() => AntigravityAdapter.currentAccounts;
