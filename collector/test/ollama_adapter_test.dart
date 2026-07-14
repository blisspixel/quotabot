import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/models.dart';
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
  });
}
