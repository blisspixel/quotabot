import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/lmstudio.dart';
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
    });

    test('is not running when no endpoint answers', () async {
      final client = MockClient((_) async => http.Response('down', 503));
      final q = await LmStudioAdapter(client: client).collect();
      expect(q.ok, isFalse);
      expect(q.error, 'not running');
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
    expect(parsed.installed.single.bytes, isNull);
    expect(parsed.installed.single.param, isNull);
    expect(parsed.installed.single.quant, isNull);
    expect(parsed.installed.single.context, isNull);
  });
}
