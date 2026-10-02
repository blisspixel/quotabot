import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/lemonade.dart';
import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _maximum = 131072;
const _observed = 'observed-model';
const _other = 'other-model';

http.Response _json(Object data) => http.Response(jsonEncode(data), 200);

http.Response _loadedList(String runtime, List<Object?> models) =>
    _json({runtime == 'ollama' ? 'models' : 'all_models_loaded': models});

Map<String, Object?> _loadedRow(String runtime) => runtime == 'ollama'
    ? {'name': _observed, 'context_length': 8192}
    : {
        'model_name': _observed,
        'recipe_options': {'ctx_size': 8192}
      };

Future<ProviderQuota> _collect(
  String runtime,
  http.Response? loadedResponse,
) async {
  final client = MockClient((request) async {
    if (request.url.path == '/api/tags') {
      return _json({
        'models': [
          for (final name in [_observed, _other]) {'name': name},
        ]
      });
    }
    if (request.url.path.endsWith('/models')) {
      return _json({
        'data': [
          for (final name in [_observed, _other])
            {'id': name, 'max_context_window': _maximum},
        ]
      });
    }
    if (request.url.path == '/api/show') {
      return _json({
        'capabilities': ['completion', 'tools'],
        'model_info': {'test.context_length': _maximum},
      });
    }
    if (loadedResponse == null) {
      throw const SocketException('synthetic loaded-state failure');
    }
    return loadedResponse;
  });
  try {
    return runtime == 'ollama'
        ? await OllamaAdapter(
                client: client,
                environment: const {},
                capabilityCache: OllamaCapabilityCache())
            .collect()
        : await LemonadeAdapter(client: client, environment: const {})
            .collect();
  } finally {
    client.close();
  }
}

Future<ProviderQuota> _collectLm(String path, Object data) async {
  final client = MockClient((request) async => request.url.path == path
      ? _json(data)
      : http.Response('unsupported', 404));
  try {
    return await LmStudioAdapter(client: client, environment: const {})
        .collect();
  } finally {
    client.close();
  }
}

void _expectUnknownInventory(ProviderQuota quota) {
  expect(quota.ok, isTrue);
  expect(quota.error, isNull);
  expect(quota.active, isFalse);
  expect(quota.status, 'reachable - load state unknown');
  expect(quota.localGenerationReadiness, isNull);
  expect(quota.models, hasLength(2));
  for (final model in quota.models) {
    expect(model.loaded, isFalse, reason: model.id);
    expect(model.loadedStateKnown, isFalse, reason: model.id);
    expect(model.contextTokens, isNull, reason: model.id);
  }
  expect(isLocalRuntimeReachableAt(quota, quota.asOf), isTrue);
  expect(isLocalRuntimeAvailableAt(quota, quota.asOf), isTrue);
}

