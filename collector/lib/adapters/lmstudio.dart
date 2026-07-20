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

  final http.Client? _http;
  final Map<String, String> _environment;

  LmStudioAdapter({http.Client? client, Map<String, String>? environment})
      : _http = client,
        _environment = environment ?? Platform.environment;

  static String baseUrl({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    return localBaseUrl(env['LMSTUDIO_HOST'], lmStudioDefaultPort);
  }

  Future<http.Response> _get(String path) => (_http?.get ?? http.get)(
        Uri.parse('${baseUrl(environment: _environment)}$path'),
      ).timeout(const Duration(seconds: 2));

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    if (!isLoopbackRuntimeHost(_environment['LMSTUDIO_HOST'])) {
      return _nonLoopback(asOf);
    }
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
      final resp = await _get('/api/v1/models');
      if (resp.statusCode != 200) return null;
      return lmStudioV1FromJson(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  Future<({List<LocalModel> installed, List<LocalModel> loaded})?>
      _nativeModels() async {
    try {
      final resp = await _get('/api/v0/models');
      if (resp.statusCode != 200) return null;
      return lmStudioNativeFromJson(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  Future<List<LocalModel>?> _compatModels() async {
    try {
      final resp = await _get('/v1/models');
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
    final key = (m['key'] as String).trim();
    if (key.isEmpty) continue;
    final instances = m['loaded_instances'];
    Map<dynamic, dynamic>? firstInstance;
    if (instances is List) {
      for (final instance in instances) {
        if (instance is Map) {
          firstInstance = instance;
          break;
        }
      }
    }
    final isLoaded = firstInstance != null;
    final loadedConfig = firstInstance?['config'];
    final loadedContext = loadedConfig is Map
        ? boundedIntFromWire(
            loadedConfig['context_length'],
            min: 1,
            max: 100000000,
          )
        : null;
    final quant = m['quantization'];
    final model = (
      name: key,
      bytes: boundedIntFromWire(m['size_bytes'], min: 0),
      param: m['params_string'] is String ? m['params_string'] as String : null,
      quant: quant is Map && quant['name'] is String
          ? quant['name'] as String
          : null,
      vramBytes: null,
      expiresAt: null,
      context: loadedContext ??
          boundedIntFromWire(
            m['max_context_length'],
            min: 1,
            max: 100000000,
          ),
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
    final id = (m['id'] as String).trim();
    if (id.isEmpty) continue;
    final model = (
      name: id,
      bytes: null,
      // LM Studio's v0 model shape carries `arch` (architecture, e.g. "llama"),
      // not a parameter size, and no parameter-count field. Leave param null
      // rather than mislabel the architecture as the model's size.
      param: null,
      quant: m['quantization'] is String ? m['quantization'] as String : null,
      vramBytes: null,
      expiresAt: null,
      context: boundedIntFromWire(
            m['loaded_context_length'],
            min: 1,
            max: 100000000,
          ) ??
          boundedIntFromWire(
            m['max_context_length'],
            min: 1,
            max: 100000000,
          ),
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
      if (m is Map &&
          m['id'] is String &&
          (m['id'] as String).trim().isNotEmpty)
        (
          name: (m['id'] as String).trim(),
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
