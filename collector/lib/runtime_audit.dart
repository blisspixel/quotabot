import 'dart:io';

import 'local_runtime_config.dart';
import 'profiles.dart';
import 'provider_ids.dart';
import 'util.dart';

const quotabotExplainV1SchemaId = 'quotabot.explain.v1';

enum RuntimeAccessKind {
  fileRead,
  fileWrite,
  environmentRead,
  process,
  network,
}

class RuntimeAccessRecord {
  final RuntimeAccessKind kind;
  final String target;
  final String purpose;
  final String dataClass;
  final String access;
  final String? method;
  final String? scheme;
  final String? host;
  final String? path;
  final bool metadataOnly;
  final bool sendsPromptOrCode;
  final bool spendsTokens;
  final bool credentialMaterial;

  const RuntimeAccessRecord({
    required this.kind,
    required this.target,
    required this.purpose,
    required this.dataClass,
    required this.access,
    this.method,
    this.scheme,
    this.host,
    this.path,
    this.metadataOnly = true,
    this.sendsPromptOrCode = false,
    this.spendsTokens = false,
    this.credentialMaterial = false,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'target': target,
        'purpose': purpose,
        'data_class': dataClass,
        'access': access,
        if (method != null) 'method': method,
        if (scheme != null) 'scheme': scheme,
        if (host != null) 'host': host,
        if (path != null) 'path': path,
        'metadata_only': metadataOnly,
        'sends_prompt_or_code': sendsPromptOrCode,
        'spends_tokens': spendsTokens,
        'credential_material': credentialMaterial,
      };
}

class ProviderRuntimeAccess {
  final String provider;
  final String displayName;
  final String kind;
  final List<RuntimeAccessRecord> reads;
  final List<RuntimeAccessRecord> network;
  final List<String> notes;
  final bool observed;
  final String? evidence;

  const ProviderRuntimeAccess({
    required this.provider,
    required this.displayName,
    required this.kind,
    this.reads = const [],
    this.network = const [],
    this.notes = const [],
    this.observed = false,
    this.evidence,
  });

  bool get hasAccess => reads.isNotEmpty || network.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'display_name': displayName,
        'kind': kind,
        if (reads.isNotEmpty) 'reads': reads.map((r) => r.toJson()).toList(),
        if (network.isNotEmpty)
          'network': network.map((r) => r.toJson()).toList(),
        if (notes.isNotEmpty) 'notes': notes,
        if (observed) 'observed': true,
        if (evidence != null) 'evidence': evidence,
      };
}

class RuntimeAccessReport {
  final int generatedAt;
  final String os;
  final bool includeReads;
  final bool includeNetwork;
  final bool collectionExecuted;
  final String evidence;
  final String? profile;
  final List<String> excludedProviders;
  final List<ProviderRuntimeAccess> providers;
  final List<RuntimeAccessRecord> shared;
  final List<String> notes;

  const RuntimeAccessReport({
    required this.generatedAt,
    required this.os,
    required this.includeReads,
    required this.includeNetwork,
    required this.collectionExecuted,
    required this.providers,
    required this.evidence,
    this.profile,
    this.excludedProviders = const [],
    this.shared = const [],
    this.notes = const [],
  });

  Iterable<RuntimeAccessRecord> get allRecords sync* {
    yield* shared;
    for (final provider in providers) {
      yield* provider.reads;
      yield* provider.network;
    }
  }

  Map<String, dynamic> toJson() => {
        'schema': quotabotExplainV1SchemaId,
        'generated_at': generatedAt,
        'os': os,
        'mode': collectionExecuted
            ? 'runtime_access_observation'
            : 'runtime_access_manifest',
        'collection_executed': collectionExecuted,
        'include_reads': includeReads,
        'include_network': includeNetwork,
        'evidence': evidence,
        if (profile != null) 'profile': profile,
        if (excludedProviders.isNotEmpty)
          'excluded_providers': excludedProviders,
        'privacy_boundary': {
          'metadata_only': true,
          'spends_tokens': false,
          'sends_prompt_or_code': false,
          'records_secrets': false,
          'url_query_values_recorded': false,
        },
        'providers': providers.map((p) => p.toJson()).toList(),
        if (shared.isNotEmpty) 'shared': shared.map((r) => r.toJson()).toList(),
        if (notes.isNotEmpty) 'notes': notes,
      };
}

