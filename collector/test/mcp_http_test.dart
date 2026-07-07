import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/mcp_http.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _quota(String provider, double usedPercent) => ProviderQuota(
      provider: provider,
      displayName: provider,
      account: 'acct',
      asOf: _now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: usedPercent,
          resetsAt: _now + 3600,
        ),
      ],
    );

List<ProviderQuota> _fixture() => [
      _quota('claude', 25),
      _quota('codex', 75),
      ProviderQuota(
        provider: 'ollama',
        displayName: 'ollama',
        account: 'local',
        asOf: _now,
        windows: [],
        kind: ProviderQuotaKind.local,
      ),
    ];

Future<int> _freePort() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return port;
}

class _Harness {
  final StreamableMcpServer server;
  final Uri uri;

  const _Harness(this.server, this.uri);

  Future<void> stop() => server.stop();
}

Future<_Harness> _start({String? token}) async {
  final port = await _freePort();
  final server = buildQuotabotStreamableHttpServer(
    config: QuotabotMcpHttpConfig(port: port, bearerToken: token),
    snapshot: () async => _fixture(),
    burnByProvider: (providers, now) => const <String, BurnStat>{},
    now: () => _now,
    catalog: const {
      'claude': [
        ModelInfo(id: 'claude-http-test', contextTokens: 200000, tools: true),
      ],
    },
  );
  await server.start();
  return _Harness(server, Uri.parse('http://127.0.0.1:$port/mcp'));
}

Future<McpClient> _connect(Uri uri, {String? token}) async {
  final client = McpClient(
    const Implementation(name: 'quotabot-http-test', version: '1.0.0'),
  );
  final transport = StreamableHttpClientTransport(
    uri,
    opts: token == null
        ? null
        : StreamableHttpClientTransportOptions(
            requestInit: {
              'headers': {'Authorization': 'Bearer $token'},
            },
          ),
  );
  await client.connect(transport);
  return client;
}

Map<String, Object?> _initializeBody() => const {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': {},
        'clientInfo': {'name': 'direct-http-test', 'version': '1.0.0'},
      },
    };

void main() {
  test('Streamable HTTP exposes the same tools and resource metadata',
      () async {
    final harness = await _start();
    addTearDown(harness.stop);
    final client = await _connect(harness.uri);
    addTearDown(client.close);

    final tools = await client.listTools();
    final byName = {for (final tool in tools.tools) tool.name: tool};
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
        'list_models',
        'suggest_model',
      ]),
    );
    for (final tool in tools.tools) {
      expect(tool.title, isNotEmpty, reason: tool.name);
      expect(tool.description, isNotEmpty, reason: tool.name);
      if (tool.name == 'reserve_provider') {
        expect(tool.annotations?.readOnlyHint, isFalse, reason: tool.name);
        expect(tool.annotations?.idempotentHint, isFalse, reason: tool.name);
      } else if (tool.name == 'release_provider') {
        expect(tool.annotations?.readOnlyHint, isFalse, reason: tool.name);
        expect(tool.annotations?.idempotentHint, isTrue, reason: tool.name);
      } else {
        expect(tool.annotations?.readOnlyHint, isTrue, reason: tool.name);
        expect(tool.annotations?.idempotentHint, isTrue, reason: tool.name);
      }
      expect(tool.outputSchema, isNotNull, reason: tool.name);
    }

    final quotas = await client.callTool(
      const CallToolRequest(name: 'list_quotas'),
    );
    expect(quotas.isError, isFalse);
    expect(quotas.structuredContent?['schema'], 'quotabot.v1');
    expect(quotas.structuredContent?['providers'] as List, hasLength(3));

    final models = await client.callTool(
      const CallToolRequest(name: 'list_models'),
    );
    expect(models.structuredContent?['schema'], 'quotabot.models.v1');
    expect(
      ((models.structuredContent?['models'] as List).first as Map)['id'],
      'claude-http-test',
    );

    final resource = await client.readResource(
      const ReadResourceRequest(uri: 'quotas://current'),
    );
    final decoded = jsonDecode(
      (resource.contents.single as TextResourceContents).text,
    ) as Map<String, dynamic>;
    expect(decoded['schema'], 'quotabot.v1');

    final alerts = await client.readResource(
      const ReadResourceRequest(uri: 'quotas://alerts'),
    );
    final alertJson = jsonDecode(
      (alerts.contents.single as TextResourceContents).text,
    ) as Map<String, dynamic>;
    expect(alertJson['schema'], 'quotabot.alerts.v1');
  });

  test('optional bearer token protects Streamable HTTP sessions', () async {
    final harness = await _start(token: 'secret-token');
    addTearDown(harness.stop);

    final denied = await http.post(
      harness.uri,
      headers: {
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode(_initializeBody()),
    );
    expect(denied.statusCode, HttpStatus.forbidden);

    final client = await _connect(harness.uri, token: 'secret-token');
    addTearDown(client.close);
    final tools = await client.listTools();
    expect(tools.tools.map((tool) => tool.name), contains('suggest_provider'));
  });

  test('DNS rebinding and endpoint hardening reject unsafe requests', () async {
    final harness = await _start();
    addTearDown(harness.stop);

    final evilOrigin = await http.post(
      harness.uri,
      headers: {
        'origin': 'https://evil.example',
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode(_initializeBody()),
    );
    expect(evilOrigin.statusCode, HttpStatus.forbidden);

    final wrongPath = await http.get(harness.uri.replace(path: '/wrong'));
    expect(wrongPath.statusCode, HttpStatus.notFound);

    final wrongMethod = await http.put(harness.uri);
    expect(wrongMethod.statusCode, HttpStatus.methodNotAllowed);
  });

  test('HTTP config stays loopback-only and normalizes endpoint paths', () {
    expect(isLoopbackMcpHost('localhost'), isTrue);
    expect(isLoopbackMcpHost('127.0.0.1'), isTrue);
    expect(isLoopbackMcpHost('[::1]'), isTrue);
    expect(isLoopbackMcpHost('0.0.0.0'), isFalse);
    expect(normalizeMcpHttpPath('mcp'), '/mcp');
    expect(() => normalizeMcpHttpPath('/mcp?x=1'), throwsArgumentError);
    expect(
      () => buildQuotabotStreamableHttpServer(
        config: const QuotabotMcpHttpConfig(host: '0.0.0.0'),
        snapshot: () async => const [],
        burnByProvider: (providers, now) => const <String, BurnStat>{},
      ),
      throwsArgumentError,
    );
  });
}
