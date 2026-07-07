import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

LocalModel _m(
  String name, {
  int? bytes,
  String? param,
  String? quant,
  int? vramBytes,
  int? expiresAt,
  int? context,
}) =>
    (
      name: name,
      bytes: bytes,
      param: param,
      quant: quant,
      vramBytes: vramBytes,
      expiresAt: expiresAt,
      context: context,
    );

void main() {
  group('localRuntimeQuota', () {
    test('reports a loaded model in use, with detail', () {
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 100,
        installed: [
          _m('qwen3-coder:latest', bytes: 4 * 1024 * 1024 * 1024),
          _m('llama3:8b', bytes: 5 * 1024 * 1024 * 1024),
          _m('phi3:mini', bytes: 2 * 1024 * 1024 * 1024),
        ],
        loaded: [
          _m(
            'qwen3-coder:latest',
            param: '7B',
            quant: 'Q4_K_M',
            vramBytes: 4 * 1024 * 1024 * 1024,
          ),
        ],
      );
      expect(q.kind, ProviderQuotaKind.local);
      expect(q.active, isTrue);
      expect(q.windows, isEmpty);
      expect(q.account, '3 models');
      expect(q.status, contains('qwen3-coder'));
      expect(q.status, contains('7B'));
      expect(q.status, contains('Q4_K_M'));
      // Detail lines include VRAM and disk usage.
      expect(q.details.any((d) => d.contains('VRAM')), isTrue);
      expect(q.details.any((d) => d.contains('on disk')), isTrue);
    });

    test('exposes each installed model in the registry shape', () {
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 100,
        installed: [
          _m('qwen3-coder:latest', bytes: 4 * 1024 * 1024 * 1024),
          _m('llama3:8b', bytes: 5 * 1024 * 1024 * 1024),
        ],
        loaded: [
          _m(
            'qwen3-coder:latest',
            quant: 'Q4_K_M',
            vramBytes: 4 * 1024 * 1024 * 1024,
            context: 32768,
          ),
        ],
      );
      expect(q.models, hasLength(2));
      final loaded = q.models.firstWhere((m) => m.id == 'qwen3-coder:latest');
      expect(loaded.local, isTrue);
      expect(loaded.loaded, isTrue);
      expect(loaded.vramBytes, 4 * 1024 * 1024 * 1024);
      expect(loaded.contextTokens, 32768);
      final idle = q.models.firstWhere((m) => m.id == 'llama3:8b');
      expect(idle.loaded, isFalse);
      expect(idle.sizeBytes, 5 * 1024 * 1024 * 1024);
      // Models survive a snapshot round-trip.
      final back = ProviderQuota.fromJson(q.toJson());
      expect(back.models.map((m) => m.id), q.models.map((m) => m.id));
      expect(
        back.models.firstWhere((m) => m.id == 'qwen3-coder:latest').loaded,
        isTrue,
      );
    });

    test('reports idle with an installed count when nothing is loaded', () {
      final q = localRuntimeQuota(
        id: 'lmstudio',
        name: 'LM Studio',
        asOf: 0,
        installed: [_m('a'), _m('b')],
        loaded: const [],
      );
      expect(q.active, isFalse);
      expect(q.status, '2 installed, idle');
    });

    test('singularizes a single installed model', () {
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 0,
        installed: [_m('solo:latest')],
        loaded: const [],
      );
      expect(q.account, '1 model');
    });

    test('round-trips status, active, and details through json', () {
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 0,
        installed: [_m('m:1')],
        loaded: [_m('m:1', param: '3B')],
      );
      final back = ProviderQuota.fromJson(q.toJson());
      expect(back.active, isTrue);
      expect(back.status, q.status);
      expect(back.details, q.details);
      expect(back.isLocal, isTrue);
    });

    test('formats context, VRAM, and an unload countdown', () {
      const now = 1000;
      final q = localRuntimeQuota(
        id: 'lmstudio',
        name: 'LM Studio',
        asOf: now,
        now: now,
        installed: [_m('a'), _m('b')],
        loaded: [
          _m(
            'a',
            vramBytes: 4 * 1024 * 1024 * 1024,
            context: 8192,
            expiresAt: now + 600,
          ),
        ],
      );
      final joined = q.details.join(' | ');
      expect(joined, contains('VRAM'));
      expect(joined, contains('ctx'));
      expect(joined, contains('unloads in'));
    });

    test('renders small models in MB and counts multiple loaded', () {
      final q = localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: 0,
        installed: [_m('a', bytes: 300 * 1024 * 1024)],
        loaded: [
          _m('a', vramBytes: 300 * 1024 * 1024),
          _m('b'),
        ],
      );
      final joined = q.details.join(' | ');
      expect(joined, contains('MB'));
      expect(joined, contains('2 models loaded'));
    });
  });

  group('ollamaModelsFromJson', () {
    test('parses names, size, vram, and details', () {
      final models = ollamaModelsFromJson({
        'models': [
          {
            'name': 'qwen3-coder:latest',
            'size': 4500000000,
            'size_vram': 4000000000,
            'details': {'parameter_size': '7B', 'quantization_level': 'Q4_K_M'},
          },
          {'noname': true}, // skipped
        ],
      });
      expect(models.length, 1);
      expect(models.first.name, 'qwen3-coder:latest');
      expect(models.first.bytes, 4500000000);
      expect(models.first.param, '7B');
      expect(models.first.quant, 'Q4_K_M');
    });

    test('is empty for an unexpected shape', () {
      expect(ollamaModelsFromJson({'models': 'nope'}), isEmpty);
      expect(ollamaModelsFromJson('x'), isEmpty);
    });
  });

  group('lmStudio parsers', () {
    test('native parse separates loaded from installed', () {
      final r = lmStudioNativeFromJson({
        'data': [
          {'id': 'a', 'state': 'loaded', 'quantization': 'Q4', 'arch': 'qwen2'},
          {'id': 'b', 'state': 'not-loaded'},
        ],
      })!;
      expect(r.installed.length, 2);
      expect(r.loaded.length, 1);
      expect(r.loaded.first.name, 'a');
      expect(r.loaded.first.quant, 'Q4');
    });

    test('native parse returns null for a bad shape', () {
      expect(lmStudioNativeFromJson({'nope': 1}), isNull);
    });

    test('compat parse lists model ids with no load state', () {
      final list = lmStudioCompatFromJson({
        'data': [
          {'id': 'm1'},
          {'id': 'm2'},
        ],
      })!;
      expect(list.map((m) => m.name), ['m1', 'm2']);
      expect(lmStudioCompatFromJson({'data': 'x'}), isNull);
    });
  });

  group('localBaseUrl', () {
    test('defaults when empty or null', () {
      expect(localBaseUrl(null, 11434), 'http://127.0.0.1:11434');
      expect(localBaseUrl('   ', 1234), 'http://127.0.0.1:1234');
    });

    test('adds http scheme and default port to a bare host', () {
      expect(localBaseUrl('myhost', 11434), 'http://myhost:11434');
    });

    test('keeps an explicit port', () {
      expect(localBaseUrl('host:9999', 11434), 'http://host:9999');
      expect(localBaseUrl('http://h:8080', 1234), 'http://h:8080');
    });

    test('respects https without forcing the local port', () {
      expect(localBaseUrl('https://remote', 11434), 'https://remote');
    });
  });
}
