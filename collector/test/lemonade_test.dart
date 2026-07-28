import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/lemonade.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/local_runtime_config.dart';
import 'package:test/test.dart';

void main() {
  group('LemonadeAdapter', () {
    test('reports installed models from an OpenAI-style listing', () async {
      final mock = MockClient((req) async {
        expect(req.url.port, lemonadeDefaultPort);
        if (req.url.path.endsWith('/health')) {
          return http.Response('unavailable', 503);
        }
        expect(req.url.path, contains('models'));
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'llama-3'},
              {'id': 'qwen-coder'},
            ],
          }),
          200,
        );
      });
      final q = await LemonadeAdapter(client: mock).collect();
      expect(q.provider, 'lemonade');
      expect(q.isLocal, isTrue);
      expect(q.ok, isTrue);
      expect(q.account, contains('2'));
      expect(q.sourceClass.wireName, 'local_runtime');
    });

    test('reports loaded state and running context from health metadata',
        () async {
      final mock = MockClient((req) async {
        switch (req.url.path) {
          case '/api/v1/models':
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'local-coder',
                    'downloaded': true,
                    'max_context_window': 32768,
                  },
                ],
              }),
              200,
            );
          case '/api/v1/health':
            return http.Response(
              jsonEncode({
                'status': 'ok',
                'all_models_loaded': [
                  {
                    'model_name': 'local-coder',
                    'recipe_options': {'ctx_size': 8192},
                  },
                ],
              }),
              200,
            );
          default:
            return http.Response('unexpected', 404);
        }
      });

      final q = await LemonadeAdapter(client: mock).collect();

      expect(q.ok, isTrue);
      expect(q.active, isTrue);
      expect(q.models.single.loaded, isTrue);
      expect(q.models.single.contextTokens, 8192);
    });

    test('uses the current default port and honors host overrides', () {
      expect(
        LemonadeAdapter.baseUrl(environment: const {}),
        'http://127.0.0.1:13305',
      );
      expect(
        LemonadeAdapter.baseUrl(
          environment: const {
            'LEMONADE_HOST': 'localhost',
            'LEMONADE_PORT': '14000',
          },
        ),
        'http://localhost:14000',
      );
    });

    test('is not-running when the server is unreachable', () async {
      final mock = MockClient((req) async => http.Response('down', 500));
      final q = await LemonadeAdapter(client: mock).collect();
      expect(q.ok, isFalse);
      expect(q.error, 'not running');
      expect(q.isLocal, isTrue);
    });

    test('reports a reachable server with no local models', () async {
      final mock = MockClient(
        (req) async => http.Response(jsonEncode({'data': <Object?>[]}), 200),
      );
      final q = await LemonadeAdapter(client: mock).collect();
      expect(q.ok, isTrue);
      expect(q.status, '0 installed, idle');
      expect(q.models, isEmpty);
      expect(isLocalRuntimeAvailableAt(q, q.asOf), isFalse);
    });

    test('does not promote a cloud-routed model as local capacity', () async {
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'object': 'list',
            'data': [
              {
                'id': 'fireworks.kimi-k2p5',
                'recipe': 'cloud',
                'cloud_provider': 'fireworks',
                'downloaded': false,
              },
            ],
          }),
          200,
        ),
      );

      final q = await LemonadeAdapter(client: mock).collect();

      expect(q.ok, isTrue);
      expect(q.models.single.cloudOffloaded, isTrue);
      expect(isLocalRuntimeReachableAt(q, q.asOf), isTrue);
      expect(isLocalRuntimeAvailableAt(q, q.asOf), isFalse);
    });

    test('parses extended local metadata and omits catalog-only rows', () {
      final models = lemonadeModelsFromJson({
        'object': 'list',
        'data': [
          {
            'id': 'local-coder',
            'recipe': 'llamacpp',
            'downloaded': true,
            'max_context_window': 32768,
            'labels': ['coding', 'tool-calling', 'vision'],
          },
          {
            'id': 'local-embedder',
            'recipe': 'llamacpp',
            'downloaded': true,
            'labels': ['embeddings'],
          },
          {
            'id': 'catalog-only',
            'recipe': 'llamacpp',
            'downloaded': false,
          },
          {
            'id': 'malformed-recipe',
            'recipe': 7,
            'downloaded': true,
          },
          {
            'id': 'malformed-provider',
            'cloud_provider': <String>[],
            'downloaded': true,
          },
          {
            'id': 'malformed-download-state',
            'recipe': 'llamacpp',
            'downloaded': 'yes',
          },
        ],
      });

      expect(models, hasLength(2));
      final coder = models!.first;
      expect(coder.name, 'local-coder');
      expect(coder.context, 32768);
      expect(coder.tools, isTrue);
      expect(coder.vision, isTrue);
      expect(coder.embedding, isNull);
      expect(models.last.embedding, isTrue);
      expect(lemonadeModelsFromJson({'data': 'invalid'}), isNull);
    });

    test('health parsing is defensive and supports the legacy loaded name', () {
      final current = lemonadeLoadedModelsFromJson({
        'all_models_loaded': [
          {
            'model_name': 'coder',
            'recipe_options': {'ctx_size': 4096},
          },
          {'model_name': ''},
          'invalid',
        ],
      });
      final legacy = lemonadeLoadedModelsFromJson({'model_loaded': ' older '});

      expect(current, hasLength(1));
      expect(current!.single.name, 'coder');
      expect(current.single.context, 4096);
      expect(legacy!.single.name, 'older');
      expect(
        lemonadeLoadedModelsFromJson({'all_models_loaded': <Object>[]}),
        isEmpty,
      );
      expect(
        lemonadeLoadedModelsFromJson({
          'all_models_loaded': 'invalid',
          'model_loaded': 'stale-legacy-value',
        }),
        isNull,
      );
      expect(lemonadeLoadedModelsFromJson('invalid'), isNull);
    });

    test('refuses credential-bearing loopback without contacting it', () async {
      var calls = 0;
      final q = await LemonadeAdapter(
        environment: const {
          'LEMONADE_HOST': 'http://user:secret@localhost:13305',
        },
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
}
