import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/http_client.dart';
import 'package:test/test.dart';

class _TrackingMockClient extends MockClient {
  bool closed = false;

  _TrackingMockClient(super.fn);

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _StreamingClient extends http.BaseClient {
  final Stream<List<int>> responseBody;
  http.BaseRequest? request;
  bool closed = false;

  _StreamingClient(this.responseBody);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    return http.StreamedResponse(responseBody, 200, request: request);
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('metadata POST preserves its bounded body and caller-owned client',
      () async {
    final client = _TrackingMockClient((request) async {
      expect(request.method, 'POST');
      expect(request.headers['content-type'], 'application/json');
      expect(request.body, '{"model":"metadata-only"}');
      return http.Response('{}', 200);
    });
    try {
      final uri = Uri.parse('http://127.0.0.1/api/show');
      expect(
        (await sendMetadataRequest(
          client,
          uri,
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: '{"model":"metadata-only"}',
          timeout: const Duration(seconds: 1),
        ))
            .statusCode,
        200,
      );
      expect(client.closed, isFalse);
      expect(
          (await client.post(uri,
                  headers: {'Content-Type': 'application/json'},
                  body: '{"model":"metadata-only"}'))
              .statusCode,
          200);
    } finally {
      client.close();
    }
  });

  test('metadata deadline must be positive', () async {
    final client = MockClient((_) async => http.Response('{}', 200));
    try {
      await expectLater(
        sendMetadataRequest(client, Uri.parse('http://127.0.0.1/metadata'),
            timeout: Duration.zero),
        throwsArgumentError,
      );
    } finally {
      client.close();
    }
  });

  test('metadata response limit must be positive', () async {
    final client = MockClient((_) async => http.Response('{}', 200));
    try {
      for (final limit in [0, -1]) {
        await expectLater(
          sendMetadataRequest(client, Uri.parse('http://127.0.0.1/metadata'),
              maxResponseBytes: limit, timeout: const Duration(seconds: 1)),
          throwsArgumentError,
        );
      }
    } finally {
      client.close();
    }
  });

  test('bounded metadata preserves response fields at its exact limit',
      () async {
    final client = MockClient((request) async => http.Response('{}', 202,
        headers: {'content-type': 'application/json', 'etag': 'test'},
        request: request,
        reasonPhrase: 'Accepted'));
    try {
      final response = await sendMetadataRequest(
          client, Uri.parse('http://127.0.0.1/metadata'),
          maxResponseBytes: 2, timeout: const Duration(seconds: 1));
      expect(response.body, '{}');
      expect(response.statusCode, 202);
      expect(response.reasonPhrase, 'Accepted');
      expect(response.headers['etag'], 'test');
      expect(response.request?.followRedirects, isTrue,
          reason: 'cloud callers retain their existing redirect behavior');
    } finally {
      client.close();
    }
  });

  test('bounded metadata retains original settlement when abort is ignored',
      () async {
    final body = StreamController<List<int>>();
    final client = _StreamingClient(body.stream);
    final original = sendMetadataRequest(
        client, Uri.parse('http://127.0.0.1/metadata'),
        maxResponseBytes: 32, timeout: const Duration(milliseconds: 20));
    var settled = false;
    final expectation = expectLater(original.whenComplete(() => settled = true),
        throwsA(isA<TimeoutException>()));
    try {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settled, isFalse);
      expect(client.closed, isFalse);
      expect(client.request, isA<http.AbortableRequest>());
      body.add(utf8.encode('{}'));
      await body.close();
      await expectation;
      expect(settled, isTrue);
      expect(client.closed, isFalse);
    } finally {
      client.close();
    }
  });

  for (final chunked in [false, true]) {
    test(
        'metadata byte limit closes a ${chunked ? 'chunked' : 'declared-size'} '
        'body and permits caller-owned client reuse', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final disconnected = Completer<void>();
      final requests = server.listen((socket) {
        sockets.add(socket);
        final first = sockets.length == 1;
        var responded = false;
        socket.listen((_) {
          if (responded) return;
          responded = true;
          if (first) {
            socket.add(utf8.encode(chunked
                ? 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
                    '800\r\n${'x' * 2048}\r\n'
                : 'HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n'
                    '${'x' * 2048}'));
          } else {
            socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n'
                'Connection: close\r\n\r\n{}'));
            unawaited(socket.close());
          }
        }, onDone: () {
          if (first && !disconnected.isCompleted) disconnected.complete();
        });
      });
      final client = http.Client();
      final uri = Uri.parse('http://127.0.0.1:${server.port}/metadata');
      try {
        await expectLater(
          sendMetadataRequest(client, uri,
              maxResponseBytes: 1024, timeout: const Duration(seconds: 2)),
          throwsA(isA<http.ClientException>().having(
              (error) => error.message, 'message', contains('too large'))),
        );
        await disconnected.future.timeout(const Duration(seconds: 1));
        expect(
            (await sendMetadataRequest(client, uri,
                    maxResponseBytes: 1024,
                    timeout: const Duration(seconds: 2)))
                .body,
            '{}');
      } finally {
        client.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        await requests.cancel();
      }
    });
  }

  test('an unrelated request abort remains an abort error', () async {
    final client =
        MockClient((_) async => throw http.RequestAbortedException());
    try {
      await expectLater(
        sendMetadataRequest(client, Uri.parse('http://127.0.0.1/metadata'),
            timeout: const Duration(seconds: 1)),
        throwsA(isA<http.RequestAbortedException>()),
      );
    } finally {
      client.close();
    }
  });

  for (final partialBody in [false, true]) {
    test(
        'native deadline closes a ${partialBody ? 'partial body' : 'stalled'} '
        'socket and permits client reuse', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final disconnected = Completer<void>();
      var connections = 0;
      final subscription = server.listen((socket) {
        sockets.add(socket);
        final first = ++connections == 1;
        var responded = false;
        socket.listen((_) {
          if (responded) return;
          responded = true;
          if (first) {
            if (partialBody) {
              socket.add(utf8.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{}',
              ));
            }
          } else {
            socket.add(utf8.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n'
              'Connection: close\r\n\r\n{}',
            ));
            unawaited(socket.close());
          }
        }, onDone: () {
          if (first && !disconnected.isCompleted) disconnected.complete();
        });
      });
      final client = http.Client();
      final uri = Uri.parse('http://127.0.0.1:${server.port}/metadata');
      try {
        await expectLater(
          sendMetadataRequest(client, uri,
              timeout: const Duration(milliseconds: 200)),
          throwsA(isA<TimeoutException>()),
        );
        await disconnected.future.timeout(const Duration(seconds: 2));
        expect(
          (await sendMetadataRequest(client, uri,
                  timeout: const Duration(seconds: 2)))
              .body,
          '{}',
        );
        expect(connections, 2);
      } finally {
        client.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        await subscription.cancel();
      }
    });
  }
}
