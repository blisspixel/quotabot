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
