import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tokens.dart';

/// xAI (Grok) OAuth via the OIDC device-authorization flow, creating a token
/// grant independent of the Grok CLI so refreshing here never invalidates the
/// CLI's own credentials.
class XaiAuth {
  static const provider = 'grok';
  static const _device = 'https://auth.x.ai/oauth2/device/code';
  static const _token = 'https://auth.x.ai/oauth2/token';
  static const _scope = 'openid profile email offline_access grok-cli:access';

  /// The public grok-cli OAuth client id (overridable for tests).
  final String clientId;
  final http.Client _http;
  XaiAuth({
    this.clientId = 'b1a00492-073a-47ea-816f-4c329264a828',
    http.Client? client,
  }) : _http = client ?? http.Client();

  /// Runs the device flow: prints the verification URL and code via [prompt],
  /// then polls until the user authorizes. Saves and returns the tokens.
  Future<Tokens> deviceLogin({
    required void Function(String url, String code) prompt,
  }) async {
    final init = await _post(_device, {'client_id': clientId, 'scope': _scope});
    if (init == null) throw StateError('device authorization failed');
    final deviceCode = init['device_code'] as String;
    var interval = (init['interval'] as num?)?.toInt() ?? 5;
    prompt(
      (init['verification_uri_complete'] ?? init['verification_uri'])
          .toString(),
      (init['user_code'] ?? '').toString(),
    );

    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(seconds: interval));
      final resp = await _postRaw(_token, {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': deviceCode,
        'client_id': clientId,
      });
      // Guard the decode: a malformed body is token material, and a raw
      // FormatException would carry a slice of it. Keep polling on bad JSON.
      Map<String, dynamic> body;
      try {
        body = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (resp.statusCode == 200) {
        final tokens = Tokens.fromOAuth(body);
        TokenStore.save(provider, tokens);
        return tokens;
      }
      final err = body['error'];
      // Per RFC 8628, slow_down means we are polling too fast: back off by 5s
      // and keep waiting. authorization_pending just means not approved yet.
      if (err == 'slow_down') {
        interval += 5;
        continue;
      }
      if (err == 'authorization_pending') continue;
      throw StateError('device login failed: $err');
    }
    throw TimeoutException('device login timed out');
  }

  /// Exchanges a refresh token for a fresh token set (xAI rotates the refresh
  /// token, so the new one is carried back).
  Future<Tokens?> refresh(String refreshToken) async {
    final json = await _post(_token, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    });
    if (json == null) return null;
    return Tokens.fromOAuth(json, priorRefresh: refreshToken);
  }

  /// Returns a fresh access token from quotabot's own grant, refreshing and
  /// persisting as needed. Null when there is no stored grant.
  Future<String?> freshAccessToken() async {
    final stored = TokenStore.load(provider);
    if (stored == null) return null;
    if (stored.isFresh) return stored.accessToken;
    if (stored.refreshToken == null) return null;
    final refreshed = await refresh(stored.refreshToken!);
    if (refreshed?.accessToken == null) return null;
    TokenStore.save(provider, refreshed!);
    return refreshed.accessToken;
  }

  Future<Map<String, dynamic>?> _post(
    String url,
    Map<String, String> form,
  ) async {
    final resp = await _postRaw(url, form);
    if (resp.statusCode != 200) return null;
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _postRaw(String url, Map<String, String> form) {
    return _http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: form,
        )
        .timeout(const Duration(seconds: 15));
  }
}
