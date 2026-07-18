import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/anthropic_auth.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/oauth_util.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempConfig;

  setUp(() {
    tempConfig = Directory.systemTemp.createTempSync('quotabot_auth_test_');
    setQuotabotDirOverrideForTesting(tempConfig);
    setTokenPermissionHardeningForTesting();
  });

  tearDown(() {
    setTokenPermissionHardeningForTesting();
    setQuotabotDirOverrideForTesting(null);
    if (tempConfig.existsSync()) tempConfig.deleteSync(recursive: true);
  });

  group('Tokens', () {
    test('isFresh respects the expiry margin', () {
      expect(
        Tokens(accessToken: 'a', expiresAt: nowEpoch() + 3600).isFresh,
        isTrue,
      );
      expect(
        Tokens(accessToken: 'a', expiresAt: nowEpoch() + 10).isFresh,
        isFalse,
      );
      expect(Tokens(accessToken: 'a').isFresh, isFalse);
    });

    test('fromOAuth carries the prior refresh token forward', () {
      final t = Tokens.fromOAuth({
        'access_token': 'AT',
        'expires_in': 3600,
      }, priorRefresh: 'R0');
      expect(t.accessToken, 'AT');
      expect(t.refreshToken, 'R0');
      expect(t.expiresAt, greaterThan(nowEpoch()));
    });

    test('fromOAuth prefers a rotated refresh token', () {
      final t = Tokens.fromOAuth({
        'access_token': 'AT',
        'refresh_token': 'R1',
        'expires_in': 3600,
      }, priorRefresh: 'R0');
      expect(t.refreshToken, 'R1');
    });

    test('fromOAuth treats an empty refresh token as absent', () {
      // A blank refresh_token must not overwrite a still-valid prior one.
      final t = Tokens.fromOAuth({
        'access_token': 'AT',
        'refresh_token': '',
        'expires_in': 3600,
      }, priorRefresh: 'R0');
      expect(t.refreshToken, 'R0');
    });

    test('round-trips through json', () {
      final t = Tokens(accessToken: 'a', refreshToken: 'r', expiresAt: 123);
      final back = Tokens.fromJson(t.toJson());
      expect(back.accessToken, 'a');
      expect(back.refreshToken, 'r');
      expect(back.expiresAt, 123);
    });
  });

  group('TokenStore', () {
    const provider = '__test_auth__';
    tearDown(() {
      TokenStore.clear(provider);
      TokenStore.clearAccounts(provider);
    });

    test('save, load, exists, clear', () {
      expect(TokenStore.exists(provider), isFalse);
      TokenStore.save(provider, Tokens(accessToken: 'a', refreshToken: 'r'));
      expect(TokenStore.exists(provider), isTrue);
      expect(TokenStore.load(provider)!.refreshToken, 'r');
      TokenStore.clear(provider);
      expect(TokenStore.load(provider), isNull);
    });

    test('save is atomic and leaves no temp file behind', () {
      TokenStore.save(provider, Tokens(accessToken: 'a', refreshToken: 'r'));
      final leftover = quotabotDir('auth')
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith(provider))
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftover, isEmpty);
      // The rename must have produced a readable grant.
      expect(TokenStore.load(provider)!.refreshToken, 'r');
    });

    test('save fails before writing when file hardening fails', () {
      setTokenPermissionHardeningForTesting(
        fileHardener: (_) => throw const FileSystemException(
          'simulated permission failure',
        ),
      );

      expect(
        () => TokenStore.save(
          provider,
          Tokens(accessToken: 'access', refreshToken: 'refresh'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(TokenStore.exists(provider), isFalse);
      expect(quotabotDir('auth').listSync().whereType<File>(), isEmpty);
    });

    test('saved token and directory are owner-only', () {
      final directory = quotabotDir('auth');
      if (Platform.isWindows) {
        final seeded = Process.runSync(
          'icacls',
          [directory.path, '/grant', '*S-1-1-0:(R)'],
        );
        expect(seeded.exitCode, 0);
      }

      TokenStore.save(provider, Tokens(accessToken: 'a', refreshToken: 'r'));
      final file = File('${directory.path}/$provider.json');
      if (Platform.isWindows) {
        final directoryAcl = Process.runSync('icacls', [directory.path]);
        final fileAcl = Process.runSync('icacls', [file.path]);
        expect(directoryAcl.exitCode, 0);
        expect(fileAcl.exitCode, 0);
        expect(directoryAcl.stdout.toString(), isNot(contains('(R)')));
        expect(fileAcl.stdout.toString(), isNot(contains('(R)')));
      } else {
        expect(directory.statSync().mode & 0x3f, 0);
        expect(file.statSync().mode & 0x3f, 0);
      }
    });

    test('rejects path-like provider ids', () {
      expect(
        () => TokenStore.save('../escape', Tokens(accessToken: 'a')),
        throwsArgumentError,
      );
      expect(() => TokenStore.exists('../escape'), throwsArgumentError);
      expect(() => TokenStore.clear('../escape'), throwsArgumentError);
      expect(() => TokenStore.load('../escape'), throwsArgumentError);
    });

    test('keeps account-scoped grants isolated from the default grant', () {
      TokenStore.save(provider, Tokens(accessToken: 'default'));
      TokenStore.save(
        provider,
        Tokens(accessToken: 'work', refreshToken: 'rw'),
        account: 'work@example.com',
      );
      TokenStore.save(
        provider,
        Tokens(accessToken: 'home', refreshToken: 'rh'),
        account: 'home@example.com',
      );

      expect(TokenStore.load(provider)!.accessToken, 'default');
      expect(
        TokenStore.load(provider, account: 'work@example.com')!.refreshToken,
        'rw',
      );
      expect(
        TokenStore.load(provider, account: 'home@example.com')!.refreshToken,
        'rh',
      );
      expect(TokenStore.accounts(provider), [
        'home@example.com',
        'work@example.com',
      ]);
    });

    test('does not put account names in auth filenames', () {
      const account = 'private.person@example.com';
      TokenStore.save(provider, Tokens(accessToken: 'a'), account: account);

      final names = quotabotDir('auth')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.startsWith(provider))
          .toList();

      expect(names, isNotEmpty);
      expect(names.any((name) => name.contains('private.person')), isFalse);
      expect(TokenStore.exists(provider, account: account), isTrue);
    });

    test('rejects empty or control-character account ids', () {
      expect(
        () => TokenStore.save(provider, Tokens(accessToken: 'a'), account: ' '),
        throwsArgumentError,
      );
      expect(
        () => TokenStore.exists(provider, account: 'bad\nid'),
        throwsArgumentError,
      );
    });
  });

  group('PKCE', () {
    test('challenge is the S256 hash of the verifier', () {
      final p = pkcePair();
      final expected = base64Url
          .encode(sha256.convert(ascii.encode(p.verifier)).bytes)
          .replaceAll('=', '');
      expect(p.challenge, expected);
      expect(p.verifier.length, greaterThanOrEqualTo(43));
    });

    test('randomState is unique and url-safe', () {
      final a = randomState(), b = randomState();
      expect(a, isNot(b));
      expect(a, matches(RegExp(r'^[A-Za-z0-9_\-]+$')));
    });
  });

  group('refresh', () {
    test(
      'XaiAuth.refresh maps the token response and keeps rotation',
      () async {
        final mock = MockClient((req) async {
          expect(req.url.toString(), contains('auth.x.ai/oauth2/token'));
          expect(req.body, contains('grant_type=refresh_token'));
          return http.Response(
            jsonEncode({'access_token': 'AT', 'expires_in': 21600}),
            200,
          );
        });
        final t = await XaiAuth(client: mock).refresh('R1');
        expect(t!.accessToken, 'AT');
        expect(t.refreshToken, 'R1'); // carried forward
        expect(t.isFresh, isTrue);
      },
    );

    test('GoogleAuth.refresh returns null on a non-200', () async {
      final mock = MockClient((req) async => http.Response('nope', 400));
      expect(await GoogleAuth(client: mock).refresh('R1'), isNull);
    });

    test('GoogleAuth.refresh maps a successful response', () async {
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({'access_token': 'GA', 'expires_in': 3600}),
          200,
        ),
      );
      final t = await GoogleAuth(client: mock).refresh('R1');
      expect(t!.accessToken, 'GA');
      expect(t.refreshToken, 'R1');
    });

    test('GoogleAuth.freshAccessToken returns a fresh account grant', () async {
      const provider = GoogleAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.save(
        provider,
        Tokens(
            accessToken: 'GA',
            refreshToken: 'GR',
            expiresAt: nowEpoch() + 3600),
        account: account,
      );
      final auth = GoogleAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      );

      expect(await auth.freshAccessToken(account: account), 'GA');
    });

    test('GoogleAuth.freshAccessToken refreshes only the account slot',
        () async {
      const provider = GoogleAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      // A different account already holds the provider-default slot.
      TokenStore.save(
        provider,
        Tokens(accessToken: 'home-token', refreshToken: 'HR', expiresAt: 1),
      );
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'GR', expiresAt: 1),
        account: account,
      );
      final auth = GoogleAuth(
        client: MockClient((req) async {
          expect(req.body, contains('refresh_token=GR'));
          return http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
            200,
          );
        }),
      );

      expect(await auth.freshAccessToken(account: account), 'fresh');
      expect(
        TokenStore.load(provider, account: account)!.accessToken,
        'fresh',
      );
      // The default slot must not be clobbered by the account refresh.
      expect(TokenStore.load(provider)!.accessToken, 'home-token');
    });

    test('GoogleAuth.freshAccessToken refreshes the default slot in place',
        () async {
      const provider = GoogleAuth.provider;
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'DR', expiresAt: 1),
      );
      final auth = GoogleAuth(
        client: MockClient((req) async {
          expect(req.body, contains('refresh_token=DR'));
          return http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
            200,
          );
        }),
      );

      expect(await auth.freshAccessToken(), 'fresh');
      expect(TokenStore.load(provider)!.accessToken, 'fresh');
      expect(TokenStore.accounts(provider), isEmpty);
    });

    test('XaiAuth.refresh returns null on a non-200', () async {
      final mock = MockClient((req) async => http.Response('no', 400));
      expect(await XaiAuth(client: mock).refresh('R'), isNull);
    });

    test('XaiAuth.freshAccessToken refreshes the selected account grant',
        () async {
      const provider = XaiAuth.provider;
      const account = 'work@example.com';
      TokenStore.save(
        provider,
        Tokens(accessToken: 'default-old', refreshToken: 'DR', expiresAt: 1),
      );
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'RW', expiresAt: 1),
        account: account,
      );
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });

      final mock = MockClient((req) async {
        expect(req.body, contains('refresh_token=RW'));
        return http.Response(
          jsonEncode({'access_token': 'fresh', 'expires_in': 21600}),
          200,
        );
      });

      expect(
        await XaiAuth(client: mock).freshAccessToken(account: account),
        'fresh',
      );
      expect(
        TokenStore.load(provider, account: account)!.accessToken,
        'fresh',
      );
      // The account refresh must not overwrite the provider-default grant.
      expect(TokenStore.load(provider)!.accessToken, 'default-old');
    });

    test('XaiAuth.freshAccessToken keeps the default slot owner on refresh',
        () async {
      const provider = XaiAuth.provider;
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.saveDefaultOwnedBy(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'DR', expiresAt: 1),
        'a@example.com',
      );
      final mock = MockClient((req) async {
        expect(req.body, contains('refresh_token=DR'));
        return http.Response(
          jsonEncode({'access_token': 'fresh', 'expires_in': 21600}),
          200,
        );
      });

      expect(await XaiAuth(client: mock).freshAccessToken(), 'fresh');
      // The owner stamp must survive the in-place default refresh, or the
      // adapter's cross-account lending guard silently reopens.
      expect(TokenStore.defaultOwner(provider), 'a@example.com');
      expect(TokenStore.load(provider)!.accessToken, 'fresh');
    });
  });

  group('AnthropicAuth', () {
    test('refresh maps the token response and posts the client id', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(), contains('console.anthropic.com'));
        expect(req.body, contains('grant_type=refresh_token'));
        expect(req.headers['anthropic-beta'], 'oauth-2025-04-20');
        return http.Response(
          jsonEncode({'access_token': 'AT', 'expires_in': 3600}),
          200,
        );
      });
      final t = await AnthropicAuth(client: mock).refresh('R1');
      expect(t!.accessToken, 'AT');
      expect(t.refreshToken, 'R1'); // carried forward
    });

    test('freshAccessToken returns a still-fresh grant without network',
        () async {
      const provider = AnthropicAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        Tokens(
            accessToken: 'AT',
            refreshToken: 'RT',
            expiresAt: nowEpoch() + 3600),
      );
      final auth = AnthropicAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      );
      expect(await auth.freshAccessToken(), 'AT');
    });

    test('freshAccessToken refreshes and persists the rotated token', () async {
      const provider = AnthropicAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
      );
      final mock = MockClient((req) async {
        expect(req.body, contains('refresh_token=R0'));
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'R1',
            'expires_in': 3600
          }),
          200,
        );
      });
      expect(await AnthropicAuth(client: mock).freshAccessToken(), 'new');
      // The rotated single-use refresh token must be persisted or the next
      // refresh fails.
      expect(TokenStore.load(provider)!.refreshToken, 'R1');
    });
  });

  group('OpenAiAuth', () {
    test('login reports a busy callback port before showing the URL', () async {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        1455,
      );
      addTearDown(() => server.close(force: true));
      var showedUrl = false;

      await expectLater(
        OpenAiAuth(clientId: 'test-client').loginLoopback(
          showUrl: (_) => showedUrl = true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('port 1455 is busy'),
          ),
        ),
      );
      expect(showedUrl, isFalse);
    });

    test('login releases the callback port when URL display fails', () async {
      await expectLater(
        OpenAiAuth(clientId: 'test-client').loginLoopback(
          showUrl: (_) => throw StateError('display failed'),
        ),
        throwsA(isA<StateError>()),
      );

      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        1455,
      );
      await server.close(force: true);
    });

    test('refresh maps the token response and keeps rotation', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(), contains('auth.openai.com/oauth/token'));
        expect(req.body, contains('grant_type=refresh_token'));
        return http.Response(
          jsonEncode({'access_token': 'AT', 'expires_in': 3600}),
          200,
        );
      });
      final t = await OpenAiAuth(client: mock).refresh('R1');
      expect(t!.accessToken, 'AT');
      expect(t.refreshToken, 'R1');
    });

    test('freshAccessToken refreshes and persists the rotated token', () async {
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
      );
      final mock = MockClient((req) async => http.Response(
            jsonEncode({
              'access_token': 'new',
              'refresh_token': 'R1',
              'expires_in': 3600
            }),
            200,
          ));
      expect(await OpenAiAuth(client: mock).freshAccessToken(), 'new');
      expect(TokenStore.load(provider)!.refreshToken, 'R1');
    });

    test('freshAccessToken returns null with no stored grant', () async {
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      expect(await OpenAiAuth().freshAccessToken(), isNull);
    });
  });

  group('GoogleAuth client', () {
    test('defaults to the bundled public client when nothing is set', () {
      final g = GoogleAuth();
      expect(g.clientId, isNotEmpty);
      expect(g.clientSecret, isNotEmpty);
    });

    test('honors an explicitly provided client', () {
      final g = GoogleAuth(clientId: 'X', clientSecret: 'Y');
      expect(g.clientId, 'X');
      expect(g.clientSecret, 'Y');
    });

    test('emailForAccessToken reads a plain userinfo email', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(), contains('/oauth2/v2/userinfo'));
        expect(req.headers['Authorization'], 'Bearer GA');
        return http.Response(jsonEncode({'email': 'work@example.com'}), 200);
      });

      expect(
        await GoogleAuth(client: mock).emailForAccessToken('GA'),
        'work@example.com',
      );
    });

    test('emailForAccessToken fails closed on bad userinfo', () async {
      final badStatus = GoogleAuth(
        client: MockClient((_) async => http.Response('no', 401)),
      );
      expect(await badStatus.emailForAccessToken('GA'), isNull);

      final badJson = GoogleAuth(
        client: MockClient((_) async => http.Response('{', 200)),
      );
      expect(await badJson.emailForAccessToken('GA'), isNull);

      final noEmail = GoogleAuth(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await noEmail.emailForAccessToken('GA'), isNull);
    });
  });

  group('XaiAuth.deviceLogin', () {
    test('prompts, polls past pending, and reports a terminal error', () async {
      var tokenCalls = 0;
      final mock = MockClient((req) async {
        if (req.url.toString().contains('device/code')) {
          return http.Response(
            jsonEncode({
              'device_code': 'DC',
              'interval': 0,
              'verification_uri_complete': 'https://x.ai/activate',
              'user_code': 'ABCD',
            }),
            200,
          );
        }
        tokenCalls++;
        final err = tokenCalls == 1 ? 'authorization_pending' : 'access_denied';
        return http.Response(jsonEncode({'error': err}), 400);
      });
      String? shownUrl, shownCode;
      await expectLater(
        XaiAuth(client: mock).deviceLogin(
          prompt: (url, code) {
            shownUrl = url;
            shownCode = code;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(shownUrl, 'https://x.ai/activate');
      expect(shownCode, 'ABCD');
      expect(tokenCalls, greaterThanOrEqualTo(2));
    });

    test('throws when device authorization fails to start', () async {
      final mock = MockClient((req) async => http.Response('no', 400));
      await expectLater(
        XaiAuth(client: mock).deviceLogin(prompt: (_, __) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('throws instead of crashing on a 200 with no device_code', () async {
      // A malformed 200 (missing device_code) must be a clean StateError, not
      // an uncaught cast TypeError.
      final mock = MockClient(
        (req) async => http.Response(jsonEncode({'interval': 5}), 200),
      );
      await expectLater(
        XaiAuth(client: mock).deviceLogin(prompt: (_, __) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('stores a successful device login under the id-token email', () async {
      const provider = XaiAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      final idToken = _unsignedJwt({'email': account});
      final mock = MockClient((req) async {
        if (req.url.toString().contains('device/code')) {
          return http.Response(
            jsonEncode({
              'device_code': 'DC',
              'interval': 0,
              'verification_uri_complete': 'https://x.ai/activate',
              'user_code': 'ABCD',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': 'AT',
            'refresh_token': 'RT',
            'expires_in': 21600,
            'id_token': idToken,
          }),
          200,
        );
      });

      await XaiAuth(client: mock).deviceLogin(prompt: (_, __) {});

      expect(TokenStore.load(provider)!.refreshToken, 'RT');
      expect(
        TokenStore.load(provider, account: account)!.accessToken,
        'AT',
      );
      expect(TokenStore.accounts(provider), contains(account));
    });
  });
}

String _unsignedJwt(Map<String, dynamic> payload) {
  String enc(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${enc({})}.${enc(payload)}.sig';
}
