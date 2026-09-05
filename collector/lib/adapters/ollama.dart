import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../http_client.dart';

import '../local_runtime_config.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

/// One local model with whatever detail the runtime exposes. Fields are
/// optional because runtimes differ (Ollama reports size and GPU residency; LM Studio
/// reports quantization and context length).
typedef LocalModel = ({
  String name,
  int? bytes,
  String? param,
  String? quant,
  int? vramBytes,
  int? expiresAt,
  int? context,
  // True when the runtime explicitly identifies cloud execution. This is
  // separate from the loopback origin of the runtime's metadata endpoint.
  bool cloud,
  UpstreamRouting upstreamRouting,
  // Capabilities the runtime itself declares for this model. Null means the
  // runtime said nothing, which fails a capability requirement rather than
  // assuming the model has the capability. A runtime that lists only model
  // names (any OpenAI-compatible endpoint) leaves these undeclared.
  bool? tools,
  bool? vision,
  bool? reasoning,
  // True when the runtime declares this an embedding model rather than a text
  // generator. Null stays routable: only a stated non-generative kind removes a
  // model from routing, never the absence of a statement.
  bool? embedding,
  // The runtime's content identity for the model blob, when it reports one.
  // Used only as a capability-cache key, never shown or stored.
  String? digest,
});

/// Capability evidence one runtime declares for one model.
typedef DeclaredModelCapabilities = ({
  bool tools,
  bool vision,
  bool? reasoning,
  bool? embedding,
  int? context,
});

class _OllamaModelMetadata {
  final DeclaredModelCapabilities? capabilities;
  final UpstreamRouting upstreamRouting;

  const _OllamaModelMetadata(this.capabilities, this.upstreamRouting);
}

extension LocalModelExecutionEvidence on LocalModel {
  bool get hasLocalExecutionVeto => localExecutionVeto(
        cloudOffloaded: cloud,
        upstreamRouting: upstreamRouting,
      );
}

/// Detects a local Ollama runtime and reports what it has, not a quota.
///
/// Local runtimes have no remaining-budget to spend, so a quota bar would be
/// meaningless. Instead this reports the useful local signal: installed models
/// and total size on disk, which model is loaded (with size, quantization, and
/// GPU residency), and whether anything is loaded. Loaded residency does not
/// prove that a model is currently computing. It carries
/// no quota windows; generation fallback excludes known upstream, cloud, and
/// embedding declarations. Missing declarations do not prove execution scope.
///
/// Reads `GET /api/tags` (installed), `GET /api/ps` (loaded), and, per model,
/// `POST /api/show` for capabilities, maximum context, and upstream declarations.
/// No login or token. Honors the standard OLLAMA_HOST override (default
/// 127.0.0.1:11434).
class OllamaAdapter {
  static const id = ollamaProviderId;
  static const name = ollamaProviderName;

  /// Most models probed for capabilities in one read. A library larger than
  /// this leaves the surplus undeclared rather than making an unbounded number
  /// of requests; the digest cache means later reads work through the rest.
  static const maxCapabilityProbes = 48;

  /// Concurrent `/api/show` requests. Small enough to stay polite to a local
  /// daemon that may be serving a generation at the same time.
  static const capabilityProbeConcurrency = 4;

  /// The installed-model inventory is the evidence that the runtime exists, so
  /// allow a daemon under startup or disk pressure longer than optional detail
  /// reads. A shorter deadline made a reachable runtime disappear from a fleet
  /// snapshot when `/api/tags` took just over two seconds.
  static const inventoryRequestTimeout = Duration(seconds: 5);

  /// Loaded-state and per-model details fail soft without hiding inventory.
  static const detailRequestTimeout = Duration(seconds: 2);

  /// Wall-clock budget for the capability pass, independent of the per-request
  /// timeout, so a daemon that answers slowly cannot hold up a fleet read. No
  /// new batch starts once it is spent, and models not reached stay undeclared.
  static const capabilityPassDeadline = Duration(seconds: 4);

