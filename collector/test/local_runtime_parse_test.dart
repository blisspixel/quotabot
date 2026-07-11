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
    });

    test('native rejects an unexpected shape', () {
      expect(lmStudioNativeFromJson({'x': 1}), isNull);
      expect(lmStudioNativeFromJson('nope'), isNull);
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
