import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/mcp_http.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;
const _token = '0123456789abcdef0123456789abcdef';

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
  final QuotabotStreamableHttpServer server;
  final Uri uri;

  const _Harness(this.server, this.uri);

  Future<void> stop() => server.stop();
}

Future<_Harness> _start({String token = _token}) async {
  // Asking the operating system for a free port and then binding it is a race:
  // the probe socket must close before the server can claim that port, and any
  // suite running in parallel can take it in the gap. The server under test
  // needs a known port to build its URL, so retry with a fresh one rather than
  // failing the whole run over a lost race.
  for (var attempt = 0;; attempt++) {
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
    try {
      await server.start();
      return _Harness(server, Uri.parse('http://127.0.0.1:$port/mcp'));
    } on SocketException {
      if (attempt >= 9) rethrow;
    }
  }
}

Future<McpClient> _connect(Uri uri, {String token = _token}) async {
  final client = McpClient(
    const Implementation(name: 'quotabot-http-test', version: '1.0.0'),
  );
  final transport = StreamableHttpClientTransport(
    uri,
    opts: StreamableHttpClientTransportOptions(
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
        'capabilities': <String, Object?>{},
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
    const liveCollectionTools = {
      'list_quotas',
      'provider_with_most_headroom',
      'suggest_provider',
      'reserve_provider',
      'list_models',
      'suggest_model',
      'check_provider_availability',
    };
    for (final tool in tools.tools) {
      expect(tool.title, isNotEmpty, reason: tool.name);
      expect(tool.description, isNotEmpty, reason: tool.name);
      if (liveCollectionTools.contains(tool.name)) {
        expect(tool.annotations?.readOnlyHint, isFalse, reason: tool.name);
        expect(tool.annotations?.idempotentHint, isFalse, reason: tool.name);
        expect(tool.annotations?.openWorldHint, isTrue, reason: tool.name);
      } else if (tool.name == 'release_provider') {
        expect(tool.annotations?.readOnlyHint, isFalse, reason: tool.name);
        expect(tool.annotations?.idempotentHint, isTrue, reason: tool.name);
        expect(tool.annotations?.openWorldHint, isFalse, reason: tool.name);
      } else if (tool.name == 'decide_now') {
        expect(tool.annotations?.readOnlyHint, isFalse, reason: tool.name);
        expect(tool.annotations?.idempotentHint, isFalse, reason: tool.name);
        expect(tool.annotations?.openWorldHint, isFalse, reason: tool.name);
      } else {
        fail('unclassified MCP tool annotations: ${tool.name}');
      }
      expect(tool.annotations?.destructiveHint, isFalse, reason: tool.name);
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

  test('required bearer token protects Streamable HTTP sessions', () async {
    expect(
      () => buildQuotabotStreamableHttpServer(
        config: const QuotabotMcpHttpConfig(),
        snapshot: () async => const [],
        burnByProvider: (providers, now) => const <String, BurnStat>{},
      ),
      throwsArgumentError,
    );

    final harness = await _start();
    addTearDown(harness.stop);

    final denied = await http.post(
      harness.uri,
      headers: {
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode(_initializeBody()),
    );
    expect(denied.statusCode, HttpStatus.unauthorized);
    expect(
      denied.headers[HttpHeaders.wwwAuthenticateHeader],
      contains('Bearer realm="$mcpHttpBearerRealm"'),
    );

    final client = await _connect(harness.uri);
    addTearDown(client.close);
    final tools = await client.listTools();
    expect(tools.tools.map((tool) => tool.name), contains('suggest_provider'));
  });

  test('rejects oversized and indeterminate HTTP request bodies', () async {
    final harness = await _start();
    addTearDown(harness.stop);

    final headers = {
      HttpHeaders.authorizationHeader: 'Bearer $_token',
      HttpHeaders.acceptHeader: 'application/json, text/event-stream',
      HttpHeaders.contentTypeHeader: 'application/json',
    };
    final oversized = await http.post(
      harness.uri,
      headers: headers,
      body: List<int>.filled(maxMcpHttpRequestBytes + 1, 0x20),
    );
    expect(oversized.statusCode, HttpStatus.requestEntityTooLarge);

    final rawClient = HttpClient();
    addTearDown(() => rawClient.close(force: true));
    final chunked = await rawClient.postUrl(harness.uri);
    headers.forEach(chunked.headers.set);
    chunked.add(utf8.encode(jsonEncode(_initializeBody())));
    final chunkedResponse = await chunked.close();
    await chunkedResponse.drain<void>();
    expect(chunkedResponse.statusCode, HttpStatus.requestEntityTooLarge);

    final unauthenticatedOversized = await http.post(
      harness.uri,
      headers: {
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: List<int>.filled(maxMcpHttpRequestBytes + 1, 0x20),
    );
    expect(
      unauthenticatedOversized.statusCode,
      HttpStatus.requestEntityTooLarge,
    );

    final wrongToken = await http.post(
      harness.uri,
      headers: {
        HttpHeaders.authorizationHeader:
            'Bearer ${_token.replaceFirst('0', '1')}',
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode(_initializeBody()),
    );
    expect(wrongToken.statusCode, HttpStatus.unauthorized);
  });

  test('DNS rebinding and endpoint hardening reject unsafe requests', () async {
    final harness = await _start();
    addTearDown(harness.stop);

    final evilOrigin = await http.post(
      harness.uri,
      headers: {
        'origin': 'https://evil.example',
        HttpHeaders.authorizationHeader: 'Bearer $_token',
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode(_initializeBody()),
    );
    expect(evilOrigin.statusCode, HttpStatus.forbidden);

    final wrongPath = await http.get(harness.uri.replace(path: '/wrong'));
    expect(wrongPath.statusCode, HttpStatus.notFound);

    final wrongMethod = await http.put(
      harness.uri,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $_token',
      },
    );
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
