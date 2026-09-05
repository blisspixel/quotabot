import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/grok.dart';
import 'package:quotabot_collector/auth/provider_disconnect.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_read_gate.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

const _reset = '2026-09-12T00:00:00Z';
Map<String, dynamic> _billing([num percent = 73]) => {
      'config': {
        'creditUsagePercent': percent,
        'currentPeriod': {
          'type': 'USAGE_PERIOD_TYPE_WEEKLY',
          'start': '2026-09-05T00:00:00Z',
          'end': _reset,
        },
        'prepaidBalance': {'val': 9000},
        'onDemandCap': {'val': 5000},
        'onDemandUsed': {'val': 10},
        'productUsage': [
          {'creditUsagePercent': 4}
        ],
      },
    };

Map<String, dynamic> _host(
        {String token = 'host-token', String user = 'user-a'}) =>
    {
      'key': token,
      'email': 'same@example.invalid',
      'user_id': user,
      'auth_mode': 'oidc',
      'oidc_issuer': XaiAuth.issuer,
      'oidc_client_id': XaiAuth.publicClientId,
    };

String _pool(String principal, {bool team = false}) => opaqueCredentialIdentity(
    'grok', 'grok-principal-v1:${team ? 'Team' : 'User'}:$principal');
http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {
    closed = true;
  }
}

