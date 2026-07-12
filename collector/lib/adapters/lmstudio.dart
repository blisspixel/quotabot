import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../local_runtime_config.dart';
import '../models.dart';
import '../provider_ids.dart';
import '../util.dart';
import 'ollama.dart' show LocalModel, localRuntimeQuota;

/// Detects a local LM Studio server and reports installed and loaded models,
/// the same way the Ollama adapter does (no quota; a local runtime has nothing
/// to spend).
///
/// Prefers LM Studio's current native REST API (`GET /api/v1/models`, released
/// in 0.4.0), which reports richer per-model evidence (loaded instances with the
/// running context length, on-disk size, quantization, parameter size, and
/// capabilities). Falls back to the older native `GET /api/v0/models` (a
/// per-model loaded/not-loaded `state`), then the OpenAI-compatible
/// `GET /v1/models`, which lists models without load state. LM Studio's local
/// server defaults to 127.0.0.1:1234; honors LMSTUDIO_HOST. Reads model metadata
/// only; never loads or invokes a model.
class LmStudioAdapter {
  static const id = lmStudioProviderId;
  static const name = lmStudioProviderName;

  static String baseUrl() =>
      localBaseUrl(Platform.environment['LMSTUDIO_HOST'], lmStudioDefaultPort);

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final native = await _v1Models() ?? await _nativeModels();
      if (native != null) {
        return localRuntimeQuota(
          id: id,
          name: name,
          asOf: asOf,
          installed: native.installed,
          loaded: native.loaded,
        );
      }
      // Fallback: OpenAI-compatible listing has no load state.
      final compat = await _compatModels();
      if (compat == null) return _notRunning(asOf);
      return localRuntimeQuota(
        id: id,
        name: name,
        asOf: asOf,
        installed: compat,
        loaded: const [],
      );
    } catch (_) {
      return _notRunning(asOf);
    }
  }

  Future<({List<LocalModel> installed, List<LocalModel> loaded})?>
      _v1Models() async {
    try {
      final resp = await http
          .get(Uri.parse('${baseUrl()}/api/v1/models'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      return lmStudioV1FromJson(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  Future<({List<LocalModel> installed, List<LocalModel> loaded})?>
      _nativeModels() async {
    try {
      final resp = await http
          .get(Uri.parse('${baseUrl()}/api/v0/models'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      return lmStudioNativeFromJson(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  Future<List<LocalModel>?> _compatModels() async {
    try {
      final resp = await http
          .get(Uri.parse('${baseUrl()}/v1/models'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      return lmStudioCompatFromJson(jsonDecode(resp.body));
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
}

/// Parses LM Studio's current native `/api/v1/models` body (0.4.0+) into
/// installed/loaded model lists, or null when the shape is unexpected. Loaded
/// models carry one or more `loaded_instances`; the running context length comes
/// from the loaded instance's config, otherwise the model's max. Unlike v0, v1
/// exposes a real parameter size (`params_string`) and object-shaped
/// quantization. Pure for testing; reads metadata only.
({List<LocalModel> installed, List<LocalModel> loaded})? lmStudioV1FromJson(
  dynamic data,
) {
  final list = data is Map ? data['models'] : null;
  if (list is! List) return null;
  final installed = <LocalModel>[];
  final loaded = <LocalModel>[];
  for (final m in list) {
    if (m is! Map || m['key'] is! String) continue;
    final instances = m['loaded_instances'];
    final isLoaded = instances is List && instances.isNotEmpty;
    final firstInstance =
        isLoaded && instances.first is Map ? instances.first as Map : null;
    final loadedConfig = firstInstance?['config'];
    final loadedContext = loadedConfig is Map
        ? finiteOrNull(loadedConfig['context_length'])?.toInt()
        : null;
    final quant = m['quantization'];
    final model = (
      name: m['key'] as String,
      bytes: finiteOrNull(m['size_bytes'])?.toInt(),
      param: m['params_string'] as String?,
      quant: quant is Map ? quant['name'] as String? : null,
      vramBytes: null,
      expiresAt: null,
      context: loadedContext ?? finiteOrNull(m['max_context_length'])?.toInt(),
      cloud: false,
    );
    installed.add(model);
    if (isLoaded) loaded.add(model);
  }
  return (installed: installed, loaded: loaded);
}

/// Parses LM Studio's native `/api/v0/models` body into installed/loaded model
/// lists (loaded = those whose `state` is "loaded"), or null when the shape is
/// unexpected. Pure for testing.
({List<LocalModel> installed, List<LocalModel> loaded})? lmStudioNativeFromJson(
  dynamic data,
) {
  final list = data is Map ? data['data'] : null;
  if (list is! List) return null;
  final installed = <LocalModel>[];
  final loaded = <LocalModel>[];
  for (final m in list) {
    if (m is! Map || m['id'] is! String) continue;
    final model = (
      name: m['id'] as String,
      bytes: null,
      // LM Studio's v0 model shape carries `arch` (architecture, e.g. "llama"),
      // not a parameter size, and no parameter-count field. Leave param null
      // rather than mislabel the architecture as the model's size.
      param: null,
      quant: m['quantization'] as String?,
      vramBytes: null,
      expiresAt: null,
      context: finiteOrNull(m['loaded_context_length'])?.toInt() ??
          finiteOrNull(m['max_context_length'])?.toInt(),
      cloud: false,
    );
    installed.add(model);
    if (m['state'] == 'loaded') loaded.add(model);
  }
  return (installed: installed, loaded: loaded);
}

/// Parses an OpenAI-compatible `/v1/models` body into model names with no load
/// state. Pure for testing.
List<LocalModel>? lmStudioCompatFromJson(dynamic data) {
  final list = data is Map ? data['data'] : null;
  if (list is! List) return null;
  return [
    for (final m in list)
      if (m is Map && m['id'] is String)
        (
          name: m['id'] as String,
          bytes: null,
          param: null,
          quant: null,
          vramBytes: null,
          expiresAt: null,
          context: null,
          cloud: false,
        ),
  ];
}
