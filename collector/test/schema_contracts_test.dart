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
            models: const [
              ModelInfo(id: 'qwen2.5-coder:7b', local: true),
            ],
          ).toJson(),
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
                'loaded': 'false',
                'size_bytes': -1,
                'vram_bytes': 'large',
              },
            ],
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
          r'$.providers[2].models[1].loaded must be a boolean',
          r'$.providers[2].models[1].size_bytes must be a non-negative integer',
          r'$.providers[2].models[1].vram_bytes must be a non-negative integer',
        ]),
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
