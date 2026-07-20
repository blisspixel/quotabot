import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/openai_auth.dart';
import '../auth/tokens.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

typedef CodexUsageFetcher = Future<Map<String, dynamic>?> Function();

/// Fetches a fresh access token from quotabot's own Codex grant, or null when
/// no grant is connected. Kept for simple adapter tests and integrations.
typedef CodexGrantToken = Future<String?> Function();

/// Fetches a usable Codex grant together with its opaque evidence identity.
/// Injectable for tests that need to model credential replacement precisely.
typedef CodexGrantCredential = Future<OpenAiCredential?> Function();

/// Reads Codex usage from the authoritative account-wide ChatGPT metadata
/// endpoint. It resolves credentials in priority order:
///   1. the credential Codex stores in ~/.codex/auth.json;
///   2. quotabot's independent refreshable grant from `quotabot login codex`.
///
/// It deliberately does not inspect rollout or session files. Those files mix
/// quota events with prompts and model responses, so reading them would violate
/// quotabot's content-blind contract. No path here calls a generation endpoint.
class CodexAdapter {
  static const id = codexProviderId;
  static const name = codexProviderName;
  static const _usageEndpoint = 'https://chatgpt.com/backend-api/wham/usage';
  static const _duplicateFallbackDeadline = Duration(seconds: 8);

  final File? _authFile;
  final CodexUsageFetcher? _usageFetcher;
  final String? _usageCredentialIdentity;
  final http.Client? _http;
  final CodexGrantCredential _grantCredential;
  final Duration _grantResolutionDeadline;

  CodexAdapter({
    File? authFile,
    CodexUsageFetcher? usageFetcher,
    String? usageCredentialIdentity,
    http.Client? client,
    CodexGrantToken? grantToken,
    CodexGrantCredential? grantCredential,
    Duration grantResolutionDeadline = const Duration(seconds: 8),
  })  : assert(
          grantToken == null || grantCredential == null,
          'provide grantToken or grantCredential, not both',
        ),
        assert(grantResolutionDeadline.inMicroseconds > 0),
        _authFile = authFile,
        _usageFetcher = usageFetcher,
        _usageCredentialIdentity = usageCredentialIdentity,
        _http = client,
        _grantResolutionDeadline = grantResolutionDeadline,
        _grantCredential = grantCredential ??
            (grantToken != null
                ? () async {
                    final token = await grantToken();
                    if (token == null || token.isEmpty) return null;
                    return OpenAiCredential(
                      accessToken: token,
                      identity: opaqueCredentialIdentity(id, token),
                    );
                  }
                : () => OpenAiAuth(client: client).freshCredential());

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    if (_usageFetcher != null) return _collectInjected(asOf);

