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
  static const _maxIdentityJwtBytes = 64 * 1024;
  static const _maxIdentityPayloadBytes = 32 * 1024;
  static const _maxAccountIdLength = 512;

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
    final response = _tokenResponse(json);
    _saveGrant(
      response.tokens,
      account: account,
      accountId: response.accountId,
    );
    return response.tokens;
  }

  Future<_OpenAiTokenResponse?> _refreshResponse(String refreshToken) async {
    final json = await _post({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'scope': _scope,
    });
    if (json == null) return null;
    return _tokenResponse(json, priorRefresh: refreshToken);
  }

  Future<Tokens?> refresh(String refreshToken) async =>
      (await _refreshResponse(refreshToken))?.tokens;

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
  Future<OpenAiCredential?> freshCredential() =>
      TokenStore.refreshTransaction(provider, (record) async {
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
        final response = await _refreshResponse(refreshToken);
        final refreshed = response?.tokens;
        final accessToken = refreshed?.accessToken;
        if (refreshed == null || accessToken == null || accessToken.isEmpty) {
          return null;
        }
        // Prefer the provider-stable account claim when this response reveals
        // it. Otherwise preserve the legacy grant generation identity.
        final refreshedIdentity = _identityFor(
          refreshed,
          // Preserve the generation identity derived before refresh when the
          // response has no stable account claim. The response may rotate the
          // refresh token, but that rotation is not a new account or grant.
          owner: identity,
          accountId: response?.accountId,
        );
        if (refreshedIdentity == null) return null;
        final persisted = _stampDefaultIdentityBestEffort(
          record,
          refreshed,
          refreshedIdentity,
        );
        if (persisted == false) return null;
        return OpenAiCredential(
          accessToken: accessToken,
          identity: refreshedIdentity,
        );
      });

  /// Fresh access token from quotabot's own grant. The default-slot path uses
  /// [freshCredential] so the Codex adapter can isolate cached evidence. The
  /// account argument remains for compatibility with named auth slots.
  Future<String?> freshAccessToken({String? account}) async {
    if (account == null) {
      return (await freshCredential())?.accessToken;
    }
    return TokenStore.refreshTransaction(
      provider,
      (record) async {
        if (record == null) return null;
        final stored = record.tokens;
        if (stored.isFresh) return stored.accessToken;
        if (stored.refreshToken == null) return null;
        final response = await _refreshResponse(stored.refreshToken!);
        final refreshed = response?.tokens;
        if (refreshed?.accessToken == null) return null;
        try {
          if (!TokenStore.replaceIfCurrent(record, refreshed!)) return null;
        } catch (_) {}
        return refreshed!.accessToken;
      },
      account: account,
    );
  }

  static void _saveGrant(
    Tokens tokens, {
    String? account,
    String? accountId,
  }) {
    final identity = _identityFor(tokens, accountId: accountId);
    if (identity == null) {
      throw StateError('token exchange returned no usable credential');
    }
    TokenStore.saveDefaultOwnedBy(provider, tokens, identity);
    if (account != null) {
      TokenStore.save(provider, tokens, account: account);
    }
  }

  static String? _identityFor(
    Tokens tokens, {
    String? owner,
    String? accountId,
  }) {
    final stableAccountId = _boundedAccountId(accountId) ??
        _chatGptAccountIdFromJwt(tokens.accessToken);
    if (stableAccountId != null) {
      return opaqueCredentialIdentity(
        provider,
        'account-id:$stableAccountId',
      );
    }
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

  static _OpenAiTokenResponse _tokenResponse(
    Map<String, dynamic> json, {
    String? priorRefresh,
  }) {
    final tokens = Tokens.fromOAuth(json, priorRefresh: priorRefresh);
    final idToken = json['id_token'];
    return _OpenAiTokenResponse(
      tokens,
      _chatGptAccountIdFromJwt(idToken is String ? idToken : null) ??
          _chatGptAccountIdFromJwt(tokens.accessToken),
    );
  }

  static String? _chatGptAccountIdFromJwt(String? token) {
    if (token == null || token.isEmpty || token.length > _maxIdentityJwtBytes) {
      return null;
    }
    final parts = token.split('.');
    if (parts.length != 3 ||
        parts[1].isEmpty ||
        parts[1].length > _maxIdentityPayloadBytes) {
      return null;
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(parts[1]));
      if (bytes.length > _maxIdentityPayloadBytes) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final claims = decoded.cast<String, dynamic>();
      final direct = _boundedAccountId(claims['chatgpt_account_id']);
      if (direct != null) return direct;
      final namespaced = claims['https://api.openai.com/auth'];
      if (namespaced is! Map) return null;
      return _boundedAccountId(namespaced['chatgpt_account_id']);
    } catch (_) {
      return null;
    }
  }

  static String? _boundedAccountId(Object? value) {
    if (value is! String) return null;
    final accountId = value.trim();
    if (accountId.isEmpty ||
        accountId.length > _maxAccountIdLength ||
        accountId.runes.any((code) => code < 0x20 || code == 0x7f)) {
      return null;
    }
    return accountId;
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

class _OpenAiTokenResponse {
  final Tokens tokens;
  final String? accountId;

  const _OpenAiTokenResponse(this.tokens, this.accountId);
}
