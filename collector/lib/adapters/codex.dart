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

  final File? _authFile;
  final CodexUsageFetcher? _usageFetcher;
  final String? _usageCredentialIdentity;
  final http.Client? _http;
  final CodexGrantCredential _grantCredential;

  CodexAdapter({
    File? authFile,
    CodexUsageFetcher? usageFetcher,
    String? usageCredentialIdentity,
    http.Client? client,
    CodexGrantToken? grantToken,
    CodexGrantCredential? grantCredential,
  })  : assert(
          grantToken == null || grantCredential == null,
          'provide grantToken or grantCredential, not both',
        ),
        _authFile = authFile,
        _usageFetcher = usageFetcher,
        _usageCredentialIdentity = usageCredentialIdentity,
        _http = client,
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
      OpenAiCredential? grant;
      try {
        final candidate = await _grantCredential();
        if (candidate != null &&
            candidate.accessToken.isNotEmpty &&
            isOpaqueCredentialIdentity(candidate.identity)) {
          grant = candidate;
        }
      } catch (_) {
        grant = null;
      }
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
    int asOf,
  ) async {
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
      ).timeout(const Duration(seconds: 10));
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
