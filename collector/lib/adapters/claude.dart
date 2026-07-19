import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/anthropic_auth.dart';
import '../auth/tokens.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

/// Fetches a fresh access token from quotabot's own Claude grant, or null when
/// no grant is connected. Injectable for tests.
typedef ClaudeGrantToken = Future<String?> Function();

/// Fetches a usable Claude grant together with its opaque evidence identity.
/// Injectable for tests that need to model credential replacement precisely.
typedef ClaudeGrantCredential = Future<ClaudeCredential?> Function();

/// A Claude access token paired with an irreversible local identity for that
/// credential generation. The identity is safe for quota cache keys; the token
/// remains confined to the request header.
class ClaudeCredential {
  final String accessToken;
  final String identity;

  const ClaudeCredential({
    required this.accessToken,
    required this.identity,
  });
}

/// Reads Claude (Anthropic) usage live from the OAuth usage endpoint. This is
/// the account-wide `/usage` data, so it already reflects usage on other
/// machines. It resolves auth in priority order:
///   1. the access token Claude Code stores in ~/.claude/.credentials.json,
///      while it is unexpired - the zero-setup path for a machine you actively
///      use Claude Code on;
///   2. quotabot's own refreshable grant from `quotabot login claude` - the
///      idle-machine path designed to keep the account-wide read live when the
///      host app has not refreshed its token here. Callers still verify the
///      resulting live observation rather than inferring success from a grant.
/// Both are zero-cost metadata reads; quotabot never calls a generation
/// endpoint.
class ClaudeAdapter {
  static const id = claudeProviderId;
  static const name = claudeProviderName;
  static const _endpoint = 'https://api.anthropic.com/api/oauth/usage';

  final http.Client? _http;
  final File? _credentialsFile;
  final ClaudeGrantCredential _grantCredential;

  ClaudeAdapter({
    http.Client? client,
    File? credentialsFile,
    ClaudeGrantToken? grantToken,
    ClaudeGrantCredential? grantCredential,
  })  : assert(
          grantToken == null || grantCredential == null,
          'provide grantToken or grantCredential, not both',
        ),
        _http = client,
        _credentialsFile = credentialsFile,
        _grantCredential = grantCredential ??
            (grantToken != null
                ? () async {
                    final token = await grantToken();
                    if (token == null || token.isEmpty) return null;
                    return ClaudeCredential(
                      accessToken: token,
                      identity: opaqueCredentialIdentity(id, token),
                    );
                  }
                : () async {
                    final credential =
                        await AnthropicAuth(client: client).freshCredential();
                    return credential == null
                        ? null
                        : ClaudeCredential(
                            accessToken: credential.accessToken,
                            identity: credential.identity,
                          );
                  });

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final host = _readHostCredential();
      final hostPlan = host?.planEvidence;

      _ReadOutcome? lastError;
      // A fresh host token is the cheapest path and must stay independent of
      // quotabot's optional grant. Resolve that grant only after host auth
      // fails, or when the host token is stale or missing.
      if (host != null && host.fresh) {
        final outcome = await _read(
          host.credential,
          hostPlan,
          asOf,
          knownExpired: false,
        );
        if (outcome.quota != null) return outcome.quota!;
        if (!outcome.unauthorized) return outcome.error!;
        lastError = outcome;
      }

      // The optional quotabot grant is independent of Claude Code's host
      // credential. A corrupt grant file or failed refresh must not prevent a
      // stale host token from getting its documented last-chance read.
      ClaudeCredential? grantCredential;
      try {
        final candidate = await _grantCredential();
        if (candidate != null &&
            candidate.accessToken.isNotEmpty &&
            isOpaqueCredentialIdentity(candidate.identity)) {
          grantCredential = candidate;
        }
      } catch (_) {
        grantCredential = null;
      }
      if (grantCredential != null) {
        final outcome = await _read(
          grantCredential,
          // The quotabot grant is independent of the host credential and may
          // belong to another Claude account. The usage endpoint does not
          // expose a stable account id or plan, so do not borrow either label
          // from a host token that was not used for this successful reading.
          null,
          asOf,
          knownExpired: false,
        );
        if (outcome.quota != null) return outcome.quota!;
        // A 401 means "try the next token"; a non-auth HTTP/network error is
        // terminal for this collection and is reported as-is.
        if (!outcome.unauthorized) return outcome.error!;
        lastError = outcome;
      }

