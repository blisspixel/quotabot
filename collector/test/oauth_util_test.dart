import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:quotabot_collector/auth/oauth_util.dart';
import 'package:test/test.dart';

void main() {
  test('randomState has 256 bits of URL-safe entropy and is unique', () {
    final a = randomState();
    final b = randomState();
    // 32 random bytes encode to 43 unpadded base64url characters. Anthropic's
    // authorize POST rejects the previous 16-byte, 22-character value.
    expect(a, hasLength(43));
    expect(b, hasLength(43));
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
      'a fixed-port capture fails closed when another process holds the '
      'IPv6 loopback port', () async {
    // A fixed-port flow redirects to localhost, which a browser may resolve
    // to ::1 first. A silent IPv4-only fallback would hand the authorization
    // redirect to whichever process pre-bound the IPv6 port. Parallel suites
    // bind loopback ports constantly, so an ephemeral port whose IPv4 twin is
    // taken by an unrelated socket is retried rather than failed.
    for (var attempt = 0; attempt < 8; attempt++) {
      HttpServer squatter;
      try {
        squatter = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
      } on SocketException {
        return; // No IPv6 loopback on this host; the lenient path is correct.
      }
      try {
        LoopbackCodeCapture? capture;
        try {
          capture = await startLoopbackCodeCapture(
            port: squatter.port,
            path: '/cb',
            expectedState: 'xyz',
          );
        } on SocketException catch (e) {
          if (!e.message
              .contains('already in use on the IPv6 loopback interface')) {
            continue; // Unrelated IPv4 collision; try a fresh port.
          }
          // The refusal under test. The failed capture must also have
          // released its IPv4 socket so a retry after closing the
          // conflicting process can bind the same port.
          final reclaimed = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            squatter.port,
          );
          await reclaimed.close(force: true);
          return;
        }
        await capture.close();
        fail('capture bound despite the IPv6 loopback conflict');
      } finally {
        await squatter.close(force: true);
      }
    }
    fail('no ephemeral port with a free IPv4 twin after 8 attempts');
  });

  test('startLoopbackCodeCapture accepts a matching IPv6 callback', () async {
    final capture = await startLoopbackCodeCapture(
      path: '/cb',
      expectedState: 'xyz',
    );
    try {
      final resp = await http.get(
        Uri.parse('http://[::1]:${capture.port}/cb?code=v6code&state=xyz'),
      );
      expect(resp.statusCode, 200);
      expect(await capture.code, 'v6code');
    } on SocketException catch (_) {
      await capture.close();
    }
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

  test('closing a loopback capture releases its port immediately', () async {
    final capture = await startLoopbackCodeCapture(
      path: '/cb',
      expectedState: 'xyz',
    );
    final cancelled = expectLater(capture.code, throwsA(isA<StateError>()));

    await capture.close();
    await cancelled;

    HttpServer? rebound;
    Object? lastError;
    for (final delayMs in const [0, 10, 25, 50, 100, 200, 400]) {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      try {
        rebound = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          capture.port,
        );
        break;
      } on SocketException catch (error) {
        lastError = error;
      }
    }
    expect(
      rebound,
      isNotNull,
      reason: 'loopback port ${capture.port} stayed in use: $lastError',
    );
    await rebound!.close(force: true);
  });
}
