import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/codex.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:quotabot_collector/provider_adapters.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  final injectedIdentity =
      opaqueCredentialIdentity(CodexAdapter.id, 'injected-usage-credential');
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_codex_adapter_');
    setQuotabotDirOverrideForTesting(Directory('${temp.path}/quotabot'));
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File writeAuth(
    String accessToken, {
    String? accountId = 'acct-1',
    String? refreshToken = 'host-refresh-token',
  }) {
    final authFile = File('${temp.path}/auth.json');
    authFile.writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': accessToken,
          if (accountId != null) 'account_id': accountId,
          if (refreshToken != null) 'refresh_token': refreshToken,
        },
      }),
    );
    return authFile;
  }

  String hostIdentity(String accountId) =>
      opaqueCredentialIdentity(CodexAdapter.id, 'account-id:$accountId');

  test('uses the host auth.json token for the account-wide read', () async {
    final authFile = writeAuth('host-tok');
    var grantCalled = false;
    final q = await CodexAdapter(
      authFile: authFile,
      grantToken: () async {
        grantCalled = true;
        throw StateError('the grant must not be resolved');
      },
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-tok');
        expect(request.headers['chatgpt-account-id'], 'acct-1');
        return http.Response(
          jsonEncode(_wham(primary: 20, secondary: 50)),
          200,
        );
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.perMachine, isFalse);
    expect(q.hasWindows, isTrue);
    expect(q.account, hostIdentity('acct-1'));
    expect(q.account, isNot(contains('acct-1')));
    expect(q.account, isNot(contains('blisspixel')));
    expect(grantCalled, isFalse);
  });

  test('collectAccounts refreshes distinct host and grant identities',
      () async {
    final authFile = writeAuth('host-tok');
    final grantIdentity =
        opaqueCredentialIdentity(CodexAdapter.id, 'independent-grant');
    final attempted = <String>[];
    final quotas = await collectCodexProviderAccounts(
      CodexAdapter(
        authFile: authFile,
        grantCredential: () async => OpenAiCredential(
          accessToken: 'grant-tok',
          identity: grantIdentity,
        ),
        client: MockClient((request) async {
          attempted.add(request.headers['Authorization']!);
          if (request.headers['Authorization'] == 'Bearer host-tok') {
            expect(request.headers['chatgpt-account-id'], 'acct-1');
          } else {
            expect(request.headers.containsKey('chatgpt-account-id'), isFalse);
          }
          return http.Response(
            jsonEncode(_wham(primary: 20, secondary: 50)),
            200,
          );
        }),
      ),
    );

    expect(quotas, hasLength(2));
    expect(quotas.every((quota) => quota.ok && quota.hasWindows), isTrue);
    expect(quotas.map((quota) => quota.account).toSet(), {
      hostIdentity('acct-1'),
      grantIdentity,
    });
    expect(attempted.toSet(), {'Bearer host-tok', 'Bearer grant-tok'});
  });

  test('collectAccounts emits one row for an exact duplicate identity',
      () async {
    final authFile = writeAuth('host-tok');
    var requests = 0;
    final quotas = await CodexAdapter(
      authFile: authFile,
      grantCredential: () async => OpenAiCredential(
        accessToken: 'duplicate-grant-token',
        identity: hostIdentity('acct-1'),
      ),
      client: MockClient((request) async {
        requests++;
        expect(request.headers['Authorization'], 'Bearer host-tok');
        return http.Response(
          jsonEncode(_wham(primary: 20, secondary: 50)),
          200,
        );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.account, hostIdentity('acct-1'));
    expect(quotas.single.ok, isTrue);
    expect(requests, 1);
  });

  test('production grant identity deduplicates the matching host account',
      () async {
    final authFile = writeAuth('host-tok', accountId: 'acct-1');
    TokenStore.save(
      OpenAiAuth.provider,
      Tokens(
        accessToken: _unsignedJwt({
          'https://api.openai.com/auth': {
            'chatgpt_account_id': 'acct-1',
          },
        }),
        refreshToken: 'grant-refresh',
        expiresAt: nowEpoch() + 3600,
      ),
    );
    var usageRequests = 0;
    final quotas = await CodexAdapter(
      authFile: authFile,
      client: MockClient((request) async {
        usageRequests++;
        expect(request.headers['Authorization'], 'Bearer host-tok');
        expect(request.headers['chatgpt-account-id'], 'acct-1');
        return http.Response(
          jsonEncode(_wham(primary: 20, secondary: 50)),
          200,
        );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.account, hostIdentity('acct-1'));
    expect(quotas.single.ok, isTrue);
    expect(usageRequests, 1);
    expect(
      TokenStore.defaultOwner(OpenAiAuth.provider),
      hostIdentity('acct-1'),
    );
  });

  test('collectAccounts uses a duplicate grant after host failure', () async {
    final authFile = writeAuth('host-tok');
    final attempted = <String>[];
    final quotas = await CodexAdapter(
      authFile: authFile,
      grantCredential: () async => OpenAiCredential(
        accessToken: 'duplicate-grant-token',
        identity: hostIdentity('acct-1'),
      ),
      client: MockClient((request) async {
        final authorization = request.headers['Authorization']!;
        attempted.add(authorization);
        return authorization == 'Bearer host-tok'
            ? http.Response('{}', 401)
            : http.Response(
                jsonEncode(_wham(primary: 20, secondary: 50)),
                200,
              );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.ok, isTrue);
    expect(quotas.single.account, hostIdentity('acct-1'));
    expect(attempted, ['Bearer host-tok', 'Bearer duplicate-grant-token']);
  });

  test('collectAccounts preserves a duplicate host throttle without retrying',
      () async {
    final authFile = writeAuth('host-tok');
    var requests = 0;
    final quotas = await CodexAdapter(
      authFile: authFile,
      grantCredential: () async => OpenAiCredential(
        accessToken: 'duplicate-grant-token',
        identity: hostIdentity('acct-1'),
      ),
      client: MockClient((request) async {
        requests++;
        expect(request.headers['Authorization'], 'Bearer host-tok');
        return http.Response(
          '{}',
          429,
          headers: {'retry-after': '120'},
        );
      }),
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.ok, isFalse);
    expect(quotas.single.account, hostIdentity('acct-1'));
    expect(quotas.single.error, 'HTTP 429');
    expect(quotas.single.pipeHealth, providerPipeHealthThrottled);
    expect(quotas.single.httpStatus, 429);
    expect(quotas.single.retryAfterSeconds, 120);
    expect(requests, 1);
  });

  test('collectAccounts preserves host evidence when grant refresh stalls',
      () async {
    final authFile = writeAuth('host-tok');
    final grantIdentity =
        opaqueCredentialIdentity(CodexAdapter.id, 'stalled-grant');
    TokenStore.saveDefaultOwnedBy(
      OpenAiAuth.provider,
      Tokens(
        accessToken: 'stored-grant',
        refreshToken: 'stored-refresh',
        expiresAt: nowEpoch() + 3600,
      ),
      grantIdentity,
    );
    final pending = Completer<OpenAiCredential?>();
    final stopwatch = Stopwatch()..start();
    final quotas = await CodexAdapter(
      authFile: authFile,
      grantCredential: () => pending.future,
      grantResolutionDeadline: const Duration(milliseconds: 20),
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-tok');
        return http.Response(
          jsonEncode(_wham(primary: 20, secondary: 50)),
          200,
        );
      }),
    ).collectAccounts();
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(quotas, hasLength(2));
    expect(quotas.first.ok, isTrue);
    expect(quotas.first.account, hostIdentity('acct-1'));
    expect(quotas.last.ok, isFalse);
    expect(quotas.last.account, grantIdentity);
    expect(quotas.last.error, contains('unable to refresh Codex grant'));
  });

  test('collectAccounts keeps distinct success and failure rows', () async {
    final authFile = writeAuth('host-tok');
    final grantIdentity =
        opaqueCredentialIdentity(CodexAdapter.id, 'healthy-grant');
    final quotas = await CodexAdapter(
      authFile: authFile,
      grantCredential: () async => OpenAiCredential(
        accessToken: 'grant-tok',
        identity: grantIdentity,
      ),
      client: MockClient((request) async =>
          request.headers['Authorization'] == 'Bearer host-tok'
              ? http.Response('{}', 503)
              : http.Response(
                  jsonEncode(_wham(primary: 20, secondary: 50)),
                  200,
                )),
    ).collectAccounts();

    expect(quotas, hasLength(2));
    expect(quotas.first.account, hostIdentity('acct-1'));
    expect(quotas.first.ok, isFalse);
    expect(quotas.first.httpStatus, 503);
    expect(quotas.last.account, grantIdentity);
    expect(quotas.last.ok, isTrue);
  });

  test('collectAccounts represents an indexed grant refresh failure', () async {
    final grantIdentity =
        opaqueCredentialIdentity(CodexAdapter.id, 'unavailable-grant');
    TokenStore.saveDefaultOwnedBy(
      OpenAiAuth.provider,
      Tokens(
        accessToken: 'stored-grant',
        refreshToken: 'stored-refresh',
        expiresAt: nowEpoch() + 3600,
      ),
      grantIdentity,
    );

    final quotas = await CodexAdapter(
      authFile: File('${temp.path}/missing-auth.json'),
      grantCredential: () async => null,
    ).collectAccounts();

    expect(quotas, hasLength(1));
    expect(quotas.single.ok, isFalse);
    expect(quotas.single.account, grantIdentity);
    expect(quotas.single.error, contains('unable to refresh Codex grant'));
  });

  test('falls through to the independent grant when host auth fails', () async {
    final authFile = writeAuth('stale-host-tok');
    final tried = <String>[];
    final q = await CodexAdapter(
      authFile: authFile,
      grantToken: () async => 'grant-tok',
      client: MockClient((request) async {
        final auth = request.headers['Authorization']!;
        tried.add(auth);
        if (auth == 'Bearer grant-tok') {
          expect(request.headers.containsKey('chatgpt-account-id'), isFalse);
          return http.Response(
            jsonEncode(_wham(primary: 20, secondary: 50)),
            200,
          );
        }
        expect(request.headers['chatgpt-account-id'], 'acct-1');
        return http.Response('{}', 401);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.perMachine, isFalse);
    expect(
      q.account,
      opaqueCredentialIdentity(CodexAdapter.id, 'grant-tok'),
    );
    expect(tried, ['Bearer stale-host-tok', 'Bearer grant-tok']);
  });

  test('falls through when a host 200 has an invalid scoped quota sibling',
      () async {
    final authFile = writeAuth('host-tok');
    final tried = <String>[];
    final q = await CodexAdapter(
      authFile: authFile,
      grantToken: () async => 'grant-tok',
      client: MockClient((request) async {
        final auth = request.headers['Authorization']!;
        tried.add(auth);
        if (auth == 'Bearer host-tok') {
          final malformed = _wham(primary: 20, secondary: 50)
            ..['additional_rate_limits'] = [
              {
                'limit_name': 'GPT-5.3-Codex-Spark',
                'rate_limit': {
                  'primary_window': {
                    'used_percent': 0,
                    'limit_window_seconds': 61,
                    'reset_at': nowEpoch() + 3600,
                  },
                },
              },
            ];
          return http.Response(jsonEncode(malformed), 200);
        }
        return http.Response(
          jsonEncode(_wham(primary: 25, secondary: 40)),
          200,
        );
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(
      q.account,
      opaqueCredentialIdentity(CodexAdapter.id, 'grant-tok'),
    );
    expect(tried, ['Bearer host-tok', 'Bearer grant-tok']);
  });

  test('malformed host auth cannot suppress the independent grant', () async {
    final authFile = File('${temp.path}/auth.json')..writeAsStringSync('{bad');
    var calls = 0;
    final q = await CodexAdapter(
      authFile: authFile,
      grantToken: () async => 'grant-tok',
      client: MockClient((request) async {
        calls++;
        expect(request.headers['Authorization'], 'Bearer grant-tok');
        expect(request.headers.containsKey('chatgpt-account-id'), isFalse);
        return http.Response(
          jsonEncode(_wham(primary: 25, secondary: 50)),
          200,
        );
      }),
    ).collect();

    expect(calls, 1);
    expect(q.ok, isTrue);
    expect(q.windows, hasLength(2));
  });

  test('no live metadata fails closed without a session-file fallback',
      () async {
    final sessions = Directory('${temp.path}/sessions')..createSync();
    File('${sessions.path}/rollout-content.jsonl').writeAsStringSync(
      '{"prompt":"private","rate_limits":{"primary":{"used_percent":1}}}\n',
    );

    final q = await CodexAdapter(
      authFile: File('${temp.path}/missing-auth.json'),
      usageFetcher: () async => null,
      usageCredentialIdentity: injectedIdentity,
      grantToken: () async => null,
    ).collect();

    expect(q.ok, isFalse);
    expect(q.windows, isEmpty);
    expect(q.error, contains('no account-wide Codex usage'));
    expect(q.error, isNot(contains('session')));
  });

  test('authoritative endpoint wins regardless of local files', () async {
    final q = await CodexAdapter(
      usageFetcher: () async => _wham(primary: 0, secondary: 100),
      usageCredentialIdentity: injectedIdentity,
    ).collect();

    expect(q.ok, isTrue);
    expect(q.account, injectedIdentity);
    expect(q.plan, 'pro');
    expect(q.windows.firstWhere((w) => w.label == '5h').usedPercent, 0);
    expect(q.windows.firstWhere((w) => w.label == 'weekly').usedPercent, 100);
    expect(q.perMachine, isFalse);
    expect(q.sourceClass.wireName, 'authoritative_live');
  });

  test('codexUsageWindows maps only valid live rate-limit windows', () {
    final windows = codexUsageWindows(_wham(primary: 12, secondary: 100));
    expect(windows.firstWhere((x) => x.label == '5h').usedPercent, 12);
    expect(windows.firstWhere((x) => x.label == 'weekly').usedPercent, 100);
    expect(codexUsageWindows(const {}), isEmpty);
    expect(
      codexUsageWindows({
        'rate_limit': {
          'primary_window': {'used_percent': 101},
        },
      }),
      isEmpty,
    );
  });

  test('accepts a weekly-only plan with a separate scoped model pool',
      () async {
    final q = await CodexAdapter(
      usageFetcher: () async => {
        'plan_type': 'pro',
        'rate_limit': {
          'allowed': true,
          'limit_reached': false,
          'primary_window': {
            'used_percent': 63,
            'limit_window_seconds': 604800,
            'reset_at': 1785011368,
          },
          'secondary_window': null,
        },
        'additional_rate_limits': [
          {
            'limit_name': 'GPT-5.3-Codex-Spark',
            'rate_limit': {
              'allowed': true,
              'limit_reached': false,
              'primary_window': {
                'used_percent': 0,
                'limit_window_seconds': 604800,
                'reset_at': 1785034650,
              },
              'secondary_window': null,
            },
          },
        ],
      },
      usageCredentialIdentity: injectedIdentity,
    ).collect();

    expect(q.ok, isTrue);
    expect(q.plan, 'pro');
    expect(q.windows, hasLength(1));
    expect(q.windows.single.label, 'weekly');
    expect(q.windows.single.usedPercent, 63);
    expect(q.modelQuotas, hasLength(1));
    expect(q.modelQuotas.single.model, 'GPT-5.3-Codex-Spark');
    expect(q.modelQuotas.single.usedPercent, 0);
  });

  test('rejects the complete response when one additional limit is malformed',
      () async {
    final q = await CodexAdapter(
      usageFetcher: () async => {
        ..._wham(primary: 20, secondary: 40),
        'additional_rate_limits': [
          {
            'limit_name': 'GPT-5.3-Codex-Spark',
            'rate_limit': {
              'allowed': true,
              'limit_reached': false,
              'primary_window': {
                'used_percent': 0,
                'limit_window_seconds': 604800,
                'reset_at': nowEpoch() + 604800,
              },
            },
          },
          {
            'limit_name': '',
            'rate_limit': {
              'primary_window': {
                'used_percent': 0,
                'limit_window_seconds': 604800,
                'reset_at': nowEpoch() + 604800,
              },
            },
          },
        ],
      },
      usageCredentialIdentity: injectedIdentity,
    ).collect();

    expect(q.ok, isFalse);
    expect(q.windows, isEmpty);
    expect(q.modelQuotas, isEmpty);
    expect(q.error, contains('invalid Codex usage response'));
  });

  test('surfaces redeemable reset credits as a structured signal', () async {
    final q = await CodexAdapter(
      usageFetcher: () async =>
          _wham(primary: 95, secondary: 40, resetCredits: 2),
      usageCredentialIdentity: injectedIdentity,
    ).collect();

    expect(q.ok, isTrue);
    expect(q.resetCreditsAvailable, 2);
    expect(
      resetAvailableMessage(q),
      allOf(contains('2 resets available in Codex'), contains('redeem')),
    );
  });

  test('reset credits are zero when absent or explicitly empty', () async {
    final none = await CodexAdapter(
      usageFetcher: () async =>
          _wham(primary: 95, secondary: 40, resetCredits: 0),
      usageCredentialIdentity: injectedIdentity,
    ).collect();
    expect(none.resetCreditsAvailable, 0);
    expect(resetAvailableMessage(none), isNull);

    final absent = await CodexAdapter(
      usageFetcher: () async => _wham(primary: 95, secondary: 40),
      usageCredentialIdentity: injectedIdentity,
    ).collect();
    expect(absent.resetCreditsAvailable, 0);
    expect(resetAvailableMessage(absent), isNull);
  });

  test('one redeemable reset reads in the singular', () async {
    final one = await CodexAdapter(
      usageFetcher: () async =>
          _wham(primary: 95, secondary: 40, resetCredits: 1),
      usageCredentialIdentity: injectedIdentity,
    ).collect();
    expect(one.resetCreditsAvailable, 1);
    expect(resetAvailableMessage(one), contains('1 reset available in Codex'));
  });

  test('host identity survives access and refresh rotation', () async {
    final authFile = writeAuth(
      'host-access-a',
      accountId: 'stable-account',
      refreshToken: 'host-refresh-a',
    );
    final client = MockClient((_) async => http.Response(
          jsonEncode(_wham(primary: 10, secondary: 20, includeEmail: false)),
          200,
        ));
    final first = await CodexAdapter(
      authFile: authFile,
      client: client,
    ).collect();

    writeAuth(
      'host-access-b',
      accountId: 'stable-account',
      refreshToken: 'host-refresh-b',
    );
    final second = await CodexAdapter(
      authFile: authFile,
      client: client,
    ).collect();

    expect(first.account, hostIdentity('stable-account'));
    expect(second.account, first.account);
    expect(isOpaqueCredentialIdentity(second.account), isTrue);
  });

  test('same-plan account replacement receives a separate identity', () async {
    final authFile = writeAuth(
      'account-a-access',
      accountId: 'account-a',
      refreshToken: 'account-a-refresh',
    );
    final client = MockClient((_) async => http.Response(
          jsonEncode(_wham(primary: 10, secondary: 20, includeEmail: false)),
          200,
        ));
    final first = await CodexAdapter(
      authFile: authFile,
      client: client,
    ).collect();

    writeAuth(
      'account-b-access',
      accountId: 'account-b',
      refreshToken: 'account-b-refresh',
    );
    final second = await CodexAdapter(
      authFile: authFile,
      client: client,
    ).collect();

    expect(first.plan, 'pro');
    expect(second.plan, 'pro');
    expect(first.account, hostIdentity('account-a'));
    expect(second.account, hostIdentity('account-b'));
    expect(second.account, isNot(first.account));
  });

  test('grant token rotation keeps its supplied stable identity', () async {
    final authFile = File('${temp.path}/missing-auth.json');
    final identity =
        opaqueCredentialIdentity(CodexAdapter.id, 'grant-generation');
    Future<ProviderQuota> read(String token) => CodexAdapter(
          authFile: authFile,
          grantCredential: () async => OpenAiCredential(
            accessToken: token,
            identity: identity,
          ),
          client: MockClient((request) async {
            expect(request.headers.containsKey('chatgpt-account-id'), isFalse);
            return http.Response(
              jsonEncode(
                _wham(primary: 10, secondary: 20, includeEmail: false),
              ),
              200,
            );
          }),
        ).collect();

    final first = await read('grant-access-a');
    final second = await read('grant-access-b');

    expect(first.account, identity);
    expect(second.account, identity);
  });

  test('replacement grants receive separate opaque identities', () async {
    final authFile = File('${temp.path}/missing-auth.json');
    final client = MockClient((_) async => http.Response(
          jsonEncode(_wham(primary: 10, secondary: 20, includeEmail: false)),
          200,
        ));
    Future<ProviderQuota> read(String generation) => CodexAdapter(
          authFile: authFile,
          grantCredential: () async => OpenAiCredential(
            accessToken: '$generation-access',
            identity: opaqueCredentialIdentity(CodexAdapter.id, generation),
          ),
          client: client,
        ).collect();

    final first = await read('grant-a');
    final second = await read('grant-b');

    expect(first.account, isNot(second.account));
    expect(isOpaqueCredentialIdentity(first.account), isTrue);
    expect(isOpaqueCredentialIdentity(second.account), isTrue);
  });

  test('current account index contains only active opaque identities', () {
    final authFile = writeAuth(
      'host-access',
      accountId: 'indexed-account',
    );
    final grantIdentity =
        opaqueCredentialIdentity(CodexAdapter.id, 'indexed-grant');
    TokenStore.saveDefaultOwnedBy(
      OpenAiAuth.provider,
      Tokens(
        accessToken: 'grant-access',
        refreshToken: 'grant-refresh',
        expiresAt: nowEpoch() + 3600,
      ),
      grantIdentity,
    );

    final accounts = CodexAdapter.currentCredentialIdentities(
      authFile: authFile,
    );

    expect(accounts, {hostIdentity('indexed-account'), grantIdentity});
    expect(accounts.every(isOpaqueCredentialIdentity), isTrue);
  });
}

Map<String, dynamic> _wham({
  required num primary,
  required num secondary,
  int? resetCredits,
  bool includeEmail = true,
}) {
  final now = nowEpoch();
  return {
    if (includeEmail) 'email': 'blisspixel@example.com',
    'plan_type': 'pro',
    'rate_limit': {
      'allowed': secondary < 100,
      'limit_reached': secondary >= 100,
      'primary_window': {
        'used_percent': primary,
        'limit_window_seconds': 18000,
        'reset_at': now + 18000,
      },
      'secondary_window': {
        'used_percent': secondary,
        'limit_window_seconds': 604800,
        'reset_at': now + 604800,
      },
    },
    if (resetCredits != null)
      'rate_limit_reset_credits': {'available_count': resetCredits},
  };
}

String _unsignedJwt(Map<String, dynamic> payload) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({})}.${encode(payload)}.sig';
}
