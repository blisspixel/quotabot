import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _quota() => ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'acct',
      asOf: _now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 20,
          resetsAt: _now + 3600,
        ),
      ],
    );

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
    final target = peer;
    if (target == null || target._closed) return;
    scheduleMicrotask(() => target.onmessage?.call(message));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onclose?.call();
    await peer?.close();
  }
}

Future<void> _pump() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('stable server keeps legacy initialize and accepts discovery', () async {
    final legacy = await _connect(McpProtocol.legacy);
    addTearDown(legacy.close);
    expect(legacy.client.getProtocolVersion(), '2025-11-25');

    final modern = await _connect(McpProtocol.require2026);
    addTearDown(modern.close);
    expect(modern.client.getProtocolVersion(), stableProtocolVersion);
    final tools = await modern.client.listTools();
    expect(tools.tools.map((tool) => tool.name), contains('list_quotas'));
    expect(tools.cacheScope, CacheScope.private);
    expect(tools.ttlMs, 0);
  });

  test('an unsupported protocol version is rejected before tool work',
      () async {
    final opened = await _serverOnly();
    addTearDown(opened.close);
    final response = Completer<JsonRpcMessage>();
    opened.clientTransport.onmessage = (message) {
      if (!response.isCompleted) response.complete(message);
    };
    await opened.clientTransport.send(
      JsonRpcListToolsRequest(
        id: 41,
        meta: buildProtocolRequestMeta(
          protocolVersion: '1999-01-01',
          clientInfo: const Implementation(name: 'client', version: '1.0.0'),
          clientCapabilities: const ClientCapabilities(),
        ),
      ),
    );
    final error = await response.future.timeout(const Duration(seconds: 5));
    expect(error, isA<JsonRpcError>());
    final rejected = error as JsonRpcError;
    expect(rejected.id, 41);
    expect(rejected.error.code, ErrorCode.unsupportedProtocolVersion.value);
  });

  test('cancelling one quota subscription leaves the other listening',
      () async {
    final opened = await _connect(McpProtocol.require2026);
    addTearDown(opened.close);
    final firstEvents = <String>[];
    final secondEvents = <String>[];
    final first = opened.client.listenSubscriptions(
      const SubscriptionsListenRequest(
        notifications: SubscriptionFilter(
          resourceSubscriptions: [quotasCurrentResourceUri],
        ),
      ),
    );
    final second = opened.client.listenSubscriptions(
      const SubscriptionsListenRequest(
        notifications: SubscriptionFilter(
          resourceSubscriptions: [quotasCurrentResourceUri],
        ),
      ),
    );
    addTearDown(second.cancel);
    first.notifications.listen((message) => firstEvents.add(message.method));
    second.notifications.listen((message) => secondEvents.add(message.method));
    await first.acknowledged.timeout(const Duration(seconds: 5));
    await second.acknowledged.timeout(const Duration(seconds: 5));

    first.cancel();
    await first.done.timeout(const Duration(seconds: 5));
    // Cancellation crosses the paired transport before the server detaches.
    await _pump();
    await opened.hub.pollOnce();
    await _pump();

    expect(secondEvents, contains(Method.notificationsResourcesUpdated));
    expect(firstEvents, isNot(contains(Method.notificationsResourcesUpdated)));
  });
}

class _Opened {
  final McpServer server;
  final McpClient client;
  final QuotaResourceSubscriptionHub hub;
  final _PairedTransport serverTransport;
  final _PairedTransport clientTransport;

  const _Opened(
    this.server,
    this.client,
    this.hub,
    this.serverTransport,
    this.clientTransport,
  );

  Future<void> close() async {
    await client.close();
    await server.close();
  }
}

Future<_Opened> _connect(McpProtocol protocol) async {
  final serverTransport = _PairedTransport();
  final clientTransport = _PairedTransport();
  serverTransport.peer = clientTransport;
  clientTransport.peer = serverTransport;
  final server = McpServer(
    const Implementation(name: 'quotabot', version: 'test'),
    options: const McpServerOptions(
      protocol: McpProtocol.stable,
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
        resources: ServerCapabilitiesResources(subscribe: true),
      ),
    ),
  );
  final hub = registerQuotabotTools(
    server,
    snapshot: () async => [_quota()],
    burnByProvider: (providers, now) => const <String, BurnStat>{},
    enableSubscriptionTimers: false,
    now: () => _now,
    profileLoader: (name) => null,
  );
  await server.connect(serverTransport);
  final client = McpClient(
    const Implementation(name: 'modern-test', version: '1.0.0'),
    options: McpClientOptions(protocol: protocol),
  );
  await client.connect(clientTransport);
  return _Opened(server, client, hub, serverTransport, clientTransport);
}

Future<_Opened> _serverOnly() async {
  final serverTransport = _PairedTransport();
  final clientTransport = _PairedTransport();
  serverTransport.peer = clientTransport;
  clientTransport.peer = serverTransport;
  final server = McpServer(
    const Implementation(name: 'quotabot', version: 'test'),
    options: const McpServerOptions(
      protocol: McpProtocol.stable,
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
        resources: ServerCapabilitiesResources(subscribe: true),
      ),
    ),
  );
  final hub = registerQuotabotTools(
    server,
    snapshot: () async => [_quota()],
    burnByProvider: (providers, now) => const <String, BurnStat>{},
    enableSubscriptionTimers: false,
    now: () => _now,
    profileLoader: (name) => null,
  );
  await server.connect(serverTransport);
  return _Opened(
    server,
    McpClient(const Implementation(name: 'unused', version: '1.0.0')),
    hub,
    serverTransport,
    clientTransport,
  );
}
