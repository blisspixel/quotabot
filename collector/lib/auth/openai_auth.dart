import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'oauth_util.dart';
import 'tokens.dart';

/// Codex (OpenAI / ChatGPT) OAuth via the loopback authorization-code + PKCE
/// flow against the Codex CLI's own public client. This mints a refresh token
/// under quotabot's own grant so an idle machine can read the account-wide
/// ChatGPT usage endpoint without the Codex CLI being active and without
/// touching `~/.codex/auth.json`.
///
/// The read this grant authorizes is the same zero-cost usage *metadata*
/// endpoint (`/backend-api/wham/usage`) the CLI's own `/status` view polls, not
/// a generation endpoint, so a connected grant spends nothing.
///
/// The Codex public client allow-lists a fixed loopback redirect
/// (`http://localhost:1455/auth/callback`), so the capture binds that exact
/// port rather than an OS-selected one.
class OpenAiAuth {
  static const provider = 'codex';

  // Codex CLI's public OAuth client. Confirm the client id / redirect port /
  // scopes on the first real `quotabot login codex` and adjust here if OpenAI
  // has rotated them; override the client id with QUOTABOT_OPENAI_CLIENT_ID.
  static const _defaultClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const _authEndpoint = 'https://auth.openai.com/oauth/authorize';
  static const _tokenEndpoint = 'https://auth.openai.com/oauth/token';
  static const _redirectPort = 1455;
  static const _redirectPath = '/auth/callback';
  static const _scope = 'openid profile email offline_access';

  final String clientId;
  // Lazily created so a collect that only reads the local grant (or finds none)
  // never allocates an HTTP client. Adapters construct a fresh OpenAiAuth on
  // every collect, so eager creation here would leak a client per refresh cycle.
  http.Client? _client;

  OpenAiAuth({String? clientId, http.Client? client})
      : clientId = _firstNonEmpty(
          clientId,
          Platform.environment['QUOTABOT_OPENAI_CLIENT_ID'],
          const String.fromEnvironment('QUOTABOT_OPENAI_CLIENT_ID'),
          _defaultClientId,
        ),
        _client = client;

  http.Client get _http => _client ??= http.Client();

  static String _firstNonEmpty(String? a, String? b, String c, String d) {
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    if (c.isNotEmpty) return c;
    return d;
  }

  /// Opens the browser, captures the redirect on the fixed loopback port, and
  /// exchanges the code for a token set that is persisted as quotabot's grant.
  Future<Tokens> loginLoopback({
    required void Function(String url) showUrl,
    String? account,
  }) async {
    final pkce = pkcePair();
    final state = randomState();
    final redirect = 'http://localhost:$_redirectPort$_redirectPath';
    // Bind the fixed port the public client allow-lists. If it is already in
    // use (a Codex login in flight, say), surface a clear error rather than
    // silently capturing on the wrong port.
    final Future<String> codeFuture;
    try {
      codeFuture = captureLoopbackCode(
        port: _redirectPort,
        path: _redirectPath,
        expectedState: state,
      );
    } on SocketException {
      throw StateError(
        'local port $_redirectPort is busy; close any in-progress Codex '
        'login and retry',
      );
    }

    final authUrl = Uri.parse(_authEndpoint).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirect,
        'scope': _scope,
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
        // Codex requests organization claims in the id_token so the CLI can
        // resolve the ChatGPT account id.
        'id_token_add_organizations': 'true',
      },
    ).toString();

    showUrl(authUrl);
    await openInBrowser(authUrl);
    final code = await codeFuture;

    final json = await _post({
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': clientId,
      'redirect_uri': redirect,
      'code_verifier': pkce.verifier,
    });
    if (json == null) throw StateError('token exchange failed');
    final tokens = Tokens.fromOAuth(json);
    _saveGrant(tokens, account: account);
    return tokens;
  }

  Future<Tokens?> refresh(String refreshToken) async {
    final json = await _post({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'scope': _scope,
    });
    if (json == null) return null;
    return Tokens.fromOAuth(json, priorRefresh: refreshToken);
  }

  /// Fresh access token from quotabot's own grant, refreshing and persisting the
  /// rotated token as needed. Null when there is no stored grant. The Codex
  /// account id needed for the usage header is read separately from the host
  /// `auth.json` (a stable identifier that does not expire).
  Future<String?> freshAccessToken({String? account}) async {
    final stored = TokenStore.load(provider, account: account);
    if (stored == null) return null;
    if (stored.isFresh) return stored.accessToken;
    if (stored.refreshToken == null) return null;
    final refreshed = await refresh(stored.refreshToken!);
    if (refreshed?.accessToken == null) return null;
    TokenStore.save(provider, refreshed!, account: account);
    return refreshed.accessToken;
  }

  static void _saveGrant(Tokens tokens, {String? account}) {
    TokenStore.save(provider, tokens);
    if (account != null) {
      TokenStore.save(provider, tokens, account: account);
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
    try {
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
