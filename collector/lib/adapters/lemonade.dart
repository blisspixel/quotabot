import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../provider_ids.dart';
import '../util.dart';
import 'lmstudio.dart' show lmStudioCompatFromJson;
import 'ollama.dart' show LocalModel, localBaseUrl, localRuntimeQuota;

/// Detects a local Lemonade Server (the AMD/lemonade-sdk OpenAI-compatible
/// runtime) and reports its installed models, like the other local runtimes.
///
/// Lemonade exposes an OpenAI-compatible API; quotabot lists models from
/// `GET /api/v1/models`, falling back to `/v1/models`. The server defaults to
/// 127.0.0.1:8000; honors LEMONADE_HOST. No quota: a local runtime has nothing
/// to spend, so it acts as an always-available routing fallback.
class LemonadeAdapter {
  static const id = lemonadeProviderId;
  static const name = lemonadeProviderName;

  final http.Client _http;
  LemonadeAdapter({http.Client? client}) : _http = client ?? http.Client();

  static String baseUrl() =>
      localBaseUrl(Platform.environment['LEMONADE_HOST'], 8000);

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      for (final path in const ['/api/v1/models', '/v1/models']) {
        final models = await _models(path);
        if (models != null) {
          return localRuntimeQuota(
            id: id,
            name: name,
            asOf: asOf,
            installed: models,
            loaded: const [],
          );
        }
      }
      return _notRunning(asOf);
    } catch (_) {
      return _notRunning(asOf);
    }
  }

  Future<List<LocalModel>?> _models(String path) async {
    try {
      final resp = await _http
          .get(Uri.parse('${baseUrl()}$path'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      final models = lmStudioCompatFromJson(jsonDecode(resp.body));
      return (models == null || models.isEmpty) ? null : models;
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