RuntimeAccessReport buildRuntimeAccessReport({
  required int generatedAt,
  required bool includeReads,
  required bool includeNetwork,
  QuotaProfile? profile,
  Set<String> excludedProviders = const {},
  List<ProviderRuntimeAccess>? providers,
  Set<String>? observedProviderIds,
  bool collectionExecuted = false,
  Map<String, String>? environment,
  String? os,
}) {
  final env = environment ?? Platform.environment;
  final operatingSystem = os ?? Platform.operatingSystem;
  final selectedProviders = providers == null
      ? defaultProviderRuntimeAccess(environment: env)
      : List<ProviderRuntimeAccess>.of(providers);
  final observedIds = observedProviderIds
      ?.map((p) => normalizeProviderId(p) ?? p)
      .where((p) => p.isNotEmpty)
      .toSet();
  final filtered = selectedProviders
      .where((p) {
        if (observedIds != null && !observedIds.contains(p.provider)) {
          return false;
        }
        if (excludedProviders.contains(p.provider)) return false;
        if (profile != null) {
          final normalizedProviders = profile.providers
              .map((p) => normalizeProviderId(p) ?? p)
              .where((p) => p.isNotEmpty)
              .toSet();
          if (normalizedProviders.isNotEmpty &&
              !normalizedProviders.contains(p.provider)) {
            return false;
          }
          final hidden = profile.hiddenProviders
              .map((p) => normalizeProviderId(p) ?? p)
              .toSet();
          if (hidden.contains(p.provider)) return false;
          if (profile.routingPolicy == ProfileRoutingPolicy.localOnly &&
              !_localProviderIds.contains(p.provider)) {
            return false;
          }
        }
        return true;
      })
      .map((p) {
        return ProviderRuntimeAccess(
          provider: p.provider,
          displayName: p.displayName,
          kind: p.kind,
          reads: includeReads ? p.reads : const [],
          network: includeNetwork ? p.network : const [],
          notes: p.notes,
          observed: collectionExecuted &&
              (observedIds == null || observedIds.contains(p.provider)),
          evidence: collectionExecuted
              ? 'provider_adapter_invoked_static_access_map'
              : null,
        );
      })
      .where((p) => p.hasAccess || p.notes.isNotEmpty)
      .toList();
  return RuntimeAccessReport(
    generatedAt: generatedAt,
    os: operatingSystem,
    includeReads: includeReads,
    includeNetwork: includeNetwork,
    collectionExecuted: collectionExecuted,
    evidence: collectionExecuted
        ? 'provider_adapter_invoked_static_access_map'
        : 'static_manifest',
    profile: profile?.name,
    excludedProviders: excludedProviders.toList()..sort(),
    providers: filtered,
    shared: includeReads ? _sharedReads(env, operatingSystem) : const [],
    notes: collectionExecuted
        ? const [
            'Provider rows are limited to adapters invoked during this collection.',
            'Access records are the audited static map for those adapters; provider-specific branches may skip some records at runtime.',
          ]
        : const [],
  );
}

