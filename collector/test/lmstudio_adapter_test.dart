import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/http_client.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

void main() {
  group('LmStudioAdapter.collect fallback ladder', () {
    test('prefers the v1 endpoint and detects a loaded model', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/v1/models') {
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'key': 'qwen2.5-7b',
                  'size_bytes': 3000000000,
                  'params_string': '7B',
                  'loaded_instances': [
                    {
                      'id': 'qwen-instance',
                      'config': {'context_length': 4096},
                    },
                  ],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('unexpected', 404);
      });

      final q = await LmStudioAdapter(client: client).collect();
      expect(q.kind, ProviderQuotaKind.local);
      expect(q.models, hasLength(1));
      expect(q.models.single.loaded, isTrue);
      expect(q.models.single.contextTokens, 4096);
      expect(q.active, isTrue);
    });

    test('falls back to the native v0 endpoint when v1 is absent', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/v0/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'm1', 'state': 'loaded'},
                {'id': 'm2', 'state': 'not-loaded'},
              ],
            }),
            200,
          );
        }
        return http.Response('absent', 404); // v1 missing
      });

      final q = await LmStudioAdapter(client: client).collect();
      expect(q.models, hasLength(2));
      expect(q.active, isTrue, reason: 'm1 is loaded');
      expect(q.models.firstWhere((m) => m.id == 'm2').loaded, isFalse);
    });

    test('falls back to the compatible listing without load state', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/v1/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'm1'},
                {'id': 'm2'},
              ],
            }),
            200,
          );
        }
        return http.Response('absent', 404); // v1 and v0 native both missing
      });

      final q = await LmStudioAdapter(client: client).collect();
      expect(q.models, hasLength(2));
      expect(q.active, isFalse, reason: 'compat listing has no load state');
      expect(q.models.every((m) => !m.loaded), isTrue);
      expect(q.models.every((m) => !m.loadedStateKnown), isTrue);
      expect(q.status, 'reachable - load state unknown');
    });

    test('reports metadata failure when every endpoint returns HTTP 503',
        () async {
      final client = MockClient((_) async => http.Response('down', 503));
      final q = await LmStudioAdapter(client: client).collect();
      expect(q.ok, isFalse);
      expect(q.error, 'runtime metadata unavailable (HTTP 503)');
      expect(q.httpStatus, 503);
    });

    test('refuses a LAN host without contacting it', () async {
      var calls = 0;
      final q = await LmStudioAdapter(
        environment: const {'LMSTUDIO_HOST': 'http://10.0.0.8:1234'},
        client: MockClient((_) async {
          calls += 1;
          return http.Response('{}', 200);
        }),
      ).collect();

      expect(calls, 0);
      expect(q.ok, isTrue);
      expect(q.error, contains('non-loopback'));
      expect(q.models, isEmpty);
    });
  });

  test('a stalled v1 socket closes while the native v0 fallback recovers',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final paths = <String>[];
    final stalledDisconnected = Completer<void>();
    final subscription = server.listen((socket) {
      sockets.add(socket);
      final bytes = <int>[];
      String? path;
      socket.listen((chunk) {
        if (path != null) return;
        bytes.addAll(chunk);
        final text = utf8.decode(bytes, allowMalformed: true);
        if (!text.contains('\r\n\r\n')) return;
        path = text.split(' ')[1];
        paths.add(path!);
        if (path == '/api/v1/models') return;
        final body = jsonEncode({
          'data': [
            {'id': 'metadata-only', 'state': 'loaded'}
          ]
        });
        socket.add(utf8.encode(
          'HTTP/1.1 200 OK\r\nContent-Length: ${utf8.encode(body).length}\r\n'
          'Connection: close\r\n\r\n$body',
        ));
        unawaited(socket.close());
      }, onDone: () {
        if (path == '/api/v1/models' && !stalledDisconnected.isCompleted) {
          stalledDisconnected.complete();
        }
      });
    });
    try {
      final quota = await LmStudioAdapter(environment: {
        'LMSTUDIO_HOST': 'http://127.0.0.1:${server.port}',
      }).collect();
      await stalledDisconnected.future.timeout(const Duration(seconds: 2));
      expect(quota.ok, isTrue);
      expect(quota.models.single.id, 'metadata-only');
      expect(quota.models.single.loaded, isTrue);
      expect(paths, ['/api/v1/models', '/api/v0/models']);
    } finally {
      closeSharedHttpClient();
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
      await subscription.cancel();
    }
  });

  test('malformed optional v1 fields do not prove loaded state or abort', () {
    final parsed = lmStudioV1FromJson({
      'models': [
        {
          'key': 'valid/model',
          'size_bytes': -1,
          'params_string': 7,
          'quantization': {'name': 4},
          'max_context_length': -1,
          'loaded_instances': ['not-an-instance'],
        },
      ],
    });

    expect(parsed, isNotNull);
    expect(parsed!.installed.single.name, 'valid/model');
    expect(parsed.loaded, isEmpty);
    expect(parsed.unknownLoadModelNames, {'valid/model'});
    expect(parsed.installed.single.bytes, isNull);
    expect(parsed.installed.single.param, isNull);
    expect(parsed.installed.single.quant, isNull);
    expect(parsed.installed.single.context, isNull);
  });
}
