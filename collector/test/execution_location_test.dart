import 'package:quotabot_collector/adapters/lemonade.dart';
import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/local_runtime_config.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:quotabot_collector/schema_contracts.dart';
import 'package:test/test.dart';

void main() {
  const now = 1760000000;

  ProviderQuota ollama(List<Map<String, Object?>> installed,
          [List<Map<String, Object?>> loaded = const []]) =>
      localRuntimeQuota(
        id: 'ollama',
        name: 'Ollama',
        asOf: now,
        installed: ollamaModelsFromJson({'models': installed}),
        loaded: ollamaModelsFromJson({'models': loaded}),
      );

  Map<String, dynamic> snapshotOf(ProviderQuota quota) => {
        'schema': quotabotV1SchemaId,
        'generated_at': now,
        'providers': [quota.toJson()],
      };

  test('loopback, load, residency, and a host GPU counter stay unknown', () {
    expect(isLoopbackRuntimeHost('127.0.0.1'), isTrue);
    expect(isLoopbackRuntimeHost('http://localhost:11434'), isTrue);
    for (final host in [
      '172.22.64.1',
      'host.docker.internal',
      'tunnel.example',
    ]) {
      expect(isLoopbackRuntimeHost(host), isFalse, reason: host);
    }

    final quota = ollama([
      {'name': 'llama3:8b', 'size': 1000, 'context_length': 8192}
    ], [
      {'name': 'llama3:8b', 'size_vram': 8000000000, 'context_length': 4096}
    ]);
    final model = quota.models.single;
    expect(model.loaded, isTrue);
    expect(model.vramBytes, 8000000000);
    expect(model.executionLocation, ExecutionLocation.unknown);
    expect(model.toJson()['execution_location'], 'unknown');
    expect(model.toJson(), isNot(contains('on_device')));
    expect(isLocalRuntimeAvailableAt(quota, now), isTrue);
    expect(
      buildModelRegistry([quota], now,
          requirements: const ModelRequirements(
            budgetPolicy: ModelBudgetPolicy.local,
          )),
      hasLength(1),
    );

    final cold = ollama([
      {'name': 'llama3:8b', 'size': 1000}
    ]);
    final withGpu = ProviderQuota.fromJson({
      ...cold.toJson(),
      'local_hardware': const LocalHardwareInfo(
        asOf: now,
        gpuMemoryTotalBytes: 16 * 1024 * 1024 * 1024,
        gpuMemoryAvailableBytes: 12 * 1024 * 1024 * 1024,
        gpuUtilizationPercent: 90,
        gpuCount: 1,
      ).toJson(),
    });
    final fit = localModelHardwareFit(
      withGpu.models.single,
      withGpu.localHardware,
    );
    expect(fit.status, LocalHardwareFitStatus.comfortable);
    expect(fit.basis, 'gpu_memory');
    expect(withGpu.models.single.executionLocation, ExecutionLocation.unknown);
    expect(
      buildModelRegistry([withGpu], now).single.toJson(),
      containsPair('execution_location', 'unknown'),
    );
    expect(
      buildModelRegistry([withGpu], now).single.toJson(),
      containsPair('hardware_fit', 'comfortable'),
    );
  });

  test('LM Studio loaded context and GPU offload are not a device claim', () {
    final inventory = lmStudioV1FromJson({
      'models': [
        {
          'type': 'llm',
          'key': 'google/gemma-test',
          'max_context_length': 262144,
          'size_bytes': 1000,
          'loaded_instances': [
            {
              'id': 'instance-1',
              'config': {
                'context_length': 4096,
                'offload_kv_cache_to_gpu': true,
              },
            },
          ],
          'capabilities': {
            'vision': true,
            'trained_for_tool_use': true,
            'reasoning': {
              'allowed_options': ['on'],
              'default': 'on',
            },
          },
        },
      ],
    });
    final quota = localRuntimeQuota(
      id: 'lmstudio',
      name: 'LM Studio',
      asOf: now,
      installed: inventory!.installed,
      loaded: inventory.loaded,
    );
    final model = quota.models.single;
    expect(model.contextTokens, 4096);
    expect(model.reasoning, isNull);
    expect(model.loaded, isTrue);
    expect(model.cloudOffloaded, isFalse);
    expect(model.executionLocation, ExecutionLocation.unknown);
    expect(model.toJson().containsKey('on_device'), isFalse);
    expect(jsonContainsDevice(model.toJson()), isFalse);
  });

  test('cloud and upstream routes publish remote and stay out of local budget',
      () {
    final cloud = ollama([
      {'name': 'qwen:cloud', 'size': 1000}
    ]);
    expect(cloud.models.single.executionLocation, ExecutionLocation.remote);
    expect(cloud.models.single.toJson()['execution_location'], 'remote');
    expect(isLocalRuntimeAvailableAt(cloud, now), isFalse);

    final upstream = ollama([
      {
        'name': 'alias:7b',
        'remote_host': 'http://10.1.2.3:11434',
        'remote_model': 'private',
      }
    ]);
    expect(upstream.models.single.upstreamRouting, UpstreamRouting.declared);
    expect(upstream.models.single.executionLocation, ExecutionLocation.remote);
    expect(upstream.models.single.toJson(), isNot(contains('10.1.2.3')));
    expect(upstream.models.single.toJson(), isNot(contains('private')));
    expect(
      buildModelRegistry([upstream], now,
          requirements: const ModelRequirements(
            budgetPolicy: ModelBudgetPolicy.local,
          )),
      isEmpty,
    );
  });

  test('a cached on-device claim cannot become stored proof', () {
    final quota = ollama([
      {'name': 'llama3:8b', 'size': 1000}
    ]);
    final raw = quota.toJson();
    (raw['models'] as List).single['execution_location'] = 'on_device';
    (raw['models'] as List).single['vram_bytes'] = 8000000000;
    final decoded = ProviderQuota.fromJson(raw);
    expect(decoded.models.single.executionLocation, ExecutionLocation.unknown);
    expect(decoded.models.single.toJson()['execution_location'], 'unknown');
    expect(sanitizeProviderQuota(decoded).models.single.executionLocation,
        ExecutionLocation.unknown);

    final hostileRemote = quota.toJson();
    (hostileRemote['models'] as List).single['execution_location'] = 'remote';
    expect(
      ProviderQuota.fromJson(hostileRemote).models.single.executionLocation,
      ExecutionLocation.unknown,
    );

    final snapshot = snapshotOf(quota);
    expect(validateQuotabotV1Snapshot(snapshot), isEmpty);
    (((snapshot['providers'] as List).single as Map)['models'] as List)
        .single['execution_location'] = 'on_device';
    expect(
      validateQuotabotV1Snapshot(snapshot),
      contains(contains('execution_location')),
    );
    expect(
      ((listModelsOutputSchema.toJson()['properties'] as Map)['models']
          as Map)['items']['properties']['execution_location']['enum'],
      ExecutionLocation.wireValues,
    );
  });

  test('incomplete Lemonade composites stay omitted and complete ones unknown',
      () {
    final incomplete = lemonadeModelsFromJson({
      'data': [
        {
          'id': 'test-composite',
          'recipe': 'collection.router',
          'downloaded': true,
          'labels': ['chat'],
          'components': ['local-chat'],
        }
      ],
    });
    expect(incomplete, isEmpty);

    final complete = lemonadeModelsFromJson({
      'data': [
        {
          'id': 'test-composite',
          'recipe': 'collection.router',
          'downloaded': true,
          'labels': ['chat'],
          'components': ['local-chat'],
          'models': [
            {
              'id': 'local-chat',
              'recipe': 'llamacpp',
              'downloaded': true,
              'labels': ['chat'],
              'components': <String>[],
            }
          ],
        }
      ],
    });
    final quota = localRuntimeQuota(
      id: 'lemonade',
      name: 'Lemonade',
      asOf: now,
      installed: complete!,
      loaded: const [],
    );
    expect(quota.models.single.cloudOffloaded, isFalse);
    expect(quota.models.single.executionLocation, ExecutionLocation.unknown);
    expect(isLocalRuntimeAvailableAt(quota, now), isTrue);
    expect(quota.models.single.toJson()['execution_location'], 'unknown');
  });

  test('catalog models do not publish an execution location', () {
    expect(
      const ModelInfo(id: 'claude-opus').toJson(),
      isNot(contains('execution_location')),
    );
  });
}

bool jsonContainsDevice(Map<String, dynamic> json) {
  final encoded = json.toString();
  return encoded.contains('deviceIdentifier') || encoded.contains('on_device');
}
