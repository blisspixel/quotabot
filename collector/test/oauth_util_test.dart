import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:quotabot_collector/auth/oauth_util.dart';
import 'package:test/test.dart';

void main() {
  test('randomState is url-safe, non-empty, and unique', () {
    final a = randomState();
    final b = randomState();
    expect(a, isNotEmpty);
    expect(a, isNot(contains('=')));
    expect(a, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(a, isNot(b));
  });

  test('pkcePair challenge is the unpadded S256 of the verifier', () {
    final p = pkcePair();
    final expected = base64Url
        .encode(sha256.convert(ascii.encode(p.verifier)).bytes)
        .replaceAll('=', '');
    expect(p.challenge, expected);
    expect(p.challenge, isNot(contains('=')));
    expect(pkcePair().verifier, isNot(p.verifier)); // fresh each call
  });

  test('freePort returns a usable loopback port', () async {
    final port = await freePort();
    expect(port, greaterThan(0));
    expect(port, lessThanOrEqualTo(65535));
  });

  test('startLoopbackCodeCapture returns the code when state matches',
      () async {
    final capture = await startLoopbackCodeCapture(
      path: '/cb',
      expectedState: 'xyz',
    );
    final resp = await http.get(
      Uri.parse('http://127.0.0.1:${capture.port}/cb?code=abc123&state=xyz'),
    );
    expect(resp.statusCode, 200);
    expect(await capture.code, 'abc123');
  });

  test(
    'startLoopbackCodeCapture ignores a state mismatch and keeps waiting',
    () async {
      final capture = await startLoopbackCodeCapture(
        path: '/cb',
        expectedState: 'expected',
      );
      final resp = await http.get(
        Uri.parse('http://127.0.0.1:${capture.port}/cb?code=abc&state=wrong'),
      );
      expect(resp.statusCode, 400);
      final ok = await http.get(
        Uri.parse(
          'http://127.0.0.1:${capture.port}/cb?code=abc&state=expected',
        ),
      );
      expect(ok.statusCode, 200);
      expect(await capture.code, 'abc');
    },
  );

  test('startLoopbackCodeCapture surfaces a provider error without waiting',
      () async {
    // A denied/error callback must complete the flow at once, not hang until
    // the multi-minute timeout.
    final capture = await startLoopbackCodeCapture(
      path: '/cb',
      expectedState: 'xyz',
    );
    // Attach the expectation (which registers a listener) before triggering the
    // callback, so the error completion is never momentarily unhandled - which
    // would otherwise fail the test in its async zone on a slower host.
    final expectation = expectLater(capture.code, throwsA(isA<StateError>()));
    final resp = await http.get(
      Uri.parse(
        'http://127.0.0.1:${capture.port}/cb?error=access_denied&state=xyz',
      ),
    );
    expect(resp.statusCode, 400);
    await expectation;
  });

  test('startLoopbackCodeCapture binds before the redirect is sent', () async {
    final capture = await startLoopbackCodeCapture(
      path: '/cb',
      expectedState: 'xyz',
    );
    final resp = await http.get(
      Uri.parse('http://127.0.0.1:${capture.port}/cb?code=abc123&state=xyz'),
    );
    expect(resp.statusCode, 200);
    expect(await capture.code, 'abc123');
  });
}
