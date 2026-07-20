import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/claude.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_adapters.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  const hostRefreshToken = 'host-refresh-token';
  late Directory temp;
  late File credentials;

  setUp(() {
    ClaudeAdapter.resetPoolIdentityMemoryForTesting();
    temp = Directory.systemTemp.createTempSync('quotabot_claude_adapter_');
    setQuotabotDirOverrideForTesting(Directory('${temp.path}/quotabot'));
    credentials = File('${temp.path}/credentials.json');
    credentials.writeAsStringSync(jsonEncode({
      'claudeAiOauth': {
        'accessToken': 'claude-token',
        'refreshToken': hostRefreshToken,
        'subscriptionType': 'max',
        'expiresAt': (nowEpoch() + 3600) * 1000,
      },
    }));
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String hostIdentity([String refreshToken = hostRefreshToken]) =>
      opaqueCredentialIdentity(ClaudeAdapter.id, refreshToken);

  String profileIdentity(String accountUuid, [String? organizationUuid]) =>
      opaqueCredentialIdentity(
        ClaudeAdapter.id,
        organizationUuid == null
            ? 'account-id:$accountUuid'
            : 'account-id:$accountUuid\u0000organization-id:$organizationUuid',
      );

  test('preserves throttled metadata from the usage endpoint', () async {
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer claude-token');
        return http.Response(
          '{}',
          429,
          headers: {'retry-after': '120'},
        );
      }),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, 'HTTP 429');
    expect(q.account, hostIdentity());
    expect(q.plan, 'max');
    expect(q.pipeHealth, providerPipeHealthThrottled);
    expect(q.httpStatus, 429);
    expect(q.retryAfterSeconds, 120);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test(
      'preserves degraded metadata without treating auth failures as pipe health',
      () async {
    final degraded = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response('{}', 529)),
    ).collect();

    expect(degraded.ok, isFalse);
    expect(degraded.pipeHealth, providerPipeHealthDegraded);
    expect(degraded.httpStatus, 529);

    final expired = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response('{}', 401)),
    ).collect();

    expect(expired.ok, isFalse);
    expect(expired.error, contains('token expired'));
    expect(expired.account, hostIdentity());
    expect(expired.pipeHealth, isNull);
    expect(expired.httpStatus, 401);
  });

  void writeCreds({
    required int expiresAtMs,
    String accessToken = 'host-token',
    String refreshToken = hostRefreshToken,
    String plan = 'max',
  }) {
    credentials.writeAsStringSync(jsonEncode({
      'claudeAiOauth': {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'subscriptionType': plan,
        'expiresAt': expiresAtMs,
      },
    }));
  }

  test('uses a fresh host token first without touching the grant', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    var grantCalled = false;
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async {
        grantCalled = true;
        return 'grant-token';
      },
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.perMachine, isFalse);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
    expect(
      q.planEvidenceSource,
      ProviderPlanEvidenceSource.hostCredential,
    );
    expect(q.planEvidenceAsOf, isNotNull);
    expect(grantCalled, isFalse);
  });

  test('collectAccounts refreshes distinct host and grant identities',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final grantIdentity =
        opaqueCredentialIdentity(ClaudeAdapter.id, 'independent-grant');
    final attempted = <String>[];
    final quotas = await collectClaudeProviderAccounts(
      ClaudeAdapter(
        credentialsFile: credentials,
        grantCredential: () async => ClaudeCredential(
          accessToken: 'grant-token',
          identity: grantIdentity,
        ),
        client: MockClient((request) async {
          attempted.add(request.headers['Authorization']!);
          if (_isProfileRequest(request)) {
            final host =
                request.headers['Authorization'] == 'Bearer host-token';
            return http.Response(
              _profileBody(
                accountUuid: host ? 'account-host' : 'account-grant',
              ),
              200,
            );
          }
          return http.Response(_usageBody(), 200);
        }),
      ),
    );

    expect(quotas, hasLength(2));
    expect(quotas.every((quota) => quota.ok && quota.hasWindows), isTrue);
    expect(quotas.map((quota) => quota.account).toSet(), {
      profileIdentity('account-host'),
      profileIdentity('account-grant'),
    });
    expect(attempted.toSet(), {'Bearer host-token', 'Bearer grant-token'});
    expect(attempted, hasLength(4));
  });

  test('collectAccounts emits one row for an exact duplicate identity',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    var requests = 0;
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => ClaudeCredential(
        accessToken: 'duplicate-grant-token',
        identity: hostIdentity(),
      ),
      client: MockClient((request) async {
        if (!_isProfileRequest(request)) requests++;
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(
          _isProfileRequest(request)
              ? _profileBody(accountUuid: 'account-shared')
              : _usageBody(),
          200,
        );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.account, profileIdentity('account-shared'));
    expect(quotas.single.ok, isTrue);
    expect(requests, 1);
  });

  test('collectAccounts uses a duplicate grant after host failure', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final attempted = <String>[];
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => ClaudeCredential(
        accessToken: 'duplicate-grant-token',
        identity: hostIdentity(),
      ),
      client: MockClient((request) async {
        final authorization = request.headers['Authorization']!;
        if (!_isProfileRequest(request)) attempted.add(authorization);
        return authorization == 'Bearer host-token'
            ? http.Response('{}', 401)
            : http.Response(
                _isProfileRequest(request)
                    ? _profileBody(accountUuid: 'account-shared')
                    : _usageBody(),
                200,
              );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.ok, isTrue);
    expect(quotas.single.account, profileIdentity('account-shared'));
    expect(attempted, [
      'Bearer host-token',
      'Bearer duplicate-grant-token',
    ]);
  });

  test('collectAccounts preserves a duplicate host throttle without retrying',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    var requests = 0;
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => ClaudeCredential(
        accessToken: 'duplicate-grant-token',
        identity: hostIdentity(),
      ),
      client: MockClient((request) async {
        if (!_isProfileRequest(request)) requests++;
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(
          '{}',
          429,
          headers: {'retry-after': '120'},
        );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.ok, isFalse);
    expect(quotas.single.account, hostIdentity());
    expect(quotas.single.error, 'HTTP 429');
    expect(quotas.single.pipeHealth, providerPipeHealthThrottled);
    expect(quotas.single.httpStatus, 429);
    expect(quotas.single.retryAfterSeconds, 120);
    expect(requests, 1);
  });

  test('collectAccounts preserves host evidence when grant refresh stalls',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final grantIdentity =
        opaqueCredentialIdentity(ClaudeAdapter.id, 'stalled-grant');
    TokenStore.saveDefaultOwnedBy(
      ClaudeAdapter.id,
      Tokens(
        accessToken: 'stored-grant',
        refreshToken: 'stored-refresh',
        expiresAt: nowEpoch() + 3600,
      ),
      grantIdentity,
    );
    final pending = Completer<ClaudeCredential?>();
    final stopwatch = Stopwatch()..start();
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () => pending.future,
      grantResolutionDeadline: const Duration(milliseconds: 20),
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collectAccounts();
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(quotas, hasLength(2));
    expect(quotas.first.ok, isTrue);
    expect(quotas.first.account, hostIdentity());
    expect(quotas.last.ok, isFalse);
    expect(quotas.last.account, grantIdentity);
    expect(quotas.last.error, contains('unable to refresh Claude grant'));
  });

  test('collectAccounts keeps distinct success and failure rows', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final grantIdentity =
        opaqueCredentialIdentity(ClaudeAdapter.id, 'healthy-grant');
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => ClaudeCredential(
        accessToken: 'grant-token',
        identity: grantIdentity,
      ),
      client: MockClient((request) async =>
          request.headers['Authorization'] == 'Bearer host-token'
              ? http.Response('{}', 503)
              : http.Response(_usageBody(), 200)),
    ).collectAccounts();

    expect(quotas, hasLength(2));
    expect(quotas.first.account, hostIdentity());
    expect(quotas.first.ok, isFalse);
    expect(quotas.first.httpStatus, 503);
    expect(quotas.last.account, grantIdentity);
    expect(quotas.last.ok, isTrue);
  });

  test('collectAccounts represents an indexed grant refresh failure', () async {
    credentials.deleteSync();
    final grantIdentity =
        opaqueCredentialIdentity(ClaudeAdapter.id, 'unavailable-grant');
    TokenStore.saveDefaultOwnedBy(
      ClaudeAdapter.id,
      Tokens(
        accessToken: 'stored-grant',
        refreshToken: 'stored-refresh',
        expiresAt: nowEpoch() + 3600,
      ),
      grantIdentity,
    );

    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => null,
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.ok, isFalse);
    expect(quotas.single.account, grantIdentity);
    expect(quotas.single.error, contains('unable to refresh Claude grant'));
  });

  test('maps the current limits payload to live quota windows', () async {
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response(_currentUsageBody(), 200)),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.windows.map((window) => window.label), ['5h', 'weekly']);
    expect(q.windows.map((window) => window.usedPercent), [45, 17]);
    expect(q.windows.every((window) => window.resetsAt != null), isTrue);
    expect(q.modelQuotas.map((quota) => quota.model), ['Fable']);
    expect(q.modelQuotas.single.usedPercent, 26);
    expect(q.modelQuotas.single.resetsAt, isNotNull);
    expect(q.modelQuotas.single.windowLabel, 'weekly');
    expect(q.perMachine, isFalse);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('current provider plan metadata overrides the local host label',
      () async {
    final payload = (jsonDecode(_currentUsageBody()) as Map<String, dynamic>)
      ..['subscription_type'] = 'team_premium';
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response(jsonEncode(payload), 200)),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.plan, 'team_premium');
    expect(
      q.planEvidenceSource,
      ProviderPlanEvidenceSource.providerMetadata,
    );
    expect(q.planEvidenceAsOf, q.asOf);
  });

  test('current Claude profile proves a Max plan when usage omits it',
      () async {
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((request) async => http.Response(
            _isProfileRequest(request)
                ? _profileBody(
                    accountUuid: 'account-max',
                    hasMax: true,
                  )
                : _currentUsageBody(),
            200,
          )),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.plan, 'max');
    expect(
      q.planEvidenceSource,
      ProviderPlanEvidenceSource.providerMetadata,
    );
    expect(q.planEvidenceAsOf, q.asOf);
  });

  test('current Claude profile proves a Team Premium plan', () async {
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((request) async => http.Response(
            _isProfileRequest(request)
                ? _profileBody(
                    accountUuid: 'account-team',
                    organizationUuid: 'organization-team',
                    organizationType: 'claude_team',
                    rateLimitTier: 'default_claude_max_20x',
                  )
                : _currentUsageBody(),
            200,
          )),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.plan, 'team_premium');
    expect(
      q.planEvidenceSource,
      ProviderPlanEvidenceSource.providerMetadata,
    );
    expect(q.planEvidenceAsOf, q.asOf);
  });

  for (final scenario in [
    (
      name: 'Pro',
      expectedPlan: 'pro',
      hasPro: true,
      organizationUuid: null,
      organizationType: null,
      rateLimitTier: null,
    ),
    (
      name: 'Team Standard',
      expectedPlan: 'team_standard',
      hasPro: false,
      organizationUuid: 'organization-standard',
      organizationType: 'claude_team',
      rateLimitTier: 'default_claude_team',
    ),
  ]) {
    test('current Claude profile proves a ${scenario.name} plan', () async {
      final q = await ClaudeAdapter(
        credentialsFile: credentials,
        client: MockClient((request) async => http.Response(
              _isProfileRequest(request)
                  ? _profileBody(
                      accountUuid: 'account-plan',
                      organizationUuid: scenario.organizationUuid,
                      hasPro: scenario.hasPro,
                      organizationType: scenario.organizationType,
                      rateLimitTier: scenario.rateLimitTier,
                    )
                  : _currentUsageBody(),
              200,
            )),
      ).collect();

      expect(q.ok, isTrue);
      expect(q.plan, scenario.expectedPlan);
      expect(
        q.planEvidenceSource,
        ProviderPlanEvidenceSource.providerMetadata,
      );
      expect(q.planEvidenceAsOf, q.asOf);
    });
  }

  test('malformed provider plan metadata cannot fall back to the host label',
      () async {
    final payload = (jsonDecode(_currentUsageBody()) as Map<String, dynamic>)
      ..['subscription_type'] = {'unexpected': 'max'};
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((request) async => http.Response(
            _isProfileRequest(request)
                ? _profileBody(
                    accountUuid: 'account-max',
                    hasMax: true,
                  )
                : jsonEncode(payload),
            200,
          )),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.plan, isNull);
    expect(q.planEvidenceSource, isNull);
    expect(q.planEvidenceAsOf, isNull);
  });

  test('same provider account collapses distinct local credentials', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => ClaudeCredential(
        accessToken: 'grant-token',
        identity: opaqueCredentialIdentity(
          ClaudeAdapter.id,
          'different-local-generation',
        ),
      ),
      client: MockClient((request) async => http.Response(
            _isProfileRequest(request)
                ? _profileBody(
                    accountUuid: 'account-shared',
                    organizationUuid: 'organization-shared',
                  )
                : _usageBody(),
            200,
          )),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.ok, isTrue);
    expect(
      quotas.single.account,
      profileIdentity('account-shared', 'organization-shared'),
    );
    expect(
      ClaudeAdapter.currentCredentialIdentities(credentialsFile: credentials),
      {profileIdentity('account-shared', 'organization-shared')},
    );
  });

  test('provider pool identity survives local credential replacement',
      () async {
    writeCreds(
      expiresAtMs: (nowEpoch() + 3600) * 1000,
      accessToken: 'host-token-a',
      refreshToken: 'host-refresh-a',
    );
    final client = MockClient((request) async => http.Response(
          _isProfileRequest(request)
              ? _profileBody(
                  accountUuid: 'account-stable',
                  organizationUuid: 'organization-stable',
                )
              : _usageBody(),
          200,
        ));
    final first = await ClaudeAdapter(
      credentialsFile: credentials,
      client: client,
    ).collect();

    writeCreds(
      expiresAtMs: (nowEpoch() + 3600) * 1000,
      accessToken: 'host-token-b',
      refreshToken: 'host-refresh-b',
    );
    final second = await ClaudeAdapter(
      credentialsFile: credentials,
      client: client,
    ).collect();

    final expected = profileIdentity('account-stable', 'organization-stable');
    expect(first.account, expected);
    expect(second.account, expected);
    expect(first.account, second.account);
  });

  test('distinct provider accounts remain separately routable', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final grantIdentity =
        opaqueCredentialIdentity(ClaudeAdapter.id, 'distinct-grant');
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => ClaudeCredential(
        accessToken: 'grant-token',
        identity: grantIdentity,
      ),
      client: MockClient((request) async {
        if (!_isProfileRequest(request)) {
          return http.Response(_usageBody(), 200);
        }
        final host = request.headers['Authorization'] == 'Bearer host-token';
        return http.Response(
          _profileBody(accountUuid: host ? 'account-host' : 'account-grant'),
          200,
        );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(2));
    expect(quotas.every((quota) => quota.ok), isTrue);
    expect(quotas.map((quota) => quota.account).toSet(), {
      profileIdentity('account-host'),
      profileIdentity('account-grant'),
    });
  });

  test('multiple successes fail closed when profile identity is unavailable',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final grantIdentity =
        opaqueCredentialIdentity(ClaudeAdapter.id, 'unidentified-grant');
    final quotas = await ClaudeAdapter(
      credentialsFile: credentials,
      grantCredential: () async => ClaudeCredential(
        accessToken: 'grant-token',
        identity: grantIdentity,
      ),
      client: MockClient((request) async => http.Response(
            _isProfileRequest(request) ? '{}' : _usageBody(),
            200,
          )),
    ).collectAccounts();

    expect(quotas, hasLength(2));
    expect(quotas.where((quota) => quota.ok), hasLength(1));
    final excluded = quotas.singleWhere((quota) => !quota.ok);
    expect(excluded.account, grantIdentity);
    expect(excluded.hasWindows, isFalse);
    expect(excluded.error, contains('identity unavailable'));
  });

  test('malformed profile identity never leaks provider identifiers', () async {
    const rawAccount = 'account-secret';
    const rawOrganization = 'organization-secret';
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((request) async => http.Response(
            _isProfileRequest(request)
                ? jsonEncode({
                    'account': {
                      'uuid': '$rawAccount\n',
                      'has_claude_max': true,
                      'has_claude_pro': false,
                    },
                    'organization': {'uuid': rawOrganization},
                  })
                : _usageBody(),
            200,
          )),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.plan, 'max');
    final encoded = jsonEncode(q.toJson());
    expect(encoded, isNot(contains(rawAccount)));
    expect(encoded, isNot(contains(rawOrganization)));
  });

  test('rejects a canonical response missing the binding weekly row', () async {
    final body = jsonDecode(_currentUsageBody()) as Map<String, dynamic>;
    (body['limits'] as List).removeWhere(
      (row) => row is Map && row['kind'] == 'weekly_all',
    );
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, 'invalid Claude usage response');
    expect(q.windows, isEmpty);
    expect(q.modelQuotas, isEmpty);
  });

  test('rejects valid Fable quota beside a malformed scoped sibling', () async {
    final body = jsonDecode(_currentUsageBody()) as Map<String, dynamic>;
    (body['limits'] as List).add({
      'kind': 'weekly_scoped',
      'group': 'weekly',
      'percent': '99',
      'resets_at': '2030-01-02T00:00:00Z',
      'scope': {
        'model': {'display_name': 'Fable'},
      },
    });
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, 'invalid Claude usage response');
    expect(q.windows, isEmpty);
    expect(q.modelQuotas, isEmpty);
  });

  test('rejects a present malformed known legacy block', () async {
    final body = jsonDecode(_currentUsageBody()) as Map<String, dynamic>
      ..['seven_day'] = {
        'utilization': 17,
        'resets_at': 'not-a-date',
      };
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, 'invalid Claude usage response');
    expect(q.windows, isEmpty);
    expect(q.modelQuotas, isEmpty);
  });

  test('host identity is opaque and stable across access-token rotation',
      () async {
    writeCreds(
      expiresAtMs: (nowEpoch() + 3600) * 1000,
      accessToken: 'host-access-a',
    );
    final client = MockClient((_) async => http.Response(_usageBody(), 200));
    final first = await ClaudeAdapter(
      credentialsFile: credentials,
      client: client,
    ).collect();

    writeCreds(
      expiresAtMs: (nowEpoch() + 3600) * 1000,
      accessToken: 'host-access-b',
    );
    final second = await ClaudeAdapter(
      credentialsFile: credentials,
      client: client,
    ).collect();

    expect(first.account, hostIdentity());
    expect(second.account, first.account);
    expect(isOpaqueCredentialIdentity(first.account), isTrue);
    expect(first.account, isNot(contains('host-access')));
    expect(first.account, isNot(contains(hostRefreshToken)));
  });

  test('same-plan host credential replacement gets a new identity', () async {
    final client = MockClient((_) async => http.Response(_usageBody(), 200));
    writeCreds(
      expiresAtMs: (nowEpoch() + 3600) * 1000,
      refreshToken: 'host-grant-a',
    );
    final first = await ClaudeAdapter(
      credentialsFile: credentials,
      client: client,
    ).collect();

    writeCreds(
      expiresAtMs: (nowEpoch() + 3600) * 1000,
      refreshToken: 'host-grant-b',
    );
    final second = await ClaudeAdapter(
      credentialsFile: credentials,
      client: client,
    ).collect();

    expect(first.plan, 'max');
    expect(second.plan, 'max');
    expect(first.account, hostIdentity('host-grant-a'));
    expect(second.account, hostIdentity('host-grant-b'));
    expect(second.account, isNot(first.account));
  });

  test('independent grant replacements get distinct identities', () async {
    credentials.deleteSync();
    final client = MockClient((_) async => http.Response(_usageBody(), 200));
    Future<ProviderQuota> read(String token) => ClaudeAdapter(
          credentialsFile: credentials,
          grantToken: () async => token,
          client: client,
        ).collect();

    final first = await read('grant-generation-a');
    final second = await read('grant-generation-b');

    expect(first.account, isNot(second.account));
    expect(isOpaqueCredentialIdentity(first.account), isTrue);
    expect(isOpaqueCredentialIdentity(second.account), isTrue);
    expect(first.plan, isNull);
    expect(second.plan, isNull);
  });

  test('current account index contains only opaque credential identities', () {
    final accounts = ClaudeAdapter.currentCredentialIdentities(
      credentialsFile: credentials,
    );

    expect(accounts, {hostIdentity()});
    expect(accounts.every(isOpaqueCredentialIdentity), isTrue);
  });

  test('network failures retain the attempted credential identity', () async {
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => throw StateError('offline')),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.account, hostIdentity());
    expect(q.error, 'unable to read Claude usage');
  });

  test('a throwing grant loader cannot break a fresh host-token read',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => throw StateError('grant refresh unavailable'),
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('a malformed host credential falls through to the independent grant',
      () async {
    credentials.writeAsStringSync('{not valid json');
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer grant-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('falls through to the grant when the host token is expired', () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        // The expired host token is demoted below the grant, so the grant is
        // the first token tried.
        expect(request.headers['Authorization'], 'Bearer grant-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('keeps the stale host token as a last chance after grant auth fails',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final tried = <String>[];
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        final auth = request.headers['Authorization']!;
        if (!_isProfileRequest(request)) tried.add(auth);
        if (auth == 'Bearer host-token') {
          return http.Response(_usageBody(), 200);
        }
        return http.Response('{}', 401);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(tried, ['Bearer grant-token', 'Bearer host-token']);
  });

  test('keeps the stale host token as a last chance when grant loading throws',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => throw StateError('grant store unavailable'),
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('falls through to the grant on a 401 from a fresh host token', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final tried = <String>[];
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        final auth = request.headers['Authorization']!;
        if (!_isProfileRequest(request)) tried.add(auth);
        if (auth == 'Bearer grant-token') {
          return http.Response(_usageBody(), 200);
        }
        return http.Response('{}', 401);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(tried, ['Bearer host-token', 'Bearer grant-token']);
  });

  test('independent grant never borrows failed host identity', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'other-account-grant',
      client: MockClient((request) async {
        if (request.headers['Authorization'] == 'Bearer host-token') {
          return http.Response('{}', 401);
        }
        expect(
          request.headers['Authorization'],
          'Bearer other-account-grant',
        );
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(
      q.account,
      opaqueCredentialIdentity(ClaudeAdapter.id, 'other-account-grant'),
    );
    expect(q.plan, isNull);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('points at both recovery paths when expired with no grant', () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => null,
      client: MockClient((_) async => http.Response('{}', 401)),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, contains('re-run claude'));
    expect(q.error, contains('quotabot login claude'));
  });

  test('preserves throttle metadata and recovery for a known-expired login',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => null,
      client: MockClient((_) async => http.Response(
            '{}',
            429,
            headers: {'retry-after': '120'},
          )),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, startsWith('HTTP 429'));
    expect(q.error, contains('saved Claude login expired'));
    expect(q.error, contains('re-run claude'));
    expect(q.error, contains('quotabot login claude'));
    expect(q.account, hostIdentity());
    expect(q.plan, 'max');
    expect(q.pipeHealth, providerPipeHealthThrottled);
    expect(q.httpStatus, 429);
    expect(q.retryAfterSeconds, 120);
  });
}

String _usageBody() => jsonEncode({
      'five_hour': {'utilization': 30, 'resets_at': '2030-01-01T00:00:00Z'},
      'seven_day': {'utilization': 20, 'resets_at': '2030-01-02T00:00:00Z'},
    });

String _currentUsageBody() => jsonEncode({
      'limits': [
        {
          'kind': 'session',
          'group': 'session',
          'percent': 45,
          'resets_at': '2030-01-01T00:00:00Z',
          'scope': null,
          'is_active': true,
        },
        {
          'kind': 'weekly_all',
          'group': 'weekly',
          'percent': 17,
          'resets_at': '2030-01-02T00:00:00Z',
          'scope': null,
          'is_active': false,
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': 26,
          'resets_at': '2030-01-02T00:00:00Z',
          'scope': {
            'model': {'id': null, 'display_name': 'Fable'},
            'surface': null,
          },
          'is_active': false,
        },
      ],
    });

bool _isProfileRequest(http.Request request) =>
    request.url.path.endsWith('/profile');

String _profileBody({
  required String accountUuid,
  String? organizationUuid,
  bool hasMax = false,
  bool hasPro = false,
  String? organizationType,
  String? rateLimitTier,
}) =>
    jsonEncode({
      'account': {
        'uuid': accountUuid,
        'has_claude_max': hasMax,
        'has_claude_pro': hasPro,
      },
      if (organizationUuid != null)
        'organization': {
          'uuid': organizationUuid,
          if (organizationType != null) 'organization_type': organizationType,
          if (rateLimitTier != null) 'rate_limit_tier': rateLimitTier,
        },
    });
