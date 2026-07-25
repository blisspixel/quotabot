import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  group('LM Studio parsing', () {
    test('native split into installed and loaded', () {
      final r = lmStudioNativeFromJson({
        'data': [
          {
            'id': 'a',
            'state': 'loaded',
            'arch': 'llama',
            'quantization': 'Q4',
            'loaded_context_length': 4096,
          },
          {'id': 'b', 'state': 'not-loaded'},
          {'no': 'id'}, // skipped
        ],
      });
      expect(r!.installed.length, 2);
      expect(r.loaded.length, 1);
      expect(r.loaded.first.name, 'a');
      expect(r.loaded.first.quant, 'Q4');
      expect(r.loaded.first.context, 4096);
      // arch ("llama") is not a parameter size, so it must not fill the param
      // slot; LM Studio's v0 shape exposes no parameter count.
      expect(r.loaded.first.param, isNull);
    });

    test('native rejects an unexpected shape', () {
      expect(lmStudioNativeFromJson({'x': 1}), isNull);
      expect(lmStudioNativeFromJson('nope'), isNull);
    });

    test('v1 reads params, object quant, and the loaded instance context', () {
      final r = lmStudioV1FromJson({
        'models': [
          {
            'key': 'example/coder-8b',
            'size_bytes': 6326938154,
            'params_string': '7.5B',
            'quantization': {'name': 'Q4_K_M', 'bits_per_weight': 4},
            'max_context_length': 131072,
            'loaded_instances': [
              {
                'id': 'example/coder-8b',
                'config': {'context_length': 8192},
              },
            ],
          },
          {
            'key': 'example/embed-v1',
            'size_bytes': 84106624,
            'quantization': {'name': 'Q4_K_M'},
            'max_context_length': 2048,
            'loaded_instances': <Object>[],
          },
          {'no': 'key'}, // skipped
        ],
      });
      expect(r!.installed.length, 2);
      expect(r.loaded.length, 1);
      final loaded = r.loaded.single;
      expect(loaded.name, 'example/coder-8b');
      expect(loaded.param, '7.5B'); // a real parameter size, unlike v0
      expect(loaded.quant, 'Q4_K_M'); // from the object-shaped quantization
      expect(loaded.bytes, 6326938154);
      expect(loaded.context, 8192); // the loaded instance's running context
      // The not-loaded model falls back to its max context.
      final notLoaded =
          r.installed.firstWhere((m) => m.name == 'example/embed-v1');
      expect(notLoaded.context, 2048);
    });

    test('v1 rejects an unexpected shape', () {
      expect(lmStudioV1FromJson({'data': <Object>[]}), isNull);
      expect(lmStudioV1FromJson('nope'), isNull);
    });

    test('v1 reads the declared capability flags', () {
      // Shape captured from a real 0.4.0+ server: capabilities is an object
      // that carries only the flags it asserts.
      final r = lmStudioV1FromJson({
        'models': [
          {
            'key': 'example/vision-8b',
            'type': 'llm',
            'max_context_length': 131072,
            'loaded_instances': <Object>[],
            'capabilities': {
              'vision': true,
              'trained_for_tool_use': true,
              'reasoning': {
                'allowed_options': ['off', 'on'],
                'default': 'on',
              },
            },
          },
          {
            'key': 'example/text-8b',
            'loaded_instances': <Object>[],
            'capabilities': {'trained_for_tool_use': false},
          },
          {'key': 'example/embed-v1', 'loaded_instances': <Object>[]},
        ],
      })!;
      final vision =
          r.installed.firstWhere((m) => m.name.endsWith('vision-8b'));
      expect(vision.tools, isTrue);
      expect(vision.vision, isTrue);
      final text = r.installed.firstWhere((m) => m.name.endsWith('text-8b'));
      expect(text.tools, isFalse);
      // The object omits flags it does not assert, so vision stays undeclared
      // rather than becoming a denial quotabot cannot back.
      expect(text.vision, isNull);
      final embed = r.installed.firstWhere((m) => m.name.endsWith('embed-v1'));
      expect(embed.tools, isNull);
      expect(embed.vision, isNull);
    });

    test('v1 reads the model kind from its type', () {
      // v1 types a vision model as `llm` and only distinguishes an embedding
      // model, which is why vision comes from the capability flags instead.
      final r = lmStudioV1FromJson({
        'models': [
          {'key': 'gen', 'type': 'llm', 'loaded_instances': <Object>[]},
          {'key': 'embed', 'type': 'embedding', 'loaded_instances': <Object>[]},
          {'key': 'unknown', 'loaded_instances': <Object>[]},
        ],
      })!;
      expect(
        {for (final m in r.installed) m.name: m.embedding},
        {'gen': false, 'embed': true, 'unknown': null},
      );
    });

    test('v1 ignores a capability field that is not a declared flag', () {
      final r = lmStudioV1FromJson({
        'models': [
          {
            'key': 'drifted',
            'loaded_instances': <Object>[],
            'capabilities': {'vision': 'yes', 'trained_for_tool_use': 1},
          },
          {
            'key': 'drifted-shape',
            'loaded_instances': <Object>[],
            'capabilities': ['vision'],
          },
        ],
      })!;
      for (final m in r.installed) {
        expect(m.tools, isNull, reason: m.name);
        expect(m.vision, isNull, reason: m.name);
      }
    });

    test('v0 reads tool use from its list and vision from the model type', () {
      // v0 carries an exhaustive capabilities array plus a model type, where
      // `vlm` is a vision-language model.
      final r = lmStudioNativeFromJson({
        'data': [
          {
            'id': 'example/vision-8b',
            'type': 'vlm',
            'state': 'not-loaded',
            'capabilities': ['tool_use'],
          },
          {
            'id': 'example/text-8b',
            'type': 'llm',
            'state': 'not-loaded',
            'capabilities': <String>[],
          },
          {'id': 'example/unknown', 'state': 'not-loaded'},
        ],
      })!;
      final vision =
          r.installed.firstWhere((m) => m.name.endsWith('vision-8b'));
      expect(vision.tools, isTrue);
      expect(vision.vision, isTrue);
      final text = r.installed.firstWhere((m) => m.name.endsWith('text-8b'));
      // A present array that omits tool_use is real evidence of its absence.
      expect(text.tools, isFalse);
      expect(text.vision, isFalse);
      final unknown = r.installed.firstWhere((m) => m.name.endsWith('unknown'));
      expect(unknown.tools, isNull);
      expect(unknown.vision, isNull);
      expect(unknown.embedding, isNull);
      expect(vision.embedding, isFalse);
      expect(text.embedding, isFalse);
    });

    test('v0 reads the model kind from its plural embedding type', () {
      final r = lmStudioNativeFromJson({
        'data': [
          {'id': 'embed', 'type': 'embeddings', 'state': 'not-loaded'},
        ],
      })!;
      expect(r.installed.single.embedding, isTrue);
    });

    test('compat lists model names without load state', () {
      final r = lmStudioCompatFromJson({
        'data': [
          {'id': 'm1'},
          {'id': 'm2'},
          {'bad': 1},
        ],
      });
      expect(r!.map((m) => m.name), ['m1', 'm2']);
      // An OpenAI-compatible listing declares no capabilities, so no capability
      // filter can admit these entries.
      expect(r.first.tools, isNull);
      expect(r.first.vision, isNull);
      expect(lmStudioCompatFromJson(42), isNull);
    });
  });

  group('Ollama parsing', () {
    test('parses model details', () {
      final r = ollamaModelsFromJson({
        'models': [
          {
            'name': 'llama:8b',
            'size': 1000,
            'size_vram': 500,
            'details': {'parameter_size': '8B', 'quantization_level': 'Q4'},
          },
          {'bad': 1}, // skipped
        ],
      });
      expect(r.length, 1);
      expect(r.first.param, '8B');
      expect(r.first.quant, 'Q4');
      expect(r.first.cloud, isFalse);
      expect(ollamaModelsFromJson('x'), isEmpty);
      expect(ollamaModelsFromJson({'models': 'no'}), isEmpty);
    });

    test('reads the running context window from an /api/ps entry', () {
      // /api/ps reports context_length per loaded model; /api/tags does not.
      final r = ollamaModelsFromJson({
        'models': [
          {'name': 'llama:8b', 'size': 1000, 'context_length': 8192},
        ],
      });
      expect(r.single.context, 8192);
    });

    test('flags a -cloud model as cloud-offloaded, not on-device', () {
      final r = ollamaModelsFromJson({
        'models': [
          {'name': 'qwen3-coder:480b-cloud', 'size': 0},
          {'name': 'llama3.2:3b', 'size': 1000},
        ],
      });
      expect(r[0].cloud, isTrue);
      expect(r[1].cloud, isFalse);
    });

    test('the model list declares no capabilities on its own', () {
      final r = ollamaModelsFromJson({
        'models': [
          {'name': 'llama:8b', 'size': 1000, 'digest': 'sha256:abc'},
        ],
      });
      expect(r.single.tools, isNull);
      expect(r.single.vision, isNull);
      expect(r.single.digest, 'sha256:abc');
    });

    test('keeps only a usable digest, since it is a cache key', () {
      final r = ollamaModelsFromJson({
        'models': [
          {'name': 'a:1b', 'digest': '  '},
          {'name': 'b:1b', 'digest': 42},
          {'name': 'c:1b', 'digest': 'x' * 129},
          {'name': 'd:1b'},
        ],
      });
      expect(r.map((m) => m.digest), everyElement(isNull));
    });

    test('show reads declared capabilities and the model maximum context', () {
      // Shape captured from a real Ollama 0.24 daemon.
      final r = ollamaShowFromJson({
        'capabilities': ['completion', 'vision', 'tools'],
        'model_info': {
          'mistral3.context_length': 393216,
          // The pre-scaling training context describes something else and must
          // not be mistaken for the model's context window.
          'mistral3.rope.scaling.original_context_length': 8192,
          'general.parameter_count': 23572403200,
        },
      })!;
      expect(r.tools, isTrue);
      expect(r.vision, isTrue);
      expect(r.context, 393216);
    });

    test('show treats an absent capability as absent, not unknown', () {
      final r = ollamaShowFromJson({
        'capabilities': ['completion', 'tools', 'insert'],
        'model_info': {'qwen2.context_length': 32768},
      })!;
      expect(r.tools, isTrue);
      expect(r.vision, isFalse);
      expect(r.context, 32768);
    });

    test('show separates a text generator from an embedding model', () {
      final generator = ollamaShowFromJson({
        'capabilities': ['completion', 'tools'],
      })!;
      expect(generator.embedding, isFalse);
      // Every Ollama model that can generate declares `completion`; a list
      // without it is an embedding model.
      final embedder = ollamaShowFromJson({
        'capabilities': ['embedding'],
      })!;
      expect(embedder.embedding, isTrue);
      expect(embedder.tools, isFalse);
      // An empty list asserts nothing, so the kind stays unknown and the model
      // keeps its route rather than being removed on absent evidence.
      final silent = ollamaShowFromJson({'capabilities': <Object>[]})!;
      expect(silent.embedding, isNull);
    });

    test('show without a capability list leaves the model undeclared', () {
      expect(ollamaShowFromJson({'model_info': <String, Object?>{}}), isNull);
      expect(ollamaShowFromJson({'capabilities': 'tools'}), isNull);
      expect(ollamaShowFromJson('nope'), isNull);
    });

    test('show survives unusable context metadata', () {
      final r = ollamaShowFromJson({
        'capabilities': <Object>[],
        'model_info': {
          'llama.context_length': -1,
          'gemma.context_length': 'wide',
          'context_length': 4096, // not architecture-prefixed
        },
      })!;
      expect(r.tools, isFalse);
      expect(r.vision, isFalse);
      expect(r.context, isNull);
    });
  });

  group('localRuntimeQuota', () {
    test('idle when nothing is loaded', () {
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 0,
        installed: const [
          (
            name: 'a',
            bytes: null,
            vramBytes: null,
            param: null,
            quant: null,
            expiresAt: null,
            context: null,
            cloud: false,
            tools: null,
            vision: null,
            embedding: null,
            digest: null,
          ),
        ],
        loaded: const [],
      );
      expect(q.active, isFalse);
      expect(q.status, contains('idle'));
      expect(q.isLocal, isTrue);
    });

    test('builds rich status and detail lines when models are loaded', () {
      final now = nowEpoch();
      final installed = <LocalModel>[
        (
          name: 'a:8b',
          bytes: 2 * 1024 * 1024 * 1024,
          vramBytes: null,
          param: '8B',
          quant: 'Q4',
          expiresAt: null,
          context: null,
          cloud: false,
          tools: null,
          vision: null,
          embedding: null,
          digest: null,
        ),
        (
          name: 'b',
          bytes: 1024 * 1024 * 1024,
          vramBytes: null,
          param: null,
          quant: null,
          expiresAt: null,
          context: null,
          cloud: false,
          tools: null,
          vision: null,
          embedding: null,
          digest: null,
        ),
      ];
      final loaded = <LocalModel>[
        (
          name: 'a:8b',
          bytes: null,
          vramBytes: 4 * 1024 * 1024 * 1024,
          param: '8B',
          quant: 'Q4',
          expiresAt: now + 1800,
          context: 8192,
          cloud: false,
          tools: null,
          vision: null,
          embedding: null,
          digest: null,
        ),
        installed[1],
      ];
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 0,
        installed: installed,
        loaded: loaded,
        now: now,
      );
      expect(q.active, isTrue);
      expect(q.status, contains('loaded'));
      expect(q.details.any((d) => d.contains('VRAM')), isTrue);
      expect(q.details.any((d) => d.contains('ctx')), isTrue);
      expect(q.details.any((d) => d.contains('unloads in')), isTrue);
      expect(q.details.any((d) => d.contains('models loaded')), isTrue);
      expect(q.details.any((d) => d.contains('on disk')), isTrue);
    });

    test('carries cloud-offload through to the model inventory', () {
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 0,
        installed: const [
          (
            name: 'qwen3-coder:480b-cloud',
            bytes: null,
            vramBytes: null,
            param: null,
            quant: null,
            expiresAt: null,
            context: null,
            cloud: true,
            tools: null,
            vision: null,
            embedding: null,
            digest: null,
          ),
          (
            name: 'llama3.2:3b',
            bytes: 1000,
            vramBytes: null,
            param: null,
            quant: null,
            expiresAt: null,
            context: null,
            cloud: false,
            tools: null,
            vision: null,
            embedding: null,
            digest: null,
          ),
        ],
        loaded: const [],
      );
      final cloud = q.models.firstWhere((m) => m.id.endsWith('-cloud'));
      final onDevice = q.models.firstWhere((m) => m.id == 'llama3.2:3b');
      expect(cloud.cloudOffloaded, isTrue);
      expect(cloud.local, isTrue); // reachable via the local daemon
      expect(onDevice.cloudOffloaded, isFalse);
    });
  });
}
