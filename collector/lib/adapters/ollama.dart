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
/// optional because runtimes differ (Ollama reports size and VRAM; LM Studio
/// reports quantization and context length).
typedef LocalModel = ({
  String name,
  int? bytes,
  String? param,
  String? quant,
  int? vramBytes,
  int? expiresAt,
  int? context,
  // True when the runtime executes this model in its cloud, not on-device. Only
  // Ollama exposes such models today (a `-cloud` name suffix); other runtimes
  // are always on-device and leave this false.
  bool cloud,
  // Capabilities the runtime itself declares for this model. Null means the
  // runtime said nothing, which fails a capability requirement rather than
  // assuming the model has the capability. A runtime that lists only model
  // names (any OpenAI-compatible endpoint) leaves all three null.
  bool? tools,
  bool? vision,
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
  bool? embedding,
  int? context,
});

/// Detects a local Ollama runtime and reports what it has, not a quota.
///
/// Local runtimes have no remaining-budget to spend, so a quota bar would be
/// meaningless. Instead this reports the useful local signal: installed models
/// and total size on disk, which model is loaded (with size, quantization, and
/// VRAM), and whether anything is loaded (a proxy for being in use). It carries
/// no quota windows; routing treats it as an always-available fallback while
/// the daemon is running.
///
/// Reads `GET /api/tags` (installed), `GET /api/ps` (loaded), and, per model,
/// `POST /api/show` for the capabilities and maximum context the model list
/// omits. No login or token. Honors the standard OLLAMA_HOST override (default
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
      final installed = await _models('/api/tags');
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
  Future<List<LocalModel>?> _models(String path) async {
    try {
      final resp = await (_http?.get ?? sharedHttpClient.get)(
        Uri.parse('${baseUrl(environment: _environment)}$path'),
      ).timeout(const Duration(seconds: 2));
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
  /// new batch starts past [capabilityPassDeadline]. Anything unresolved keeps
  /// undeclared capabilities, so a slow or drifted daemon degrades to today's
  /// behavior instead of guessing. Metadata only: `/api/show` reads the model's
  /// manifest and never loads or runs it.
  Future<List<LocalModel>> _withDeclaredCapabilities(
    List<LocalModel> installed,
  ) async {
    final resolved = <String, DeclaredModelCapabilities>{};
    final pending = <LocalModel>[];
    for (final m in installed) {
      final digest = m.digest;
      final cached = digest == null ? null : _capabilities.lookup(digest);
      if (cached != null) {
        resolved[m.name] = cached;
      } else if (pending.length < maxCapabilityProbes) {
        pending.add(m);
      }
    }

    final elapsed = Stopwatch()..start();
    for (var i = 0; i < pending.length; i += capabilityProbeConcurrency) {
      if (elapsed.elapsed >= capabilityPassDeadline) break;
      final chunk = pending.skip(i).take(capabilityProbeConcurrency);
      final probed = await Future.wait([
        for (final m in chunk) _declaredCapabilities(m).then((c) => (m, c)),
      ]);
      for (final (model, caps) in probed) {
        if (caps == null) continue;
        resolved[model.name] = caps;
        final digest = model.digest;
        if (digest != null) _capabilities.store(digest, caps);
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
  Future<DeclaredModelCapabilities?> _declaredCapabilities(
    LocalModel model,
  ) async {
    try {
      final resp = await (_http?.post ?? sharedHttpClient.post)(
        Uri.parse('${baseUrl(environment: _environment)}/api/show'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'model': model.name}),
      ).timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      return ollamaShowFromJson(jsonDecode(resp.body));
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

  final _byDigest = <String, DeclaredModelCapabilities>{};

  int get length => _byDigest.length;

  DeclaredModelCapabilities? lookup(String digest) => _byDigest[digest];

  void store(String digest, DeclaredModelCapabilities capabilities) {
    if (_byDigest.length >= maxEntries) _byDigest.clear();
    _byDigest[digest] = capabilities;
  }

  void clear() => _byDigest.clear();
}

/// The process-wide capability cache used when no cache is injected.
final OllamaCapabilityCache sharedOllamaCapabilityCache =
    OllamaCapabilityCache();

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
  return (
    tools: declared.contains('tools'),
    vision: declared.contains('vision'),
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
LocalModel _declaring(
    LocalModel model, DeclaredModelCapabilities capabilities) {
  return (
    name: model.name,
    bytes: model.bytes,
    param: model.param,
    quant: model.quant,
    vramBytes: model.vramBytes,
    expiresAt: model.expiresAt,
    context: model.context ?? capabilities.context,
    cloud: model.cloud,
    tools: capabilities.tools,
    vision: capabilities.vision,
    embedding: capabilities.embedding,
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
      // Ollama cloud models carry a `-cloud` tag suffix (e.g.
      // `qwen3-coder:480b-cloud`); they run on ollama.com, not on-device.
      cloud: name.toLowerCase().endsWith('-cloud'),
      // Neither model-list endpoint declares capabilities; `/api/show` does,
      // and the adapter folds that in afterwards.
      tools: null,
      vision: null,
      embedding: null,
      digest: _digest(m['digest']),
    ));
  }
  return out;
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
/// identically: a status headline, rich detail lines, and an in-use flag, with
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
  final headline = loaded.isEmpty ? null : loaded.first;

  final status = headline == null
      ? '${installed.length} installed, idle'
      : [
          shortName(headline.name),
          if (headline.param != null) headline.param,
          if (headline.quant != null) headline.quant,
          'loaded',
        ].join(' ');

  final details = <String>[];
  if (headline != null) {
    final bits = <String>[];
    if (headline.vramBytes != null) {
      bits.add('${formatCompactBytes(headline.vramBytes!)} VRAM');
    }
    if (headline.context != null) {
      bits.add('${formatContextTokens(headline.context!)} ctx');
    }
    if (headline.expiresAt != null) {
      final secs = headline.expiresAt! - (now ?? nowEpoch());
      if (secs > 0) bits.add('unloads in ${_dur(secs)}');
    }
    if (bits.isNotEmpty) details.add(bits.join(' . '));
    if (loaded.length > 1) details.add('${loaded.length} models loaded');
  }
  final totalBytes = installed.fold<int>(0, (s, m) => s + (m.bytes ?? 0));
  details.add(
    totalBytes > 0
        ? '${installed.length} installed . ${formatCompactBytes(totalBytes)} on disk'
        : '${installed.length} installed',
  );

  // Normalize the installed list into the registry model shape, marking which
  // are loaded and folding in the loaded entry's live VRAM/context.
  final loadedByName = {for (final m in loaded) m.name: m};
  final models = [
    for (final m in installed)
      ModelInfo(
        id: m.name,
        local: true,
        cloudOffloaded: m.cloud,
        loaded: loadedByName.containsKey(m.name),
        sizeBytes: m.bytes,
        quant: m.quant,
        contextTokens: loadedByName[m.name]?.context ?? m.context,
        vramBytes: loadedByName[m.name]?.vramBytes,
        // Carried so capability gates can admit a local model the runtime
        // declares as capable. Null stays null: an undeclared capability must
        // keep failing a requirement for it.
        tools: m.tools,
        vision: m.vision,
        embedding: m.embedding,
      ),
  ];

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
