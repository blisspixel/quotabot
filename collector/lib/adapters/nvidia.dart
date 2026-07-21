import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../http_client.dart';

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
      final get = _http?.get ?? sharedHttpClient.get;
      final resp = await get(
        Uri.parse('$_base/models'),
        headers: {'Authorization': 'Bearer $key'},
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        final retryAfter =
            retryAfterSeconds(resp.headers['retry-after'], now: asOf);
        return _keyInvalid(
          asOf,
          httpStatus: resp.statusCode,
          pipeHealth: providerPipeHealthForHttpStatus(resp.statusCode),
          retryAfterSeconds: retryAfter,
        );
      }
      if (!_hasUsableModelListing(resp.bodyBytes)) {
        return _keyInvalid(asOf, httpStatus: 200);
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
        kind: ProviderQuotaKind.subscription,
      );
    } catch (_) {
      return _keyInvalid(asOf);
    }
  }

  // Not configuring an optional provider is a setup state, not a failed read.
  // Reporting it as ok with no windows renders as "no live data" (the same as
  // an installed-but-unread local tool), not a red ERROR for a provider the
  // user never enabled. A key that is present but rejected still fails loudly
  // (see _keyInvalid); only the never-set-up case is quieted here.
  ProviderQuota _noKey(int asOf) => ProviderQuota(
        provider: id,
        displayName: name,
        account: 'default',
        plan: 'free trial',
        asOf: asOf,
        ok: true,
        status: 'not configured; optional free-trial provider',
        windows: const [],
      );

  ProviderQuota _keyInvalid(
    int asOf, {
    int? httpStatus,
    String? pipeHealth,
    int? retryAfterSeconds,
  }) =>
      ProviderQuota(
        provider: id,
        displayName: name,
        account: 'default',
        plan: 'free trial',
        asOf: asOf,
        ok: false,
        error: _modelsFailureMessage(httpStatus, pipeHealth),
        pipeHealth: pipeHealth,
        httpStatus: httpStatus,
        retryAfterSeconds: retryAfterSeconds,
      );
}

String _modelsFailureMessage(int? httpStatus, String? pipeHealth) {
  final status = httpStatus == null ? '' : ' (HTTP $httpStatus)';
  if (pipeHealth == providerPipeHealthThrottled) {
    return 'NVIDIA /models throttled$status';
  }
  if (pipeHealth == providerPipeHealthDegraded) {
    return 'NVIDIA /models degraded$status';
  }
  if (httpStatus == 200) {
    return 'NVIDIA /models returned an invalid or empty response';
  }
  if (httpStatus != null) {
    return 'NVIDIA key rejected by /models$status';
  }
  return 'NVIDIA key present but /models failed (network or invalid response)';
}

const int _maxNvidiaModelsBytes = 2 * 1024 * 1024;

bool _hasUsableModelListing(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > _maxNvidiaModelsBytes) return false;
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) return false;
    return data.any(
      (model) =>
          model is Map &&
          model['id'] is String &&
          (model['id'] as String).trim().isNotEmpty,
    );
  } catch (_) {
    return false;
  }
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