  final http.Client? _http;
  final Map<String, String> _environment;
  final OllamaCapabilityCache _capabilities;

  OllamaAdapter({
    http.Client? client,
    Map<String, String>? environment,
    OllamaCapabilityCache? capabilityCache,
  })  : _http = client,
        _environment = environment ?? Platform.environment,
        _capabilities = capabilityCache ?? sharedOllamaCapabilityCache;

  static String baseUrl({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    return localBaseUrl(env['OLLAMA_HOST'], ollamaDefaultPort);
  }

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    if (!isLoopbackRuntimeHost(_environment['OLLAMA_HOST'])) {
      return _nonLoopback(asOf);
    }
    try {
      final installed = await _models(
        '/api/tags',
        timeout: inventoryRequestTimeout,
      );
      if (installed == null) return _notRunning(asOf);
      final loaded = await _models('/api/ps') ?? const [];
      return localRuntimeQuota(
        id: id,
        name: name,
        asOf: asOf,
        installed: await _withDeclaredCapabilities(installed),
        loaded: loaded,
      );
    } catch (_) {
      return _notRunning(asOf);
    }
  }

  /// Fetches and parses an Ollama model list endpoint, or null when the daemon
  /// is unreachable.
  Future<List<LocalModel>?> _models(
    String path, {
    Duration timeout = detailRequestTimeout,
  }) async {
    try {
      final resp = await (_http?.get ?? sharedHttpClient.get)(
        Uri.parse('${baseUrl(environment: _environment)}$path'),
      ).timeout(timeout);
      if (resp.statusCode != 200) return null;
      return ollamaModelsFromJson(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  /// Fills in the declared capabilities and maximum context that `/api/tags`
  /// omits, by reading each model's own metadata from `/api/show`.
  ///
  /// Without this every capability filter (`--require-tools`,
  /// `--require-vision`, `--min-context`) would reject every Ollama model,
  /// because an undeclared capability never satisfies a requirement. The pass
  /// is deliberately bounded: results are cached by content digest so a refresh
  /// loop re-probes nothing, at most [maxCapabilityProbes] models are probed per
  /// read, at most [capabilityProbeConcurrency] requests are in flight, and no
  /// new batch starts past [capabilityPassDeadline]. The bounded selection
  /// rotates across unresolved models so failed or uncacheable early entries do
  /// not permanently starve the rest of a large library. Anything unresolved
  /// keeps undeclared capabilities, so a slow or drifted daemon degrades to
  /// today's behavior instead of guessing. Metadata only: `/api/show` reads the
  /// model's manifest and never loads or runs it.
  Future<List<LocalModel>> _withDeclaredCapabilities(
    List<LocalModel> installed,
  ) async {
    final resolved = <String, _OllamaModelMetadata>{};
    final pending = <LocalModel>[];
    for (final m in installed) {
      final digest = m.digest;
      final cached = digest == null ? null : _capabilities._byDigest[digest];
      if (cached != null) {
        resolved[m.name] = cached;
      } else {
        pending.add(m);
      }
    }

    final selected = _capabilities._nextProbes(
      pending,
      limit: maxCapabilityProbes,
    );
    final elapsed = Stopwatch()..start();
    for (var i = 0; i < selected.length; i += capabilityProbeConcurrency) {
      if (elapsed.elapsed >= capabilityPassDeadline) break;
      final chunk = selected.skip(i).take(capabilityProbeConcurrency);
      final probed = await Future.wait([
        for (final m in chunk) _modelMetadata(m).then((c) => (m, c)),
      ]);
      for (final (model, caps) in probed) {
        if (caps == null) continue;
        resolved[model.name] = caps;
        final digest = model.digest;
        if (digest != null) _capabilities._storeMetadata(digest, caps);
      }
    }

    if (resolved.isEmpty) return installed;
    return [
      for (final m in installed)
        if (resolved[m.name] case final caps?) _declaring(m, caps) else m,
    ];
  }

  /// Reads one model's declared metadata, or null when the daemon does not
  /// answer with a shape quotabot can trust.
  Future<_OllamaModelMetadata?> _modelMetadata(
    LocalModel model,
  ) async {
    try {
      final resp = await (_http?.post ?? sharedHttpClient.post)(
        Uri.parse('${baseUrl(environment: _environment)}/api/show'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'model': model.name}),
      ).timeout(detailRequestTimeout);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body);
      final capabilities = ollamaShowFromJson(data);
      final upstream = ollamaUpstreamRoutingFromJson(data);
      if (capabilities == null && upstream == UpstreamRouting.notReported) {
        return null;
      }
      return _OllamaModelMetadata(capabilities, upstream);
    } catch (_) {
      return null;
    }
  }

  ProviderQuota _notRunning(int asOf) => ProviderQuota(
        provider: id,
        displayName: name,
        account: 'local',
        plan: 'local',
        kind: ProviderQuotaKind.local,
        asOf: asOf,
        ok: false,
        error: 'not running',
      );

  ProviderQuota _nonLoopback(int asOf) => ProviderQuota(
        provider: id,
        displayName: name,
        account: 'local',
        plan: 'local',
        kind: ProviderQuotaKind.local,
        asOf: asOf,
        ok: true,
        status: 'configured host is not loopback',
        error: 'non-loopback runtime host is not eligible as local capacity',
      );
}

/// Remembers the capabilities a model declared, keyed by the runtime's own
/// content digest.
///
/// A digest identifies an exact model blob, so a cached entry can never
/// describe a different model: re-pulling a tag produces a new digest and is
/// probed again. That makes the capability read a one-time cost per model
/// rather than a per-refresh one, which matters for the desktop and `top`
/// refresh loops. Entries are metadata about local files only; nothing is
/// written to disk.
class OllamaCapabilityCache {
  OllamaCapabilityCache({this.maxEntries = 512});

