import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:test/test.dart';

void main() {
  group('OllamaAdapter.collect fallback ladder', () {
    test('reports installed and loaded when both endpoints answer', () async {
      final client = MockClient((req) async {
        switch (req.url.path) {
          case '/api/tags':
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'llama3:8b', 'size': 4000000000},
                ],
              }),
              200,
            );
          case '/api/ps':
            return http.Response(
              jsonEncode({
                'models': [
                  {
                    'name': 'llama3:8b',
                    'size_vram': 5000000000,
                    'context_length': 8192,
                  },
                ],
              }),
              200,
            );
          default:
            return http.Response('unexpected', 404);
        }
      });

      final q = await OllamaAdapter(client: client).collect();
      expect(q.kind, ProviderQuotaKind.local);
      expect(q.ok, isTrue);
      expect(q.active, isTrue, reason: 'a model is loaded');
      expect(q.models, hasLength(1));
      expect(q.models.single.loaded, isTrue);
      expect(q.models.single.vramBytes, 5000000000);
    });

    test('reports installed-only when the loaded endpoint fails', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/tags') {
          return http.Response(
            jsonEncode({
              'models': [
                {'name': 'llama3:8b'},
              ],
            }),
            200,
          );
        }
        return http.Response('down', 500); // /api/ps unavailable
      });

      final q = await OllamaAdapter(client: client).collect();
      expect(q.ok, isTrue);
      expect(q.active, isFalse, reason: 'nothing is loaded');
      expect(q.models, hasLength(1));
      expect(q.models.single.loaded, isFalse);
    });

    test('is not running when the installed endpoint is unreachable', () async {
      final client = MockClient((_) async => http.Response('no daemon', 503));
      final q = await OllamaAdapter(client: client).collect();
      expect(q.ok, isFalse);
      expect(q.error, 'not running');
    });

    test('is not running when the client throws', () async {
      final client = MockClient(
        (_) async => throw const SocketException('connection refused'),
      );
      final q = await OllamaAdapter(client: client).collect();
      expect(q.ok, isFalse);
      expect(q.error, 'not running');
    });

    test('refuses a non-loopback host without contacting it', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls += 1;
        return http.Response('{}', 200);
      });
      final q = await OllamaAdapter(
        client: client,
        environment: const {'OLLAMA_HOST': 'http://192.168.1.20:11434'},
      ).collect();

      expect(calls, 0);
      expect(q.ok, isTrue, reason: 'the configuration issue stays visible');
      expect(q.models, isEmpty);
      expect(q.error, contains('non-loopback'));
      expect(retainCollectedProviderQuota(q), isTrue);
      expect(isLocalRuntimeAvailableAt(q, q.asOf), isFalse);
    });

    test('accepts exact loopback hosts', () async {
      for (final host in [
        'localhost:11434',
        '127.42.0.9:11434',
        'http://[::1]:11434',
      ]) {
        var calls = 0;
        final q = await OllamaAdapter(
          environment: {'OLLAMA_HOST': host},
          client: MockClient((request) async {
            calls += 1;
            expect(request.url.path, anyOf('/api/tags', '/api/ps'));
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'local:1b'},
                ],
              }),
              200,
            );
          }),
        ).collect();
        expect(calls, 2, reason: host);
        expect(q.ok, isTrue, reason: host);
      }
    });
  });

  test('optional model metadata shape drift does not drop valid inventory', () {
    final models = ollamaModelsFromJson({
      'models': [
        {
          'name': 'valid:1b',
          'size': -1,
          'size_vram': 'not-a-number',
          'context_length': -4096,
          'details': {
            'parameter_size': 1,
            'quantization_level': <String, Object?>{},
          },
        },
      ],
    });

    expect(models.single.name, 'valid:1b');
    expect(models.single.bytes, isNull);
    expect(models.single.vramBytes, isNull);
    expect(models.single.context, isNull);
    expect(models.single.param, isNull);
    expect(models.single.quant, isNull);
  });
}
