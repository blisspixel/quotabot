import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/anthropic_auth.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/oauth_http.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
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
    temp = Directory.systemTemp.createTempSync('quotabot_oauth_deadline_');
    setQuotabotDirOverrideForTesting(temp);
    setTokenPermissionHardeningForTesting(
      directoryHardener: (_) {},
      fileHardener: (_) {},
    );
  });

  tearDown(() {
    setTokenPermissionHardeningForTesting();
    setQuotabotDirOverrideForTesting(null);
    temp.deleteSync(recursive: true);
  });

  test('token helper requires a positive timeout and one body form', () {
    final uri = Uri.parse('https://example.invalid/token');
    expect(
      () => postOAuthTokenRequest(
        uri: uri,
        headers: const {'Content-Type': 'application/json'},
        body: '{}',
        timeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => postOAuthTokenRequest(
        uri: uri,
        headers: const {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 1),
      ),
      throwsArgumentError,
    );
    expect(
      () => postOAuthTokenRequest(
        uri: uri,
        headers: const {'Content-Type': 'application/json'},
        body: '{}',
        bodyFields: const {'a': 'b'},
        timeout: const Duration(seconds: 1),
      ),
      throwsArgumentError,
    );
  });

  test('Claude aborted token POST settles before its refresh guard is released',
      () async {
    const provider = AnthropicAuth.provider;
    TokenStore.save(
      provider,
      const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
    );
    final aborted = Completer<void>();
    final settle = Completer<void>();
    var requests = 0;
    final client = _AbortClient((request) async {
      requests++;
      expect(request.method, 'POST');
      expect(request.url.toString(), contains('/v1/oauth/token'));
      expect(request.followRedirects, isFalse);
      await (request as http.AbortableRequest).abortTrigger;
      aborted.complete();
      await settle.future;
      throw http.RequestAbortedException(request.url);
    });
    final auth = AnthropicAuth(
      client: client,
      requestTimeout: const Duration(milliseconds: 10),
    );
    final first = auth.freshAccessToken();
    await aborted.future;
    await expectLater(
      TokenStore.refreshTransaction(
        provider,
        (_) async => true,
        acquisitionTimeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(requests, 1);
    settle.complete();
    expect(await first, isNull);
    expect(TokenStore.load(provider)!.accessToken, 'old');
    expect(
      await TokenStore.refreshTransaction(
        provider,
        (_) async => true,
        acquisitionTimeout: const Duration(milliseconds: 20),
      ),
      isTrue,
    );
  });

  test(
      'Claude persists a late 200 token rotation after the publication deadline',
      () async {
    const provider = AnthropicAuth.provider;
    TokenStore.save(
      provider,
      const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
    );
    final started = Completer<void>();
    final release = Completer<void>();
    var requests = 0;
    final auth = AnthropicAuth(
      client: MockClient((_) async {
        requests++;
        started.complete();
        await release.future;
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'R1',
            'expires_in': 3600,
          }),
          200,
        );
      }),
      requestTimeout: const Duration(milliseconds: 10),
    );
    final refresh = auth.freshAccessToken();
    await started.future;
    var drained = false;
    final drain =
        TokenStore.drainActiveRefreshTransactions().then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained, isFalse);
    expect(TokenStore.load(provider)!.accessToken, 'old');
    release.complete();
    expect(await refresh, 'new');
    await drain;
    expect(drained, isTrue);
    expect(requests, 1);
    expect(TokenStore.load(provider)!.refreshToken, 'R1');
  });

  test(
      'Codex persists a late 200 token rotation after the publication deadline',
      () async {
    const provider = OpenAiAuth.provider;
    TokenStore.save(
      provider,
      const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
    );
    final started = Completer<void>();
    final release = Completer<void>();
    final auth = OpenAiAuth(
      client: MockClient((_) async {
        started.complete();
        await release.future;
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'R1',
            'expires_in': 3600,
          }),
          200,
        );
      }),
      requestTimeout: const Duration(milliseconds: 10),
    );
    final refresh = auth.freshAccessToken();
    await started.future;
    var drained = false;
    final drain =
        TokenStore.drainActiveRefreshTransactions().then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained, isFalse);
    release.complete();
    expect(await refresh, 'new');
    await drain;
    expect(drained, isTrue);
    expect(TokenStore.load(provider)!.refreshToken, 'R1');
  });

  test(
      'Antigravity persists a late 200 token rotation after the publication deadline',
      () async {
    const provider = GoogleAuth.provider;
    TokenStore.save(
      provider,
      const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
    );
    final started = Completer<void>();
    final release = Completer<void>();
    final auth = GoogleAuth(
      client: MockClient((_) async {
        started.complete();
        await release.future;
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'R1',
            'expires_in': 3600,
          }),
          200,
        );
      }),
      requestTimeout: const Duration(milliseconds: 10),
    );
    final refresh = auth.freshAccessToken();
    await started.future;
    var drained = false;
    final drain =
        TokenStore.drainActiveRefreshTransactions().then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained, isFalse);
    release.complete();
    expect(await refresh, 'new');
    await drain;
    expect(drained, isTrue);
    expect(TokenStore.load(provider)!.refreshToken, 'R1');
  });
}