  /// Upper bound on remembered models. Reaching it drops everything rather
  /// than tracking eviction order for a cache this cheap to refill.
  final int maxEntries;

  final _byDigest = <String, _OllamaModelMetadata>{};
  var _nextProbeOffset = 0;

  int get length => _byDigest.length;

  DeclaredModelCapabilities? lookup(String digest) =>
      _byDigest[digest]?.capabilities;

  /// Returns a bounded rotating slice of unresolved models. The cursor lives
  /// with the shared cache because collectors create a fresh adapter per read.
  List<LocalModel> _nextProbes(
    List<LocalModel> unresolved, {
    required int limit,
  }) {
    if (unresolved.isEmpty || limit <= 0) return const [];
    if (unresolved.length <= limit) {
      _nextProbeOffset = 0;
      return List.unmodifiable(unresolved);
    }

    final start = _nextProbeOffset % unresolved.length;
    final selected = <LocalModel>[
      for (var i = 0; i < limit; i++)
        unresolved[(start + i) % unresolved.length],
    ];
    _nextProbeOffset = (start + limit) % unresolved.length;
    return List.unmodifiable(selected);
  }

  void store(String digest, DeclaredModelCapabilities capabilities) {
    _storeMetadata(digest,
        _OllamaModelMetadata(capabilities, UpstreamRouting.notReported));
  }

  void _storeMetadata(String digest, _OllamaModelMetadata metadata) {
    if (_byDigest.length >= maxEntries) _byDigest.clear();
    _byDigest[digest] = metadata;
  }

