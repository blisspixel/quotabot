import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../provider_ids.dart';
import '../util.dart';

/// Detects NVIDIA NIM trial access via env key and safe discovery call.
///
/// NVIDIA-hosted NIM APIs are available for free development and testing
/// through build.nvidia.com. The API is OpenAI-compatible at
/// integrate.api.nvidia.com/v1. NVIDIA does not expose a zero-cost endpoint for
/// remaining trial balance or model-specific rate-limit headroom, and runtime
/// inference calls would spend the user's allowance.
///
/// This adapter is opportunistic: if NVIDIA_API_KEY (or nvapi) env is present,
/// it performs a zero-cost GET /v1/models (discovery only) to confirm the key
/// works, then reports availability with no quota windows. No login, no tokens
/// spent, fail-soft.
///
/// Key from env only. Honors no extra network if key absent.
class NvidiaAdapter {
  static const id = nvidiaProviderId;
  static const name = nvidiaProviderName;

  static const _base = 'https://integrate.api.nvidia.com/v1';

  final http.Client? _http;
  final String? Function()? _keySource;

  NvidiaAdapter({http.Client? client, String? Function()? keySource})
      : _http = client,
        _keySource = keySource;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    final key = resolveNvidiaApiKey(
      explicit: _keySource?.call(),
      env: Platform.environment,
    );
    if (key == null) {
      return _noKey(asOf);
    }
    try {
      final get = _http?.get ?? http.get;
      final resp = await get(
        Uri.parse('$_base/models'),
        headers: {'Authorization': 'Bearer $key'},
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        return _keyInvalid(asOf);
      }
      // Success: key works. NVIDIA does not expose a zero-cost numeric balance
      // endpoint, so this is availability only rather than a quota window.
      return ProviderQuota(
        provider: id,
        displayName: name,
        account: 'default',
        plan: 'free trial',
        asOf: asOf,
        ok: true,
        status: 'free trial available; balance unknown',
        details: const [
          'free serverless APIs for development',
          'trial rate limits are model-specific and unpublished',
        ],
        windows: const [],
        kind: 'subscription',
      );
    } catch (_) {
      return _keyInvalid(asOf);
    }
  }

  ProviderQuota _noKey(int asOf) => ProviderQuota(
        provider: id,
        displayName: name,
        account: 'default',
        plan: 'free trial',
        asOf: asOf,
        ok: false,
        error: 'NVIDIA NIM not configured; set NVIDIA_API_KEY or nvapi',
      );

  ProviderQuota _keyInvalid(int asOf) => ProviderQuota(
        provider: id,
        displayName: name,
        account: 'default',
        plan: 'free trial',
        asOf: asOf,
        ok: false,
        error: 'NVIDIA key present but /models failed (invalid or network)',
      );
}

String? resolveNvidiaApiKey({
  String? explicit,
  Map<String, String> env = const {},
}) {
  for (final value in [
    explicit,
    env['NVIDIA_API_KEY'],
    env['nvapi'],
  ]) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}
