import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../local_runtime_config.dart';
import '../models.dart';
import '../provider_ids.dart';
import '../util.dart';
import 'ollama.dart' show LocalModel, localRuntimeQuota;

/// Detects a local Lemonade Server (the AMD/lemonade-sdk OpenAI-compatible
/// runtime) and reports its installed models, like the other local runtimes.
///
/// Lemonade exposes an OpenAI-compatible API; quotabot lists models from
/// `GET /api/v1/models`, falling back to `/v1/models`. The server defaults to
/// 127.0.0.1:13305; honors LEMONADE_HOST and LEMONADE_PORT. No quota: a local
/// runtime has nothing to spend, so it acts as an always-available fallback.
class LemonadeAdapter {
  static const id = lemonadeProviderId;
  static const name = lemonadeProviderName;

  final http.Client? _injectedClient;
  final Map<String, String> _environment;
  LemonadeAdapter({http.Client? client, Map<String, String>? environment})
      : _injectedClient = client,
        _environment = environment ?? Platform.environment;

  static String baseUrl({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    return localBaseUrl(
      env['LEMONADE_HOST'],
      lemonadeDefaultPort,
      rawPort: env['LEMONADE_PORT'],
    );
  }

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    if (!isLoopbackRuntimeHost(_environment['LEMONADE_HOST'])) {
      return _nonLoopback(asOf);
    }
    // Own the client for this collect: close it in `finally` when we created it,
    // so a long-lived TUI's periodic refresh does not leak a client (and its
    // connection pool) every cycle. An injected client is the caller's to close.
    final client = _injectedClient ?? http.Client();
    try {
      for (final path in const ['/api/v1/models', '/v1/models']) {
        final models = await _models(path, client);
        if (models != null) {
          final healthPath =
              path.startsWith('/api/') ? '/api/v1/health' : '/v1/health';
          final loaded = await _loadedModels(healthPath, client) ?? const [];
          final installedNames = {for (final model in models) model.name};
          return localRuntimeQuota(
            id: id,
            name: name,
            asOf: asOf,
            installed: models,
            loaded: [
              for (final model in loaded)
                if (installedNames.contains(model.name)) model,
            ],
          );
        }
      }
      return _notRunning(asOf);
    } catch (_) {
      return _notRunning(asOf);
    } finally {
      if (_injectedClient == null) client.close();
    }
  }

  Future<List<LocalModel>?> _models(String path, http.Client client) async {
    try {
      final resp = await client
          .get(Uri.parse('${baseUrl(environment: _environment)}$path'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      return lemonadeModelsFromJson(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  Future<List<LocalModel>?> _loadedModels(
    String path,
    http.Client client,
  ) async {
    try {
      final resp = await client
          .get(Uri.parse('${baseUrl(environment: _environment)}$path'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      return lemonadeLoadedModelsFromJson(jsonDecode(resp.body));
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

/// Parses Lemonade's extended OpenAI-compatible model list. The default list
/// contains downloaded local models, but configured cloud providers also add
/// remotely executed entries with `recipe: "cloud"`. Keep those visible for
/// inspection while marking them cloud-offloaded so they can never prove free
/// on-device capacity. An explicit non-downloaded local catalog entry is not an
/// installed model and is therefore omitted.
List<LocalModel>? lemonadeModelsFromJson(dynamic data) {
  final list = data is Map ? data['data'] : null;
  if (list is! List) return null;
  final models = <LocalModel>[];
  for (final raw in list) {
    if (raw is! Map || raw['id'] is! String) continue;
    final id = (raw['id'] as String).trim();
    if (id.isEmpty) continue;
    if (raw.containsKey('recipe') &&
        raw['recipe'] != null &&
        raw['recipe'] is! String) {
      continue;
    }
    if (raw.containsKey('cloud_provider') &&
        raw['cloud_provider'] != null &&
        raw['cloud_provider'] is! String) {
      continue;
    }
    final recipe = raw['recipe'] is String
        ? (raw['recipe'] as String).trim().toLowerCase()
        : null;
    final cloudProvider = raw['cloud_provider'] is String
        ? (raw['cloud_provider'] as String).trim()
        : '';
    final cloud = recipe == 'cloud' || cloudProvider.isNotEmpty;
    if (!cloud && raw.containsKey('downloaded') && raw['downloaded'] is! bool) {
      continue;
    }
    if (raw['downloaded'] == false && !cloud) continue;

    final rawLabels = raw['labels'];
    final labels = rawLabels is List
        ? <String>{
            for (final label in rawLabels)
              if (label is String) label.trim().toLowerCase(),
          }
        : null;
    models.add((
      name: id,
      bytes: null,
      param: null,
      quant: null,
      vramBytes: null,
      expiresAt: null,
      context: boundedIntFromWire(
        raw['max_context_window'],
        min: 1,
        max: 100000000,
      ),
      cloud: cloud,
      upstreamRouting: UpstreamRouting.notReported,
      tools: labels?.contains('tool-calling'),
      vision: labels?.contains('vision'),
      reasoning: null,
      embedding: labels?.contains('embeddings') == true ? true : null,
      digest: null,
    ));
  }
  return models;
}

/// Parses Lemonade's health response into the models currently loaded by its
/// backend processes. Optional health metadata fails soft and never determines
/// whether the inventory endpoint itself is reachable.
List<LocalModel>? lemonadeLoadedModelsFromJson(dynamic data) {
  if (data is! Map) return null;
  final rawLoaded = data['all_models_loaded'];
  if (rawLoaded is List) {
    final loaded = <LocalModel>[];
    for (final raw in rawLoaded) {
      if (raw is! Map) continue;
      final model = _lemonadeLoadedModel(raw);
      if (model != null) loaded.add(model);
    }
    return loaded;
  }
  if (data.containsKey('all_models_loaded')) return null;

  // Older servers exposed only the most recently loaded model name.
  final legacy = data['model_loaded'];
  if (legacy is! String || legacy.trim().isEmpty) return null;
  return [_localModel(name: legacy.trim())];
}

LocalModel? _lemonadeLoadedModel(Map<dynamic, dynamic> raw) {
  final rawName = raw['model_name'];
  if (rawName is! String || rawName.trim().isEmpty) return null;
  final options = raw['recipe_options'];
  return _localModel(
    name: rawName.trim(),
    context: options is Map
        ? boundedIntFromWire(
            options['ctx_size'],
            min: 1,
            max: 100000000,
          )
        : null,
  );
}

LocalModel _localModel({required String name, int? context}) => (
      name: name,
      bytes: null,
      param: null,
      quant: null,
      vramBytes: null,
      expiresAt: null,
      context: context,
      cloud: false,
      upstreamRouting: UpstreamRouting.notReported,
      tools: null,
      vision: null,
      reasoning: null,
      embedding: null,
      digest: null,
    );
