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

typedef _CollectRuntime = Future<ProviderQuota> Function(http.Client client);

final _collectors = <String, _CollectRuntime>{
  'ollama': (client) => OllamaAdapter(
        client: client,
        capabilityCache: OllamaCapabilityCache(),
        environment: const {},
      ).collect(),
  'lmstudio': (client) => LmStudioAdapter(
        client: client,
        environment: const {},
      ).collect(),
  'lemonade': (client) => LemonadeAdapter(
        client: client,
        environment: const {},
      ).collect(),
};

const _inventoryPaths = <String, List<String>>{
  'ollama': ['/api/tags'],
  'lmstudio': ['/api/v1/models', '/api/v0/models', '/v1/models'],
  'lemonade': ['/api/v1/models', '/v1/models'],
};

http.Response _emptyInventory(String runtime) => http.Response(
      jsonEncode(runtime == 'lemonade'
          ? {'data': <Object?>[]}
          : {'models': <Object?>[]}),
      200,
    );

void _expectUnavailable(ProviderQuota quota) {
  expect(quota.ok, isFalse);
  expect(quota.isLocal, isTrue);
  expect(quota.models, isEmpty);
  expect(quota.windows, isEmpty);
  expect(isLocalRuntimeReachableAt(quota, quota.asOf), isFalse);
  expect(isLocalRuntimeAvailableAt(quota, quota.asOf), isFalse);
  expect(jsonEncode(quota.toJson()), isNot(contains('private-response')));
}

void main() {
  for (final runtime in _collectors.entries) {
    for (final failure in const [
      (
        status: 401,
        error: 'runtime metadata authentication required (HTTP 401)'
      ),
      (status: 403, error: 'runtime metadata access denied (HTTP 403)'),
      (status: 503, error: 'runtime metadata unavailable (HTTP 503)'),
      (status: 404, error: 'runtime metadata unavailable (HTTP 404)'),
      (status: 405, error: 'runtime metadata unavailable (HTTP 405)'),
      (status: 302, error: 'runtime metadata unavailable (HTTP 302)'),
    ]) {
      test('${runtime.key} diagnoses inventory HTTP ${failure.status}',
          () async {
        final paths = <String>[];
        final client = MockClient((request) async {
          paths.add(request.url.path);
          expect(request.method, 'GET');
          expect(request.body, isEmpty);
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(request.followRedirects, isFalse);
          return http.Response('private-response', failure.status,
              reasonPhrase: 'private-response');
        });
        try {
          final quota = await runtime.value(client);
          _expectUnavailable(quota);
          expect(quota.error, failure.error);
          expect(quota.httpStatus, failure.status);
          expect(quota.toJson()['http_status'], failure.status);
          expect(paths, _inventoryPaths[runtime.key]);
        } finally {
          client.close();
        }
      });
    }

    for (final body in [
      'private-response is not JSON',
      jsonEncode({'models': 'private-response', 'data': 'private-response'}),
    ]) {
      test('${runtime.key} diagnoses invalid successful inventory: $body',
          () async {
        final client = MockClient((_) async => http.Response(body, 200));
        try {
          final quota = await runtime.value(client);
          _expectUnavailable(quota);
          expect(quota.error, 'invalid runtime model metadata');
          expect(quota.httpStatus, 200);
        } finally {
          client.close();
        }
      });
    }

    test('${runtime.key} keeps transport failure separate from HTTP evidence',
        () async {
      final client = MockClient((_) async =>
          throw const SocketException('private-response connection refused'));
      try {
        final quota = await runtime.value(client);
        _expectUnavailable(quota);
        expect(quota.error, 'not running');
        expect(quota.httpStatus, isNull);
      } finally {
        client.close();
      }
    });

    test('${runtime.key} keeps valid empty inventory distinct and recovers',
        () async {
      var failing = true;
      final client = MockClient((request) async {
        if (failing) return http.Response('private-response', 401);
        if (_inventoryPaths[runtime.key]!.contains(request.url.path)) {
          return _emptyInventory(runtime.key);
        }
        return http.Response('{}', 503); // Optional loaded metadata.
      });
      try {
        final failed = await runtime.value(client);
        expect(failed.error,
            'runtime metadata authentication required (HTTP 401)');
        failing = false;
        final quota = await runtime.value(client);
        expect(quota.ok, isTrue);
        expect(quota.error, isNull);
        expect(quota.httpStatus, isNull);
        expect(quota.status, 'reachable - no local models installed');
        expect(quota.models, isEmpty);
        expect(isLocalRuntimeReachableAt(quota, quota.asOf), isTrue);
        expect(isLocalRuntimeAvailableAt(quota, quota.asOf), isFalse);
      } finally {
        client.close();
      }
    });

    if (runtime.key == 'ollama') continue;
    for (final earlier in const [
      (
        status: 401,
        body: 'private-response',
        expectedStatus: 401,
        error: 'runtime metadata authentication required (HTTP 401)'
      ),
      (
        status: 403,
        body: 'private-response',
        expectedStatus: 403,
        error: 'runtime metadata access denied (HTTP 403)'
      ),
      (
        status: 200,
        body: 'private-response',
        expectedStatus: 200,
        error: 'invalid runtime model metadata'
      ),
      (
        status: 503,
        body: 'private-response',
        expectedStatus: 503,
        error: 'runtime metadata unavailable (HTTP 503)'
      ),
    ]) {
      for (final fallback in [404, 405, null]) {
        test(
            '${runtime.key} retains ${earlier.status} diagnosis after '
            '${fallback ?? 'transport'} fallback failure', () async {
          final paths = <String>[];
          final client = MockClient((request) async {
            paths.add(request.url.path);
            if (paths.length == 1) {
              return http.Response(earlier.body, earlier.status);
            }
            if (fallback == null) {
              throw const SocketException('private-response fallback failure');
            }
            return http.Response('private-response', fallback);
          });
          try {
            final quota = await runtime.value(client);
            _expectUnavailable(quota);
            expect(quota.error, earlier.error);
            expect(quota.httpStatus, earlier.expectedStatus);
            expect(paths, _inventoryPaths[runtime.key]);
          } finally {
            client.close();
          }
        });
      }
    }

    test('${runtime.key} accepts a valid fallback after access rejection',
        () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        return switch (request.url.path) {
          '/v1/models' => http.Response(
              jsonEncode({
                'data': [
                  {'id': 'fallback-model'}
                ]
              }),
              200),
          '/v1/health' => http.Response('{}', 503),
          _ => http.Response('private-response', 403),
        };
      });
      try {
        final quota = await runtime.value(client);
        expect(quota.ok, isTrue);
        expect(quota.error, isNull);
        expect(quota.httpStatus, isNull);
        expect(quota.models.single.id, 'fallback-model');
        expect(paths, [
          ..._inventoryPaths[runtime.key]!,
          if (runtime.key == 'lemonade') '/v1/health',
        ]);
      } finally {
        client.close();
      }
    });
  }
}