void main() {
  late Directory temp;
  late File authFile;
  late int clock;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_grok_');
    setQuotabotDirOverrideForTesting(temp);
    setTokenPermissionHardeningForTesting(
        directoryHardener: (_) {}, fileHardener: (_) {});
    authFile = File('${temp.path}/host-auth.json');
    clock = nowEpoch();
  });
  tearDown(() async {
    await ProviderReadGate.drainActive();
    setTokenPermissionHardeningForTesting();
    setQuotabotDirOverrideForTesting(null);
    temp.deleteSync(recursive: true);
  });

  void writeHost([Map<String, dynamic>? record]) => authFile
      .writeAsStringSync(jsonEncode({XaiAuth.hostScope: record ?? _host()}));
  void own(String owner,
      {String token = 'owned-token', bool defaultOnly = false}) {
    final tokens = Tokens(
        accessToken: token,
        refreshToken: 'refresh-$token',
        expiresAt: nowEpoch() + 3600);
    if (defaultOnly) {
      TokenStore.saveDefaultOwnedBy('grok', tokens, owner);
    } else {
      TokenStore.save('grok', tokens, account: owner);
    }
  }

  ProviderReadGate gate() => ProviderReadGate(
      directory: Directory('${temp.path}/read-gates'),
      clock: () => clock,
      jitter: (_) => 0,
      hardenDirectory: (_) {},
      hardenFile: (_) {});
  GrokAdapter adapter(http.Client client,
          {GrokTokenResolver? resolver,
          Duration timeout = const Duration(seconds: 5)}) =>
      GrokAdapter(
          authFile: authFile,
          client: client,
          readGate: gate(),
          tokenResolver: resolver,
          requestTimeout: timeout,
          grantResolutionDeadline: const Duration(milliseconds: 30));

  test('disconnect blocks host and independently owned grants before all reads',
      () async {
    writeHost();
    own('owner');
    var reads = 0;
    final subject = GrokAdapter(
        authFile: authFile,
        disconnectReader: () => true,
        client: MockClient((_) async {
          reads++;
          return _json(_billing());
        }));
    expect(subject.accountIndex, isEmpty);
    expect(
        (await subject.collect()).error, providerDisconnectedMessage('grok'));
    expect(reads, 0);
  });

  test(
      'modern billing GET uses exact identity headers and leaves host immutable',
      () async {
    writeHost();
    final before = authFile.readAsBytesSync();
    final client = _StreamClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(),
          'https://cli-chat-proxy.grok.com/v1/billing?format=credits');
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer host-token');
      expect(request.headers['X-XAI-Token-Auth'], 'xai-grok-cli');
      expect(request.headers['x-userid'], 'user-a');
      expect(await request.finalize().toBytes(), isEmpty);
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(_billing()))), 200);
    });
    final q = await adapter(client).collect();
    expect(q.account, _pool('user-a'));
    expect(q.windows.single.usedPercent, 73);
    expect(q.windows.single.percent, 73);
    expect(q.plan, isNull);
    expect(q.windows.single.resetsAt, 1789171200);
    expect(authFile.readAsBytesSync(), before);
    expect(client.closed, isFalse);
    final public = jsonEncode(q.toJson());
    for (final private in [
      'host-token',
      'user-a',
      'same@example.invalid',
      'prepaidBalance',
      'productUsage'
    ]) {
      expect(public, isNot(contains(private)));
    }
  });

  for (final mode in ['oidc', 'external']) {
    test('pinned first-party $mode record is eligible', () async {
      writeHost(_host()..['auth_mode'] = mode);
      expect(
          (await adapter(MockClient((_) async => _json(_billing(0)))).collect())
              .windows
              .single
              .percent,
          0);
    });
  }
  for (final change in <String, Object?>{
    'auth_mode': 'api_key',
    'oidc_issuer': 'https://customer.example',
    'oidc_client_id': 'other-client',
    'principal_type': 'Other',
    'principal_id': 'untyped',
    'team_id': 'untyped-team',
    'user_id': 'bad\r\nheader',
    'key': 'bad\r\ntoken',
    'expires_at': 'invalid',
  }.entries) {
    test('ineligible ${change.key} never forwards the host token', () async {
      writeHost(_host()..[change.key] = change.value);
      var reads = 0;
      final subject = adapter(MockClient((_) async {
        reads++;
        return _json(_billing());
      }));
      expect(subject.accountIndex, isEmpty);
      expect((await subject.collect()).windows, isEmpty);
      expect(reads, 0);
    });
  }
  test('arbitrary scopes and legacy web login do not reach either endpoint',
      () async {
    var reads = 0;
    final client = MockClient((_) async {
      reads++;
      return _json(_billing());
    });
    authFile.writeAsStringSync(jsonEncode({'other': _host()}));
    expect((await adapter(client).collect()).error, contains('first-party'));
    authFile.writeAsStringSync(jsonEncode({
      'https://accounts.x.ai/sign-in': _host()..['auth_mode'] = 'web_login'
    }));
    expect((await adapter(client).collect()).error, contains('sign in again'));
    expect(reads, 0);
  });
  test('missing malformed and oversized auth remain bounded account errors',
      () async {
    final client =
        MockClient((_) async => throw StateError('unexpected metadata'));
    expect(
        (await adapter(client).collect()).error, contains('no Grok account'));
    for (final body in ['[]', '{invalid', ' ' * (256 * 1024 + 1)]) {
      authFile.writeAsStringSync(body);
      expect((await adapter(client).collect()).error, isNotNull);
    }
  });

  for (final fails in ['throw', 'delay']) {
    test(
        'optional grant $fails cannot suppress or postpone starting host billing',
        () async {
      writeHost();
      own('optional-owner');
      final started = Completer<void>();
      final unresolved = Completer<String?>();
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/billing');
        started.complete();
        return _json(_billing(20));
      });
      final subject = adapter(client, resolver: (_, __) async {
        await started.future;
        if (fails == 'throw') throw StateError('private grant error');
        return unresolved.future;
      });
      final result = subject.collectAccounts();
      await started.future;
      final rows = await result;
      expect(
          rows
              .firstWhere((q) => q.account == _pool('user-a'))
              .windows
              .single
              .percent,
          20);
      expect(rows.where((q) => q.error != null), hasLength(1));
      expect(jsonEncode(rows.map((q) => q.toJson()).toList()),
          isNot(contains('private grant error')));
      unresolved.complete(null);
    });
  }

  for (final defaultOnly in [false, true]) {
    test(
        'owned ${defaultOnly ? 'default' : 'scoped'} account works without a host file',
        () async {
      own('login-label', defaultOnly: defaultOnly);
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        expect(request.headers['authorization'], 'Bearer owned-token');
        if (request.url.path == '/v1/user') {
          expect(request.url.queryParameters, {'include': 'subscription'});
          expect(request.headers.containsKey('x-userid'), isFalse);
          return _json({
            'userId': 'owned-user',
            'email': 'irrelevant@example.invalid',
            'subscriptionTier': 'SuperGrok'
          });
        }
        expect(request.headers['x-userid'], 'owned-user');
        return _json(_billing(40));
      });
      final q = await adapter(client).collect();
      expect(requests, ['/v1/user', '/v1/billing']);
      expect(q.account, _pool('owned-user'));
      expect(q.plan, 'SuperGrok');
      expect(q.planEvidenceSource, ProviderPlanEvidenceSource.providerMetadata);
      expect(q.windows.single.percent, 40);
      expect(authFile.existsSync(), isFalse);
      expect(adapter(client).accountIndex, {_pool('owned-user')});
    });
  }
  test('optional grant discovery failure preserves a usable host account',
      () async {
    writeHost();
    Directory('${temp.path}/quotabot').createSync();
    File('${temp.path}/quotabot/auth')
        .writeAsStringSync('unusable optional grant directory');
    final q = await GrokAdapter(
        authFile: authFile,
        disconnectReader: () => false,
        readGate: gate(),
        client: MockClient((_) async => _json(_billing()))).collect();
    expect(q.account, _pool('user-a'));
    expect(q.windows.single.percent, 73);
  });
  test('an ownerless default cannot be lent to a host account', () async {
    writeHost();
    TokenStore.save(
        'grok', Tokens(accessToken: 'unowned', expiresAt: nowEpoch() + 3600));
    final tokens = <String>[];
    final rows = await adapter(MockClient((request) async {
      tokens.add(request.headers['authorization']!);
      return _json(_billing());
    })).collectAccounts();
    expect(rows, hasLength(1));
    expect(tokens, ['Bearer host-token']);
  });
  test('scoped record with a forged owner is not discovered', () async {
    own('scoped-owner');
    final record = quotabotDir('auth')
        .listSync()
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.json'));
    final body = jsonDecode(record.readAsStringSync()) as Map<String, dynamic>;
    body['_account'] = 'someone-else';
    record.writeAsStringSync(jsonEncode(body));
    final subject =
        adapter(MockClient((_) async => throw StateError('no request')));
    expect(subject.accountIndex, isEmpty);
    expect((await subject.collect()).windows, isEmpty);
  });

  test('same email never merges independently proved personal and team pools',
      () async {
    writeHost();
    own('same@example.invalid');
    final reads = <String>[];
    final rows = await adapter(MockClient((request) async {
      if (request.url.path == '/v1/user') {
        return _json({
          'userId': 'user-a',
          'email': 'same@example.invalid',
          'principalType': 'Team',
          'principalId': 'team-a',
          'teamId': 'team-a'
        });
      }
      reads.add(request.headers['authorization']!);
      return _json(_billing(
          request.headers['authorization'] == 'Bearer host-token' ? 20 : 80));
    })).collectAccounts();
    expect(rows.map((q) => q.account),
        unorderedEquals([_pool('user-a'), _pool('team-a', team: true)]));
    expect(
        rows.map((q) => q.windows.single.percent), unorderedEquals([80, 20]));
    expect(reads, hasLength(2));
  });
  test('team login placeholder is enriched without mutating the host record',
      () async {
    writeHost(_host(user: 'team-a')
      ..addAll({
        'principal_type': 'Team',
        'principal_id': 'team-a',
        'team_id': 'team-a'
      }));
    final before = authFile.readAsBytesSync();
    final paths = <String>[];
    final q = await adapter(MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/v1/user') {
        return _json({
          'userId': 'real-user',
          'principalType': 'Team',
          'principalId': 'team-a',
          'teamId': 'team-a'
        });
      }
      expect(request.headers['x-userid'], 'real-user');
      return _json(_billing());
    })).collect();
    expect(paths, ['/v1/user', '/v1/billing']);
    expect(q.account, _pool('team-a', team: true));
    expect(authFile.readAsBytesSync(), before);
  });
  test('host placeholder cannot adopt a different proved pool', () async {
    writeHost(_host(user: 'team-a')
      ..addAll({
        'principal_type': 'Team',
        'principal_id': 'team-a',
        'team_id': 'team-a'
      }));
    final subject = adapter(MockClient((request) async {
      expect(request.url.path, '/v1/user');
      return _json({
        'userId': 'real-user',
        'principalType': 'Team',
        'principalId': 'team-b',
        'teamId': 'team-b'
      });
    }));
    final rows = await subject.collectAccounts();
    expect(rows, hasLength(1));
    expect(rows.single.account, _pool('team-a', team: true));
    expect(rows.single.error, contains('identity changed'));
    expect(rows.single.windows, isEmpty);
    expect(subject.accountIndex, {_pool('team-a', team: true)});
  });

  test('two grants for one proved pool share one concurrent billing read',
      () async {
    writeHost();
    own('same-owner');
    final hostStarted = Completer<void>();
    final profileDone = Completer<void>();
    var billingReads = 0;
    final rows = await adapter(MockClient((request) async {
      if (request.url.path == '/v1/user') {
        await hostStarted.future;
        profileDone.complete();
        return _json({'userId': 'user-a'});
      }
      billingReads++;
      hostStarted.complete();
      await profileDone.future;
      return _json(_billing());
    })).collectAccounts();
    expect(rows, hasLength(1));
    expect(billingReads, 1);
  });
  for (final status in [401, 403, 429, 503]) {
    test(
        'same-pool alternate credential after HTTP $status obeys authentication-only fallback',
        () async {
      writeHost();
      own('same-owner');
      final billingTokens = <String>[];
      final rows = await adapter(MockClient((request) async {
        if (request.url.path == '/v1/user') return _json({'userId': 'user-a'});
        final token = request.headers['authorization']!;
        billingTokens.add(token);
        if (token == 'Bearer host-token') {
          return http.Response('private error', status,
              headers: {'retry-after': '120'});
        }
        return _json(_billing());
      })).collectAccounts();
      expect(rows, hasLength(1));
      expect(
          billingTokens,
          status == 401
              ? ['Bearer host-token', 'Bearer owned-token']
              : ['Bearer host-token']);
      expect(rows.single.error == null, status == 401);
      if (status != 401) expect(rows.single.httpStatus, status);
    });
  }
  test(
      'recorded expiry skips an expired host credential and allows the owned account',
      () async {
    writeHost(_host()..['expires_at'] = '2020-01-01T00:00:00Z');
    own('same-owner');
    final tokens = <String>[];
    final rows = await adapter(MockClient((request) async {
      tokens.add(request.headers['authorization']!);
      return _json(
          request.url.path == '/v1/user' ? {'userId': 'user-a'} : _billing());
    })).collectAccounts();
    expect(rows.single.error, isNull);
    expect(tokens, everyElement('Bearer owned-token'));
  });

  test(
      'retry deadline survives a new adapter and does not block another principal',
      () async {
    writeHost();
    var hostReads = 0;
    var otherReads = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/user') {
        return _json({'userId': 'other-user'});
      }
      if (request.headers['authorization'] == 'Bearer host-token') {
        hostReads++;
        return hostReads == 1
            ? http.Response('', 429, headers: {'retry-after': '120'})
            : _json(_billing());
      }
      otherReads++;
      return _json(_billing(10));
    });
    expect((await adapter(client).collect()).httpStatus, 429);
    own('different-owner');
    clock += 10;
    final rows = await adapter(client).collectAccounts();
    expect(hostReads, 1);
    expect(otherReads, 1);
    expect(rows.first.retryAfterSeconds, 110);
    expect(rows.last.windows.single.percent, 10);
    clock += 111;
    expect((await adapter(client).collectAccounts()).first.error, isNull);
    expect(hostReads, 2);
  });
  test(
      'profile cooldown cannot produce billing evidence or borrow a cached pool',
      () async {
    own('owner');
    var profileReads = 0;
    var billingReads = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/user') {
        profileReads++;
        return profileReads == 1
            ? _json({'userId': 'owned-user'})
            : http.Response('', 503, headers: {'retry-after': '120'});
      }
      billingReads++;
      return _json(_billing());
    });
    expect((await adapter(client).collect()).account, _pool('owned-user'));
    final failed = await adapter(client).collect();
    expect(failed.account, _pool('owned-user'));
    expect(failed.windows, isEmpty);
    expect(failed.plan, isNull);
    final retry = await adapter(client).collect();
    expect(retry.windows, isEmpty);
    expect(profileReads, 2);
    expect(billingReads, 1);
    own('owner', token: 'replacement');
    expect(adapter(client).accountIndex, isNot(contains(_pool('owned-user'))));
    TokenStore.clearAccounts('grok');
    expect(adapter(client).accountIndex, isEmpty);
  });
  for (final profile in <Map<String, dynamic>>[
    {'email': 'owner'},
    {'userId': 'user-a', 'principalType': 'Team'},
    {
      'userId': 'user-a',
      'principalType': 'Team',
      'principalId': 'a',
      'teamId': 'b'
    },
    {'userId': 'user-a', 'teamId': 'a'},
    {'userId': 'user-a', 'principalType': 'unknown'},
  ]) {
    test(
        'incomplete or contradictory principal never authorizes owned billing $profile',
        () async {
      own('owner');
      final q = await adapter(MockClient((request) async {
        expect(request.url.path, '/v1/user');
        return _json(profile);
      })).collect();
      expect(q.windows, isEmpty);
      expect(q.plan, isNull);
      expect(q.account, isNot(_pool('user-a')));
    });
  }

  test(
      'redirect and malformed modern response have no legacy transport fallback',
      () async {
    writeHost();
    for (final status in [302, 200]) {
      var calls = 0;
      final q = await adapter(MockClient((request) async {
        calls++;
        expect(request.method, 'GET');
        expect(request.url.host, 'cli-chat-proxy.grok.com');
        return http.Response('secret-body', status,
            headers: {'location': 'https://other.invalid'});
      })).collect();
      expect(calls, 1);
      expect(q.windows, isEmpty);
      expect(q.error, isNot(contains('secret-body')));
      clock += 1200;
    }
  });
  for (final declared in [false, true]) {
    test(
        'response cap stops ${declared ? 'declared' : 'streamed'} oversized body before accumulation',
        () async {
      writeHost();
      var cancelled = false;
      final stream = StreamController<List<int>>(onCancel: () {
        cancelled = true;
      });
      final client = _StreamClient((_) async {
        if (!declared) stream.add(List.filled(128 * 1024 + 1, 65));
        return http.StreamedResponse(stream.stream, 200,
            contentLength: declared ? 128 * 1024 + 1 : null);
      });
      final q = await adapter(client).collect();
      expect(q.windows, isEmpty);
      expect(cancelled, isTrue);
      await stream.close();
    });
  }
  test('timeout keeps the raw gate occupied until actual cancellation settles',
      () async {
    writeHost();
    final aborted = Completer<void>();
    final settle = Completer<void>();
    var calls = 0;
    final client = _StreamClient((request) async {
      calls++;
      await (request as http.AbortableRequest).abortTrigger;
      aborted.complete();
      await settle.future;
      throw http.RequestAbortedException(request.url);
    });
    final first =
        adapter(client, timeout: const Duration(milliseconds: 10)).collect();
    await aborted.future;
    final busy = await adapter(client).collect();
    expect(busy.error, contains('already in progress'));
    expect(calls, 1);
    settle.complete();
    final failed = await first;
    expect(failed.error, contains('timed out'));
    expect(failed.pipeHealth, providerPipeHealthThrottled);
    final cooldown = await adapter(client).collect();
    expect(cooldown.error, contains('retry deadline'));
    expect(calls, 1);
  });

  test(
      'a late non-200 result is a timeout and cannot trigger credential fallback',
      () async {
    writeHost();
    final client = _StreamClient((request) async {
      await (request as http.AbortableRequest).abortTrigger;
      return http.StreamedResponse(const Stream.empty(), 401);
    });
    final q = await adapter(client, timeout: const Duration(milliseconds: 10))
        .collect();
    expect(q.httpStatus, isNull);
    expect(q.error, contains('timed out'));
    expect(q.pipeHealth, providerPipeHealthThrottled);
  });

  group('included billing parser', () {
    for (final percent in [0, 42.5, 100]) {
      test('preserves exact included usage $percent', () {
        final q = grokBillingWindowFromJson(_billing(percent))!;
        expect(q.usedPercent, percent);
        expect(q.label, 'weekly');
        expect(q.resetsAt, 1789171200);
      });
    }
    test('monthly modern period retains its declared reset', () {
      final body = _billing();
      (body['config']['currentPeriod'] as Map)['type'] =
          'USAGE_PERIOD_TYPE_MONTHLY';
      expect(grokBillingWindowFromJson(body)!.label, 'monthly');
    });
    Map<String, dynamic> oldConfig() => {
          'monthlyLimit': {'val': 100},
          'used': {'val': 25},
          'billingPeriodEnd': _reset
        };
    for (final bad in [null, '25', -1, 101, double.nan, double.infinity]) {
      test('present-invalid modern percentage $bad cannot borrow old quota',
          () {
        final config = oldConfig()..['creditUsagePercent'] = bad;
        expect(grokBillingWindowFromJson({'config': config}), isNull);
      });
    }
    test('a modern period without its percent cannot borrow old quota', () {
      expect(
          grokBillingWindowFromJson(
              {'config': oldConfig()..['currentPeriod'] = <String, dynamic>{}}),
          isNull);
    });
    for (final end in [
      '2026-02-30T00:00:00Z',
      '2026-09-12T25:00:00Z',
      '2026-09-12T00:00:00',
      '2026-09-12T00:00:00+00:99',
      'yesterday'
    ]) {
      test('rejects invalid or ambiguous reset $end', () {
        final body = _billing();
        (body['config']['currentPeriod'] as Map)['end'] = end;
        expect(grokBillingWindowFromJson(body), isNull);
      });
    }
    test('unknown period and reversed interval do not create headroom', () {
      final body = _billing();
      final period = body['config']['currentPeriod'] as Map;
      period['type'] = 'UNKNOWN';
      expect(grokBillingWindowFromJson(body), isNull);
      period['type'] = 'USAGE_PERIOD_TYPE_WEEKLY';
      period['start'] = _reset;
      expect(grokBillingWindowFromJson(body), isNull);
    });
    test('deprecated included cents require an explicit used field', () {
      final config = oldConfig();
      expect(grokBillingWindowFromJson({'config': config})!.usedPercent, 25);
      config['used'] = <String, dynamic>{};
      expect(grokBillingWindowFromJson({'config': config})!.usedPercent, 0);
      config.remove('used');
      expect(grokBillingWindowFromJson({'config': config}), isNull);
    });
    test('invalid deprecated included counts cannot be clamped into quota', () {
      for (final used in [-1, 101, 9007199254740992, '25']) {
        expect(
            grokBillingWindowFromJson({
              'config': oldConfig()..['used'] = {'val': used},
            }),
            isNull);
      }
      expect(
          grokBillingWindowFromJson({
            'config': oldConfig()..['monthlyLimit'] = <String, dynamic>{},
          }),
          isNull);
    });
    test(
        'prepaid on-demand and product usage never substitute for included quota',
        () {
      final config = _billing()['config'] as Map;
      config.remove('creditUsagePercent');
      config.remove('currentPeriod');
      expect(grokBillingWindowFromJson({'config': config}), isNull);
      expect(grokBillingWindowFromJson({'config': null}), isNull);
      expect(grokBillingWindowFromJson({}), isNull);
    });
  });
}
