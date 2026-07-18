import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/schema_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('quotabot.v1 schema contract', () {
    test('exports a frozen JSON Schema 2020-12 document', () {
      expect(quotabotV1JsonSchema[r'$schema'],
          'https://json-schema.org/draft/2020-12/schema');
      expect(quotabotV1JsonSchema[r'$id'], quotabotV1SchemaUri);
      expect(quotabotV1JsonSchema['additionalProperties'], isTrue);
      expect(quotabotV1JsonSchema['required'],
          containsAll(['schema', 'generated_at', 'providers']));
      final defs = quotabotV1JsonSchema[r'$defs'] as Map<String, Object?>;
      final provider = defs['providerQuota'] as Map<String, Object?>;
      final properties = provider['properties'] as Map<String, Object?>;
      expect(properties, contains('source_class'));
      final sourceClass = properties['source_class'] as Map<String, Object?>;
      expect(sourceClass['enum'], ProviderSourceClass.wireValues);
      expect(properties, contains('drift_reason'));
      expect(properties, contains('drift_observed_at'));
      final driftReason = properties['drift_reason'] as Map<String, Object?>;
      expect(driftReason['pattern'], r'\S');
    });

    test('accepts additive fields while enforcing stable required fields', () {
      final snapshot = {
        'schema': quotabotV1SchemaId,
        'generated_at': 1782000000,
        'future_root': true,
        'providers': [
          ProviderQuota(
            provider: 'claude',
            displayName: 'Claude',
            account: 'work@example.com',
            plan: 'max',
            source: providerQuotaManualSource,
            asOf: 1782000000,
            pipeHealth: providerPipeHealthThrottled,
            httpStatus: 429,
            retryAfterSeconds: 120,
            windows: [
              QuotaWindow(
                label: 'weekly',
                usedPercent: 42,
                resetsAt: 1782604800,
              ),
            ],
          ).toJson()
            ..['future_provider'] = 'ok'
            ..['windows'] = [
              {
                'label': 'weekly',
                'used_percent': 42,
                'resets_at': 1782604800,
                'future_window': 'ok',
              },
            ],
          ProviderQuota(
            provider: 'ollama',
            displayName: 'Ollama',
            account: '2 models',
            plan: 'local',
            kind: ProviderQuotaKind.local,
            asOf: 1782000000,
            localHardware: const LocalHardwareInfo(
              asOf: 1782000000,
              systemMemoryTotalBytes: 16 * 1024 * 1024 * 1024,
              systemMemoryAvailableBytes: 8 * 1024 * 1024 * 1024,
              gpuMemoryTotalBytes: 8 * 1024 * 1024 * 1024,
              gpuMemoryAvailableBytes: 6 * 1024 * 1024 * 1024,
              gpuCount: 1,
            ),
            models: const [
              ModelInfo(id: 'qwen2.5-coder:7b', local: true),
            ],
          ).toJson(),
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'work@example.com',
            asOf: 1782000000,
            windows: [
              QuotaWindow(label: 'weekly', usedPercent: 55),
            ],
          )
              .withProviderDrift('weekly reset moved earlier', 1782000060)
              .toJson(),
          ProviderQuota(
            provider: 'antigravity',
            displayName: 'Antigravity',
            account: 'work@example.com',
            asOf: 1782000000,
            windows: [
              QuotaWindow(label: '5h', usedPercent: 10),
            ],
            models: const [
              ModelInfo(id: 'temp-promo', quotaIncludedUntil: 1785000000),
            ],
          ).toJson(),
        ],
      };

      expect(validateQuotabotV1Snapshot(snapshot), isEmpty);
    });

    test('rejects a present but blank provider drift reason', () {
      final snapshot = {
        'schema': quotabotV1SchemaId,
        'generated_at': 1782000000,
        'providers': [
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'default',
            asOf: 1782000000,
            windows: [QuotaWindow(label: 'weekly', usedPercent: 50)],
            driftReason: '   ',
            driftObservedAt: 1782000010,
          ).toJson(),
        ],
      };

      expect(
        validateQuotabotV1Snapshot(snapshot),
        contains(r'$.providers[0].drift_reason must not be blank'),
      );
    });

    test('keeps source class additive but rejects unknown present values', () {
      final legacy = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'default',
        asOf: 1782000000,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 50)],
      ).toJson()
        ..remove('source_class');
      expect(
        validateQuotabotV1Snapshot({
          'schema': quotabotV1SchemaId,
          'generated_at': 1782000000,
          'providers': [legacy],
        }),
        isEmpty,
      );

      legacy['source_class'] = 'future_class';
      expect(
        validateQuotabotV1Snapshot({
          'schema': quotabotV1SchemaId,
          'generated_at': 1782000000,
          'providers': [legacy],
        }),
        contains(
          r'$.providers[0].source_class must be one of authoritative_live, this_machine_fallback, passive_local_evidence, local_runtime, status_only, manual',
        ),
      );
    });

    test('rejects contract-breaking snapshots with precise paths', () {
      final errors = validateQuotabotV1Snapshot({
        'schema': 'quotabot.v2',
        'generated_at': -1,
        'providers': [
          {
            'provider': '',
            'display_name': 'Broken',
            'account': 'default',
            'kind': 'subscription',
            'ok': true,
            'as_of': 1782000000,
            'stale': false,
            'windows': [
              {'label': '', 'used_percent': 140},
            ],
          },
        ],
      });

      expect(
        errors,
        containsAll([
          r'$.schema must be "quotabot.v1"',
          r'$.generated_at must be a non-negative integer',
          r'$.providers[0].provider must be a non-empty string',
          r'$.providers[0].windows[0].label must be a non-empty string',
          r'$.providers[0].windows[0].used_percent must be a finite number from 0 to 100',
        ]),
      );
    });

    test('rejects non-object and non-array structural violations', () {
      final errors = validateQuotabotV1Snapshot({
        'schema': quotabotV1SchemaId,
        'profile': 123,
        'account_filter': false,
        'error': ['bad'],
        'generated_at': 1782000000,
        'providers': [
          'bad-provider',
          {
            'provider': 'codex',
            'display_name': 'Codex',
            'account': 'default',
            'kind': 'subscription',
            'ok': true,
            'as_of': 1782000000,
            'stale': false,
            'pipe_health': 'overheated',
            'http_status': 99,
            'retry_after_seconds': -1,
            'suspect': false,
            'drift_reason': 42,
            'drift_observed_at': -1,
            'windows': 'bad-windows',
            'models': 'bad-models',
          },
          {
            'provider': 'ollama',
            'display_name': 'Ollama',
            'account': 'local',
            'kind': 'local',
            'ok': true,
            'as_of': 1782000000,
            'stale': false,
            'windows': [
              'bad-window',
              {
                'label': 'raw',
                'used': -1,
                'limit': 0,
              },
            ],
            'models': [
              'bad-model',
              {
                'id': '',
                'context_tokens': 0,
                'max_output_tokens': 'many',
                'tools': 'yes',
                'vision': 'no',
                'display_name': 1,
                'reasoning': false,
                'tier': 2,
                'quant': 3,
                'quota_included_until': -5,
                'local': 'true',
                'cloud_offloaded': 'false',
                'loaded': 'false',
                'size_bytes': -1,
                'vram_bytes': 'large',
              },
            ],
            'local_hardware': {
              'as_of': -1,
              'system_memory_total_bytes': 100,
              'system_memory_available_bytes': 200,
              'gpu_memory_total_bytes': 0,
              'gpu_memory_available_bytes': -1,
              'gpu_count': 65,
            },
          },
        ],
      });

      expect(
        errors,
        containsAll([
          r'$.profile must be a string',
          r'$.account_filter must be a string',
          r'$.error must be a string',
          r'$.providers[0] must be an object',
          r'$.providers[1].windows must be an array',
          r'$.providers[1].models must be an array',
          r'$.providers[1].suspect must be a string',
          r'$.providers[1].drift_reason must be a string',
          r'$.providers[1].drift_observed_at must be a non-negative integer',
          r'$.providers[1].pipe_health must be one of healthy, throttled, degraded, no_data',
          r'$.providers[1].http_status must be an integer from 100 to 599',
          r'$.providers[1].retry_after_seconds must be a non-negative integer',
          r'$.providers[2].windows[0] must be an object',
          r'$.providers[2].windows[1].used must be a finite non-negative number',
          r'$.providers[2].windows[1].limit must be a finite number greater than 0',
          r'$.providers[2].models[0] must be an object',
          r'$.providers[2].models[1].id must be a non-empty string',
          r'$.providers[2].models[1].context_tokens must be a positive integer',
          r'$.providers[2].models[1].max_output_tokens must be a positive integer',
          r'$.providers[2].models[1].tools must be a boolean',
          r'$.providers[2].models[1].vision must be a boolean',
          r'$.providers[2].models[1].display_name must be a string',
          r'$.providers[2].models[1].reasoning must be a string',
          r'$.providers[2].models[1].tier must be a string',
          r'$.providers[2].models[1].quant must be a string',
          r'$.providers[2].models[1].quota_included_until must be a non-negative integer',
          r'$.providers[2].models[1].local must be a boolean',
          r'$.providers[2].models[1].cloud_offloaded must be a boolean',
          r'$.providers[2].models[1].loaded must be a boolean',
          r'$.providers[2].models[1].size_bytes must be a non-negative integer',
          r'$.providers[2].models[1].vram_bytes must be a non-negative integer',
          r'$.providers[2].local_hardware.as_of must be a non-negative integer',
          r'$.providers[2].local_hardware.gpu_memory_total_bytes must be a positive integer',
          r'$.providers[2].local_hardware.gpu_memory_available_bytes must be a non-negative integer',
          r'$.providers[2].local_hardware.gpu_count must be an integer from 0 to 64',
          r'$.providers[2].local_hardware.system_memory_available_bytes must not exceed system_memory_total_bytes',
        ]),
      );
    });

    test('rejects local hardware evidence on a subscription provider', () {
      final snapshot = {
        'schema': quotabotV1SchemaId,
        'generated_at': 1782000000,
        'providers': [
          {
            'provider': 'codex',
            'display_name': 'Codex',
            'account': 'default',
            'kind': 'subscription',
            'ok': true,
            'as_of': 1782000000,
            'stale': false,
            'windows': const <Object?>[],
            'local_hardware': {
              'as_of': 1782000000,
              'system_memory_total_bytes': 1024,
            },
          },
        ],
      };

      expect(
        validateQuotabotV1Snapshot(snapshot),
        contains(
          r'$.providers[0].local_hardware requires kind=local',
        ),
      );
    });

    test('accepts decoded maps that are not statically typed', () {
      final errors = validateQuotabotV1Snapshot({
        'schema': quotabotV1SchemaId,
        'generated_at': 1782000000,
        'providers': <Map<Object?, Object?>>[
          {
            'provider': 'codex',
            'display_name': 'Codex',
            'account': 'default',
            'kind': 'subscription',
            'ok': true,
            'as_of': 1782000000,
            'stale': false,
            'windows': <Map<Object?, Object?>>[
              {'label': 'weekly', 'used_percent': 30},
            ],
            'models': <Map<Object?, Object?>>[
              {'id': 'codex-test'},
            ],
          },
        ],
      });

      expect(errors, isEmpty);
    });
  });
}