  void clear() {
    _byDigest.clear();
    _nextProbeOffset = 0;
  }
}

/// The process-wide capability cache used when no cache is injected.
final OllamaCapabilityCache sharedOllamaCapabilityCache =
    OllamaCapabilityCache();

/// Reads only the declaration shape, retaining no target string. Ollama permits
/// custom upstreams through OLLAMA_REMOTES, so this never implies public cloud
/// or paid execution. Source: Ollama v0.33.3 at b79067b0, server/create.go:128
/// and server/routes.go:2522. Both fields are omitted for ordinary inventories.
UpstreamRouting ollamaUpstreamRoutingFromJson(dynamic data) {
  if (data is! Map ||
      (!data.containsKey('remote_host') && !data.containsKey('remote_model'))) {
    return UpstreamRouting.notReported;
  }
  final host = data['remote_host'];
  final model = data['remote_model'];
  if (host is! String ||
      model is! String ||
      host.isEmpty ||
      model.isEmpty ||
      host.length > 2048 ||
      model.length > 512 ||
      _upstreamInvalidCharacters.hasMatch(host) ||
      _upstreamInvalidCharacters.hasMatch(model)) {
    return UpstreamRouting.unresolved;
  }
  try {
    final uri = Uri.parse(host);
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.port < 1 ||
        uri.port > 65535) {
      return UpstreamRouting.unresolved;
    }
    return UpstreamRouting.declared;
  } on FormatException {
    return UpstreamRouting.unresolved;
  }
}

final _upstreamInvalidCharacters = RegExp(r'[\s\x00-\x1f\x7f]');

/// Parses an Ollama `/api/show` body into the capability evidence it declares,
/// or null when the body carries no capability list (an unexpected or drifted
/// shape must leave the model undeclared, not silently capable).
///
/// Ollama's `capabilities` array is exhaustive for the model, so an absent
/// entry is real evidence that the model lacks that ability. Every model that
/// can generate text declares `completion`, so a non-empty list without it is
/// an embedding-only model. An empty list states nothing at all and leaves the
/// kind unknown, because no positive evidence should remove a working route.
/// The context value is the model's own maximum,
/// published under the architecture-prefixed `<arch>.context_length` key; the
/// running context of a loaded model comes from `/api/ps` instead and takes
/// precedence over this.
DeclaredModelCapabilities? ollamaShowFromJson(dynamic data) {
  if (data is! Map) return null;
  final capabilities = data['capabilities'];
  if (capabilities is! List) return null;
  final declared = <String>{
    for (final c in capabilities)
      if (c is String) c.trim().toLowerCase(),
  };
  // Ollama declares its thinking capability in the same metadata array:
  // https://github.com/ollama/ollama/blob/main/types/model/capability.go
  // An empty or malformed list cannot newly qualify a reasoning route.
  final validReasoningDeclaration = capabilities.isNotEmpty &&
      capabilities.every((c) => c is String && c.trim().isNotEmpty);
  return (
    tools: declared.contains('tools'),
    vision: declared.contains('vision'),
    reasoning: validReasoningDeclaration ? declared.contains('thinking') : null,
    embedding: declared.isEmpty ? null : !declared.contains('completion'),
    context: _ollamaMaxContext(data['model_info']),
  );
}

/// Only the architecture-prefixed key states the model's context window.
/// Deeper keys such as `<arch>.rope.scaling.original_context_length` describe
/// the pre-scaling training context and would understate it.
final _ollamaContextKey = RegExp(r'^[^.]+\.context_length$');

int? _ollamaMaxContext(dynamic modelInfo) {
  if (modelInfo is! Map) return null;
  int? best;
  for (final entry in modelInfo.entries) {
    final key = entry.key;
    if (key is! String || !_ollamaContextKey.hasMatch(key)) continue;
    final value = boundedIntFromWire(entry.value, min: 1, max: 100000000);
    if (value == null) continue;
    if (best == null || value > best) best = value;
  }
  return best;
}

/// Returns [model] carrying [capabilities]. A context window already reported
/// by the runtime wins, because that is the model as currently configured
/// rather than the maximum the model supports.
LocalModel _declaring(LocalModel model, _OllamaModelMetadata metadata) {
  final capabilities = metadata.capabilities;
  return (
    name: model.name,
    bytes: model.bytes,
    param: model.param,
    quant: model.quant,
    vramBytes: model.vramBytes,
    expiresAt: model.expiresAt,
    context: model.context ?? capabilities?.context,
    cloud: model.cloud,
    upstreamRouting: model.upstreamRouting.combine(metadata.upstreamRouting),
    tools: capabilities?.tools ?? model.tools,
    vision: capabilities?.vision ?? model.vision,
    reasoning: capabilities?.reasoning ?? model.reasoning,
    embedding: capabilities?.embedding ?? model.embedding,
    digest: model.digest,
  );
}

