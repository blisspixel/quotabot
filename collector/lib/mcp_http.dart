import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart';

import 'leases.dart';
import 'mcp.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'profiles.dart';
import 'util.dart';

const defaultMcpHttpHost = '127.0.0.1';
const defaultMcpHttpPort = 8722;
const defaultMcpHttpPath = '/mcp';
const maxMcpHttpRequestBytes = 256 * 1024;
const maxMcpHttpDrainBytes = 512 * 1024;
const minMcpHttpBearerTokenCharacters = 32;
const mcpHttpBearerRealm = 'quotabot-mcp';
const _mcpAllowedHosts = {'localhost', '127.0.0.1', '::1'};

class QuotabotMcpHttpConfig {
  final String host;
  final int port;
  final String path;
  final String? bearerToken;
  final Set<String>? allowedOrigins;

  const QuotabotMcpHttpConfig({
    this.host = defaultMcpHttpHost,
    this.port = defaultMcpHttpPort,
    this.path = defaultMcpHttpPath,
    this.bearerToken,
    this.allowedOrigins,
  });
}

String normalizeMcpHttpPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return defaultMcpHttpPath;
  if (trimmed.contains('?') || trimmed.contains('#')) {
    throw ArgumentError.value(
        path, 'path', 'path must not contain query/fragment');
  }
  return trimmed.startsWith('/') ? trimmed : '/$trimmed';
}

bool isLoopbackMcpHost(String host) {
  var normalized = host.trim().toLowerCase();
  if (normalized.startsWith('[') && normalized.endsWith(']')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}

Set<String> defaultMcpAllowedOrigins(int port) => {
      'http://localhost:$port',
      'http://127.0.0.1:$port',
      'http://[::1]:$port',
    };

/// Loopback Streamable HTTP MCP server that owns admission before the
/// upstream session transport reads a body.
///
/// Missing or invalid bearer tokens are `401` with a Bearer challenge.
/// POST bodies without a declared length, or larger than
/// [maxMcpHttpRequestBytes], are `413`. Host/origin rebinding stays `403`.
class QuotabotStreamableHttpServer {
  final String host;
  final int port;
  final String path;
  final String bearerToken;
  final Set<String>? allowedOrigins;
  final McpServer Function(String sessionId) serverFactory;

  HttpServer? _http;
  Set<String>? _boundOrigins;
  final Map<String, StreamableHTTPServerTransport> _transports = {};
  final Map<String, McpServer> _servers = {};

  QuotabotStreamableHttpServer({
    required this.host,
    required this.port,
    required this.path,
    required this.bearerToken,
    required this.serverFactory,
    this.allowedOrigins,
  });

  Future<void> start() async {
    if (_http != null) {
      throw StateError('Server already started');
    }
    final http = await HttpServer.bind(host, port);
    _http = http;
    _boundOrigins = allowedOrigins ?? defaultMcpAllowedOrigins(http.port);
    http.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
    for (final transport in _transports.values) {
      await transport.close();
    }
    _transports.clear();
    _servers.clear();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }
    if (request.uri.path != path) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await request.response.close();
      return;
    }
    if (request.method != 'GET' &&
        request.method != 'POST' &&
        request.method != 'DELETE') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, POST, DELETE, OPTIONS')
        ..write('Method Not Allowed');
      await request.response.close();
      return;
    }
    if (request.method == 'POST' &&
        (request.contentLength < 0 ||
            request.contentLength > maxMcpHttpRequestBytes)) {
      await _rejectPayloadTooLarge(request);
      return;
    }
    if (!_hasBearerToken(request, bearerToken)) {
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer realm="$mcpHttpBearerRealm"',
        )
        ..write('Unauthorized');
      await request.response.close();
      return;
    }

    try {
      switch (request.method) {
        case 'POST':
          await _handlePost(request);
        case 'GET':
          await _handleSessionRequest(request);
        case 'DELETE':
          await _handleSessionRequest(request);
      }
    } catch (_) {
      if (!request.response.headers.contentType
          .toString()
          .startsWith('text/event-stream')) {
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Internal Server Error');
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _rejectPayloadTooLarge(HttpRequest request) async {
    final declared = request.contentLength;
    if (declared > 0 && declared <= maxMcpHttpDrainBytes) {
      await request.drain<void>();
    } else {
      request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    }
    request.response
      ..statusCode = HttpStatus.requestEntityTooLarge
      ..write('Payload Too Large');
    await request.response.close();
  }

  Future<void> _handlePost(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId != null && !_transports.containsKey(sessionId)) {
      await _jsonRpcError(
        request.response,
        httpStatus: HttpStatus.notFound,
        errorCode: ErrorCode.connectionClosed,
        message: 'Session not found',
      );
      return;
    }

    final bodyBytes = await request.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) {
        builder.add(chunk);
        return builder;
      },
    );
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(bodyBytes.takeBytes()));
    } catch (_) {
      await _jsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.parseError,
        message: 'Parse error',
      );
      return;
    }
    if (body is List) {
      await _jsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.invalidRequest,
        message: 'Invalid Request: Batch JSON-RPC payloads are not supported',
      );
      return;
    }
    if (body is! Map) {
      await _jsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.invalidRequest,
        message:
            'Invalid Request: POST body must contain a JSON-RPC message object',
      );
      return;
    }

    if (sessionId != null) {
      await _transports[sessionId]!.handleRequest(request, body);
      return;
    }
    if (body['method'] == 'initialize') {
      final transport = _createTransport();
      await transport.handleRequest(request, body);
      return;
    }
    await _jsonRpcError(
      request.response,
      httpStatus: HttpStatus.badRequest,
      errorCode: ErrorCode.connectionClosed,
      message:
          'Bad Request: No valid session ID provided or not an initialization request',
    );
  }

  Future<void> _handleSessionRequest(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId == null) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing session ID');
      await request.response.close();
      return;
    }
    final transport = _transports[sessionId];
    if (transport == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Session not found');
      await request.response.close();
      return;
    }
    await transport.handleRequest(request);
  }

  StreamableHTTPServerTransport _createTransport() {
    late final StreamableHTTPServerTransport transport;
    transport = StreamableHTTPServerTransport(
      options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: _mcpSessionId,
        enableDnsRebindingProtection: true,
        allowedHosts: _mcpAllowedHosts,
        allowedOrigins: _boundOrigins,
        strictProtocolVersionHeaderValidation: true,
        rejectBatchJsonRpcPayloads: true,
        onsessioninitialized: (sessionId) {
          _transports[sessionId] = transport;
          final server = serverFactory(sessionId);
          _servers[sessionId] = server;
          server.connect(transport).catchError((_) {
            _transports.remove(sessionId);
            _servers.remove(sessionId);
          });
        },
      ),
    );
    transport.onclose = () {
      final sessionId = transport.sessionId;
      if (sessionId != null) {
        _transports.remove(sessionId);
        _servers.remove(sessionId);
      }
    };
    return transport;
  }
}

