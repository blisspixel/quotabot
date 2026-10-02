import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../http_client.dart';
import '../local_runtime_config.dart';
import '../models.dart';
import '../provider_ids.dart';
import '../util.dart';
import 'local_runtime_inventory.dart';
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
    final diagnostics = LocalRuntimeInventoryDiagnostics();
    try {
      for (final path in const ['/api/v1/models', '/v1/models']) {
        final inventory = await _models(path, diagnostics);
        if (inventory != null) {
          final models = inventory.models;
          final healthPath =
              path.startsWith('/api/') ? '/api/v1/health' : '/v1/health';
          final loaded = await _loadedModels(healthPath);
          final installedNames = {for (final model in models) model.name};
          return localRuntimeQuota(
            id: id,
            name: name,
            asOf: asOf,
            installed: models,
            loaded: [
              for (final model in loaded?.models ?? const <LocalModel>[])
                if (installedNames.contains(model.name)) model,
            ],
            loadedInventoryComplete: loaded?.complete ?? false,
            detailLines: [
              if (inventory.omittedComposites > 0)
                '${inventory.omittedComposites} composite '
                    'model${inventory.omittedComposites == 1 ? '' : 's'} '
                    'omitted - component scope unresolved',
            ],
          );
        }
      }
      return _unavailable(asOf, diagnostics);
    } catch (_) {
      return _unavailable(asOf, diagnostics);
    }
  }

  Future<http.Response> _get(String path) => sendMetadataRequest(
        _injectedClient ?? sharedHttpClient,
        Uri.parse('${baseUrl(environment: _environment)}$path'),
        followRedirects: false,
        maxResponseBytes: localRuntimeMetadataMaxResponseBytes,
        timeout: const Duration(seconds: 2),
      ).timeout(const Duration(seconds: 2));

  Future<_LemonadeInventory?> _models(
    String path,
    LocalRuntimeInventoryDiagnostics diagnostics,
  ) =>
      diagnostics.read(() => _get(path), _lemonadeInventoryFromJson);

  Future<({List<LocalModel> models, bool complete})?> _loadedModels(
      String path) async {
    try {
      final resp = await _get(path);
      if (resp.statusCode != 200) return null;
      return lemonadeLoadedObservationFromJson(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  ProviderQuota _unavailable(
    int asOf,
    LocalRuntimeInventoryDiagnostics diagnostics,
  ) =>
      ProviderQuota(
        provider: id,
        displayName: name,
        account: 'local',
        plan: 'local',
        kind: ProviderQuotaKind.local,
        asOf: asOf,
        ok: false,
        error: diagnostics.error,
        httpStatus: diagnostics.httpStatus,
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
List<LocalModel>? lemonadeModelsFromJson(dynamic data) =>
    _lemonadeInventoryFromJson(data)?.models;

typedef _LemonadeInventory = ({
  List<LocalModel> models,
  int omittedComposites,
});

_LemonadeInventory? _lemonadeInventoryFromJson(dynamic data) {
  final list = data is Map ? data['data'] : null;
  if (list is! List) return null;
  final models = <LocalModel>[];
  var omittedComposites = 0;
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
    var cloud = recipe == 'cloud' || cloudProvider.isNotEmpty;
    final components = raw['components'];
    final composite = recipe?.startsWith('collection.') == true ||
        raw.containsKey('models') ||
        (raw.containsKey('components') &&
            (components is! List || components.isNotEmpty));
    if (!cloud && composite) {
      final scope = _CompositeScopeResolver().resolve(raw);
      if (scope == _ComponentScope.unresolved) {
        omittedComposites++;
        continue;
      }
      cloud = scope == _ComponentScope.cloud;
    }
    if (!cloud && raw.containsKey('downloaded') && raw['downloaded'] is! bool) {
      continue;
    }
    if (raw['downloaded'] == false && !cloud) continue;

    final rawLabels = raw['labels'];
    if (raw.containsKey('labels') &&
        (rawLabels is! List ||
            rawLabels
                .any((label) => label is! String || label.trim().isEmpty))) {
      continue;
    }
    final labels = rawLabels is List
        ? <String>{
            for (final label in rawLabels)
              (label as String).trim().toLowerCase()
          }
        : null;
    final deployment = _deploymentFromLabels(labels);
    // Current servers reject conflicting modes; a drifted response must not
    // repair such a declaration into a text-generation route.
    if (deployment.conflicting) continue;
    models.add((
      name: id,
      bytes: null,
      param: null,
      quant: null,
      vramBytes: null,
      expiresAt: null,
      // A present but invalid current limit must not become a larger model
      // maximum. Current servers omit this field when no positive limit is
      // known; null is not a documented unloaded-state signal.
      context: raw.containsKey('context_length')
          ? boundedIntFromWire(raw['context_length'], min: 1, max: 100000000)
          : boundedIntFromWire(raw['max_context_window'],
              min: 1, max: 100000000),
      cloud: cloud,
      upstreamRouting: UpstreamRouting.notReported,
      tools: labels?.contains('tool-calling'),
      vision: labels?.contains('vision'),
      reasoning: null,
      embedding: deployment.embedding ? true : null,
      textGeneration: deployment.textGeneration,
      digest: null,
    ));
  }
  return (models: models, omittedComposites: omittedComposites);
}

enum _ComponentScope { legacyLocal, cloud, unresolved }

/// Negative execution evidence from Lemonade v2026.39.1's model serializer.
/// Only `components` identities and their embedded `models` metadata are read;
/// collection routing policies, prompts, and backend arguments are not inspected.
/// A complete supported non-cloud tree preserves legacy eligibility. It does
/// not prove execution in the collector's physical environment.
/// Sources: src/cpp/server/server.cpp:model_info_to_json, model_types.h, and the
/// recipe registry in CMakeLists.txt at that tag, reviewed 2026-09-30.
class _CompositeScopeResolver {
  static const _maxDepth = 3;
  static const _maxNodes = 64;
  static const _leafRecipes = {
    'llamacpp',
    'llamacpp-hrx',
    'whispercpp',
    'moonshine',
    'kokoro',
    'sd-cpp',
    'flm',
    'ryzenai-llm',
    'vllm',
    'thenoise',
    'ds4',
    'thinksound',
    'acestep',
    'onnxruntime',
    'trellis',
    'openmoss',
  };

  var _nodes = 0;
  final _identityFacts = <String, String>{};

  _ComponentScope resolve(Map<dynamic, dynamic> raw,
      [int depth = 0, Set<String> ancestors = const {}]) {
    if (++_nodes > _maxNodes || depth > _maxDepth) {
      return _ComponentScope.unresolved;
    }
    final id = _componentId(raw['id']);
    final recipeRaw = raw['recipe'];
    final providerRaw = raw['cloud_provider'];
    if (id == null ||
        ancestors.contains(id) ||
        recipeRaw is! String ||
        recipeRaw.length > 128 ||
        (providerRaw is String && providerRaw.length > 256) ||
        (providerRaw != null && providerRaw is! String)) {
      return _ComponentScope.unresolved;
    }
    final recipe = recipeRaw.trim().toLowerCase();
    final components = raw['components'];
    if (components is! List || components.length > _maxNodes) {
      return _ComponentScope.unresolved;
    }
    final componentIds = <String>[];
    for (final component in components) {
      final componentId = _componentId(component);
      if (componentId == null) return _ComponentScope.unresolved;
      componentIds.add(componentId);
    }
    componentIds.sort();
    final facts = jsonEncode([
      recipe,
      providerRaw is String ? providerRaw.trim() : null,
      raw['downloaded'] is bool ? raw['downloaded'] : null,
      componentIds,
    ]);
    final previous = _identityFacts[id];
    if (previous != null && previous != facts) {
      return _ComponentScope.unresolved;
    }
    _identityFacts[id] = facts;
    if (recipe == 'cloud') {
      return components.isEmpty && !raw.containsKey('models')
          ? _ComponentScope.cloud
          : _ComponentScope.unresolved;
    }
    if (providerRaw is String && providerRaw.trim().isNotEmpty) {
      return _ComponentScope.unresolved;
    }
    if (_leafRecipes.contains(recipe)) {
      return components.isEmpty &&
              !raw.containsKey('models') &&
              raw['downloaded'] == true
          ? _ComponentScope.legacyLocal
          : _ComponentScope.unresolved;
    }
    if (recipe != 'collection.omni' && recipe != 'collection.router') {
      return _ComponentScope.unresolved;
    }
    final embedded = raw['models'];
    if (raw['downloaded'] != true ||
        components.isEmpty ||
        components.length > _maxNodes ||
        embedded is! List ||
        embedded.length != components.length) {
      return _ComponentScope.unresolved;
    }
    final expected = <String>{};
    for (final component in components) {
      final componentId = _componentId(component);
      if (componentId == null || !expected.add(componentId)) {
        return _ComponentScope.unresolved;
      }
    }
    final children = <String, Map<dynamic, dynamic>>{};
    for (final child in embedded) {
      if (child is! Map) return _ComponentScope.unresolved;
      final childId = _componentId(child['id']);
      if (childId == null ||
          !expected.contains(childId) ||
          children.containsKey(childId)) {
        return _ComponentScope.unresolved;
      }
      children[childId] = child;
    }
    var cloud = false;
    final nextAncestors = {...ancestors, id};
    for (final child in children.values) {
      final scope = resolve(child, depth + 1, nextAncestors);
      if (scope == _ComponentScope.unresolved) {
        return _ComponentScope.unresolved;
      }
      cloud = cloud || scope == _ComponentScope.cloud;
    }
    return cloud ? _ComponentScope.cloud : _ComponentScope.legacyLocal;
  }
}

String? _componentId(dynamic raw) {
  if (raw is! String) return null;
  final id = raw.trim();
  return id.isEmpty ||
          id.length > 512 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(id)
      ? null
      : id;
}

/// Deployment labels are distinct from characteristic labels such as coding,
/// reasoning, vision, and tool-calling. Older servers may report only those
/// characteristics, so an absent deployment declaration remains unknown.
({bool conflicting, bool embedding, bool? textGeneration})
    _deploymentFromLabels(
  Set<String>? labels,
) {
  final modes = <String>{
    for (final label in labels ?? const <String>{})
      switch (label) {
        'embedding' || 'embeddings' => 'embedding',
        'classifier' || 'classification' => 'classification',
        'chat' ||
        'transcription' ||
        'reranking' ||
        'image' ||
        'tts' ||
        'audio-generation' ||
        '3d' =>
          label,
        _ => '',
      },
  }..remove('');
  return (
    conflicting: modes.length > 1,
    embedding: modes.contains('embedding'),
    textGeneration: modes.isEmpty ? null : modes.contains('chat'),
  );
}

/// Parses Lemonade's health response into the models currently loaded by its
/// backend processes. Optional health metadata fails soft and never determines
/// whether the inventory endpoint itself is reachable.
List<LocalModel>? lemonadeLoadedModelsFromJson(dynamic data) =>
    lemonadeLoadedObservationFromJson(data)?.models;

/// A valid exhaustive list establishes absence. A legacy recent-model name
/// alone has no versioned residency guarantee. Malformed lists are incomplete.
({List<LocalModel> models, bool complete})? lemonadeLoadedObservationFromJson(
  dynamic data,
) {
  if (data is! Map) return null;
  final rawLoaded = data['all_models_loaded'];
  if (rawLoaded is List) {
    final loaded = <LocalModel>[];
    for (final raw in rawLoaded) {
      if (raw is! Map) continue;
      final model = _lemonadeLoadedModel(raw);
      if (model != null) loaded.add(model);
    }
    return (models: loaded, complete: loaded.length == rawLoaded.length);
  }
  if (data.containsKey('all_models_loaded')) return null;

  // The stable contract describes this as a recent-model name. Without the
  // exhaustive list, do not assume an older server still has that model loaded.
  final legacy = data['model_loaded'];
  if (legacy is! String || legacy.trim().isEmpty) return null;
  return (models: const <LocalModel>[], complete: false);
}

LocalModel? _lemonadeLoadedModel(Map<dynamic, dynamic> raw) {
  final rawName = raw['model_name'];
  if (rawName is! String || rawName.trim().isEmpty) return null;
  final options = raw['recipe_options'];
  final type = raw['type'] is String
      ? (raw['type'] as String).trim().toLowerCase()
      : null;
  return _localModel(
    name: rawName.trim(),
    embedding: type == 'embedding' || type == 'embeddings' ? true : null,
    textGeneration: switch (type) {
      'llm' => true,
      'embedding' ||
      'embeddings' ||
      'reranking' ||
      'transcription' ||
      'image' ||
      'tts' ||
      'audio-generation' ||
      'classification' ||
      'classifier' ||
      '3d' =>
        false,
      _ => null,
    },
    context: options is Map
        ? boundedIntFromWire(
            options['ctx_size'],
            min: 1,
            max: 100000000,
          )
        : null,
  );
}

LocalModel _localModel({
  required String name,
  int? context,
  bool? embedding,
  bool? textGeneration,
}) =>
    (
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
      embedding: embedding,
      textGeneration: textGeneration,
      digest: null,
    );