/// Parses an Ollama `/api/tags` or `/api/ps` response body into [LocalModel]s.
/// Pure and defensive so it can be tested against fixtures.
List<LocalModel> ollamaModelsFromJson(dynamic data) {
  final models = data is Map ? data['models'] : null;
  if (models is! List) return const [];
  final out = <LocalModel>[];
  for (final m in models) {
    if (m is! Map || m['name'] is! String) continue;
    final details = m['details'];
    final name = (m['name'] as String).trim();
    if (name.isEmpty) continue;
    out.add((
      name: name,
      // Reject negative, fractional, and non-finite metadata from a rogue or
      // drifted localhost server rather than poisoning the model inventory.
      bytes: boundedIntFromWire(m['size'], min: 0),
      vramBytes: boundedIntFromWire(m['size_vram'], min: 0),
      param: details is Map && details['parameter_size'] is String
          ? details['parameter_size'] as String
          : null,
      quant: details is Map && details['quantization_level'] is String
          ? details['quantization_level'] as String
          : null,
      expiresAt: parseIsoToEpoch(m['expires_at']),
      // `/api/ps` reports the running model's context window directly; `/api/tags`
      // omits it (stays null there). No `/api/show` call is needed.
      context: boundedIntFromWire(
        m['context_length'],
        min: 1,
        max: 100000000,
      ),
      // Ollama cloud models use a `:cloud` source tag (`kimi-k2.5:cloud`) or a
      // `-cloud` tag suffix (`qwen3-coder:480b-cloud`). Either form runs on
      // ollama.com, not on-device.
      cloud: ollamaModelNameIsCloud(name),
      upstreamRouting: ollamaUpstreamRoutingFromJson(m),
      // Neither model-list endpoint declares capabilities; `/api/show` does,
      // and the adapter folds that in afterwards.
      tools: null,
      vision: null,
      reasoning: null,
      embedding: null,
      digest: _digest(m['digest']),
    ));
  }
  return out;
}

/// Whether an Ollama model name is a cloud-offloaded route.
///
/// Documented names use a `:cloud` source tag (`kimi-k2.5:cloud`) or a
/// `-cloud` suffix on the last tag (`qwen3-coder:480b-cloud`). Any colon
/// segment that is exactly `cloud` or that ends with `-cloud` is treated as
/// offloaded so a local-only or free budget cannot count it as on-device.
bool ollamaModelNameIsCloud(String name) {
  final lower = name.trim().toLowerCase();
  if (lower.isEmpty) return false;
  for (final segment in lower.split(':')) {
    if (segment == 'cloud' || segment.endsWith('-cloud')) return true;
  }
  return false;
}

/// Accepts a plausible content digest for use as a cache key only. A rogue or
/// drifted daemon cannot make it unbounded, and it never reaches output.
String? _digest(dynamic value) {
  if (value is! String) return null;
  final digest = value.trim();
  if (digest.isEmpty || digest.length > 128) return null;
  return digest;
}