    try {
      ProviderQuota? lastError;
      final host = _readHostCredential();
      if (host != null) {
        final outcome = await _read(
          host.credential,
          host.accountId,
          asOf,
        );
        if (outcome.quota != null) return outcome.quota!;
        lastError = outcome.error;
      }

      // The quotabot grant can belong to a different ChatGPT account. Never
      // reuse the host account selector or identity for this request.
      final grant = await _resolveGrantCredential();
      if (grant != null) {
        final outcome = await _read(grant, null, asOf);
        if (outcome.quota != null) return outcome.quota!;
        lastError = outcome.error;
      }

      if (lastError != null) return lastError;
      return _noUsage(asOf);
    } catch (_) {
      return ProviderQuota.error(
        id,
        name,
        'unable to read Codex usage',
        asOf,
      );
    }
  }

  /// Reads every active Codex credential identity. The host login and
  /// quotabot's refreshable grant can point at different ChatGPT accounts, so a
  /// successful host read must not prevent the grant account from refreshing.
  /// Exact duplicate identities use the host token first and emit one row.
  Future<List<ProviderQuota>> collectAccounts() async {
    final asOf = nowEpoch();
    if (_usageFetcher != null) return [await _collectInjected(asOf)];

    try {
      final host = _readHostCredential();
      final indexedGrantIdentity = OpenAiAuth.currentCredentialIdentity();

      // Start the host request before grant refresh. This keeps a slow grant
      // from consuming the registered adapter's outer deadline and discarding
      // a healthy host observation.
      final hostOutcomeFuture =
          host == null ? null : _read(host.credential, host.accountId, asOf);
      final grant = await _resolveGrantCredential().timeout(
        _grantResolutionDeadline,
        onTimeout: () => null,
      );
      final sameIdentity = host != null &&
          grant != null &&
          host.credential.identity == grant.identity;
      final grantOutcomeFuture =
          grant == null || sameIdentity ? null : _read(grant, null, asOf);

      final hostOutcome = await hostOutcomeFuture;
      if (sameIdentity) {
        if (hostOutcome!.quota != null ||
            hostOutcome.error?.httpStatus != 401) {
          return [hostOutcome.quota ?? hostOutcome.error!];
        }
        final fallback = await _read(
          grant,
          null,
          asOf,
          timeout: _duplicateFallbackDeadline,
        );
        return [fallback.quota ?? fallback.error!];
      }

      final results = <ProviderQuota>[];
      if (hostOutcome != null) {
        results.add(hostOutcome.quota ?? hostOutcome.error!);
      }
      if (grantOutcomeFuture != null) {
        final outcome = await grantOutcomeFuture;
        results.add(outcome.quota ?? outcome.error!);
      } else if (isOpaqueCredentialIdentity(indexedGrantIdentity) &&
          indexedGrantIdentity != host?.credential.identity) {
        results.add(_unavailableGrant(asOf, indexedGrantIdentity!));
      }
      return results.isEmpty ? [_noUsage(asOf)] : results;
    } catch (_) {
      return [
        ProviderQuota.error(
          id,
          name,
          'unable to read Codex usage',
          asOf,
        ),
      ];
    }
  }

  ProviderQuota _unavailableGrant(int asOf, String identity) =>
      ProviderQuota.error(
        id,
        name,
        'unable to refresh Codex grant (run quotabot login codex)',
        asOf,
        account: identity,
      );

  Future<OpenAiCredential?> _resolveGrantCredential() async {
    try {
      final candidate = await _grantCredential();
      if (candidate != null &&
          candidate.accessToken.isNotEmpty &&
          isOpaqueCredentialIdentity(candidate.identity)) {
        return candidate;
      }
    } catch (_) {
      // A corrupt or unavailable grant must not suppress the host credential.
    }
    return null;
  }

  /// A parser injection still needs an explicit opaque identity. This prevents
  /// test or embedding hooks from accidentally reintroducing plan- or
  /// email-keyed evidence into an account-scoped cache.
  Future<ProviderQuota> _collectInjected(int asOf) async {
    final identity = _usageCredentialIdentity;
    if (!isOpaqueCredentialIdentity(identity)) {
      return ProviderQuota.error(
        id,
        name,
        'no credential identity for account-wide Codex usage',
        asOf,
      );
    }
    try {
      final body = await _usageFetcher!();
      if (body == null) return _noUsage(asOf, account: identity!);
      return _quotaFromBody(body, identity!, asOf) ??
          ProviderQuota.error(
            id,
            name,
            'invalid Codex usage response',
            asOf,
            account: identity,
          );
    } catch (_) {
      return ProviderQuota.error(
        id,
        name,
        'unable to read Codex usage',
        asOf,
        account: identity!,
      );
    }
  }

  Future<_ReadOutcome> _read(
    OpenAiCredential credential,
    String? accountId,
    int asOf, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    http.Response response;
    try {
      final get = _http?.get ?? http.get;
      response = await get(
        Uri.parse(_usageEndpoint),
        headers: {
          'Authorization': 'Bearer ${credential.accessToken}',
          if (accountId != null && accountId.isNotEmpty)
            'chatgpt-account-id': accountId,
        },
      ).timeout(timeout);
    } catch (_) {
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          'unable to read Codex usage',
          asOf,
          account: credential.identity,
        ),
      );
    }

    if (response.statusCode != 200) {
      final authFailure = response.statusCode == 401;
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          authFailure
              ? 'token expired (re-run codex, or quotabot login codex)'
              : 'HTTP ${response.statusCode}',
          asOf,
          account: credential.identity,
          pipeHealth: authFailure
              ? null
              : providerPipeHealthForHttpStatus(response.statusCode),
          httpStatus: response.statusCode,
          retryAfterSeconds:
              retryAfterSeconds(response.headers['retry-after'], now: asOf),
        ),
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('unexpected usage shape');
      }
      final quota = _quotaFromBody(decoded, credential.identity, asOf);
      if (quota == null) throw const FormatException('missing quota windows');
      return _ReadOutcome.ok(quota);
    } catch (_) {
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          'invalid Codex usage response',
          asOf,
          account: credential.identity,
        ),
      );
    }
  }

  ProviderQuota? _quotaFromBody(
    Map<String, dynamic> body,
    String identity,
    int asOf,
  ) {
    final usage = codexLiveUsage(body);
    if (usage == null) return null;
    final rawPlan = body['plan_type']?.toString().trim();
    final plan = rawPlan == null || rawPlan.isEmpty ? null : rawPlan;
    return ProviderQuota(
      provider: id,
      displayName: name,
      account: identity,
      plan: plan,
      asOf: asOf,
      windows: usage.windows,
      modelQuotas: usage.modelQuotas,
      resetCreditsAvailable: codexResetCredits(body) ?? 0,
    );
  }

  ProviderQuota _noUsage(int asOf, {String account = 'unknown'}) =>
      ProviderQuota.error(
        id,
        name,
        'no account-wide Codex usage (run codex, or quotabot login codex)',
        asOf,
        account: account,
      );

  _HostCredential? _readHostCredential() => _readHostCredentialFile(
        _authFile ?? File('${home()}/.codex/auth.json'),
      );

  /// Credential identities currently present on this machine. Cache fallback
  /// is admitted only for identities in this set, so a replaced login cannot
  /// resurrect or drift-compare a prior account's evidence.
  static Set<String> get currentAccounts => currentCredentialIdentities();

  static Set<String> currentCredentialIdentities({File? authFile}) {
    final found = <String>{};
    final host = _readHostCredentialFile(
      authFile ?? File('${home()}/.codex/auth.json'),
    );
    if (host != null) found.add(host.credential.identity);
    final grant = OpenAiAuth.currentCredentialIdentity();
    if (isOpaqueCredentialIdentity(grant)) found.add(grant!);
    return found;
  }

  static _HostCredential? _readHostCredentialFile(File authFile) {
    try {
      if (!authFile.existsSync()) return null;
      final auth = jsonDecode(authFile.readAsStringSync());
      if (auth is! Map) return null;
      final tokens = auth['tokens'];
      if (tokens is! Map) return null;
      final access = tokens['access_token'];
      if (access is! String || access.isEmpty) return null;
      final account = tokens['account_id'];
      final refresh = tokens['refresh_token'];
      final accountId =
          account is String && account.isNotEmpty ? account : null;
      final refreshToken =
          refresh is String && refresh.isNotEmpty ? refresh : null;
      // The ChatGPT account id survives host access and refresh rotation. When
      // older auth files omit it, the refresh token is stable across access
      // rotation; access-token material is the fail-closed last resort.
      final identityMaterial = accountId != null
          ? 'account-id:$accountId'
          : refreshToken != null
              ? 'refresh-token:$refreshToken'
              : 'access-token:$access';
      return _HostCredential(
        credential: OpenAiCredential(
          accessToken: access,
          identity: opaqueCredentialIdentity(id, identityMaterial),
        ),
        accountId: accountId,
      );
    } catch (_) {
      // A partially-written or corrupt host file must not suppress a healthy
      // independent quotabot grant.
      return null;
    }
  }
}

class _HostCredential {
  final OpenAiCredential credential;
  final String? accountId;

  const _HostCredential({
    required this.credential,
    required this.accountId,
  });
}

class _ReadOutcome {
  final ProviderQuota? quota;
  final ProviderQuota? error;

  const _ReadOutcome._(this.quota, this.error);

  factory _ReadOutcome.ok(ProviderQuota quota) => _ReadOutcome._(quota, null);

  factory _ReadOutcome.error(ProviderQuota error) =>
      _ReadOutcome._(null, error);
}