void main() {
  for (final runtime in ['ollama', 'lemonade']) {
    for (final failure in <http.Response?>[
      null,
      http.Response('unavailable', 503),
      http.Response('invalid JSON', 200),
      _json({'models': 'invalid', 'all_models_loaded': 'invalid'}),
      _loadedList(runtime, [
        null,
        42,
        {},
        {runtime == 'ollama' ? 'name' : 'model_name': ' '}
      ]),
    ]) {
      test(
          '$runtime preserves unknown residency after invalid loaded probe '
          '${failure?.body ?? 'transport failure'}', () async {
        _expectUnknownInventory(await _collect(runtime, failure));
      });
    }

    test('$runtime successful empty loaded list proves cold inventory',
        () async {
      final quota = await _collect(runtime, _loadedList(runtime, []));
      expect(quota.status, 'ready - no model loaded');
      expect(quota.localGenerationReadiness, 'cold');
      for (final model in quota.models) {
        expect(model.loaded, isFalse);
        expect(model.loadedStateKnown, isTrue);
        expect(model.contextTokens, _maximum);
      }
    });

    test('$runtime complete loaded list preserves running and cold contexts',
        () async {
      final quota =
          await _collect(runtime, _loadedList(runtime, [_loadedRow(runtime)]));
      final observed = quota.models.firstWhere((m) => m.id == _observed);
      final other = quota.models.firstWhere((m) => m.id == _other);
      expect(observed.loaded, isTrue);
      expect(observed.loadedStateKnown, isTrue);
      expect(observed.contextTokens, 8192);
      expect(other.loaded, isFalse);
      expect(other.loadedStateKnown, isTrue);
      expect(other.contextTokens, _maximum);
    });

    test(
        '$runtime partial list retains positive residency but no context bound',
        () async {
      final quota = await _collect(
          runtime, _loadedList(runtime, [_loadedRow(runtime), 'malformed']));
      final observed = quota.models.firstWhere((m) => m.id == _observed);
      final other = quota.models.firstWhere((m) => m.id == _other);
      expect(quota.active, isTrue);
      expect(observed.loaded, isTrue);
      expect(observed.loadedStateKnown, isTrue);
      expect(observed.contextTokens, isNull);
      expect(other.loaded, isFalse);
      expect(other.loadedStateKnown, isFalse);
      expect(other.contextTokens, isNull);
    });
  }

  test('legacy Lemonade recent name alone leaves all residency unknown',
      () async {
    _expectUnknownInventory(
        await _collect('lemonade', _json({'model_loaded': _observed})));
  });

  test('malformed Lemonade loaded list never falls back to legacy positive',
      () async {
    _expectUnknownInventory(await _collect(
        'lemonade',
        _json({
          'all_models_loaded': 'invalid',
          'model_loaded': _observed,
        })));
  });

  test(
      'LM Studio v1 distinguishes unknown declarations from valid empty arrays',
      () async {
    for (final declaration in <Object?>[
      null,
      false,
      {},
      'loaded',
      [42]
    ]) {
      for (final includeField in [false, true]) {
        final quota = await _collectLm('/api/v1/models', {
          'models': [
            {
              'key': _observed,
              'max_context_length': _maximum,
              if (includeField) 'loaded_instances': declaration
            },
            {
              'key': _other,
              'max_context_length': _maximum,
              'loaded_instances': <Object?>[]
            },
          ]
        });
        final observed = quota.models.firstWhere((m) => m.id == _observed);
        final other = quota.models.firstWhere((m) => m.id == _other);
        expect(observed.loadedStateKnown, isFalse);
        expect(observed.loaded, isFalse);
        expect(observed.contextTokens, isNull);
        expect(other.loadedStateKnown, isTrue);
        expect(other.loaded, isFalse);
        expect(other.contextTokens, _maximum);
        expect(quota.status, 'reachable - load state unknown');
      }
    }
  });

  test(
      'LM Studio v1 partial instance list preserves positive with unknown bound',
      () async {
    final valid = {
      'id': 'instance',
      'config': {'context_length': 8192}
    };
    for (final instances in [
      [valid, 42],
      [42, valid]
    ]) {
      final parsed = lmStudioV1FromJson({
        'models': [
          {'key': _observed, 'loaded_instances': instances},
        ]
      })!;
      expect(parsed.loaded, hasLength(1));
      expect(parsed.unknownLoadModelNames, {_observed});
      final quota = await _collectLm('/api/v1/models', {
        'models': [
          {
            'key': _observed,
            'max_context_length': _maximum,
            'loaded_instances': instances
          },
          {
            'key': _other,
            'max_context_length': _maximum,
            'loaded_instances': <Object?>[]
          },
        ]
      });
      final observed = quota.models.firstWhere((m) => m.id == _observed);
      final other = quota.models.firstWhere((m) => m.id == _other);
      expect(observed.loaded, isTrue);
      expect(observed.loadedStateKnown, isTrue);
      expect(observed.contextTokens, isNull);
      expect(other.loadedStateKnown, isTrue);
      expect(other.contextTokens, _maximum);
    }
  });

  test(
      'LM Studio v1 invalid instance identity cannot prove residency or context',
      () async {
    for (final identity in <Object?>[
      null,
      42,
      false,
      {},
      '',
      ' ',
      'x' * 513,
      'invalid\nidentity'
    ]) {
      for (final includeField in [false, true]) {
        final invalid = <String, Object?>{
          if (includeField) 'id': identity,
          'config': {'context_length': 65536},
        };
        final valid = {
          'id': 'valid-instance',
          'config': {'context_length': 8192}
        };
        for (final instances in [
          [invalid],
          [invalid, valid],
          [valid, invalid]
        ]) {
          final quota = await _collectLm('/api/v1/models', {
            'models': [
              {
                'key': _observed,
                'max_context_length': _maximum,
                'loaded_instances': instances
              },
            ]
          });
          final model = quota.models.single;
          expect(model.loaded, instances.length == 2);
          expect(model.loadedStateKnown, instances.length == 2);
          expect(model.contextTokens, isNull);
        }
      }
    }
    final emptyInstance = await _collectLm('/api/v1/models', {
      'models': [
        {
          'key': _observed,
          'loaded_instances': [<String, Object?>{}]
        },
      ]
    });
    expect(emptyInstance.models.single.loadedStateKnown, isFalse);
    expect(emptyInstance.models.single.loaded, isFalse);
  });

  test('LM Studio v0 requires exact loaded or not-loaded state evidence',
      () async {
    for (final state in <Object?>[
      null,
      false,
      {},
      'LOADED',
      'invalid',
      'loaded',
      'not-loaded'
    ]) {
      final quota = await _collectLm('/api/v0/models', {
        'data': [
          {
            'id': _observed,
            'max_context_length': _maximum,
            'loaded_context_length': 8192,
            'state': state
          },
        ]
      });
      final model = quota.models.single;
      expect(model.loaded, state == 'loaded');
      expect(
          model.loadedStateKnown, state == 'loaded' || state == 'not-loaded');
      expect(
          model.contextTokens,
          state == 'loaded'
              ? 8192
              : state == 'not-loaded'
                  ? _maximum
                  : null);
    }
    final parsed = lmStudioNativeFromJson({
      'data': [
        {'id': _observed, 'max_context_length': _maximum},
      ]
    })!;
    expect(parsed.unknownLoadModelNames, {_observed});
  });

  test('LM Studio compatibility listing has no residency observation',
      () async {
    _expectUnknownInventory(await _collectLm('/v1/models', {
      'data': [
        {'id': _observed},
        {'id': _other},
      ]
    }));
  });
}
