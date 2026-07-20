import 'dart:async';
import 'dart:io';

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
      bool? followsRedirects;
      final client = MockClient((request) {
        followsRedirects = request.followRedirects;
        return http.Response('', 204);
      });
      final r = await postAlert('https://example.com/hook', payload,
          allowExternal: true, client: client);
      expect(r.ok, isTrue);
      expect(r.statusCode, 204);
      expect(followsRedirects, isTrue);
    });

    test('reports a non-2xx response as failure', () async {
      final client = MockClient((_) => http.Response('nope', 500));
      final r =
          await postAlert('http://127.0.0.1:9000', payload, client: client);
      expect(r.ok, isFalse);
      expect(r.statusCode, 500);
    });

    test('does not buffer or wait for the webhook response body', () async {
      final cancelled = Completer<void>();
      final controller = StreamController<List<int>>(
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      final client = _StreamClient(
        (request) => http.StreamedResponse(
          controller.stream,
          HttpStatus.noContent,
          request: request,
        ),
      );

      final r = await postAlert(
        'http://127.0.0.1:9000',
        payload,
        client: client,
      ).timeout(const Duration(seconds: 1));

      expect(r.ok, isTrue);
      expect(r.statusCode, HttpStatus.noContent);
      await cancelled.future.timeout(const Duration(seconds: 1));
      await controller.close();
    });

    test('uses one deadline for headers and response cancellation', () async {
      final client = _DeadlineClient();
      addTearDown(client.dispose);
      final stopwatch = Stopwatch()..start();
      final resultFuture = postAlert(
        'http://127.0.0.1:9000',
        payload,
        timeout: const Duration(milliseconds: 600),
        client: client,
      );

      await Future<void>.delayed(const Duration(milliseconds: 250));
      client.releaseResponse();
      await client.cancellationStarted.future.timeout(
        const Duration(milliseconds: 150),
      );
      final result = await resultFuture.timeout(const Duration(seconds: 1));
      stopwatch.stop();

      expect(result.ok, isFalse);
      expect(result.error, 'transport failure');
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(500));
      expect(stopwatch.elapsedMilliseconds, lessThan(750));
    });

    test('refuses to follow a loopback redirect to another destination',
        () async {
      bool? followsRedirects;
      final client = MockClient((request) {
        followsRedirects = request.followRedirects;
        return http.Response(
          '',
          307,
          headers: {'location': 'https://example.com/collect'},
        );
      });

      final r = await postAlert(
        'http://127.0.0.1:9000/quota',
        payload,
        client: client,
      );

      expect(followsRedirects, isFalse);
      expect(r.ok, isFalse);
      expect(r.statusCode, 307);
    });

    test('a loopback redirect never reaches its destination', () async {
      var destinationRequests = 0;
      final destination =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final redirector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await redirector.close(force: true);
        await destination.close(force: true);
      });
      destination.listen((request) async {
        destinationRequests++;
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });
      redirector.listen((request) async {
        request.response
          ..statusCode = HttpStatus.seeOther
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${destination.port}/collect',
          );
        await request.response.close();
      });

      final r = await postAlert(
        'http://127.0.0.1:${redirector.port}/quota',
        payload,
      );

      expect(r.ok, isFalse);
      expect(r.statusCode, HttpStatus.seeOther);
      expect(destinationRequests, 0);
    });

    test('never exposes transport exception details', () async {
      final client = MockClient(
        (_) => throw Exception('QB_WEBHOOK_SECRET_SENTINEL'),
      );
      final r =
          await postAlert('http://127.0.0.1:9000', payload, client: client);
      expect(r.ok, isFalse);
      expect(r.error, 'transport failure');
      expect(r.error, isNot(contains('QB_WEBHOOK_SECRET_SENTINEL')));
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

class _StreamClient extends http.BaseClient {
  final http.StreamedResponse Function(http.BaseRequest) handler;
  _StreamClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      handler(request);
}

class _DeadlineClient extends http.BaseClient {
  final cancellationStarted = Completer<void>();
  final _cancellationFinished = Completer<void>();
  final _response = Completer<http.StreamedResponse>();
  late final StreamController<List<int>> _controller;
  http.BaseRequest? _request;

  _DeadlineClient() {
    _controller = StreamController<List<int>>(
      onCancel: () {
        if (!cancellationStarted.isCompleted) {
          cancellationStarted.complete();
        }
        return _cancellationFinished.future;
      },
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _request = request;
    return _response.future;
  }

  void releaseResponse() {
    _response.complete(
      http.StreamedResponse(
        _controller.stream,
        HttpStatus.noContent,
        request: _request,
      ),
    );
  }

  Future<void> dispose() async {
    if (!_cancellationFinished.isCompleted) {
      _cancellationFinished.complete();
    }
    await _controller.close();
  }
}
