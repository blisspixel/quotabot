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
  static const _userinfoEndpoint =
      'https://www.googleapis.com/oauth2/v2/userinfo';
  static const _scope =
      'https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email';

  // Antigravity's own public installed-app OAuth client (the one the Antigravity
  // CLI/IDE ship). Used by default so `login antigravity` works for anyone with
  // no Google Cloud project to set up; the user still signs in with their own
  // Google account in the browser. This client (not the gemini-cli one) is what
  // the Cloud Code model-quota endpoint accepts. Installed-app client secrets
  // are non-confidential by design; override with QUOTABOT_GOOGLE_CLIENT_ID and
  // QUOTABOT_GOOGLE_CLIENT_SECRET to use your own client instead.
  static const _publicClientId =
      '1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com';
  static const _publicClientSecret = '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';

  final String clientId;
  final String clientSecret;
  final http.Client _http;
  GoogleAuth({String? clientId, String? clientSecret, http.Client? client})
      : clientId = _firstNonEmpty(
            clientId,
            Platform.environment['QUOTABOT_GOOGLE_CLIENT_ID'],
            const String.fromEnvironment('QUOTABOT_GOOGLE_CLIENT_ID'),
            _publicClientId),
        clientSecret = _firstNonEmpty(
            clientSecret,
            Platform.environment['QUOTABOT_GOOGLE_CLIENT_SECRET'],
            const String.fromEnvironment('QUOTABOT_GOOGLE_CLIENT_SECRET'),
            _publicClientSecret),
        _http = client ?? http.Client();

  static String _firstNonEmpty(String? a, String? b, String c, String d) {
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    if (c.isNotEmpty) return c;
    return d;
  }

  /// Opens the system browser, captures the redirect on a loopback port, and
  /// exchanges the code for tokens. Saves and returns them.
  Future<Tokens> loginLoopback({
    required void Function(String url) showUrl,
    String? account,
  }) async {
    if (clientId.isEmpty || clientSecret.isEmpty) {
      throw StateError(
        'Antigravity login has no configured OAuth client',
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
    final resolvedAccount = account ??
        (tokens.accessToken == null
            ? null
            : await emailForAccessToken(tokens.accessToken!));
    _saveGrant(tokens, account: resolvedAccount);
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
  Future<String?> freshAccessToken({String? account}) async {
    final stored = TokenStore.load(provider, account: account);
    if (stored == null) return null;
    if (stored.isFresh) return stored.accessToken;
    if (stored.refreshToken == null) return null;
    final refreshed = await refresh(stored.refreshToken!);
    if (refreshed?.accessToken == null) return null;
    // Persist the rotated token only to the slot it was loaded from. Writing
    // the default slot here too would let a background refresh of one account
    // overwrite the provider-default grant with that account's tokens, so a
    // later default-slot fallback could return the wrong account's token.
    TokenStore.save(provider, refreshed!, account: account);
    return refreshed.accessToken;
  }

  /// Establishes the grant at login: the account-scoped slot when the email is
  /// known, and always the provider-default slot so the primary-account
  /// fallback has a deterministic grant to fall back to.
  static void _saveGrant(Tokens tokens, {String? account}) {
    TokenStore.save(provider, tokens);
    if (account != null) {
      TokenStore.save(provider, tokens, account: account);
    }
  }

  /// Returns the signed-in Google account email for an access token, or null
  /// when Google does not return a plain email. Raw userinfo bodies are never
  /// propagated into errors because they are account metadata.
  Future<String?> emailForAccessToken(String accessToken) async {
    try {
      final resp = await _http.get(
        Uri.parse(_userinfoEndpoint),
        headers: {'Authorization': 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final email = decoded['email'];
      return email is String && email.isNotEmpty ? email : null;
    } catch (_) {
      return null;
    }
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
    // Parse inside a guard: a malformed 200 body is token material, and a raw
    // FormatException would put a slice of it into an error string.
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
