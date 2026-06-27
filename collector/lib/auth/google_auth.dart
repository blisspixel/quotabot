import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'oauth_util.dart';
import 'tokens.dart';

/// Google (Antigravity) OAuth via the native-app loopback authorization-code
/// flow with PKCE (RFC 8252). This mints a refresh token under quotabot's own
/// grant, so Antigravity stays live without reopening the IDE and without
/// touching the IDE's credentials.
class GoogleAuth {
  static const provider = 'antigravity';
  static const _authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const _scope =
      'https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email';

  final String clientId;
  final String clientSecret;
  final http.Client _http;
  GoogleAuth({String? clientId, String? clientSecret, http.Client? client})
      : clientId = clientId ??
            Platform.environment['QUOTABOT_GOOGLE_CLIENT_ID'] ??
            const String.fromEnvironment('QUOTABOT_GOOGLE_CLIENT_ID'),
        clientSecret = clientSecret ??
            Platform.environment['QUOTABOT_GOOGLE_CLIENT_SECRET'] ??
            const String.fromEnvironment('QUOTABOT_GOOGLE_CLIENT_SECRET'),
        _http = client ?? http.Client();

  /// Opens the system browser, captures the redirect on a loopback port, and
  /// exchanges the code for tokens. Saves and returns them.
  Future<Tokens> loginLoopback({
    required void Function(String url) showUrl,
  }) async {
    if (clientId.isEmpty || clientSecret.isEmpty) {
      throw StateError(
        'Antigravity login requires QUOTABOT_GOOGLE_CLIENT_ID and QUOTABOT_GOOGLE_CLIENT_SECRET',
      );
    }
    final pkce = pkcePair();
    final state = randomState();
    final capture = await startLoopbackCodeCapture(
      path: '/callback',
      expectedState: state,
    );
    final redirect = 'http://127.0.0.1:${capture.port}/callback';
    final authUrl = Uri.parse(_authEndpoint).replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': _scope,
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
      },
    ).toString();

    showUrl(authUrl);
    await openInBrowser(authUrl);
    final code = await capture.code;

    final json = await _post({
      'code': code,
      'client_id': clientId,
      'client_secret': clientSecret,
      'redirect_uri': redirect,
      'grant_type': 'authorization_code',
      'code_verifier': pkce.verifier,
    });
    if (json == null) throw StateError('token exchange failed');
    final tokens = Tokens.fromOAuth(json);
    TokenStore.save(provider, tokens);
    return tokens;
  }

  Future<Tokens?> refresh(String refreshToken) async {
    final json = await _post({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'client_secret': clientSecret,
    });
    if (json == null) return null;
    return Tokens.fromOAuth(json, priorRefresh: refreshToken);
  }

  /// Fresh access token from quotabot's own grant, refreshing and persisting as
  /// needed. Null when there is no stored grant.
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

  Future<Map<String, dynamic>?> _post(Map<String, String> form) async {
    final resp = await _http
        .post(
          Uri.parse(_tokenEndpoint),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: form,
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
