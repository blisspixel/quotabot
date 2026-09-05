import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:quotabot_collector/adapters/codex.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_read_gate.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late File auth;
  late int now;
  late ProviderReadGate gate;
  final hostIdentity =
      opaqueCredentialIdentity('codex', 'account-id:synthetic-account');

  void writeHost(
      {String access = 'host-access', String refresh = 'host-refresh'}) {
    auth.writeAsStringSync(jsonEncode({
      'tokens': {
        'access_token': access,
        'refresh_token': refresh,
        'account_id': 'synthetic-account'
      },
    }));
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_codex_gate_');
    setQuotabotDirOverrideForTesting(temp);
    now = nowEpoch();
    auth = File('${temp.path}/synthetic-auth.json');
    writeHost();
    gate = ProviderReadGate(
      directory: Directory('${temp.path}/gates'),
      clock: () => now,
      jitter: (_) => 0,
      hardenDirectory: (_) {},
      hardenFile: (_) {},
    );
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    temp.deleteSync(recursive: true);
  });

  CodexAdapter adapter(http.Client client, {OpenAiCredential? grant}) =>
      CodexAdapter(
        authFile: auth,
        client: client,
        readGate: gate,
        grantCredential: () async => grant,
      );

  for (final status in [429, 403, 503]) {
    test(
        'HTTP $status cannot be bypassed by an exact-account grant or repeated read',
        () async {
      var requests = 0;
      final client = _MetadataClient((request) async {
        requests++;
        expect(request.headers['Authorization'], 'Bearer host-access');
        return http.Response('synthetic-private-provider-body', status,
            headers: status == 403 ? {} : {'retry-after': '7200'});
      });
      final read = adapter(client,
          grant: OpenAiCredential(
            accessToken: 'same-account-grant',
            identity: hostIdentity,
          ));
      final first = await read.collectAccounts();
      expect(first.single.httpStatus, status);
      now += 10;
      final second = await read.collectAccounts();
      expect(second, hasLength(1));
      expect(second.single.ok, isFalse);
      expect(second.single.windows, isEmpty);
      expect(second.single.account, hostIdentity);
      expect(second.single.httpStatus, status);
      expect(second.single.retryAfterSeconds, status == 403 ? 50 : 7190);
      expect(jsonEncode(second.single.toJson()),
          isNot(contains('synthetic-private-provider-body')));
      expect(requests, 1);
      // The single-result compatibility method must use the same gate too.
      expect((await read.collect()).httpStatus, status);
      expect(requests, 1);
    });
  }

  test('access and refresh rotation retain the configured account deadline',
      () async {
    var requests = 0;
    final client = _MetadataClient((_) async {
      requests++;
      return requests == 1
          ? http.Response('{}', 429, headers: {'retry-after': '300'})
          : http.Response(_usage(now), 200);
    });
    expect((await adapter(client).collect()).httpStatus, 429);
    writeHost(access: 'rotated-access', refresh: 'rotated-refresh');
    final saved = auth.readAsStringSync();
    now += 20;
    final deferred = await adapter(client).collect();
    expect(deferred.httpStatus, 429);
    expect(deferred.retryAfterSeconds, 280);
    expect(requests, 1);
    now += 280;
    final recovered = await adapter(client).collect();
    expect(recovered.ok, isTrue);
    expect(recovered.requestAdmission, RequestAdmission.allowed);
    expect(recovered.account, hostIdentity);
    expect(requests, 2);
    expect(auth.readAsStringSync(), saved);
  });

  test('an authorized 401 fallback remains independent of quota cooldown',
      () async {
    final requests = <String>[];
    final client = _MetadataClient((request) async {
      final bearer = request.headers['Authorization']!;
      requests.add(bearer);
      if (bearer == 'Bearer host-access') return http.Response('{}', 401);
      expect(request.headers.containsKey('chatgpt-account-id'), isFalse);
      return http.Response(_usage(now), 200);
    });
    final saved = auth.readAsStringSync();
    final result = await adapter(client,
        grant: OpenAiCredential(
          accessToken: 'authorized-grant',
          identity: hostIdentity,
        )).collectAccounts();
    expect(result.single.ok, isTrue);
    expect(result.single.account, hostIdentity);
    expect(requests, ['Bearer host-access', 'Bearer authorized-grant']);
    expect(auth.readAsStringSync(), saved);
  });

  test(
      'another account still refreshes and fresh admission denial remains a veto',
      () async {
    final otherIdentity =
        opaqueCredentialIdentity('codex', 'account-id:other-account');
    var hostReads = 0;
    var otherReads = 0;
    final client = _MetadataClient((request) async {
      if (request.headers['Authorization'] == 'Bearer host-access') {
        hostReads++;
        return http.Response('{}', 429, headers: {'retry-after': '7200'});
      }
      otherReads++;
      expect(request.headers.containsKey('chatgpt-account-id'), isFalse);
      return http.Response(_usage(now, allowed: false), 200);
    });
    final read = adapter(client,
        grant: OpenAiCredential(
          accessToken: 'other-grant',
          identity: otherIdentity,
        ));
    for (var iteration = 0; iteration < 2; iteration++) {
      final result = await read.collectAccounts();
      expect(result, hasLength(2));
      expect(result.first.httpStatus, 429);
      final other = result.last;
      expect(other.account, otherIdentity);
      expect(other.ok, isTrue);
      expect(other.windows.single.usedPercent, 25);
      expect(other.requestAdmission, RequestAdmission.denied);
      expect(providerAvailability(other, now).available, isFalse);
      now += 10;
    }
    expect(hostReads, 1);
    expect(otherReads, 2);
  });

  test('damaged gate storage returns failed metadata without fresh windows',
      () async {
    var requests = 0;
    final client = _MetadataClient((_) async {
      requests++;
      return http.Response('{}', 503, headers: {'retry-after': '120'});
    });
    final read = adapter(client);
    await read.collect();
    final state = Directory('${temp.path}/gates')
        .listSync()
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.json'));
    state.writeAsStringSync('{broken');
    final failed = await read.collect();
    expect(failed.ok, isFalse);
    expect(failed.account, hostIdentity);
    expect(failed.windows, isEmpty);
    expect(failed.error, 'Codex usage read coordination unavailable');
    expect(requests, 1);
  });
}

String _usage(int now, {bool allowed = true}) => jsonEncode({
      'plan_type': 'pro',
      'rate_limit': {
        'allowed': allowed,
        'limit_reached': !allowed,
        'primary_window': {
          'used_percent': 25,
          'limit_window_seconds': 604800,
          'reset_at': now + 86400,
        },
        'secondary_window': null,
      },
    });

class _MetadataClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest) respond;
  _MetadataClient(this.respond);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request, isA<http.AbortableRequest>());
    expect((request as http.AbortableRequest).abortTrigger, isNotNull);
    expect(request.method, 'GET');
    expect(
        request.url.toString(), 'https://chatgpt.com/backend-api/wham/usage');
    final response = await respond(request);
    return http.StreamedResponse(
        Stream.value(response.bodyBytes), response.statusCode,
        headers: response.headers, request: request);
  }
}
