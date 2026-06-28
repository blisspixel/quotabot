import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(
  String id,
  List<QuotaWindow> windows, {
  bool stale = false,
  String kind = 'subscription',
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: windows,
      stale: stale,
      kind: kind,
    );

ProviderQuota _local(String id) => _q(id, const [], kind: 'local');

/// A snapshot exercising all builders: a healthy subscription, a nearly spent
/// one, and a local runtime fallback.
List<ProviderQuota> _fixture() => [
      _q('claude', [
        QuotaWindow(label: 'weekly', usedPercent: 20, resetsAt: _now + 3600),
      ]),
      _q('codex', [QuotaWindow(label: '5h', usedPercent: 95)]),
      _local('ollama'),
    ];

/// An in-memory [Transport] pair that ferries already-parsed JSON-RPC messages
/// straight to the peer, so a real [McpClient] and [McpServer] can talk with no
/// process or socket. Delivery is via microtask to avoid synchronous reentrancy.
class _PairedTransport implements Transport {
  _PairedTransport? peer;
  bool _closed = false;

  @override
  void Function()? onclose;
  @override
  void Function(Error error)? onerror;
  @override
  void Function(JsonRpcMessage message)? onmessage;

  @override
  String? get sessionId => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    final p = peer;
    if (p == null || p._closed) return;
    scheduleMicrotask(() => p.onmessage?.call(message));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onclose?.call();
    peer?.close();
  }
}

void main() {
  group('response builders', () {
    test('quotasSnapshot carries schema, time, and every provider', () {
      final snap = quotasSnapshot(_fixture(), _now);
      expect(snap['schema'], 'quotabot.v1');
      expect(snap['generated_at'], _now);
      final providers = snap['providers'] as List;
      expect(providers, hasLength(3));
      expect((providers.first as Map)['provider'], 'claude');
    });

    test('quotasSnapshot of nothing is still a valid empty snapshot', () {
      final snap = quotasSnapshot(const [], _now);
      expect(snap['providers'], isEmpty);
    });

    test('mostHeadroomResponse names the freest provider', () {
      final r = mostHeadroomResponse(_fixture(), _now);
      expect(r['provider'], 'claude');
      expect(r['headroom_percent'], 80);
      expect(r['stale'], isFalse);
    });

    test('mostHeadroomResponse reports null with a reason when none usable',
        () {
      final r = mostHeadroomResponse(const [], _now);
      expect(r['provider'], isNull);
      expect(r['reason'], isNotEmpty);
    });

    test('suggestResponse returns the versioned suggestion shape', () {
      final r = suggestResponse(_fixture(), _now);
      expect(r['schema'], 'quotabot.suggest.v1');
      expect((r['recommended'] as Map)['provider'], 'claude');
      expect(r['fallback'], isA<Map>());
      expect(r['ranked'], isA<List>());
    });

    test('availabilityResponse answers for a known provider', () {
      final r = availabilityResponse(_fixture(), _now, 'CLAUDE');
      expect(r['provider'], 'claude');
      expect(r['available'], isTrue);
      expect(r['headroom_percent'], 80);
    });

    test('availabilityResponse flags an unknown provider', () {
      expect(
        availabilityResponse(_fixture(), _now, 'nope')['error'],
        'unknown provider',
      );
      expect(
        availabilityResponse(_fixture(), _now, null)['error'],
        'unknown provider',
      );
    });
  });

  group('registered server (real round-trip)', () {
    late McpServer server;
    late McpClient client;

    Future<void> connect(List<ProviderQuota> snapshot) async {
      final serverT = _PairedTransport();
      final clientT = _PairedTransport();
      serverT.peer = clientT;
      clientT.peer = serverT;

      server = McpServer(
        const Implementation(name: 'quotabot', version: 'test'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(
            tools: ServerCapabilitiesTools(),
            resources: ServerCapabilitiesResources(),
          ),
        ),
      );
      registerQuotabotTools(
        server,
        snapshot: () async => snapshot,
        burnByProvider: (providers, now) => const {},
        now: () => _now,
      );
      await server.connect(serverT);

      client = McpClient(const Implementation(name: 'test', version: '1.0.0'));
      await client.connect(clientT);
    }

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('every tool is read-only and declares an output schema', () async {
      await connect(_fixture());
      final tools = await client.listTools();
      final byName = {for (final t in tools.tools) t.name: t};
      expect(
        byName.keys,
        containsAll([
          'list_quotas',
          'provider_with_most_headroom',
          'suggest_provider',
          'check_provider_availability',
        ]),
      );
      for (final t in tools.tools) {
        expect(t.annotations?.readOnlyHint, isTrue, reason: t.name);
        expect(t.outputSchema, isNotNull, reason: t.name);
      }
    });

    // A schema/payload mismatch makes the server (and the client) raise, so a
    // clean call across the wire is proof the structuredContent conforms.
    test('each tool returns schema-valid structured content', () async {
      await connect(_fixture());

      final quotas = await client.callTool(
        const CallToolRequest(name: 'list_quotas'),
      );
      expect(quotas.isError, isFalse);
      expect(quotas.structuredContent?['schema'], 'quotabot.v1');

      final headroom = await client.callTool(
        const CallToolRequest(name: 'provider_with_most_headroom'),
      );
      expect(headroom.structuredContent?['provider'], 'claude');

      final suggest = await client.callTool(
        const CallToolRequest(name: 'suggest_provider'),
      );
      expect(suggest.structuredContent?['schema'], 'quotabot.suggest.v1');

      final known = await client.callTool(
        const CallToolRequest(
          name: 'check_provider_availability',
          arguments: {'provider': 'claude'},
        ),
      );
      expect(known.structuredContent?['available'], isTrue);

      final unknown = await client.callTool(
        const CallToolRequest(
          name: 'check_provider_availability',
          arguments: {'provider': 'nope'},
        ),
      );
      expect(unknown.structuredContent?['error'], 'unknown provider');

      // Back-compat: structured tools also serialize a text content block.
      expect(quotas.content, isNotEmpty);
    });

    test('the no-data snapshot still validates against every schema', () async {
      await connect(const []);
      for (final name in [
        'list_quotas',
        'provider_with_most_headroom',
        'suggest_provider',
      ]) {
        final r = await client.callTool(CallToolRequest(name: name));
        expect(r.isError, isFalse, reason: name);
        expect(r.structuredContent, isNotNull, reason: name);
      }
    });

    test('the quotas resource serves the same snapshot JSON', () async {
      await connect(_fixture());
      final res = await client.readResource(
        const ReadResourceRequest(uri: 'quotas://current'),
      );
      final text = (res.contents.first as TextResourceContents).text;
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      expect(decoded['schema'], 'quotabot.v1');
      expect((decoded['providers'] as List), hasLength(3));
    });
  });
}
