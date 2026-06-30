import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/leases.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/profiles.dart';
import 'package:quotabot_collector/schema_contracts.dart';
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

ProviderQuota _accountQ(String id, String account, double usedPercent) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: account,
      asOf: _now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: usedPercent)],
    );

QuotaProfile? _noProfile(String name) => null;

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
      expect(validateQuotabotV1Snapshot(snap), isEmpty);
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
      expect(r['routing_policy'], 'balanced');
      expect((r['recommended'] as Map)['provider'], 'claude');
      expect(r['fallback'], isA<Map>());
      expect(r['ranked'], isA<List>());
    });

    test('suggestResponse can prefer local runtime explicitly', () {
      final r = suggestResponse(_fixture(), _now, preferLocal: true);
      expect(r['routing_policy'], 'local_first');
      expect((r['recommended'] as Map)['provider'], 'ollama');
      expect(r['using_local_fallback'], isTrue);
    });

    test('availabilityResponse answers for a known provider', () {
      final r = availabilityResponse(_fixture(), _now, 'CLAUDE', null);
      expect(r['provider'], 'claude');
      expect(r['available'], isTrue);
      expect(r['headroom_percent'], 80);
    });

    test('availabilityResponse flags an unknown provider', () {
      expect(
        availabilityResponse(_fixture(), _now, 'nope', null)['error'],
        'unknown provider',
      );
      expect(
        availabilityResponse(_fixture(), _now, null, null)['error'],
        'unknown provider',
      );
    });
  });

  group('registered server (real round-trip)', () {
    late McpServer server;
    late McpClient client;
    late QuotaResourceSubscriptionHub subscriptions;

    Future<void> connect(
      List<ProviderQuota> snapshot, {
      SnapshotProvider? snapshotProvider,
      ProfileLoader profileLoader = _noProfile,
      CachedSnapshotProvider cachedSnapshot = emptyCachedSnapshot,
      RouteLeaseStore leaseStore = const NoopRouteLeaseStore(),
      bool enableSubscriptionTimers = false,
    }) async {
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
      subscriptions = registerQuotabotTools(
        server,
        snapshot: snapshotProvider ?? () async => snapshot,
        burnByProvider: (providers, now) => const <String, BurnStat>{},
        cachedSnapshot: cachedSnapshot,
        leaseStore: leaseStore,
        enableSubscriptionTimers: enableSubscriptionTimers,
        now: () => _now,
        profileLoader: profileLoader,
        catalog: const {
          'claude': [
            ModelInfo(id: 'claude-test', contextTokens: 200000, tools: true),
          ],
        },
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
          'decide_now',
          'reserve_provider',
          'release_provider',
          'check_provider_availability',
        ]),
      );
      for (final t in tools.tools) {
        if (t.name == 'reserve_provider') {
          expect(t.annotations?.readOnlyHint, isFalse, reason: t.name);
          expect(t.annotations?.idempotentHint, isFalse, reason: t.name);
        } else if (t.name == 'release_provider') {
          expect(t.annotations?.readOnlyHint, isFalse, reason: t.name);
          expect(t.annotations?.idempotentHint, isTrue, reason: t.name);
        } else {
          expect(t.annotations?.readOnlyHint, isTrue, reason: t.name);
          expect(t.annotations?.idempotentHint, isTrue, reason: t.name);
        }
        expect(t.outputSchema, isNotNull, reason: t.name);
      }
      final listModelsProperties = byName['list_models']!
          .outputSchema!
          .toJson()['properties'] as Map<String, dynamic>;
      final modelProperties = (((listModelsProperties['models'] as Map)['items']
          as Map)['properties'] as Map);
      expect(modelProperties.keys,
          containsAll(['size_bytes', 'vram_bytes', 'quant']));
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

      final localFirst = await client.callTool(
        const CallToolRequest(
          name: 'suggest_provider',
          arguments: {'local_first': true},
        ),
      );
      expect(localFirst.structuredContent?['routing_policy'], 'local_first');
      expect(
        (localFirst.structuredContent?['recommended'] as Map)['provider'],
        'ollama',
      );

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

      final models = await client.callTool(
        const CallToolRequest(name: 'list_models'),
      );
      expect(models.structuredContent?['schema'], 'quotabot.models.v1');
      // The fixture catalog gives claude one model, gated by its live budget.
      final list = models.structuredContent?['models'] as List;
      final claude = list.firstWhere((m) => (m as Map)['id'] == 'claude-test');
      expect((claude as Map)['provider'], 'claude');
      expect(claude['headroom_percent'], 80);

      // A capability filter the fixture model does not meet excludes it.
      final filtered = await client.callTool(
        const CallToolRequest(
          name: 'list_models',
          arguments: {'require_reasoning': true},
        ),
      );
      expect(filtered.structuredContent?['models'], isEmpty);

      final localOnly = await client.callTool(
        const CallToolRequest(
          name: 'list_models',
          arguments: {'budget': 'local'},
        ),
      );
      expect(localOnly.structuredContent?['budget_policy'], 'local');
      expect(localOnly.structuredContent?['models'], isEmpty);

      final pick = await client.callTool(
        const CallToolRequest(name: 'suggest_model'),
      );
      expect(pick.structuredContent?['schema'], 'quotabot.suggest_model.v1');
      expect(
          (pick.structuredContent?['recommended'] as Map)['id'], 'claude-test');

      final badBudget = await client.callTool(
        const CallToolRequest(
          name: 'suggest_model',
          arguments: {'budget': 'paid_api'},
        ),
      );
      expect(badBudget.isError, isFalse);
      expect(
        badBudget.structuredContent?['error'],
        'unknown budget policy: "paid_api"',
      );
      expect(badBudget.structuredContent?['ranked'], isEmpty);

      // Back-compat: structured tools also serialize a text content block.
      expect(quotas.content, isNotEmpty);
    });

    test('profile arguments filter tools without changing default calls',
        () async {
      await connect(
        _fixture(),
        profileLoader: (name) => name == 'local'
            ? const QuotaProfile(
                name: 'local',
                routingPolicy: ProfileRoutingPolicy.localOnly,
              )
            : null,
      );

      final all = await client.callTool(
        const CallToolRequest(name: 'list_quotas'),
      );
      expect(all.structuredContent?['profile'], isNull);
      expect(all.structuredContent?['providers'] as List, hasLength(3));

      final filtered = await client.callTool(
        const CallToolRequest(
          name: 'list_quotas',
          arguments: {'profile': 'local'},
        ),
      );
      expect(filtered.isError, isFalse);
      expect(filtered.structuredContent?['profile'], 'local');
      final providers = filtered.structuredContent?['providers'] as List;
      expect(providers, hasLength(1));
      expect((providers.single as Map)['provider'], 'ollama');

      final suggestion = await client.callTool(
        const CallToolRequest(
          name: 'suggest_provider',
          arguments: {'profile': 'local'},
        ),
      );
      expect(suggestion.structuredContent?['profile'], 'local');
      expect(suggestion.structuredContent?['using_local_fallback'], isTrue);
      expect(
        (suggestion.structuredContent?['recommended'] as Map)['provider'],
        'ollama',
      );
    });

    test('account arguments scope routing queries after profile filtering',
        () async {
      await connect([
        _accountQ('claude', 'work@example.com', 20),
        _accountQ('codex', 'home@example.com', 10),
      ]);

      final quotas = await client.callTool(
        const CallToolRequest(
          name: 'list_quotas',
          arguments: {'account': 'work@example.com'},
        ),
      );
      expect(quotas.structuredContent?['account_filter'], 'work@example.com');
      final providers = quotas.structuredContent?['providers'] as List;
      expect(providers, hasLength(1));
      expect((providers.single as Map)['provider'], 'claude');

      final suggestion = await client.callTool(
        const CallToolRequest(
          name: 'suggest_provider',
          arguments: {'account': 'home@example.com'},
        ),
      );
      expect(
          suggestion.structuredContent?['account_filter'], 'home@example.com');
      expect(
        (suggestion.structuredContent?['recommended'] as Map)['provider'],
        'codex',
      );

      final missingAccount = await client.callTool(
        const CallToolRequest(
          name: 'check_provider_availability',
          arguments: {
            'provider': 'claude',
            'account': 'home@example.com',
          },
        ),
      );
      expect(
        missingAccount.structuredContent?['error'],
        'unknown provider/account',
      );
    });

    test('exclude arguments filter MCP routing and model tools', () async {
      await connect(_fixture());

      final quotas = await client.callTool(
        const CallToolRequest(
          name: 'list_quotas',
          arguments: {
            'exclude': ['claude'],
          },
        ),
      );
      final providers = quotas.structuredContent?['providers'] as List;
      expect(providers.map((p) => (p as Map)['provider']),
          isNot(contains('claude')));

      final suggestion = await client.callTool(
        const CallToolRequest(
          name: 'suggest_provider',
          arguments: {
            'exclude': ['claude'],
          },
        ),
      );
      expect(
        (suggestion.structuredContent?['recommended'] as Map)['provider'],
        'ollama',
      );

      final models = await client.callTool(
        const CallToolRequest(
          name: 'list_models',
          arguments: {
            'exclude': ['claude'],
          },
        ),
      );
      expect(models.structuredContent?['models'], isEmpty);
    });

    test('malformed MCP exclude arguments return a structured error', () async {
      await connect(_fixture());

      final quotas = await client.callTool(
        const CallToolRequest(
          name: 'list_quotas',
          arguments: {
            'exclude': ['../bad'],
          },
        ),
      );

      expect(quotas.structuredContent?['error'],
          'invalid exclude provider: ../bad');
      expect(quotas.structuredContent?['providers'], isEmpty);
    });

    test('exclude arguments filter reservation choice', () async {
      var nextId = 0;
      final store = InMemoryRouteLeaseStore(
        idFactory: () => 'lease-${++nextId}',
      );
      await connect(
        [
          _q('claude', [
            QuotaWindow(label: 'weekly', usedPercent: 20),
          ]),
          _q('codex', [
            QuotaWindow(label: 'weekly', usedPercent: 30),
          ]),
        ],
        leaseStore: store,
      );

      final reserved = await client.callTool(
        const CallToolRequest(
          name: 'reserve_provider',
          arguments: {
            'exclude': ['claude'],
          },
        ),
      );

      expect(reserved.structuredContent?['reserved'], isTrue);
      final lease = reserved.structuredContent?['lease'] as Map;
      expect(lease['provider'], 'codex');
    });

    test('reserve_provider shifts later suggestions until release', () async {
      var nextId = 0;
      final store = InMemoryRouteLeaseStore(
        idFactory: () => 'lease-${++nextId}',
      );
      await connect(
        [
          _q('claude', [
            QuotaWindow(label: 'weekly', usedPercent: 20),
          ]),
          _q('codex', [
            QuotaWindow(label: 'weekly', usedPercent: 30),
          ]),
        ],
        leaseStore: store,
      );

      final reserved = await client.callTool(
        const CallToolRequest(
          name: 'reserve_provider',
          arguments: {
            'provider': 'claude',
            'weight_percent': 30,
            'lease_seconds': 120,
            'idempotency_key': 'retry-lease',
          },
        ),
      );
      expect(reserved.structuredContent?['reserved'], isTrue);
      expect(reserved.structuredContent?['reused'], isFalse);
      final lease = reserved.structuredContent?['lease'] as Map;
      expect(lease['id'], 'lease-1');
      expect(lease['provider'], 'claude');

      final retry = await client.callTool(
        const CallToolRequest(
          name: 'reserve_provider',
          arguments: {
            'provider': 'claude',
            'weight_percent': 30,
            'lease_seconds': 120,
            'idempotency_key': 'retry-lease',
          },
        ),
      );
      expect(retry.structuredContent?['reused'], isTrue);
      expect((retry.structuredContent?['lease'] as Map)['id'], 'lease-1');

      final leasedSuggestion = await client.callTool(
        const CallToolRequest(name: 'suggest_provider'),
      );
      expect(
        (leasedSuggestion.structuredContent?['recommended'] as Map)['provider'],
        'codex',
      );
      final active =
          leasedSuggestion.structuredContent?['active_leases'] as List;
      expect((active.single as Map)['discount_percent'], 30);

      final released = await client.callTool(
        const CallToolRequest(
          name: 'release_provider',
          arguments: {'lease_id': 'lease-1'},
        ),
      );
      expect(released.structuredContent?['released'], isTrue);
      expect(released.structuredContent?['active_leases'], isEmpty);

      final clearSuggestion = await client.callTool(
        const CallToolRequest(name: 'suggest_provider'),
      );
      expect(
        (clearSuggestion.structuredContent?['recommended'] as Map)['provider'],
        'claude',
      );
    });

    test('reserve_provider reports profile and explicit target failures',
        () async {
      await connect(_fixture());

      final missingProfile = await client.callTool(
        const CallToolRequest(
          name: 'reserve_provider',
          arguments: {'profile': 'missing'},
        ),
      );
      expect(missingProfile.structuredContent?['reserved'], isFalse);
      expect(
        missingProfile.structuredContent?['reason'],
        'unknown profile: missing',
      );

      final missingTarget = await client.callTool(
        const CallToolRequest(
          name: 'reserve_provider',
          arguments: {'provider': 'claude', 'account': 'other'},
        ),
      );
      expect(missingTarget.structuredContent?['reserved'], isFalse);
      expect(
        missingTarget.structuredContent?['reason'],
        'requested provider/account unavailable',
      );
    });

    test('reserve_provider refuses local and spent targets', () async {
      await connect([
        _local('ollama'),
        _q('claude', [
          QuotaWindow(label: 'weekly', usedPercent: 100),
        ]),
      ]);

      final local = await client.callTool(
        const CallToolRequest(
          name: 'reserve_provider',
          arguments: {'provider': 'ollama'},
        ),
      );
      expect(local.structuredContent?['reserved'], isFalse);
      expect(
        local.structuredContent?['reason'],
        'local runtimes do not need quota leases',
      );

      final spent = await client.callTool(
        const CallToolRequest(
          name: 'reserve_provider',
          arguments: {'provider': 'claude'},
        ),
      );
      expect(spent.structuredContent?['reserved'], isFalse);
      expect(
        spent.structuredContent?['reason'],
        'claude has no effective headroom available',
      );
    });

    test('release_provider handles a blank lease id without throwing',
        () async {
      await connect(_fixture());

      final released = await client.callTool(
        const CallToolRequest(
          name: 'release_provider',
          arguments: {'lease_id': '   '},
        ),
      );
      expect(released.structuredContent?['released'], isFalse);
      expect(released.structuredContent?['reason'], 'lease_id is required');
    });

    test('decide_now uses cached snapshot without live collection', () async {
      var liveCalls = 0;
      await connect(
        const [],
        snapshotProvider: () async {
          liveCalls++;
          throw StateError('live collection should not run');
        },
        cachedSnapshot: () async => CachedQuotaSnapshot(
          providers: _fixture(),
          asOf: _now - 10,
          source: 'disk',
        ),
      );

      final decision = await client.callTool(
        const CallToolRequest(
          name: 'decide_now',
          arguments: {'max_age_seconds': 60, 'local_first': true},
        ),
      );
      expect(decision.structuredContent?['schema'], 'quotabot.decision.v1');
      expect(decision.structuredContent?['routing_policy'], 'local_first');
      expect(decision.structuredContent?['source'], 'disk');
      expect(decision.structuredContent?['snapshot_as_of'], _now - 10);
      expect(decision.structuredContent?['snapshot_age_seconds'], 10);
      expect(decision.structuredContent?['snapshot_stale'], isFalse);
      expect(
        (decision.structuredContent?['recommended'] as Map)['provider'],
        'ollama',
      );
      expect(liveCalls, 0);
    });

    test('resource subscriptions notify when a quota alert fires', () async {
      var snapshotIndex = 0;
      final snapshots = [
        [
          _accountQ('claude', 'work@example.com', 20),
          _accountQ('codex', 'home@example.com', 30),
        ],
        [
          _accountQ('claude', 'work@example.com', 95),
          _accountQ('codex', 'home@example.com', 30),
        ],
      ];
      await connect(
        const [],
        snapshotProvider: () async => snapshots[snapshotIndex],
      );
      final updated = <String>[];
      client.setNotificationHandler<JsonRpcResourceUpdatedNotification>(
        Method.notificationsResourcesUpdated,
        (notification) async {
          updated.add(notification.updatedParams.uri);
        },
        (params, meta) => JsonRpcResourceUpdatedNotification.fromJson({
          'params': {
            ...?params,
            if (meta != null) '_meta': meta,
          },
        }),
      );

      await client.subscribeResource(
        const SubscribeRequest(uri: 'quotas://alerts'),
      );
      await subscriptions.pollOnce();
      expect(updated, isEmpty);

      snapshotIndex = 1;
      await subscriptions.pollOnce();
      expect(updated, ['quotas://alerts']);

      final alerts = await client.readResource(
        const ReadResourceRequest(uri: 'quotas://alerts'),
      );
      final alertJson = jsonDecode(
        (alerts.contents.first as TextResourceContents).text,
      ) as Map<String, dynamic>;
      final fired = alertJson['alerts'] as List;
      expect(fired, hasLength(1));
      expect((fired.single as Map)['kind'], 'low_quota');
      expect((fired.single as Map)['provider'], 'claude');
      expect((fired.single as Map)['severity'], 'red');

      await client.unsubscribeResource(
        const UnsubscribeRequest(uri: 'quotas://alerts'),
      );
      await subscriptions.pollOnce();
      expect(updated, ['quotas://alerts']);
    });

    test('missing profile returns a structured error', () async {
      await connect(_fixture());

      final quotas = await client.callTool(
        const CallToolRequest(
          name: 'list_quotas',
          arguments: {'profile': 'missing'},
        ),
      );

      expect(quotas.isError, isFalse);
      expect(quotas.structuredContent?['profile'], 'missing');
      expect(quotas.structuredContent?['error'], 'unknown profile: missing');
      expect(quotas.structuredContent?['providers'], isEmpty);
    });

    test('the no-data snapshot still validates against every schema', () async {
      await connect(const []);
      for (final name in [
        'list_quotas',
        'provider_with_most_headroom',
        'suggest_provider',
        'decide_now',
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

      final alerts = await client.readResource(
        const ReadResourceRequest(uri: 'quotas://alerts'),
      );
      final alertJson = jsonDecode(
        (alerts.contents.first as TextResourceContents).text,
      ) as Map<String, dynamic>;
      expect(alertJson['schema'], 'quotabot.alerts.v1');
      expect(alertJson['alerts'], isEmpty);
    });
  });
}
