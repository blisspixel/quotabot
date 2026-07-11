import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/anthropic_auth.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

/// Fetches a fresh access token from quotabot's own Claude grant, or null when
/// no grant is connected. Injectable for tests.
typedef ClaudeGrantToken = Future<String?> Function();

/// Reads Claude (Anthropic) usage live from the OAuth usage endpoint. This is
/// the account-wide `/usage` data, so it already reflects usage on other
/// machines. It resolves auth in priority order:
///   1. the access token Claude Code stores in ~/.claude/.credentials.json,
///      while it is unexpired - the zero-setup path for a machine you actively
///      use Claude Code on;
///   2. quotabot's own refreshable grant from `quotabot login claude` - the
///      idle-machine path that keeps the account-wide read live when the host
///      app has not refreshed its token here.
/// Both are zero-cost metadata reads; quotabot never calls a generation
/// endpoint.
class ClaudeAdapter {
  static const id = claudeProviderId;
  static const name = claudeProviderName;
  static const _endpoint = 'https://api.anthropic.com/api/oauth/usage';

  final http.Client? _http;
  final File? _credentialsFile;
  final ClaudeGrantToken _grantToken;

  ClaudeAdapter({
    http.Client? client,
    File? credentialsFile,
    ClaudeGrantToken? grantToken,
  })  : _http = client,
        _credentialsFile = credentialsFile,
        _grantToken = grantToken ??
            (() => AnthropicAuth(client: client).freshAccessToken());

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final host = _readHostCredential();
      final plan = host?.plan;

      // Try tokens in priority order. A fresh host token goes first (no refresh
      // round trip); a stale host token is demoted below the self-refreshing
      // grant but still tried last in case its expiry estimate was wrong.
      final grantToken = await _grantToken();
      final ordered = <String>[
        if (host != null && host.fresh) host.token,
        if (grantToken != null) grantToken,
        if (host != null && !host.fresh) host.token,
      ];

      if (ordered.isEmpty) {
        // No usable credential at all: neither a host token nor a grant.
        if (host == null) {
          return ProviderQuota.error(
            id,
            name,
            'no ~/.claude/.credentials.json (run claude, or quotabot login claude)',
            asOf,
          );
        }
        return ProviderQuota.error(id, name, 'no oauth access token', asOf);
      }

      _ReadOutcome? lastError;
      for (final token in ordered) {
        final outcome = await _read(token, plan, asOf);
        if (outcome.quota != null) return outcome.quota!;
        // A 401 means "try the next token"; a non-auth HTTP/network error is
        // terminal for this collection and is reported as-is.
        if (!outcome.unauthorized) return outcome.error!;
        lastError = outcome;
      }
      // Every candidate token was unauthorized.
      return lastError?.error ??
          ProviderQuota.error(
            id,
            name,
            'token expired (re-run claude, or quotabot login claude)',
            asOf,
            account: plan ?? 'default',
            plan: plan,
          );
    } catch (_) {
      return ProviderQuota.error(id, name, 'unable to read Claude usage', asOf);
    }
  }

  /// Reads usage with one bearer token. Returns a quota on success, an
  /// `unauthorized` marker on 401 (caller should try the next token), or a
  /// terminal error for any other non-200.
  Future<_ReadOutcome> _read(String token, String? plan, int asOf) async {
    final get = _http?.get ?? http.get;
    final resp = await get(
      Uri.parse(_endpoint),
      headers: {
        'Authorization': 'Bearer $token',
        'anthropic-beta': 'oauth-2025-04-20',
        'anthropic-version': '2023-06-01',
      },
    ).timeout(const Duration(seconds: 10));

    if (resp.statusCode == 401) {
      return _ReadOutcome.unauthorized(
        ProviderQuota.error(
          id,
          name,
          'token expired (re-run claude, or quotabot login claude)',
          asOf,
          account: plan ?? 'default',
          plan: plan,
          httpStatus: resp.statusCode,
        ),
      );
    }
    if (resp.statusCode != 200) {
      final retryAfter =
          retryAfterSeconds(resp.headers['retry-after'], now: asOf);
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          'HTTP ${resp.statusCode}',
          asOf,
          account: plan ?? 'default',
          plan: plan,
          pipeHealth: providerPipeHealthForHttpStatus(resp.statusCode),
          httpStatus: resp.statusCode,
          retryAfterSeconds: retryAfter,
        ),
      );
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _ReadOutcome.ok(
      ProviderQuota(
        provider: id,
        displayName: name,
        account: plan ?? 'default',
        plan: plan,
        asOf: asOf,
        windows: claudeWindows(data),
      ),
    );
  }

  /// Reads the host access token and its freshness from the Claude Code
  /// credentials file. `expiresAt` there is epoch milliseconds; treat the token
  /// as fresh only with a 60s safety margin so a token about to expire is
  /// demoted below the self-refreshing grant.
  _HostCredential? _readHostCredential() {
    final credFile =
        _credentialsFile ?? File('${home()}/.claude/.credentials.json');
    if (!credFile.existsSync()) return null;
    final oauth = (jsonDecode(credFile.readAsStringSync())
        as Map)['claudeAiOauth'] as Map?;
    final token = oauth?['accessToken'] as String?;
    if (token == null || token.isEmpty) return null;
    final plan = oauth?['subscriptionType']?.toString();
    final expiresAtMs = oauth?['expiresAt'];
    final fresh = expiresAtMs is int && expiresAtMs ~/ 1000 > nowEpoch() + 60;
    return _HostCredential(token: token, plan: plan, fresh: fresh);
  }
}

class _HostCredential {
  final String token;
  final String? plan;
  final bool fresh;
  _HostCredential({required this.token, this.plan, required this.fresh});
}

class _ReadOutcome {
  final ProviderQuota? quota;
  final ProviderQuota? error;
  final bool unauthorized;
  _ReadOutcome._(this.quota, this.error, this.unauthorized);
  factory _ReadOutcome.ok(ProviderQuota q) => _ReadOutcome._(q, null, false);
  factory _ReadOutcome.error(ProviderQuota e) => _ReadOutcome._(null, e, false);
  factory _ReadOutcome.unauthorized(ProviderQuota e) =>
      _ReadOutcome._(null, e, true);
}
