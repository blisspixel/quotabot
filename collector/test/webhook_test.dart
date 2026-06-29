import 'package:http/http.dart' as http;
import 'package:quotabot_collector/webhook.dart';
import 'package:test/test.dart';

void main() {
  group('isLoopbackUrl', () {
    test('accepts loopback hosts', () {
      expect(isLoopbackUrl('http://127.0.0.1:9000/quota'), isTrue);
      expect(isLoopbackUrl('http://localhost:8080'), isTrue);
      expect(isLoopbackUrl('http://127.5.6.7/x'), isTrue); // all of 127/8
      expect(isLoopbackUrl('http://[::1]:9000'), isTrue);
    });

    test('rejects external and malformed hosts', () {
      expect(isLoopbackUrl('https://hooks.slack.com/services/x'), isFalse);
      expect(isLoopbackUrl('http://192.168.1.5:9000'), isFalse);
      expect(isLoopbackUrl('http://example.com'), isFalse);
      expect(isLoopbackUrl('not a url'), isFalse);
      expect(isLoopbackUrl('ftp://127.0.0.1'), isFalse); // wrong scheme
    });
  });

  group('postAlert', () {
    final payload = {'schema': 'quotabot.alert.v1', 'provider': 'codex'};

    test('refuses a non-loopback host unless external is allowed', () async {
      final r = await postAlert('https://example.com/hook', payload);
      expect(r.ok, isFalse);
      expect(r.error, contains('loopback'));
    });

    test('rejects an invalid url', () async {
      final r = await postAlert('not a url', payload);
      expect(r.ok, isFalse);
    });

    test('posts JSON to a loopback host and reports success', () async {
      Map<String, String>? sentHeaders;
      String? sentBody;
      final client = MockClient((req) {
        sentHeaders = req.headers;
        sentBody = req.body;
        return http.Response('ok', 200);
      });
      final r = await postAlert('http://127.0.0.1:9000/quota', payload,
          client: client);
      expect(r.ok, isTrue);
      expect(r.statusCode, 200);
      expect(sentHeaders?['content-type'], contains('application/json'));
      expect(sentBody, contains('quotabot.alert.v1'));
    });

    test('posts to an external host only when allowed', () async {
      final client = MockClient((_) => http.Response('', 204));
      final r = await postAlert('https://example.com/hook', payload,
          allowExternal: true, client: client);
      expect(r.ok, isTrue);
      expect(r.statusCode, 204);
    });

    test('reports a non-2xx response as failure', () async {
      final client = MockClient((_) => http.Response('nope', 500));
      final r =
          await postAlert('http://127.0.0.1:9000', payload, client: client);
      expect(r.ok, isFalse);
      expect(r.statusCode, 500);
    });

    test('never throws on a transport error', () async {
      final client = MockClient((_) => throw Exception('connection refused'));
      final r =
          await postAlert('http://127.0.0.1:9000', payload, client: client);
      expect(r.ok, isFalse);
      expect(r.error, contains('connection refused'));
    });
  });
}

/// A minimal stand-in for `http.Client` that answers each request with the
/// caller-supplied handler, so webhook delivery is tested without a socket.
class MockClient extends http.BaseClient {
  final http.Response Function(http.Request) handler;
  MockClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    final resp = handler(req);
    return http.StreamedResponse(
      Stream.value(resp.bodyBytes),
      resp.statusCode,
      headers: resp.headers,
      request: request,
    );
  }
}
