import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'oauth_util.dart';
import 'tokens.dart';

/// One usable Anthropic access token plus its safe local evidence identity.
/// [identity] is an irreversible credential-generation fingerprint, not an
/// account name and never token material.
class AnthropicCredential {
  final String accessToken;
  final String identity;

  const AnthropicCredential({
    required this.accessToken,
    required this.identity,
  });
}

/// Claude (Anthropic) OAuth via the authorization-code + PKCE flow against
/// Claude Code's own public client. This mints a refresh token under quotabot's
/// own grant, providing an idle machine a separately refreshable path to
/// account-wide usage without the Claude
/// Code app being open and without ever touching `~/.claude/.credentials.json`.
///
/// The read this grant authorizes is the same zero-cost usage *metadata*
/// endpoint the in-CLI `/usage` command polls; quotabot never calls a generation
/// endpoint, so a connected grant still spends nothing.
///
/// Flow shape: Claude Code's public client redirects the browser to a fixed
/// console callback that displays a `code#state` value for the user to paste
/// back (it does not allow arbitrary loopback redirects the way Antigravity's
/// client does), so this is a manual paste-back flow rather than a loopback
/// capture. [promptCode] receives the shown URL indirectly (via [showUrl]) and
/// returns whatever the user pastes.
class AnthropicAuth {
  static const provider = 'claude';

  // Claude Code's public OAuth client. Public/native clients ship no
  // confidential secret; the user still signs in with their own Anthropic
  // account in the browser. These endpoints and the client id are the values
  // Claude Code itself uses; override the client id with QUOTABOT_ANTHROPIC_
  // CLIENT_ID if Anthropic rotates the public client. Confirm on the first real
  // `quotabot login claude` and adjust here if the provider has changed them.
  static const _defaultClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const _authEndpoint = 'https://claude.ai/oauth/authorize';
  static const _tokenEndpoint = 'https://console.anthropic.com/v1/oauth/token';
  static const _redirect = 'https://console.anthropic.com/oauth/code/callback';

  // Scope set that authorizes the account usage-metadata read. `user:profile`
  // is the account-identity scope; `user:inference` matches the scope Claude
  // Code requests and is included only to guarantee the usage endpoint accepts
  // the token. quotabot never performs inference with it. `org:create_api_key`
  // is deliberately NOT requested: quotabot must never be able to mint API keys.
  static const _scope = 'user:profile user:inference';

  final String clientId;
  // Injected clients remain caller-owned. Without one, package-level requests
  // use a short-lived client, so the fresh auth object created for each collect
  // never leaves an owned connection pool behind.
  final http.Client? _client;

  AnthropicAuth({String? clientId, http.Client? client})
      : clientId = _firstNonEmpty(
          clientId,
          Platform.environment['QUOTABOT_ANTHROPIC_CLIENT_ID'],
          const String.fromEnvironment('QUOTABOT_ANTHROPIC_CLIENT_ID'),
          _defaultClientId,
        ),
        _client = client;

  static String _firstNonEmpty(String? a, String? b, String c, String d) {
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    if (c.isNotEmpty) return c;
    return d;
  }

  /// Runs the paste-back login: builds the authorize URL, opens the browser via
  /// [showUrl], then exchanges the code the user pastes (via [promptCode]) for a
  /// token set and persists it as quotabot's grant. The pasted value may be the
  /// bare code or the `code#state` form the console page shows.
  Future<Tokens> loginManual({
    required void Function(String url) showUrl,
    required Future<String> Function() promptCode,
    String? account,
  }) async {
    final pkce = pkcePair();
    final state = randomState();
    final authUrl = Uri.parse(_authEndpoint).replace(
      queryParameters: {
        'code': 'true',
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': _redirect,
        'scope': _scope,
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
      },
    ).toString();

    showUrl(authUrl);
    await openInBrowser(authUrl);

    final pasted = (await promptCode()).trim();
    if (pasted.isEmpty) throw StateError('no authorization code provided');
    // The console page presents the value as `code#state`; accept either form
    // and verify the returned state matches to defeat a swapped-code injection.
    final hash = pasted.indexOf('#');
    final code = hash >= 0 ? pasted.substring(0, hash) : pasted;
    final returnedState = hash >= 0 ? pasted.substring(hash + 1) : null;
    if (returnedState != null && returnedState != state) {
      throw StateError('authorization state mismatch');
    }

    final json = await _post({
      'grant_type': 'authorization_code',
      'code': code,
      'state': state,
      'client_id': clientId,
      'redirect_uri': _redirect,
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
  /// persisting the rotated token as needed. The identity remains stable across
  /// refresh-token rotation, but a replacement login receives a new identity.
  Future<AnthropicCredential?> freshCredential() async {
    final record = TokenStore.loadRecord(provider);
    if (record == null) return null;
    final stored = record.tokens;
    final owner = record.owner;
    final identity = _identityFor(
      stored,
      owner: owner,
    );
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
      return AnthropicCredential(
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
    // Persist the rotated refresh token (providers rotate single-use tokens),
    // but keep the identity derived before refresh. A rotation is still the
    // same grant; only a later login is a new credential generation.
    final persisted = _stampDefaultIdentityBestEffort(
      record,
      refreshed,
      identity,
    );
    if (persisted == false) return null;
    return AnthropicCredential(
      accessToken: accessToken,
      identity: identity,
    );
  }

  /// Fresh access token from quotabot's own grant. The default-slot path uses
  /// [freshCredential] so the Claude adapter can keep cache evidence isolated.
  /// The account argument remains for compatibility with named auth slots.
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
    // The named-slot compatibility path has no default-slot ownership marker.
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
      // The provider may already have rotated the refresh token. Keep this
      // access token usable for the current metadata read, then fail closed on
      // future cache lookup if the stable identity could not be persisted.
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(Map<String, String> form) async {
    final url = Uri.parse(_tokenEndpoint);
    const headers = {
      'Content-Type': 'application/x-www-form-urlencoded',
      'anthropic-beta': 'oauth-2025-04-20',
    };
    final client = _client;
    final request = client == null
        ? http.post(url, headers: headers, body: form)
        : client.post(url, headers: headers, body: form);
    final resp = await request.timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    // Guard the decode: a malformed 200 body is token material, and a raw
    // FormatException would carry a slice of it into an error string.
    try {
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
