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
/// Reads `GET /api/tags` (installed) and `GET /api/ps` (loaded). No login or
/// token. Honors the standard OLLAMA_HOST override (default 127.0.0.1:11434).
class OllamaAdapter {
  static const id = ollamaProviderId;
  static const name = ollamaProviderName;

  final http.Client? _http;
  final Map<String, String> _environment;

  OllamaAdapter({http.Client? client, Map<String, String>? environment})
      : _http = client,
        _environment = environment ?? Platform.environment;

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
        installed: installed,
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
    ));
  }
  return out;
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
