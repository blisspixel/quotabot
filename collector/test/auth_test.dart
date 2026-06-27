import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/oauth_util.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
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
    tearDown(() => TokenStore.clear(provider));

    test('save, load, exists, clear', () {
      expect(TokenStore.exists(provider), isFalse);
      TokenStore.save(provider, Tokens(accessToken: 'a', refreshToken: 'r'));
      expect(TokenStore.exists(provider), isTrue);
      expect(TokenStore.load(provider)!.refreshToken, 'r');
      TokenStore.clear(provider);
      expect(TokenStore.load(provider), isNull);
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
  });
}
