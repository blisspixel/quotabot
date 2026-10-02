import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:quotabot_collector/adapters/lemonade.dart';
import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/http_client.dart';
import 'package:quotabot_collector/local_runtime_config.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

typedef _CollectRuntime = Future<ProviderQuota> Function(
    http.Client? client, String host);

final _collectors = <String, _CollectRuntime>{
  'ollama': (client, host) => OllamaAdapter(
        client: client,
        capabilityCache: OllamaCapabilityCache(),
        environment: {'OLLAMA_HOST': host},
      ).collect(),
  'lmstudio': (client, host) => LmStudioAdapter(
        client: client,
        environment: {'LMSTUDIO_HOST': host},
      ).collect(),
  'lemonade': (client, host) => LemonadeAdapter(
        client: client,
        environment: {'LEMONADE_HOST': host},
      ).collect(),
};

class _MetadataClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;

  _MetadataClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);

  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse _jsonResponse(Object data, http.BaseRequest request) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(data))), 200,
        request: request);

void main() {
  tearDown(resetSharedHttpClientForTesting);

  for (final runtime in _collectors.entries) {
    test('${runtime.key} keeps all reads on the configured metadata path',
        () async {
      final paths = <String>[];
      final client = _MetadataClient((request) async {
        paths.add(request.url.path);
        expect(request.followRedirects, isFalse);
        expect(request, isA<http.AbortableRequest>());
        return switch (request.url.path) {
          '/api/tags' => _jsonResponse({
              'models': [
                {'name': 'metadata-chat'}
              ]
            }, request),
          '/api/ps' => _jsonResponse({'models': <Object?>[]}, request),
          '/api/show' => _jsonResponse({
              'capabilities': ['completion', 'tools']
            }, request),
          '/api/v1/models' when runtime.key == 'lmstudio' => _jsonResponse({
              'models': [
                {'key': 'metadata-chat', 'type': 'llm'}
              ]
            }, request),
          '/api/v1/models' => _jsonResponse({
              'data': [
                {'id': 'metadata-chat'}
              ]
            }, request),
          _ => _jsonResponse({'all_models_loaded': <Object?>[]}, request),
        };
      });
      try {
        final quota = await runtime.value(client, 'http://127.0.0.1:12345');
        expect(quota.ok, isTrue);
        expect(quota.models.single.id, 'metadata-chat');
        expect(client.closed, isFalse);
        expect(
            paths,
            runtime.key == 'ollama'
                ? ['/api/tags', '/api/ps', '/api/show']
                : runtime.key == 'lmstudio'
                    ? ['/api/v1/models']
                    : ['/api/v1/models', '/api/v1/health']);
      } finally {
        client.close();
      }
    });

    test('${runtime.key} refuses an across-host metadata redirect', () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var targetReads = 0;
      final targetRequests = target.listen((request) async {
        targetReads++;
        request.response.write('{}');
        await request.response.close();
      });
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final originRequests = origin.listen((request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader,
            'http://localhost:${target.port}/unsupported');
        await request.response.close();
      });
      final client = http.Client();
      try {
        final quota =
            await runtime.value(client, 'http://127.0.0.1:${origin.port}');
        expect(quota.ok, isFalse);
        expect(quota.models, isEmpty);
        expect(targetReads, 0);
      } finally {
        client.close();
        await origin.close(force: true);
        await target.close(force: true);
        await originRequests.cancel();
        await targetRequests.cancel();
      }
    });

    test('${runtime.key} rejects an oversized model list', () async {
      final padding = 'x' * localRuntimeMetadataMaxResponseBytes;
      final client = _MetadataClient((request) async => _jsonResponse({
            'models': [
              {'key': 'metadata-chat', 'name': 'metadata-chat', 'type': 'llm'}
            ],
            'data': [
              {'id': 'metadata-chat'}
            ],
            'ignored': padding,
          }, request));
      try {
        final quota = await runtime.value(client, 'http://127.0.0.1:12345');
        expect(quota.ok, isFalse);
        expect(quota.models, isEmpty);
        expect(client.closed, isFalse);
      } finally {
        client.close();
      }
    });
  }

  for (final partialBody in [false, true]) {
    test(
        'Lemonade cancels ${partialBody ? 'partial' : 'stalled'} metadata '
        'before fallback and preserves its caller-owned client', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final firstDisconnected = Completer<void>();
      final paths = <String>[];
      final requests = server.listen((socket) {
        sockets.add(socket);
        final first = sockets.length == 1;
        var responded = false;
        final requestText = StringBuffer();
        socket.listen((bytes) {
          if (responded) return;
          requestText.write(utf8.decode(bytes));
          if (!requestText.toString().contains('\r\n\r\n')) return;
          responded = true;
          final path = requestText.toString().split(' ')[1];
          paths.add(path);
          if (first) {
            if (partialBody) {
              socket.add(utf8
                  .encode('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{}'));
            }
            return;
          }
          final body = jsonEncode(path == '/v1/models'
              ? {
                  'data': [
                    {'id': 'fallback-chat'}
                  ]
                }
              : {'all_models_loaded': <Object?>[]});
          socket.add(utf8.encode('HTTP/1.1 200 OK\r\n'
              'Content-Length: ${utf8.encode(body).length}\r\n'
              'Connection: close\r\n\r\n$body'));
          unawaited(socket.close());
        }, onDone: () {
          if (first && !firstDisconnected.isCompleted) {
            firstDisconnected.complete();
          }
        });
      });
      final client = http.Client();
      final host = 'http://127.0.0.1:${server.port}';
      try {
        final quota = await LemonadeAdapter(
            client: client, environment: {'LEMONADE_HOST': host}).collect();
        await firstDisconnected.future.timeout(const Duration(seconds: 2));
        expect(quota.ok, isTrue);
        expect(quota.models.single.id, 'fallback-chat');
        expect(paths, ['/api/v1/models', '/v1/models', '/v1/health']);
        expect((await client.get(Uri.parse('$host/probe'))).statusCode, 200);
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

  test('Lemonade cannot begin a read after shared-client retirement', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var reads = 0;
    final requests = server.listen((request) async {
      reads++;
      request.response.write('{}');
      await request.response.close();
    });
    try {
      retireSharedHttpClient();
      final quota = await LemonadeAdapter(environment: {
        'LEMONADE_HOST': 'http://127.0.0.1:${server.port}',
      }).collect();
      expect(quota.ok, isFalse);
      expect(reads, 0);
      expect(isSharedHttpClientRetired, isTrue);
    } finally {
      await server.close(force: true);
      await requests.cancel();
    }
  });

  test('Lemonade cannot start fallback after shared-client retirement',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    final requests = server.listen((request) async {
      paths.add(request.uri.path);
      request.response.statusCode = HttpStatus.notFound;
      retireSharedHttpClient();
      await request.response.close();
    });
    try {
      final quota = await LemonadeAdapter(environment: {
        'LEMONADE_HOST': 'http://127.0.0.1:${server.port}',
      }).collect();
      expect(quota.ok, isFalse);
      expect(paths, ['/api/v1/models']);
      expect(isSharedHttpClientRetired, isTrue);
    } finally {
      await server.close(force: true);
      await requests.cancel();
    }
  });
}