/// Builds a normalized snapshot for a local runtime from its installed and
/// loaded models. Shared by every local-runtime adapter so they present
/// identically: a status headline, rich detail lines, and a loaded-model flag, with
/// no quota windows.
ProviderQuota localRuntimeQuota({
  required String id,
  required String name,
  required int asOf,
  required List<LocalModel> installed,
  required List<LocalModel> loaded,
  int? now,
}) {
  String shortName(String n) => n.split(':').first;
  final loadedByName = <String, List<LocalModel>>{};
  for (final model in loaded) {
    loadedByName.putIfAbsent(model.name, () => []).add(model);
  }
  // Tags, show, and running metadata may race. Combine negative declarations
  // monotonically; a name match cannot attach a different digest's residency.
  final models = <ModelInfo>[];
  final coherentLoaded = <String, LocalModel>{};
  for (final model in installed) {
    final matches = loadedByName[model.name] ?? const <LocalModel>[];
    var upstream = model.upstreamRouting;
    var cloud = model.cloud;
    var identityConflict = false;
    for (final running in matches) {
      upstream = upstream.combine(running.upstreamRouting);
      cloud = cloud || running.cloud;
      if (model.digest != null &&
          running.digest != null &&
          model.digest != running.digest) {
        identityConflict = true;
      }
    }
    final veto = localExecutionVeto(
      cloudOffloaded: cloud,
      upstreamRouting: upstream,
    );
    final running =
        matches.isEmpty || veto || identityConflict ? null : matches.first;
    if (running != null) coherentLoaded[model.name] = running;
    models.add(ModelInfo(
      id: model.name,
      local: true,
      cloudOffloaded: cloud,
      upstreamRouting: upstream,
      loaded: running != null,
      sizeBytes: model.bytes,
      quant: model.quant,
      contextTokens: running?.context ?? model.context,
      vramBytes: running?.vramBytes,
      tools: model.tools,
      vision: model.vision,
      reasoning: model.reasoning == true ? 'reasoning' : null,
      embedding: model.embedding,
    ));
  }
  final localInstalled =
      models.where((model) => !model.hasLocalGenerationVeto).toList();
  final localLoaded = localInstalled.where((model) => model.loaded).toList();
  final headline =
      localLoaded.isEmpty ? null : coherentLoaded[localLoaded.first.id];
  final hasUnresolved = models
      .any((model) => model.upstreamRouting == UpstreamRouting.unresolved);
  final hasUpstream =
      models.any((model) => model.upstreamRouting == UpstreamRouting.declared);

  final status = headline == null
      ? localInstalled.isNotEmpty
          ? 'ready - no model loaded'
          : hasUnresolved
              ? 'reachable - upstream routing unresolved'
              : hasUpstream
                  ? 'reachable - upstream routing declared'
                  : models.isNotEmpty &&
                          models.every((model) => model.cloudOffloaded)
                      ? 'reachable - cloud routes only'
                      : models.isNotEmpty
                          ? 'reachable - no generation models'
                          : 'reachable - no local models installed'
      : [
          shortName(headline.name),
          if (headline.param != null) headline.param,
          if (headline.quant != null) headline.quant,
          'loaded',
        ].join(' ');

  final details = <String>[];
  if (hasUnresolved || hasUpstream) {
    details.add(
        'Upstream routing reported; execution location and cost unverified');
  }
  if (headline != null) {
    final bits = <String>[];
    if (headline.vramBytes != null) {
      bits.add('${formatCompactBytes(headline.vramBytes!)} GPU resident');
    }
    if (headline.context != null) {
      bits.add('${formatContextTokens(headline.context!)} running context');
    }
    if (headline.expiresAt != null) {
      final secs = headline.expiresAt! - (now ?? nowEpoch());
      if (secs > 0) bits.add('unloads in ${_dur(secs)}');
    }
    if (bits.isNotEmpty) details.add(bits.join(' . '));
    if (localLoaded.length > 1) {
      details.add('+${localLoaded.length - 1} more loaded');
    }
  }
  final totalBytes = models
      .where((model) => !model.hasLocalExecutionVeto)
      .fold<int>(0, (sum, model) => sum + (model.sizeBytes ?? 0));
  details.add(
    totalBytes > 0
        ? '${installed.length} installed . ${formatCompactBytes(totalBytes)} on disk'
        : '${installed.length} installed',
  );

  return ProviderQuota(
    provider: id,
    displayName: name,
    asOf: asOf,
    kind: ProviderQuotaKind.local,
    account: '${installed.length} model${installed.length == 1 ? '' : 's'}',
    plan: 'local',
    status: status,
    active: headline != null,
    details: details,
    models: models,
    perMachine: true,
  );
}

String _dur(int secs) {
  if (secs < 3600) return '${(secs / 60).round()}m';
  return '${(secs / 3600).toStringAsFixed(1)}h';
}
