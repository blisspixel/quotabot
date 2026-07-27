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

    test('keeps reachable inventory beyond the old two-second deadline',
        () async {
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/api/tags':
            await Future<void>.delayed(const Duration(milliseconds: 2100));
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'slow-but-live:7b'},
                ],
              }),
              200,
            );
          case '/api/ps':
            return http.Response(jsonEncode({'models': <Object>[]}), 200);
          case '/api/show':
            return http.Response(
              jsonEncode({
                'capabilities': ['completion'],
              }),
              200,
            );
          default:
            return http.Response('unexpected', 404);
        }
      });

      final q = await OllamaAdapter(client: client).collect();

      expect(q.ok, isTrue);
      expect(q.models.single.id, 'slow-but-live:7b');
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
            expect(
              request.url.path,
              anyOf('/api/tags', '/api/ps', '/api/show'),
            );
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
        // Inventory, load state, and the one capability probe for the single
        // installed model, all against the configured loopback origin.
        expect(calls, 3, reason: host);
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

  group('OllamaAdapter capability enrichment', () {
    /// Answers the model-list endpoints with [installed] and nothing loaded,
    /// and `/api/show` from [show] keyed by the requested model name.
    MockClient runtime(
      List<Map<String, Object?>> installed,
      Map<String, Map<String, Object?>> show, {
      void Function(String model)? onShow,
    }) =>
        MockClient((request) async {
          switch (request.url.path) {
            case '/api/tags':
              return http.Response(jsonEncode({'models': installed}), 200);
            case '/api/ps':
              return http.Response(jsonEncode({'models': <Object>[]}), 200);
            case '/api/show':
              final model =
                  (jsonDecode(request.body) as Map)['model'] as String;
              onShow?.call(model);
              final body = show[model];
              if (body == null) return http.Response('not found', 404);
              return http.Response(jsonEncode(body), 200);
            default:
              return http.Response('unexpected', 404);
          }
        });

    test('fills declared capabilities and the cold model maximum context',
        () async {
      final q = await OllamaAdapter(
        capabilityCache: OllamaCapabilityCache(),
        client: runtime(
          [
            {'name': 'coder:32b', 'size': 1000, 'digest': 'sha256:a'},
            {'name': 'seer:24b', 'size': 2000, 'digest': 'sha256:b'},
          ],
          {
            'coder:32b': {
              'capabilities': ['completion', 'tools', 'insert'],
              'model_info': {'qwen2.context_length': 32768},
            },
            'seer:24b': {
              'capabilities': ['completion', 'vision', 'tools'],
              'model_info': {'mistral3.context_length': 393216},
            },
          },
        ),
      ).collect();

      final coder = q.models.firstWhere((m) => m.id == 'coder:32b');
      expect(coder.tools, isTrue);
      expect(coder.vision, isFalse);
      // /api/tags carries no context at all, so without this pass a
      // --min-context filter could never admit a cold Ollama model.
      expect(coder.contextTokens, 32768);
      final seer = q.models.firstWhere((m) => m.id == 'seer:24b');
      expect(seer.vision, isTrue);
      expect(seer.contextTokens, 393216);
    });

    test('a running context window still wins over the model maximum',
        () async {
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/api/tags':
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'coder:32b', 'digest': 'sha256:a'},
                ],
              }),
              200,
            );
          case '/api/ps':
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'coder:32b', 'context_length': 8192},
                ],
              }),
              200,
            );
          case '/api/show':
            return http.Response(
              jsonEncode({
                'capabilities': ['completion', 'tools'],
                'model_info': {'qwen2.context_length': 32768},
              }),
              200,
            );
          default:
            return http.Response('unexpected', 404);
        }
      });

      final q = await OllamaAdapter(
        capabilityCache: OllamaCapabilityCache(),
        client: client,
      ).collect();
      final coder = q.models.single;
      expect(coder.loaded, isTrue);
      expect(coder.tools, isTrue);
      // How the model is running now, not the maximum it could be loaded with.
      expect(coder.contextTokens, 8192);
    });

    test('an unreadable capability probe leaves the model undeclared',
        () async {
      final q = await OllamaAdapter(
        capabilityCache: OllamaCapabilityCache(),
        client: runtime(
          [
            {'name': 'coder:32b', 'size': 1000, 'digest': 'sha256:a'},
          ],
          const {}, // every probe 404s
        ),
      ).collect();

      // The inventory survives intact; only the capability claim is withheld.
      expect(q.ok, isTrue);
      expect(q.models.single.id, 'coder:32b');
      expect(q.models.single.sizeBytes, 1000);
      expect(q.models.single.tools, isNull);
      expect(q.models.single.vision, isNull);
    });

    test('a cached digest is not probed again on the next read', () async {
      final probed = <String>[];
      final cache = OllamaCapabilityCache();
      final client = runtime(
        [
          {'name': 'coder:32b', 'digest': 'sha256:a'},
        ],
        {
          'coder:32b': {
            'capabilities': ['completion', 'tools'],
            'model_info': <String, Object?>{},
          },
        },
        onShow: probed.add,
      );

      final first =
          await OllamaAdapter(capabilityCache: cache, client: client).collect();
      final second =
          await OllamaAdapter(capabilityCache: cache, client: client).collect();

      expect(probed, ['coder:32b'], reason: 'the second read reuses the cache');
      expect(first.models.single.tools, isTrue);
      expect(second.models.single.tools, isTrue);
      expect(cache.length, 1);
    });

    test('a model with no digest is never cached under another identity',
        () async {
      final probed = <String>[];
      final cache = OllamaCapabilityCache();
      final client = runtime(
        [
          {'name': 'coder:32b'},
        ],
        {
          'coder:32b': {
            'capabilities': ['completion', 'tools'],
          },
        },
        onShow: probed.add,
      );

      await OllamaAdapter(capabilityCache: cache, client: client).collect();
      await OllamaAdapter(capabilityCache: cache, client: client).collect();

      expect(probed, ['coder:32b', 'coder:32b']);
      expect(cache.length, 0);
    });

    test('a re-pulled tag gets a fresh probe under its new digest', () async {
      final cache = OllamaCapabilityCache();
      Future<ProviderQuota> read(String digest, List<String> capabilities) =>
          OllamaAdapter(
            capabilityCache: cache,
            client: runtime(
              [
                {'name': 'coder:32b', 'digest': digest},
              ],
              {
                'coder:32b': {'capabilities': capabilities},
              },
            ),
          ).collect();

      final before = await read('sha256:a', ['completion']);
      final after = await read('sha256:b', ['completion', 'vision']);

      expect(before.models.single.vision, isFalse);
      expect(after.models.single.vision, isTrue);
    });

    test('probing is capped so a large library cannot run unbounded', () async {
      final probed = <String>[];
      final installed = [
        for (var i = 0; i < OllamaAdapter.maxCapabilityProbes + 5; i++)
          {'name': 'model:$i', 'digest': 'sha256:$i'},
      ];
      final q = await OllamaAdapter(
        capabilityCache: OllamaCapabilityCache(),
        client: runtime(
          installed,
          {
            for (final m in installed)
              m['name'] as String: {
                'capabilities': ['completion', 'tools'],
              },
          },
          onShow: probed.add,
        ),
      ).collect();

      expect(probed, hasLength(OllamaAdapter.maxCapabilityProbes));
      // Every model still appears; only the surplus stays undeclared.
      expect(q.models, hasLength(installed.length));
      expect(q.models.where((m) => m.tools == true),
          hasLength(OllamaAdapter.maxCapabilityProbes));
      expect(q.models.where((m) => m.tools == null), hasLength(5));
    });

    test('failed early probes do not starve later models on refresh', () async {
      final cache = OllamaCapabilityCache();
      final installed = [
        for (var i = 0; i < OllamaAdapter.maxCapabilityProbes + 2; i++)
          {'name': 'model:$i', 'digest': 'sha256:$i'},
      ];
      final probed = <String>[];
      final client = runtime(
        installed,
        {
          for (var i = OllamaAdapter.maxCapabilityProbes;
              i < installed.length;
              i++)
            'model:$i': {
              'capabilities': ['completion', 'tools'],
            },
        },
        onShow: probed.add,
      );

      final first = await OllamaAdapter(
        capabilityCache: cache,
        client: client,
      ).collect();
      final second = await OllamaAdapter(
        capabilityCache: cache,
        client: client,
      ).collect();

      expect(first.models.where((m) => m.tools == true), isEmpty);
      expect(
        second.models.skip(OllamaAdapter.maxCapabilityProbes),
        everyElement(
          isA<ModelInfo>().having((m) => m.tools, 'tools', isTrue),
        ),
      );
      expect(probed, contains('model:${OllamaAdapter.maxCapabilityProbes}'));
      expect(
          probed, contains('model:${OllamaAdapter.maxCapabilityProbes + 1}'));
    });
  });
}
