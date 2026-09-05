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

Future<_Harness> _start({
  String token = _token,
  Duration requestBodyTimeout = defaultMcpHttpRequestBodyTimeout,
  int maxSessions = defaultMaxMcpHttpSessions,
  int maxConcurrentRequests = defaultMaxMcpHttpConcurrentRequests,
}) async {
  // Asking the operating system for a free port and then binding it is a race:
  // the probe socket must close before the server can claim that port, and any
  // suite running in parallel can take it in the gap. The server under test
  // needs a known port to build its URL, so retry with a fresh one rather than
  // failing the whole run over a lost race.
  for (var attempt = 0;; attempt++) {
    final port = await _freePort();
    final server = buildQuotabotStreamableHttpServer(
      config: QuotabotMcpHttpConfig(
        port: port,
        bearerToken: token,
        requestBodyTimeout: requestBodyTimeout,
        maxSessions: maxSessions,
        maxConcurrentRequests: maxConcurrentRequests,
      ),
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

Future<String> _incompleteRawResponse(_Harness harness, String request) async {
  final socket = await Socket.connect('127.0.0.1', harness.uri.port);
  try {
    socket.write(request);
    await socket.flush();
    return await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 3));
  } finally {
    socket.destroy();
  }
}

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

    http.Response? unauthenticatedOversized;
    final unauthenticatedElapsed = Stopwatch()..start();
    try {
      unauthenticatedOversized = await http
          .post(
            harness.uri,
            headers: {
              HttpHeaders.acceptHeader: 'application/json, text/event-stream',
              HttpHeaders.contentTypeHeader: 'application/json',
            },
            body: List<int>.filled(maxMcpHttpRequestBytes + 1, 0x20),
          )
          .timeout(const Duration(seconds: 2));
    } on http.ClientException {
      // Windows can abort the upload after the server flushes and closes its
      // unauthorized response. That prompt close is an equally bounded
      // rejection for a client that is still writing the oversized body.
    }
    expect(
        unauthenticatedElapsed.elapsed, lessThan(const Duration(seconds: 2)));
    if (unauthenticatedOversized != null) {
      expect(
        unauthenticatedOversized.statusCode,
        HttpStatus.unauthorized,
      );
      expect(
        unauthenticatedOversized.headers[HttpHeaders.wwwAuthenticateHeader],
        contains('Bearer realm="$mcpHttpBearerRealm"'),
      );
    }

    final preauthSocket = await Socket.connect('127.0.0.1', harness.uri.port);
    addTearDown(preauthSocket.destroy);
    final preauthElapsed = Stopwatch()..start();
    preauthSocket.write(
      'POST ${harness.uri.path} HTTP/1.1\r\n'
      'Host: 127.0.0.1:${harness.uri.port}\r\n'
      'Accept: application/json, text/event-stream\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: ${maxMcpHttpRequestBytes + 1}\r\n'
      'Connection: close\r\n'
      '\r\n'
      '{',
    );
    await preauthSocket.flush();
    final preauthResponse = await utf8.decoder
        .bind(preauthSocket)
        .join()
        .timeout(const Duration(seconds: 3));
    expect(preauthResponse, contains(' 401 '));
    expect(preauthResponse, contains('Unauthorized'));
    expect(preauthElapsed.elapsed, lessThan(const Duration(seconds: 2)));

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

  test('times out a stalled authenticated request body', () async {
    final harness = await _start(
      requestBodyTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(harness.stop);

    final socket = await Socket.connect('127.0.0.1', harness.uri.port);
    addTearDown(socket.destroy);
    socket.write(
      'POST ${harness.uri.path} HTTP/1.1\r\n'
      'Host: 127.0.0.1:${harness.uri.port}\r\n'
      'Authorization: Bearer $_token\r\n'
      'Accept: application/json, text/event-stream\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: 100\r\n'
      'Connection: close\r\n'
      '\r\n'
      '{',
    );
    await socket.flush();

    final response = await utf8.decoder.bind(socket).join().timeout(
          const Duration(seconds: 3),
        );
    expect(response, contains(' 408 '));
    expect(response, contains('Request body timed out'));
  });

  test('early MCP rejections release incomplete request bodies promptly',
      () async {
    final harness = await _start(
      requestBodyTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(harness.stop);
    final authority = '127.0.0.1:${harness.uri.port}';
    final cases = <(String, String)>[
      (
        ' 200 ',
        'OPTIONS ${harness.uri.path} HTTP/1.1\r\n'
            'Host: $authority\r\n'
            'Content-Length: 100\r\n'
            'Connection: close\r\n\r\n{',
      ),
      (
        ' 404 ',
        'POST /wrong HTTP/1.1\r\n'
            'Host: $authority\r\n'
            'Content-Length: 100\r\n'
            'Connection: close\r\n\r\n{',
      ),
      (
        ' 405 ',
        'PUT ${harness.uri.path} HTTP/1.1\r\n'
            'Host: $authority\r\n'
            'Content-Length: 100\r\n'
            'Connection: close\r\n\r\n{',
      ),
      (
        ' 404 ',
        'POST ${harness.uri.path} HTTP/1.1\r\n'
            'Host: $authority\r\n'
            'Authorization: Bearer $_token\r\n'
            'Mcp-Session-Id: missing-session\r\n'
            'Content-Length: 100\r\n'
            'Connection: close\r\n\r\n{',
      ),
      (
        ' 400 ',
        'GET ${harness.uri.path} HTTP/1.1\r\n'
            'Host: $authority\r\n'
            'Authorization: Bearer $_token\r\n'
            'Content-Length: 100\r\n'
            'Connection: close\r\n\r\n{',
      ),
      (
        ' 413 ',
        'POST ${harness.uri.path} HTTP/1.1\r\n'
            'Host: $authority\r\n'
            'Authorization: Bearer $_token\r\n'
            'Content-Length: ${maxMcpHttpDrainBytes + 1}\r\n'
            'Connection: close\r\n\r\n{',
      ),
      (
        ' 413 ',
        'POST ${harness.uri.path} HTTP/1.1\r\n'
            'Host: $authority\r\n'
            'Authorization: Bearer $_token\r\n'
            'Transfer-Encoding: chunked\r\n'
            'Connection: close\r\n\r\n1\r\n{\r\n',
      ),
    ];
    for (final entry in cases) {
      final elapsed = Stopwatch()..start();
      final response = await _incompleteRawResponse(harness, entry.$2);
      expect(response, contains(entry.$1),
          reason: entry.$2.split('\r\n').first);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    }
  });

  test('MCP request capacity is bounded and recovers', () async {
    final harness = await _start(
      requestBodyTimeout: const Duration(seconds: 3),
      maxConcurrentRequests: 1,
    );
    addTearDown(harness.stop);
    final authority = '127.0.0.1:${harness.uri.port}';
    final stalled = await Socket.connect('127.0.0.1', harness.uri.port);
    addTearDown(stalled.destroy);
    stalled.write(
      'POST ${harness.uri.path} HTTP/1.1\r\n'
      'Host: $authority\r\n'
      'Authorization: Bearer $_token\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: 100\r\n'
      'Connection: close\r\n\r\n{',
    );
    await stalled.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final busy = await _incompleteRawResponse(
      harness,
      'GET ${harness.uri.path} HTTP/1.1\r\n'
      'Host: $authority\r\n'
      'Authorization: Bearer $_token\r\n'
      'Connection: close\r\n\r\n',
    );
    expect(busy, contains(' 503 '));
    expect(busy, contains('Request capacity reached'));

    stalled.destroy();
    http.Response? recovered;
    for (var attempt = 0; attempt < 20; attempt++) {
      recovered = await http.get(
        harness.uri,
        headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'},
      );
      if (recovered.statusCode != HttpStatus.serviceUnavailable) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(recovered?.statusCode, HttpStatus.badRequest);
    expect(recovered?.body, contains('Missing session ID'));
  });

  test('bounds authenticated Streamable HTTP sessions', () async {
    final harness = await _start(maxSessions: 1);
    addTearDown(harness.stop);
    final first = await _connect(harness.uri);
    addTearDown(first.close);

    final second = await http.post(
      harness.uri,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $_token',
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode(_initializeBody()),
    );
    expect(second.statusCode, HttpStatus.serviceUnavailable);
    expect(second.headers[HttpHeaders.retryAfterHeader], '1');
    expect(second.body, contains('Session capacity reached'));
  });

  test('authenticated DELETE releases a session slot for a new client',
      () async {
    final harness = await _start(maxSessions: 1);
    addTearDown(harness.stop);
    final initialized = await http.post(
      harness.uri,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $_token',
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: jsonEncode(_initializeBody()),
    );
    expect(initialized.statusCode, HttpStatus.ok);
    final sessionId = initialized.headers['mcp-session-id'];
    expect(sessionId, isNotEmpty);

    final deleted = await http.delete(harness.uri, headers: {
      HttpHeaders.authorizationHeader: 'Bearer $_token',
      'mcp-session-id': sessionId!,
      'mcp-protocol-version': '2025-11-25',
    });
    expect(deleted.statusCode, HttpStatus.ok);

    final replacement = await _connect(harness.uri);
    addTearDown(replacement.close);
    expect((await replacement.listTools()).tools.map((tool) => tool.name),
        contains('suggest_provider'));
  });

  test('stopping multiple sessions tolerates their close callbacks', () async {
    final harness = await _start();
    addTearDown(harness.stop);
    final first = await _connect(harness.uri);
    addTearDown(first.close);
    final second = await _connect(harness.uri);
    addTearDown(second.close);

    await expectLater(harness.stop(), completes);
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
    expect(
      () => QuotabotStreamableHttpServer(
        host: '0.0.0.0',
        port: 8722,
        path: '/mcp',
        bearerToken: _token,
        serverFactory: (_) => throw StateError('must not construct'),
      ),
      throwsArgumentError,
    );
    expect(
      () => buildQuotabotStreamableHttpServer(
        config: const QuotabotMcpHttpConfig(
          bearerToken: _token,
          requestBodyTimeout: Duration.zero,
        ),
        snapshot: () async => const [],
        burnByProvider: (providers, now) => const <String, BurnStat>{},
      ),
      throwsArgumentError,
    );
    expect(
      () => buildQuotabotStreamableHttpServer(
        config: const QuotabotMcpHttpConfig(
          bearerToken: _token,
          maxSessions: 0,
        ),
        snapshot: () async => const [],
        burnByProvider: (providers, now) => const <String, BurnStat>{},
      ),
      throwsArgumentError,
    );
    expect(
      () => buildQuotabotStreamableHttpServer(
        config: const QuotabotMcpHttpConfig(
          bearerToken: _token,
          maxConcurrentRequests: 0,
        ),
        snapshot: () async => const [],
        burnByProvider: (providers, now) => const <String, BurnStat>{},
      ),
      throwsArgumentError,
    );
  });
}
