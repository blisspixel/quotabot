import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/anthropic_auth.dart';
import '../auth/tokens.dart';
import '../http_client.dart';
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
  static const _profileEndpoint = 'https://api.anthropic.com/api/oauth/profile';
  static const _profileDeadline = Duration(seconds: 4);
  static const _maxProfileBodyBytes = 64 * 1024;
  static const _duplicateFallbackDeadline = Duration(seconds: 8);
  static const _maxRememberedPoolIdentities = 32;
  static final Map<String, String> _poolByCredential = {};

  final http.Client? _http;
  final File? _credentialsFile;
  final ClaudeGrantCredential _grantCredential;
  final Duration _grantResolutionDeadline;

  ClaudeAdapter({
    http.Client? client,
    File? credentialsFile,
    ClaudeGrantToken? grantToken,
    ClaudeGrantCredential? grantCredential,
    Duration grantResolutionDeadline = const Duration(seconds: 8),
  })  : assert(
          grantToken == null || grantCredential == null,
          'provide grantToken or grantCredential, not both',
        ),
        assert(grantResolutionDeadline.inMicroseconds > 0),
        _http = client,
        _credentialsFile = credentialsFile,
        _grantResolutionDeadline = grantResolutionDeadline,
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
      final grantCredential = await _resolveGrantCredential();
      if (grantCredential != null) {
        final outcome = await _read(
          grantCredential,
          // The quotabot grant is independent of the host credential and may
          // belong to another Claude account. Do not borrow identity or plan
          // from a host token that was not used for this provider read.
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

  /// Reads every active Claude credential identity instead of treating the
  /// first successful token as evidence for the whole provider. Host and
  /// quotabot grants can belong to different accounts, so each distinct
  /// identity receives its own live result. Exact duplicate identities share a
  /// fallback chain and produce one row.
  Future<List<ProviderQuota>> collectAccounts() async {
    final asOf = nowEpoch();
    try {
      final host = _readHostCredential();
      final indexedGrantIdentity = AnthropicAuth.currentCredentialIdentity();

      // Start a healthy host read before resolving the independent grant. A
      // slow or broken grant must never consume the provider-wide deadline and
      // hide current host evidence.
      final hostOutcomeFuture = host == null
          ? null
          : _read(
              host.credential,
              host.planEvidence,
              asOf,
              knownExpired: host.knownExpired,
            );
      final grant = await _resolveGrantCredential().timeout(
        _grantResolutionDeadline,
        onTimeout: () => null,
      );
      final sameIdentity =
          host != null && grant != null && host.identity == grant.identity;
      final grantOutcomeFuture = grant == null || sameIdentity
          ? null
          : _read(
              grant,
              null,
              asOf,
              knownExpired: false,
            );

      final hostOutcome = await hostOutcomeFuture;
      if (sameIdentity) {
        if (hostOutcome!.quota != null || !hostOutcome.unauthorized) {
          return [hostOutcome.quota ?? hostOutcome.error!];
        }
        final fallback = await _read(
          grant,
          null,
          asOf,
          knownExpired: false,
          timeout: _duplicateFallbackDeadline,
        );
        return [fallback.quota ?? fallback.error!];
      }

      final outcomes = <_ReadOutcome>[];
      if (hostOutcome != null) {
        outcomes.add(hostOutcome);
      }
      if (grantOutcomeFuture != null) {
        final outcome = await grantOutcomeFuture;
        outcomes.add(outcome);
      }
      final results = _safeAccountRows(outcomes, asOf);
      final indexedGrantAccount = indexedGrantIdentity == null
          ? null
          : _accountForCredential(indexedGrantIdentity);
      if (grantOutcomeFuture == null &&
          isOpaqueCredentialIdentity(indexedGrantIdentity) &&
          !results.any((quota) => quota.account == indexedGrantAccount)) {
        results.add(_unavailableGrant(asOf, indexedGrantAccount!));
      }
      if (results.isNotEmpty) return results;
      return [
        ProviderQuota.error(
          id,
          name,
          'no usable Claude login (run claude, or quotabot login claude)',
          asOf,
        ),
      ];
    } catch (_) {
      return [
        ProviderQuota.error(id, name, 'unable to read Claude usage', asOf),
      ];
    }
  }

  ProviderQuota _unavailableGrant(int asOf, String identity) =>
      ProviderQuota.error(
        id,
        name,
        'unable to refresh Claude grant (run quotabot login claude)',
        asOf,
        account: identity,
      );

  /// Keeps independently proven provider accounts separate while preventing
  /// two credential generations for one subscription from becoming two
  /// routable quota pools. If profile identity is unavailable for any of
  /// several successful reads, only one remains routable until the provider's
  /// profile metadata recovers. This deliberately favors under-routing over
  /// spending the same subscription twice through parallel leases.
  List<ProviderQuota> _safeAccountRows(
    List<_ReadOutcome> outcomes,
    int asOf,
  ) {
    final successes =
        outcomes.where((outcome) => outcome.quota != null).toList();
    if (successes.length <= 1) {
      return [
        for (final outcome in outcomes) outcome.quota ?? outcome.error!,
      ];
    }

    final allIdentified =
        successes.every((outcome) => outcome.poolIdentity != null);
    if (allIdentified) {
      final seenPools = <String>{};
      return [
        for (final outcome in outcomes)
          if (outcome.quota == null)
            outcome.error!
          else if (seenPools.add(outcome.poolIdentity!))
            outcome.quota!,
      ];
    }

    final primary = successes.firstWhere(
      (outcome) => outcome.poolIdentity != null,
      orElse: () => successes.first,
    );
    return [
      for (final outcome in outcomes)
        if (outcome.quota == null)
          outcome.error!
        else if (identical(outcome, primary))
          outcome.quota!
        else
          ProviderQuota.error(
            id,
            name,
            'account identity unavailable; quota excluded to prevent '
            'duplicate routing',
            asOf,
            account: outcome.quota!.account,
            plan: outcome.quota!.plan,
            planEvidenceSource: outcome.quota!.planEvidenceSource,
            planEvidenceAsOf: outcome.quota!.planEvidenceAsOf,
          ),
    ];
  }

  Future<ClaudeCredential?> _resolveGrantCredential() async {
    try {
      final candidate = await _grantCredential();
      if (candidate != null &&
          candidate.accessToken.isNotEmpty &&
          isOpaqueCredentialIdentity(candidate.identity)) {
        return candidate;
      }
    } catch (_) {
      // A corrupt or unavailable independent grant must not suppress the host
      // credential's live metadata read.
    }
    return null;
  }

  /// Reads usage with one bearer token. Returns a quota on success, an
  /// `unauthorized` marker on 401 (caller should try the next token), or a
  /// terminal error for any other non-200.
  Future<_ReadOutcome> _read(
    ClaudeCredential credential,
    _PlanEvidence? fallbackPlanEvidence,
    int asOf, {
    required bool knownExpired,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final knownAccount = _accountForCredential(credential.identity);
    // Profile metadata is a zero-cost provider read using the same credential.
    // Start it alongside usage so stable account-pool identity and current plan
    // proof add no serial network round trip. _readProfile catches every failure
    // and resolves to null, so an early usage error cannot leave an unhandled
    // asynchronous exception behind.
    final profileFuture = _readProfile(credential, asOf);
    http.Response resp;
    try {
      final get = _http?.get ?? sharedHttpClient.get;
      resp = await get(
        Uri.parse(_endpoint),
        headers: {
          'Authorization': 'Bearer ${credential.accessToken}',
          'anthropic-beta': 'oauth-2025-04-20',
          'anthropic-version': '2023-06-01',
        },
      ).timeout(timeout);
    } catch (e) {
      final health = providerPipeHealthForReadError(e);
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          health == providerPipeHealthThrottled
              ? 'Claude usage read timed out'
              : 'unable to read Claude usage',
          asOf,
          account: knownAccount,
          plan: fallbackPlanEvidence?.plan,
          planEvidenceSource: fallbackPlanEvidence?.source,
          planEvidenceAsOf: fallbackPlanEvidence?.asOf,
          pipeHealth: health,
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
          account: knownAccount,
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
          account: knownAccount,
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
      final profile = await profileFuture;
      final poolIdentity = profile?.poolIdentity ??
          _poolIdentityForCredential(credential.identity);
      final account = poolIdentity ?? credential.identity;
      final planEvidence = decoded.containsKey('subscription_type')
          ? _providerPlanEvidence(decoded, asOf)
          : profile?.planEvidence ?? fallbackPlanEvidence;
      return _ReadOutcome.ok(
        ProviderQuota(
          provider: id,
          displayName: name,
          account: account,
          plan: planEvidence?.plan,
          planEvidenceSource: planEvidence?.source,
          planEvidenceAsOf: planEvidence?.asOf,
          asOf: asOf,
          windows: usage.windows,
          modelQuotas: usage.modelQuotas,
        ),
        poolIdentity: poolIdentity,
      );
    } catch (_) {
      return _ReadOutcome.error(
        ProviderQuota.error(
          id,
          name,
          'invalid Claude usage response',
          asOf,
          account: knownAccount,
          plan: fallbackPlanEvidence?.plan,
          planEvidenceSource: fallbackPlanEvidence?.source,
          planEvidenceAsOf: fallbackPlanEvidence?.asOf,
        ),
      );
    }
  }

  Future<_ProfileEvidence?> _readProfile(
    ClaudeCredential credential,
    int asOf,
  ) async {
    try {
      final get = _http?.get ?? sharedHttpClient.get;
      final response = await get(
        Uri.parse(_profileEndpoint),
        headers: {
          'Authorization': 'Bearer ${credential.accessToken}',
          'Content-Type': 'application/json',
          'anthropic-beta': 'oauth-2025-04-20',
          'anthropic-version': '2023-06-01',
        },
      ).timeout(_profileDeadline);
      if (response.statusCode != 200 ||
          response.bodyBytes.length > _maxProfileBodyBytes) {
        return null;
      }
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: false),
      );
      if (decoded is! Map<String, dynamic>) return null;
      final evidence = _profileEvidence(decoded, asOf);
      if (evidence != null) {
        _rememberPoolIdentity(credential.identity, evidence.poolIdentity);
      }
      return evidence;
    } catch (_) {
      return null;
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

  /// Credential generations currently present on this machine. The usage
  /// endpoint alone has no stable account id, so persisted cache admission uses
  /// these opaque identities even though a successful companion profile read
  /// can detect duplicate live subscription pools.
  static Set<String> get currentAccounts => currentCredentialIdentities();

  static Set<String> currentCredentialIdentities({File? credentialsFile}) {
    final found = <String>{};
    final host = _readHostCredentialFile(
      credentialsFile ?? File('${home()}/.claude/.credentials.json'),
    );
    if (host != null) {
      found.add(_accountForCredential(host.identity));
    }
    final grant = AnthropicAuth.currentCredentialIdentity();
    if (isOpaqueCredentialIdentity(grant)) {
      found.add(_accountForCredential(grant!));
    }
    return found;
  }

  /// Clears the in-memory credential-to-pool index between isolated tests.
  /// Production code must never call this method.
  static void resetPoolIdentityMemoryForTesting() {
    var assertsEnabled = false;
    assert(() {
      assertsEnabled = true;
      return true;
    }());
    if (!assertsEnabled) {
      throw StateError('pool identity reset is testing-only');
    }
    _poolByCredential.clear();
  }

  static String? _poolIdentityForCredential(String identity) =>
      _poolByCredential[identity];

  static String _accountForCredential(String identity) =>
      _poolIdentityForCredential(identity) ?? identity;

  static void _rememberPoolIdentity(String credential, String pool) {
    if (_poolByCredential[credential] == pool) return;
    _poolByCredential.remove(credential);
    while (_poolByCredential.length >= _maxRememberedPoolIdentities) {
      _poolByCredential.remove(_poolByCredential.keys.first);
    }
    _poolByCredential[credential] = pool;
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

class _ProfileEvidence {
  final String poolIdentity;
  final _PlanEvidence? planEvidence;

  const _ProfileEvidence({
    required this.poolIdentity,
    required this.planEvidence,
  });
}

_ProfileEvidence? _profileEvidence(
  Map<String, dynamic> profile,
  int asOf,
) {
  final account = profile['account'];
  if (account is! Map) return null;
  final accountId = _boundedProfileId(account['uuid']);
  if (accountId == null) return null;

  String? organizationId;
  String? organizationType;
  String? rateLimitTier;
  final organization = profile['organization'];
  if (organization != null) {
    if (organization is! Map) return null;
    organizationId = _boundedProfileId(organization['uuid']);
    if (organizationId == null) return null;
    organizationType = _boundedProfileLabel(organization['organization_type']);
    rateLimitTier = _boundedProfileLabel(organization['rate_limit_tier']);
  }

  final hasMax = account['has_claude_max'];
  final hasPro = account['has_claude_pro'];
  String? plan;
  if (hasMax is bool && hasPro is bool && hasMax != hasPro) {
    plan = hasMax ? 'max' : 'pro';
  } else if (hasMax == false &&
      hasPro == false &&
      organizationType?.toLowerCase() == 'claude_team') {
    plan = rateLimitTier?.toLowerCase().contains('claude_max') == true
        ? 'team_premium'
        : 'team_standard';
  }

  final poolMaterial = organizationId == null
      ? 'account-id:$accountId'
      : 'account-id:$accountId\u0000organization-id:$organizationId';
  return _ProfileEvidence(
    poolIdentity: opaqueCredentialIdentity(ClaudeAdapter.id, poolMaterial),
    planEvidence: plan == null
        ? null
        : _PlanEvidence(
            plan: plan,
            source: ProviderPlanEvidenceSource.providerMetadata,
            asOf: asOf,
          ),
  );
}

String? _boundedProfileId(Object? value) {
  if (value is! String) return null;
  final id = value.trim();
  if (id.isEmpty ||
      id.length > 128 ||
      stripTerminalControl(id) != id ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(id)) {
    return null;
  }
  return id;
}

String? _boundedProfileLabel(Object? value) {
  if (value is! String) return null;
  final label = value.trim();
  if (label.isEmpty ||
      label.length > 128 ||
      stripTerminalControl(label) != label) {
    return null;
  }
  return label;
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
  final String? poolIdentity;
  _ReadOutcome._(
    this.quota,
    this.error,
    this.unauthorized,
    this.poolIdentity,
  );
  factory _ReadOutcome.ok(
    ProviderQuota q, {
    String? poolIdentity,
  }) =>
      _ReadOutcome._(q, null, false, poolIdentity);
  factory _ReadOutcome.error(ProviderQuota e) =>
      _ReadOutcome._(null, e, false, null);
  factory _ReadOutcome.unauthorized(ProviderQuota e) =>
      _ReadOutcome._(null, e, true, null);
}
