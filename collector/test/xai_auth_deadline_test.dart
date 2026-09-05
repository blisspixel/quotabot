import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

class _AbortClient extends http.BaseClient {
  _AbortClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_xai_deadline_');
    setQuotabotDirOverrideForTesting(temp);
    setTokenPermissionHardeningForTesting(
        directoryHardener: (_) {}, fileHardener: (_) {});
    TokenStore.saveDefaultOwnedBy(
        'grok',
        const Tokens(accessToken: 'old', refreshToken: 'refresh', expiresAt: 1),
        'owner');
  });
  tearDown(() {
    setTokenPermissionHardeningForTesting();
    setQuotabotDirOverrideForTesting(null);
    temp.deleteSync(recursive: true);
  });

  test('bounded guard contention cannot start a late refresh after release',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final holder = TokenStore.refreshTransaction<void>('grok', (_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    var requests = 0;
    final auth = XaiAuth(
        refreshAcquisitionTimeout: const Duration(milliseconds: 100),
        client: MockClient((_) async {
          requests++;
          return http.Response(
              jsonEncode({'access_token': 'new', 'expires_in': 3600}), 200);
        }));
    try {
      await expectLater(auth.freshAccessToken(requiredDefaultOwner: 'owner'),
          throwsA(isA<FileSystemException>()));
      expect(requests, 0);
    } finally {
      release.complete();
      await holder;
    }
    // Let a wrongly retained acquisition complete if it was left live by an
    // outer .timeout; this must still never start a token POST or token write.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(requests, 0);
    expect(TokenStore.load('grok')!.accessToken, 'old');
  });

  test('fresh immutable tokens do not wait for a held refresh guard', () async {
    TokenStore.saveDefaultOwnedBy(
        'grok',
        Tokens(
            accessToken: 'fresh',
            refreshToken: 'refresh',
            expiresAt: nowEpoch() + 3600),
        'owner');
    final entered = Completer<void>();
    final release = Completer<void>();
    final holder = TokenStore.refreshTransaction<void>('grok', (_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    try {
      final auth = XaiAuth(
          refreshAcquisitionTimeout: const Duration(milliseconds: 20),
          client:
              MockClient((_) async => throw StateError('no token request')));
      expect(
          await auth.freshAccessToken(requiredDefaultOwner: 'owner'), 'fresh');
    } finally {
      release.complete();
      await holder;
    }
  });

  test('aborted token POST settles before its refresh guard is released',
      () async {
    final aborted = Completer<void>();
    final settle = Completer<void>();
    var requests = 0;
    final client = _AbortClient((request) async {
      requests++;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://auth.x.ai/oauth2/token');
      expect(request.followRedirects, isFalse);
      await (request as http.AbortableRequest).abortTrigger;
      aborted.complete();
      await settle.future;
      throw http.RequestAbortedException(request.url);
    });
    final auth = XaiAuth(
        client: client,
        requestTimeout: const Duration(milliseconds: 10),
        refreshAcquisitionTimeout: const Duration(milliseconds: 20));
    final first = auth.freshAccessToken(requiredDefaultOwner: 'owner');
    await aborted.future;
    await expectLater(auth.freshAccessToken(requiredDefaultOwner: 'owner'),
        throwsA(isA<FileSystemException>()));
    expect(requests, 1);
    settle.complete();
    expect(await first, isNull);
    expect(TokenStore.load('grok')!.accessToken, 'old');
    expect(
        await TokenStore.refreshTransaction('grok', (_) async => true,
            acquisitionTimeout: const Duration(milliseconds: 20)),
        isTrue);
  });

  for (final declared in [true, false]) {
    test(
        'token response cap rejects ${declared ? 'declared' : 'streamed'} oversized body',
        () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(onCancel: () {
        cancelled = true;
      });
      final client = _AbortClient((_) async {
        if (!declared) stream.add(List.filled(128 * 1024 + 1, 65));
        return http.StreamedResponse(stream.stream, 200,
            contentLength: declared ? 128 * 1024 + 1 : null);
      });
      expect(
          await XaiAuth(client: client)
              .freshAccessToken(requiredDefaultOwner: 'owner'),
          isNull);
      expect(cancelled, isTrue);
      expect(TokenStore.load('grok')!.accessToken, 'old');
      await stream.close();
    });
  }

  test('token redirect is rejected without replacing the owned grant',
      () async {
    var requests = 0;
    final client = _AbortClient((request) async {
      requests++;
      expect(request.followRedirects, isFalse);
      return http.StreamedResponse(const Stream.empty(), 302,
          headers: {'location': 'https://other.invalid/token'});
    });
    expect(
        await XaiAuth(client: client)
            .freshAccessToken(requiredDefaultOwner: 'owner'),
        isNull);
    expect(requests, 1);
    expect(TokenStore.load('grok')!.accessToken, 'old');
  });
}
