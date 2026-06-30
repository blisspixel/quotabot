import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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

  static String baseUrl() =>
      localBaseUrl(Platform.environment['OLLAMA_HOST'], 11434);

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
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
      final resp = await http
          .get(Uri.parse('${baseUrl()}$path'))
          .timeout(const Duration(seconds: 2));
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
        kind: 'local',
        asOf: asOf,
        ok: false,
        error: 'not running',
      );
}

/// Resolves a local runtime base URL from a raw host value (often an env var
/// like OLLAMA_HOST or LMSTUDIO_HOST). Accepts a bare host, host:port, or full
/// URL, defaults the scheme to http, and supplies [defaultPort] when none is
/// given (except https, which keeps its default 443). Pure for testing.
String localBaseUrl(String? raw, int defaultPort) {
  if (raw == null || raw.trim().isEmpty) return 'http://127.0.0.1:$defaultPort';
  var h = raw.trim();
  if (!h.startsWith('http://') && !h.startsWith('https://')) h = 'http://$h';
  final uri = Uri.parse(h);
  if (uri.hasPort) return '${uri.scheme}://${uri.host}:${uri.port}';
  if (uri.scheme == 'https') return '${uri.scheme}://${uri.host}';
  return '${uri.scheme}://${uri.host}:$defaultPort';
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
    out.add((
      name: m['name'] as String,
      bytes: (m['size'] as num?)?.toInt(),
      vramBytes: (m['size_vram'] as num?)?.toInt(),
      param: details is Map ? details['parameter_size'] as String? : null,
      quant: details is Map ? details['quantization_level'] as String? : null,
      expiresAt: parseIsoToEpoch(m['expires_at']),
      context: null,
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
    if (headline.vramBytes != null)
      bits.add('${formatCompactBytes(headline.vramBytes!)} VRAM');
    if (headline.context != null)
      bits.add('${formatContextTokens(headline.context!)} ctx');
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
    kind: 'local',
    account: '${installed.length} model${installed.length == 1 ? '' : 's'}',
    plan: 'local',
    status: status,
    active: headline != null,
    details: details,
    models: models,
  );
}

String _dur(int secs) {
  if (secs < 3600) return '${(secs / 60).round()}m';
  return '${(secs / 3600).toStringAsFixed(1)}h';
}