QuotabotStreamableHttpServer buildQuotabotStreamableHttpServer({
  required QuotabotMcpHttpConfig config,
  required SnapshotProvider snapshot,
  required BurnProvider burnByProvider,
  CachedSnapshotProvider cachedSnapshot = emptyCachedSnapshot,
  RouteLeaseStore leaseStore = const NoopRouteLeaseStore(),
  bool enableSubscriptionTimers = true,
  int Function() now = nowEpoch,
  Map<String, List<ModelInfo>> catalog = kModelCatalog,
  ProfileLoader profileLoader = loadProfile,
}) {
  final path = normalizeMcpHttpPath(config.path);
  if (!isLoopbackMcpHost(config.host)) {
    throw ArgumentError.value(
      config.host,
      'host',
      'Streamable HTTP MCP must bind to localhost, 127.0.0.1, or ::1',
    );
  }
  if (config.port < 1 || config.port > 65535) {
    throw ArgumentError.value(config.port, 'port', 'port must be 1..65535');
  }
  final bearerToken = config.bearerToken?.trim();
  if (bearerToken == null ||
      bearerToken.length < minMcpHttpBearerTokenCharacters) {
    throw ArgumentError.value(
      null,
      'bearerToken',
      'Streamable HTTP MCP requires a bearer token of at least '
          '$minMcpHttpBearerTokenCharacters characters',
    );
  }

  return QuotabotStreamableHttpServer(
    host: config.host,
    port: config.port,
    path: path,
    bearerToken: bearerToken,
    allowedOrigins: config.allowedOrigins,
    serverFactory: (_) => buildQuotabotMcpServer(
      snapshot: snapshot,
      burnByProvider: burnByProvider,
      cachedSnapshot: cachedSnapshot,
      leaseStore: leaseStore,
      enableSubscriptionTimers: enableSubscriptionTimers,
      now: now,
      catalog: catalog,
      profileLoader: profileLoader,
    ),
  );
}

String _mcpSessionId() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

Future<void> _jsonRpcError(
  HttpResponse response, {
  required int httpStatus,
  required ErrorCode errorCode,
  required String message,
}) async {
  response
    ..statusCode = httpStatus
    ..write(
      jsonEncode(
        JsonRpcError(
          id: null,
          error: JsonRpcErrorData(
            code: errorCode.value,
            message: message,
          ),
        ).toJson(),
      ),
    );
  await response.close();
}

bool _hasBearerToken(HttpRequest request, String expected) {
  final value = request.headers.value(HttpHeaders.authorizationHeader);
  if (value == null) return false;
  final index = value.indexOf(' ');
  if (index <= 0) return false;
  final scheme = value.substring(0, index).toLowerCase();
  final token = value.substring(index + 1).trim();
  return scheme == 'bearer' && _constantTimeEquals(token, expected);
}

bool _constantTimeEquals(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  var diff = left.length ^ right.length;
  final length = math.max(left.length, right.length);
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    diff |= x ^ y;
  }
  return diff == 0;
}
