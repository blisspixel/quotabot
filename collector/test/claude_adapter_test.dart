import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/claude.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  const hostRefreshToken = 'host-refresh-token';
  late Directory temp;
  late File credentials;

  setUp(() {
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

  test('malformed provider plan metadata cannot fall back to the host label',
      () async {
    final payload = (jsonDecode(_currentUsageBody()) as Map<String, dynamic>)
      ..['subscription_type'] = {'unexpected': 'max'};
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response(jsonEncode(payload), 200)),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.plan, isNull);
    expect(q.planEvidenceSource, isNull);
    expect(q.planEvidenceAsOf, isNull);
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
        tried.add(auth);
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
        tried.add(auth);
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