List<ProviderRuntimeAccess> defaultProviderRuntimeAccess({
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final h = _home(env);
  final appData = _appData(env, h);
  final config = _configBase(env, h);
  return [
    ProviderRuntimeAccess(
      provider: claudeProviderId,
      displayName: claudeProviderName,
      kind: 'subscription',
      reads: [
        _file(_joinPath(h, '.claude/.credentials.json'),
            'Claude OAuth access token',
            dataClass: 'credential'),
        _file(_joinPath(config, 'quotabot/auth/claude*.json'),
            'quotabot stored Claude OAuth grant',
            dataClass: 'credential'),
        _fileWrite(_joinPath(config, 'quotabot/auth/claude*.json'),
            'rotated Claude OAuth grant persistence',
            dataClass: 'credential'),
      ],
      network: [
        _https('GET', 'api.anthropic.com', '/api/oauth/usage',
            'Claude usage metadata'),
        _https('POST', 'console.anthropic.com', '/v1/oauth/token',
            'Claude OAuth token refresh',
            dataClass: 'credential_exchange'),
      ],
      notes: const ['Response bodies are parsed only for quota windows.'],
    ),
    ProviderRuntimeAccess(
      provider: codexProviderId,
      displayName: codexProviderName,
      kind: 'subscription',
      reads: [
        _file(_joinPath(h, '.codex/auth.json'),
            'Codex ChatGPT OAuth access token',
            dataClass: 'credential'),
        _file(_joinPath(h, '.codex/sessions/**/rollout-*.jsonl'),
            'Codex local rate-limit fallback snapshots'),
        _file(_joinPath(config, 'quotabot/auth/codex*.json'),
            'quotabot stored Codex OAuth grant',
            dataClass: 'credential'),
        _fileWrite(_joinPath(config, 'quotabot/auth/codex*.json'),
            'rotated Codex OAuth grant persistence',
            dataClass: 'credential'),
      ],
      network: [
        _https('GET', 'chatgpt.com', '/backend-api/wham/usage',
            'Codex usage metadata'),
        _https('POST', 'auth.openai.com', '/oauth/token',
            'Codex OAuth token refresh',
            dataClass: 'credential_exchange'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: grokProviderId,
      displayName: grokProviderName,
      kind: 'subscription',
      reads: [
        _file(_joinPath(h, '.grok/auth.json'),
            'Grok CLI account and bearer token',
            dataClass: 'credential'),
        _file(_joinPath(config, 'quotabot/auth/grok*.json'),
            'quotabot stored Grok OAuth grant',
            dataClass: 'credential'),
        _fileWrite(_joinPath(config, 'quotabot/auth/grok*.json'),
            'rotated Grok OAuth grant persistence',
            dataClass: 'credential'),
      ],
      network: [
        _https(
            'POST',
            'grok.com',
            '/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig',
            'Grok billing quota metadata'),
        _https('POST', 'auth.x.ai', '/oauth2/token', 'Grok OAuth token refresh',
            dataClass: 'credential_exchange'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: antigravityProviderId,
      displayName: antigravityProviderName,
      kind: 'subscription',
      reads: [
        _file(_joinPath(appData, 'Antigravity*/**/globalStorage/state.vscdb'),
            'Antigravity account, plan, and local quota cache'),
        _file(_joinPath(h, '.gemini/oauth_creds.json'),
            'Gemini CLI OAuth fallback token',
            dataClass: 'credential'),
        _file(
            _joinPath(h, '.gemini/accounts.json'), 'Gemini CLI account labels',
            dataClass: 'account_metadata'),
        _file(_joinPath(config, 'quotabot/auth/antigravity*.json'),
            'quotabot stored Antigravity OAuth grant',
            dataClass: 'credential'),
        _fileWrite(_joinPath(config, 'quotabot/auth/antigravity*.json'),
            'rotated Antigravity OAuth grant persistence',
            dataClass: 'credential'),
      ],
      network: [
        _https('POST', 'cloudcode-pa.googleapis.com',
            '/v1internal:loadCodeAssist', 'Antigravity Code Assist metadata'),
        _https('POST', 'cloudcode-pa.googleapis.com', '/v1internal:onboardUser',
            'Antigravity Code Assist onboarding'),
        _https(
            'POST',
            'cloudcode-pa.googleapis.com',
            '/v1internal:fetchAvailableModels',
            'Antigravity per-model quota metadata'),
        _https('POST', 'oauth2.googleapis.com', '/token',
            'Google OAuth token refresh',
            dataClass: 'credential_exchange'),
        _https('GET', 'www.googleapis.com', '/oauth2/v2/userinfo',
            'Google account label lookup',
            dataClass: 'account_metadata'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: cursorProviderId,
      displayName: cursorProviderName,
      kind: 'subscription',
      reads: [
        _file(_globalStorage(appData, h, 'Cursor'),
            'Cursor local account, plan, and usage metadata'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: windsurfProviderId,
      displayName: windsurfProviderName,
      kind: 'subscription',
      reads: [
        _file(_joinPath(appData, 'Windsurf*/**/globalStorage/state.vscdb'),
            'Windsurf or Devin Desktop local quota cache'),
        _file(_joinPath(appData, 'devin/credentials.toml'),
            'Devin CLI credential presence',
            dataClass: 'credential'),
        _file(_joinPath(appData, 'devin/config.json'),
            'Devin CLI account metadata',
            dataClass: 'account_metadata'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: kiroProviderId,
      displayName: kiroProviderName,
      kind: 'subscription',
      reads: [
        _file(_globalStorage(appData, h, 'Kiro'),
            'Kiro local account and usage metadata'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: ollamaProviderId,
      displayName: ollamaProviderName,
      kind: 'local',
      network: [
        _localRuntime(env, 'OLLAMA_HOST', ollamaDefaultPort, '/api/tags',
            'Ollama installed model metadata'),
        _localRuntime(env, 'OLLAMA_HOST', ollamaDefaultPort, '/api/ps',
            'Ollama loaded model metadata'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: lmStudioProviderId,
      displayName: lmStudioProviderName,
      kind: 'local',
      network: [
        _localRuntime(env, 'LMSTUDIO_HOST', lmStudioDefaultPort,
            '/api/v1/models', 'LM Studio native model metadata'),
        _localRuntime(env, 'LMSTUDIO_HOST', lmStudioDefaultPort,
            '/api/v0/models', 'LM Studio native model metadata (older API)'),
        _localRuntime(env, 'LMSTUDIO_HOST', lmStudioDefaultPort, '/v1/models',
            'LM Studio OpenAI-compatible model metadata fallback'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: lemonadeProviderId,
      displayName: lemonadeProviderName,
      kind: 'local',
      network: [
        _localRuntime(env, 'LEMONADE_HOST', lemonadeDefaultPort,
            '/api/v1/models', 'Lemonade model metadata',
            portVariable: 'LEMONADE_PORT'),
        _localRuntime(env, 'LEMONADE_HOST', lemonadeDefaultPort, '/v1/models',
            'Lemonade OpenAI-compatible model metadata fallback',
            portVariable: 'LEMONADE_PORT'),
      ],
    ),
    ProviderRuntimeAccess(
      provider: nvidiaProviderId,
      displayName: nvidiaProviderName,
      kind: 'subscription',
      reads: const [
        RuntimeAccessRecord(
          kind: RuntimeAccessKind.environmentRead,
          target: 'environment:NVIDIA_API_KEY or environment:nvapi',
          purpose: 'NVIDIA API key presence',
          dataClass: 'credential',
          access: 'read',
          metadataOnly: false,
          credentialMaterial: true,
        ),
      ],
      network: [
        _https('GET', 'integrate.api.nvidia.com', '/v1/models',
            'NVIDIA model-list metadata and key validation'),
      ],
      notes: const ['NVIDIA is not treated as measured quota-plan budget.'],
    ),
  ];
}

List<RuntimeAccessRecord> _sharedReads(
  Map<String, String> env,
  String operatingSystem,
) {
  final h = _home(env);
  final config = _configBase(env, h);
  return [
    _file(_joinPath(config, 'quotabot/manual/manual_quotas.json'),
        'self-reported manual quota entries'),
    _file(_joinPath(config, 'quotabot/cache/*.json'),
        'last-known quota snapshot cache'),
    _fileWrite(_joinPath(config, 'quotabot/cache/*.json'),
        'fresh quota snapshot cache writes'),
    _file(_joinPath(config, 'quotabot/cache/history_*.jsonl'),
        'local analytics history for burn and calibration'),
    _fileWrite(_joinPath(config, 'quotabot/cache/history_*.jsonl'),
        'local analytics history updates'),
    _file(_joinPath(h, '.quotabot/litellm_metrics.jsonl'),
        'local LiteLLM routed-request metadata'),
    ..._localHardwareAccess(env, operatingSystem),
  ];
}

List<RuntimeAccessRecord> _localHardwareAccess(
  Map<String, String> env,
  String operatingSystem,
) =>
    switch (operatingSystem) {
      'linux' => [
          _file('/proc/meminfo', 'passive system memory capacity',
              dataClass: 'hardware_metadata'),
          _process(
            '/usr/bin/nvidia-smi --query-gpu=memory.total,memory.free',
            'largest single NVIDIA GPU memory capacity, when installed',
          ),
        ],
      'windows' => [
          _process(
            '${env['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe Get-CimInstance Win32_OperatingSystem',
            'passive system memory capacity',
          ),
          _process(
            '${env['SystemRoot'] ?? r'C:\Windows'}\\System32\\nvidia-smi.exe --query-gpu=memory.total,memory.free',
            'largest single NVIDIA GPU memory capacity, when installed',
          ),
          _process(
            '${env['ProgramFiles'] ?? r'C:\Program Files'}\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe --query-gpu=memory.total,memory.free',
            'alternate NVIDIA GPU memory utility location, when installed',
          ),
        ],
      'macos' => [
          _process(
            '/usr/sbin/sysctl -n hw.memsize',
            'passive total system memory capacity',
          ),
          _process(
            '/usr/bin/vm_stat',
            'passive available system memory capacity',
          ),
        ],
      _ => const <RuntimeAccessRecord>[],
    };

RuntimeAccessRecord _file(
  String target,
  String purpose, {
  String dataClass = 'quota_metadata',
}) =>
    RuntimeAccessRecord(
      kind: RuntimeAccessKind.fileRead,
      target: target,
      purpose: purpose,
      dataClass: dataClass,
      access: 'read',
      metadataOnly: dataClass != 'credential',
      credentialMaterial: dataClass == 'credential',
    );

RuntimeAccessRecord _fileWrite(
  String target,
  String purpose, {
  String dataClass = 'quota_metadata',
}) =>
    RuntimeAccessRecord(
      kind: RuntimeAccessKind.fileWrite,
      target: target,
      purpose: purpose,
      dataClass: dataClass,
      access: 'write',
      metadataOnly: dataClass != 'credential',
      credentialMaterial: dataClass == 'credential',
    );

RuntimeAccessRecord _process(String target, String purpose) =>
    RuntimeAccessRecord(
      kind: RuntimeAccessKind.process,
      target: target,
      purpose: purpose,
      dataClass: 'hardware_metadata',
      access: 'execute',
    );

RuntimeAccessRecord _https(
  String method,
  String host,
  String path,
  String purpose, {
  String dataClass = 'quota_metadata',
}) =>
    RuntimeAccessRecord(
      kind: RuntimeAccessKind.network,
      target: 'https://$host$path',
      method: method,
      scheme: 'https',
      host: host,
      path: path,
      purpose: purpose,
      dataClass: dataClass,
      access: 'request',
      metadataOnly: dataClass != 'credential_exchange',
      credentialMaterial: dataClass == 'credential_exchange',
    );

RuntimeAccessRecord _http(
        String method, String host, String path, String purpose,
        {String scheme = 'http'}) =>
    RuntimeAccessRecord(
      kind: RuntimeAccessKind.network,
      target: '$scheme://$host$path',
      method: method,
      scheme: scheme,
      host: host,
      path: path,
      purpose: purpose,
      dataClass: 'local_runtime_metadata',
      access: 'request',
    );

RuntimeAccessRecord _localRuntime(
  Map<String, String> env,
  String variable,
  int defaultPort,
  String path,
  String purpose, {
  String? portVariable,
}) {
  final origin = resolveLocalRuntimeOrigin(
    env[variable],
    defaultPort,
    rawPort: portVariable == null ? null : env[portVariable],
  );
  return _http('GET', origin.authority, path, purpose, scheme: origin.scheme);
}

String _home(Map<String, String> env) =>
    env['USERPROFILE'] ?? env['HOME'] ?? home();

String _configBase(Map<String, String> env, String h) =>
    env['LOCALAPPDATA'] ?? env['XDG_CONFIG_HOME'] ?? '$h/.config';

String _appData(Map<String, String> env, String h) {
  if (Platform.isWindows) return env['APPDATA'] ?? '$h/AppData/Roaming';
  if (Platform.isMacOS) return '$h/Library/Application Support';
  return env['XDG_CONFIG_HOME'] ?? '$h/.config';
}

String _globalStorage(String appData, String h, String appName) {
  if (Platform.isWindows) {
    return _joinPath(appData, '$appName/User/globalStorage/state.vscdb');
  }
  if (Platform.isMacOS) {
    return _joinPath(h,
        'Library/Application Support/$appName/User/globalStorage/state.vscdb');
  }
  return _joinPath(appData, '$appName/User/globalStorage/state.vscdb');
}

String _joinPath(String base, String relative) =>
    '$base${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

const _localProviderIds = {
  ollamaProviderId,
  lmStudioProviderId,
  lemonadeProviderId,
};
