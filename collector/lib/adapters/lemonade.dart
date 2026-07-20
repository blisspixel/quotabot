import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../local_runtime_config.dart';
import '../models.dart';
import '../provider_ids.dart';
import '../util.dart';
import 'lmstudio.dart' show lmStudioCompatFromJson;
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