      // A stale host token is the last chance after the self-refreshing grant.
      // Its expiry estimate can be wrong, so a successful read still wins.
      if (host != null && !host.fresh) {
        final outcome = await _read(
          host.credential,
          hostPlan,
          asOf,
          knownExpired: host.knownExpired,
        );
        if (outcome.quota != null) return outcome.quota!;
        if (!outcome.unauthorized) return outcome.error!;
        lastError = outcome;
      }

      if (host == null && grantCredential == null) {
        return ProviderQuota.error(
          id,
          name,
          'no usable Claude login (run claude, or quotabot login claude)',
          asOf,
        );
      }
      // Every candidate token was unauthorized.
      return lastError?.error ??
          ProviderQuota.error(
            id,
            name,
            'token expired (re-run claude, or quotabot login claude)',
            asOf,
            account: host?.identity ?? 'unknown',
            plan: hostPlan?.plan,
            planEvidenceSource: hostPlan?.source,
            planEvidenceAsOf: hostPlan?.asOf,
          );
    } catch (_) {
      return ProviderQuota.error(id, name, 'unable to read Claude usage', asOf);
    }
  }

  /// Reads usage with one bearer token. Returns a quota on success, an
  /// `unauthorized` marker on 401 (caller should try the next token), or a
  /// terminal error for any other non-200.
  Future<_ReadOutcome> _read(
    ClaudeCredential credential,
    _PlanEvidence? fallbackPlanEvidence,
    int asOf, {
    required bool knownExpired,
  }) async {
    http.Response resp;
    try {
      final get = _http?.get ?? http.get;
      resp = await get(
        Uri.parse(_endpoint),
        headers: {
          'Authorization': 'Bearer ${credential.accessToken}',
          'anthropic-beta': 'oauth-2025-04-20',
          'anthropic-version': '2023-06-01',
        },
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          'unable to read Claude usage',
          asOf,
          account: credential.identity,
          plan: fallbackPlanEvidence?.plan,
          planEvidenceSource: fallbackPlanEvidence?.source,
          planEvidenceAsOf: fallbackPlanEvidence?.asOf,
        ),
      );
    }

    if (resp.statusCode == 401) {
      return _ReadOutcome.unauthorized(
        ProviderQuota.error(
          id,
          name,
          'token expired (re-run claude, or quotabot login claude)',
          asOf,
          account: credential.identity,
          plan: fallbackPlanEvidence?.plan,
          planEvidenceSource: fallbackPlanEvidence?.source,
          planEvidenceAsOf: fallbackPlanEvidence?.asOf,
          httpStatus: resp.statusCode,
        ),
      );
    }
    if (resp.statusCode != 200) {
      final retryAfter =
          retryAfterSeconds(resp.headers['retry-after'], now: asOf);
      final recovery = knownExpired
          ? '; saved Claude login expired '
              '(re-run claude, or quotabot login claude)'
          : '';
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          'HTTP ${resp.statusCode}$recovery',
          asOf,
          account: credential.identity,
          plan: fallbackPlanEvidence?.plan,
          planEvidenceSource: fallbackPlanEvidence?.source,
          planEvidenceAsOf: fallbackPlanEvidence?.asOf,
          pipeHealth: providerPipeHealthForHttpStatus(resp.statusCode),
          httpStatus: resp.statusCode,
          retryAfterSeconds: retryAfter,
        ),
      );
    }

    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('unexpected usage shape');
      }
      final usage = claudeLiveUsage(decoded, observedAt: asOf);
      if (usage == null) {
        throw const FormatException('incomplete Claude usage response');
      }
      final planEvidence = decoded.containsKey('subscription_type')
          ? _providerPlanEvidence(decoded, asOf)
          : fallbackPlanEvidence;
      return _ReadOutcome.ok(
        ProviderQuota(
          provider: id,
          displayName: name,
          account: credential.identity,
          plan: planEvidence?.plan,
          planEvidenceSource: planEvidence?.source,
          planEvidenceAsOf: planEvidence?.asOf,
          asOf: asOf,
          windows: usage.windows,
          modelQuotas: usage.modelQuotas,
        ),
      );
    } catch (_) {
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          'invalid Claude usage response',
          asOf,
          account: credential.identity,
          plan: fallbackPlanEvidence?.plan,
          planEvidenceSource: fallbackPlanEvidence?.source,
          planEvidenceAsOf: fallbackPlanEvidence?.asOf,
        ),
      );
    }
  }

  /// Reads the host access token and its freshness from the Claude Code
  /// credentials file. `expiresAt` there is epoch milliseconds; treat the token
  /// as fresh only with a 60s safety margin so a token about to expire is
  /// demoted below the self-refreshing grant.
  _HostCredential? _readHostCredential() {
    final credFile =
        _credentialsFile ?? File('${home()}/.claude/.credentials.json');
    return _readHostCredentialFile(credFile);
  }

  /// Credential generations currently present on this machine. The provider
  /// does not expose a stable account id from its usage endpoint, so these
  /// opaque identities are the only safe boundary for cached evidence.
  static Set<String> get currentAccounts => currentCredentialIdentities();

  static Set<String> currentCredentialIdentities({File? credentialsFile}) {
    final found = <String>{};
    final host = _readHostCredentialFile(
      credentialsFile ?? File('${home()}/.claude/.credentials.json'),
    );
    if (host != null) found.add(host.identity);
    final grant = AnthropicAuth.currentCredentialIdentity();
    if (isOpaqueCredentialIdentity(grant)) found.add(grant!);
    return found;
  }

  static _HostCredential? _readHostCredentialFile(File credFile) {
    if (!credFile.existsSync()) return null;
    try {
      final decoded = jsonDecode(credFile.readAsStringSync());
      if (decoded is! Map) return null;
      final oauth = decoded['claudeAiOauth'];
      if (oauth is! Map) return null;
      final token = oauth['accessToken'];
      if (token is! String || token.isEmpty) return null;
      final refreshToken = oauth['refreshToken'];
      final identityMaterial = refreshToken is String && refreshToken.isNotEmpty
          ? refreshToken
          : token;
      final plan = _boundedPlanLabel(oauth['subscriptionType']);
      int? planEvidenceAsOf;
      if (plan != null) {
        final modified =
            credFile.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
        if (modified > 0 && modified <= nowEpoch() + 300) {
          planEvidenceAsOf = modified;
        }
      }
      final expiresAtMs = oauth['expiresAt'];
      final expiresAt = expiresAtMs is int ? expiresAtMs ~/ 1000 : null;
      final now = nowEpoch();
      final fresh = expiresAt != null && expiresAt > now + 60;
      final knownExpired = expiresAt != null && expiresAt <= now;
      return _HostCredential(
        credential: ClaudeCredential(
          accessToken: token,
          identity: opaqueCredentialIdentity(id, identityMaterial),
        ),
        planEvidence: plan == null || planEvidenceAsOf == null
            ? null
            : _PlanEvidence(
                plan: plan,
                source: ProviderPlanEvidenceSource.hostCredential,
                asOf: planEvidenceAsOf,
              ),
        fresh: fresh,
        knownExpired: knownExpired,
      );
    } catch (_) {
      // A partially-written or corrupt host credential must not mask
      // quotabot's independent refreshable grant.
      return null;
    }
  }
}

class _HostCredential {
  final ClaudeCredential credential;
  final _PlanEvidence? planEvidence;
  final bool fresh;
  final bool knownExpired;
  _HostCredential({
    required this.credential,
    this.planEvidence,
    required this.fresh,
    required this.knownExpired,
  });

  String get identity => credential.identity;
}

class _PlanEvidence {
  final String plan;
  final ProviderPlanEvidenceSource source;
  final int asOf;

  const _PlanEvidence({
    required this.plan,
    required this.source,
    required this.asOf,
  });
}

_PlanEvidence? _providerPlanEvidence(
  Map<String, dynamic> usage,
  int asOf,
) {
  final plan = _boundedPlanLabel(usage['subscription_type']);
  if (plan == null) return null;
  return _PlanEvidence(
    plan: plan,
    source: ProviderPlanEvidenceSource.providerMetadata,
    asOf: asOf,
  );
}

String? _boundedPlanLabel(Object? value) {
  if (value is! String) return null;
  final plan = value.trim();
  if (plan.isEmpty || plan.length > 64 || stripTerminalControl(plan) != plan) {
    return null;
  }
  return plan;
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
