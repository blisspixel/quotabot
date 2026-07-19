import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'oauth_util.dart';
import 'tokens.dart';

/// One usable OpenAI access token plus its safe local evidence identity.
/// [identity] is an irreversible credential fingerprint, not an account name
/// and never token material.
class OpenAiCredential {
  final String accessToken;
  final String identity;

  const OpenAiCredential({
    required this.accessToken,
    required this.identity,
  });
}

/// Codex (OpenAI / ChatGPT) OAuth via the loopback authorization-code + PKCE
/// flow against the Codex CLI's own public client. This mints a refresh token
/// under quotabot's own grant, providing an idle machine a separately
/// refreshable path to the account-wide
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
  // Injected clients remain caller-owned. Without one, package-level requests
  // use a short-lived client, so the fresh auth object created for each collect
  // never leaves an owned connection pool behind.
  final http.Client? _client;

  OpenAiAuth({String? clientId, http.Client? client})
      : clientId = _firstNonEmpty(
          clientId,
          Platform.environment['QUOTABOT_OPENAI_CLIENT_ID'],
          const String.fromEnvironment('QUOTABOT_OPENAI_CLIENT_ID'),
          _defaultClientId,
        ),
        _client = client;

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
    final LoopbackCodeCapture capture;
    try {
      capture = await startLoopbackCodeCapture(
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

    late final String code;
    try {
      showUrl(authUrl);
      await openInBrowser(authUrl);
      code = await capture.code;
    } catch (_) {
      await capture.close();
      rethrow;
    }

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

  /// Returns the current default grant identity without exposing its tokens.
  /// Legacy grants are upgraded deterministically from their strongest stored
  /// credential on the next successful read.
  static String? currentCredentialIdentity() {
    final record = TokenStore.loadRecord(provider);
    if (record == null) return null;
    return _identityFor(record.tokens, owner: record.owner);
  }

  /// Fresh default access credential from quotabot's own grant, refreshing and
  /// persisting rotated tokens as needed. The identity remains stable through
  /// refresh-token rotation, while a replacement login receives a new one.
  Future<OpenAiCredential?> freshCredential() async {
    final record = TokenStore.loadRecord(provider);
    if (record == null) return null;
    final stored = record.tokens;
    final owner = record.owner;
    final identity = _identityFor(stored, owner: owner);
    if (identity == null) return null;
    if (stored.isFresh) {
      if (owner != identity) {
        final persisted = _stampDefaultIdentityBestEffort(
          record,
          stored,
          identity,
        );
        if (persisted == false) return null;
      }
      return OpenAiCredential(
        accessToken: stored.accessToken!,
        identity: identity,
      );
    }
    final refreshToken = stored.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    final refreshed = await refresh(refreshToken);
    final accessToken = refreshed?.accessToken;
    if (refreshed == null || accessToken == null || accessToken.isEmpty) {
      return null;
    }
    // A rotated refresh token still belongs to the same grant. Preserve the
    // identity established before refresh while persisting the new token set.
    final persisted = _stampDefaultIdentityBestEffort(
      record,
      refreshed,
      identity,
    );
    if (persisted == false) return null;
    return OpenAiCredential(
      accessToken: accessToken,
      identity: identity,
    );
  }

  /// Fresh access token from quotabot's own grant. The default-slot path uses
  /// [freshCredential] so the Codex adapter can isolate cached evidence. The
  /// account argument remains for compatibility with named auth slots.
  Future<String?> freshAccessToken({String? account}) async {
    if (account == null) {
      return (await freshCredential())?.accessToken;
    }
    final record = TokenStore.loadRecord(provider, account: account);
    if (record == null) return null;
    final stored = record.tokens;
    if (stored.isFresh) return stored.accessToken;
    if (stored.refreshToken == null) return null;
    final refreshed = await refresh(stored.refreshToken!);
    if (refreshed?.accessToken == null) return null;
    // Best-effort persist of the rotated token: the old refresh token is already
    // burned, so a save failure must not discard the valid access token and fail
    // this read. See AnthropicAuth.freshAccessToken.
    try {
      if (!TokenStore.replaceIfCurrent(record, refreshed!)) return null;
    } catch (_) {}
    return refreshed!.accessToken;
  }

  static void _saveGrant(Tokens tokens, {String? account}) {
    final identity = _identityFor(tokens);
    if (identity == null) {
      throw StateError('token exchange returned no usable credential');
    }
    TokenStore.saveDefaultOwnedBy(provider, tokens, identity);
    if (account != null) {
      TokenStore.save(provider, tokens, account: account);
    }
  }

  static String? _identityFor(Tokens tokens, {String? owner}) {
    if (isOpaqueCredentialIdentity(owner)) return owner;
    final refresh = tokens.refreshToken;
    final access = tokens.accessToken;
    final material = refresh != null && refresh.isNotEmpty
        ? refresh
        : access != null && access.isNotEmpty
            ? access
            : null;
    return material == null
        ? null
        : opaqueCredentialIdentity(provider, material);
  }

  static bool? _stampDefaultIdentityBestEffort(
    TokenRecord current,
    Tokens tokens,
    String identity,
  ) {
    try {
      return TokenStore.replaceIfCurrent(current, tokens, owner: identity);
    } catch (_) {
      // Keep the newly valid access token usable for this metadata read even
      // when local persistence fails after the provider rotated the grant.
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(Map<String, String> form) async {
    final url = Uri.parse(_tokenEndpoint);
    const headers = {
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    final client = _client;
    final request = client == null
        ? http.post(url, headers: headers, body: form)
        : client.post(url, headers: headers, body: form);
    final resp = await request.timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
