import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/local_server.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(String id, double usedPercent) => ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: usedPercent,
          resetsAt: _now + 3600,
        ),
      ],
    );

ProviderQuota _local(String id) => ProviderQuota(
      provider: id,
      displayName: id,
      account: 'local',
      asOf: _now,
      kind: ProviderQuotaKind.local,
    );

Future<({int status, Map<String, dynamic> body})> _requestJson(
  Uri uri, {
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return (
      status: response.statusCode,
      body: jsonDecode(body) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _getJson(
  Uri uri, {
  int expectedStatus = 200,
}) async {
  final response = await _requestJson(uri);
  expect(response.status, expectedStatus);
  return response.body;
}

void main() {
  test('local server serves snapshot, health, providers, and errors', () async {
    var collections = 0;
    final logs = <String>[];
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections += 1;
        return [_q('claude', 20)];
      },
      now: () => _now,
      log: logs.add,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      expect(logs.first, contains('quotabot local server listening'));

      final snapshot = await _getJson(Uri.parse('$base/'));
      expect(snapshot['schema'], 'quotabot.v1');
      expect(snapshot['providers'], hasLength(1));

      final suggestion = await _getJson(Uri.parse('$base/suggest'));
      expect((suggestion['recommended'] as Map)['provider'], 'claude');

      final provider = await _getJson(Uri.parse('$base/providers/claude'));
      expect(provider['provider'], 'claude');
      expect(collections, 1);

      final health = await _getJson(Uri.parse('$base/health'));
      expect(health['ok'], isTrue);

      final unknownProvider = await _getJson(
        Uri.parse('$base/providers/missing'),
        expectedStatus: 404,
      );
      expect(unknownProvider['error'], 'unknown provider');

      final missingPath = await _getJson(
        Uri.parse('$base/missing'),
        expectedStatus: 404,
      );
      expect(missingPath['error'], 'not found');

      final wrongMethod = await _requestJson(
        Uri.parse('$base/health'),
        method: 'POST',
      );
      expect(wrongMethod.status, 405);
      expect(wrongMethod.body['error'], 'method not allowed');
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects a non-loopback Host header (DNS-rebinding guard)', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/'),
        );
        request.headers.set('host', 'evil.example');
        final response = await request.close();
        final body = jsonDecode(await utf8.decodeStream(response))
            as Map<String, dynamic>;
        expect(response.statusCode, 403);
        expect(body['error'], 'forbidden host');
        expect(body.containsKey('providers'), isFalse);
      } finally {
        client.close(force: true);
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('allows a loopback Host header with a port', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      for (final host in ['localhost:9999', '127.0.0.1:1', '[::1]:8721']) {
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/health'),
          );
          request.headers.set('host', host);
          final response = await request.close();
          expect(response.statusCode, 200, reason: 'host $host must pass');
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest honors exclude query providers', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 20),
        _q('codex', 30),
      ],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest?exclude=claude'),
      );

      expect((json['recommended'] as Map)['provider'], 'codex');
      final ranked = json['ranked'] as List;
      expect(
        ranked.map((entry) => (entry as Map)['provider']),
        isNot(contains('claude')),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest honors local-first query policy', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 20),
        _local('ollama'),
      ],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse(
          'http://127.0.0.1:${server.port}/suggest?local_first=true',
        ),
      );

      expect(json['routing_policy'], 'local_first');
      expect((json['recommended'] as Map)['provider'], 'ollama');
      expect(json['using_local_fallback'], isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest honors explicit cost policy', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 20),
        _q('codex', 30),
      ],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse(
          'http://127.0.0.1:${server.port}/suggest?cost_penalty=claude:1',
        ),
      );

      expect(json['cost_weight'], 1.0);
      expect((json['recommended'] as Map)['provider'], 'codex');
      final claude = (json['ranked'] as List).cast<Map>().firstWhere(
            (entry) => entry['provider'] == 'claude',
          );
      expect(claude['cost_penalty'], 1.0);
      expect(claude['cost_discount'], 0.5);
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest rejects malformed exclude providers', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest?exclude=../bad'),
        expectedStatus: 400,
      );

      expect(json['error'], 'invalid exclude provider: ../bad');
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest rejects malformed cost policy', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse(
          'http://127.0.0.1:${server.port}/suggest?cost_penalty=../bad:1',
        ),
        expectedStatus: 400,
      );

      expect(json['error'], 'invalid cost-penalty provider: ../bad');
    } finally {
      await server.close(force: true);
    }
  });

  test('local server hides internal errors from clients', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => throw StateError('secret detail'),
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/'),
        expectedStatus: 500,
      );

      expect(json['error'], 'internal error');
      expect(json.toString(), isNot(contains('secret detail')));
    } finally {
      await server.close(force: true);
    }
  });
}
