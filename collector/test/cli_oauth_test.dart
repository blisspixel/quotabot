import 'dart:convert';
import 'dart:typed_data';

import 'package:quotabot_collector/auth/cli_oauth.dart';
import 'package:quotabot_collector/auth/os_secret_store.dart';
import 'package:test/test.dart';

void main() {
  test('parses the nested agy OS keyring blob', () {
    const raw = '''
{
  "auth_method": "consumer",
  "token": {
    "access_token": "example-access",
    "token_type": "Bearer",
    "refresh_token": "example-refresh",
    "expiry": "2026-08-19T09:16:27.7739171-07:00"
  }
}
''';
    final material = parseCliOauthSecret(raw);
    expect(material, isNotNull);
    expect(material!.accessToken, 'example-access');
    expect(material.refreshToken, 'example-refresh');
    expect(material.antigravityClient, isTrue);
    expect(material.expiryMs, isNotNull);
    expect(
      cliOauthAccessIsFresh(
        material,
        nowMs:
            DateTime.parse('2026-08-19T08:00:00-07:00').millisecondsSinceEpoch,
      ),
      isTrue,
    );
    expect(
      cliOauthAccessIsFresh(
        material,
        nowMs:
            DateTime.parse('2026-08-19T09:16:00-07:00').millisecondsSinceEpoch,
      ),
      isFalse,
    );
  });

  test('parses Gemini CLI oauth_creds.json', () {
    const raw = '''
{
  "access_token": "example-cli-access",
  "refresh_token": "example-cli-refresh",
  "expiry_date": 1782000000000,
  "id_token": "example-id-token"
}
''';
    final material = parseCliOauthSecret(raw);
    expect(material!.accessToken, 'example-cli-access');
    expect(material.refreshToken, 'example-cli-refresh');
    expect(material.expiryMs, 1782000000000);
    expect(material.idToken, 'example-id-token');
    expect(material.antigravityClient, isFalse);
  });

  test('treats Go oauth2 expiry strings as Antigravity-client tokens', () {
    final material = parseCliOauthSecret(
      '{"access_token":"example-x-access","refresh_token":"example-x-refresh","expiry":"2026-01-01T00:00:00Z"}',
    );
    expect(material!.antigravityClient, isTrue);
    expect(material.expiryMs,
        DateTime.parse('2026-01-01T00:00:00Z').millisecondsSinceEpoch);
  });

  test('rejects empty or non-oauth JSON', () {
    expect(parseCliOauthSecret(''), isNull);
    expect(parseCliOauthSecret('{'), isNull);
    expect(parseCliOauthSecret('{"auth_method":"consumer"}'), isNull);
    expect(parseCliOauthSecret('[]'), isNull);
  });

  test('agy OS keyring blob parses when the CLI is signed in', () {
    final raw = readAgyOsKeyringSecret();
    if (raw == null) return;
    final material = parseCliOauthSecret(raw);
    expect(material, isNotNull);
    expect(
      material!.refreshToken != null || material.accessToken != null,
      isTrue,
    );
    expect(material.antigravityClient, isTrue);
  });

  test('decodeOsSecretBytes reads UTF-8 and UTF-16LE JSON', () {
    expect(decodeOsSecretBytes(Uint8List(0)), isNull);
    expect(decodeOsSecretBytes(Uint8List.fromList(utf8.encode('{"a":1}'))),
        '{"a":1}');
    expect(
      decodeOsSecretBytes(
        Uint8List.fromList([0x7b, 0x00, 0x22, 0x00, 0x61, 0x00, 0x22, 0x00]),
      ),
      '{"a"',
    );
    expect(decodeOsSecretBytes(Uint8List.fromList([0xff, 0xfe, 0x00])), isNull);
  });

  test('parseOauthExpiryMs accepts seconds, millis, and RFC3339', () {
    expect(parseOauthExpiryMs(0), isNull);
    expect(parseOauthExpiryMs(1782000000), 1782000000000);
    expect(parseOauthExpiryMs(1782000000000), 1782000000000);
    expect(
      parseOauthExpiryMs('2026-08-19T09:16:27.7739171-07:00'),
      DateTime.parse('2026-08-19T09:16:27.773917-07:00').millisecondsSinceEpoch,
    );
  });
}
