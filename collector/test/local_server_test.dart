import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

import 'package:quotabot_collector/local_server.dart';

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
