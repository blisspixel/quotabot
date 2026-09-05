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
import 'refresh_timer.dart';
import 'util.dart';

const defaultMcpHttpHost = '127.0.0.1';
const defaultMcpHttpPort = 8722;
const defaultMcpHttpPath = '/mcp';
const maxMcpHttpRequestBytes = 256 * 1024;
const maxMcpHttpDrainBytes = 512 * 1024;
const minMcpHttpBearerTokenCharacters = 32;
const defaultMcpHttpRequestBodyTimeout = Duration(seconds: 15);
const defaultMaxMcpHttpSessions = 64;
const defaultMaxMcpHttpConcurrentRequests = 128;
const _rejectedRequestSocketDestroyDelay = Duration(milliseconds: 25);
const mcpHttpBearerRealm = 'quotabot-mcp';
const _mcpAllowedHosts = {'localhost', '127.0.0.1', '::1'};

class QuotabotMcpHttpConfig {
  final String host;
  final int port;
  final String path;
  final String? bearerToken;
  final Set<String>? allowedOrigins;
  final Duration requestBodyTimeout;
  final int maxSessions;
  final int maxConcurrentRequests;

  const QuotabotMcpHttpConfig({
    this.host = defaultMcpHttpHost,
    this.port = defaultMcpHttpPort,
    this.path = defaultMcpHttpPath,
    this.bearerToken,
    this.allowedOrigins,
    this.requestBodyTimeout = defaultMcpHttpRequestBodyTimeout,
    this.maxSessions = defaultMaxMcpHttpSessions,
    this.maxConcurrentRequests = defaultMaxMcpHttpConcurrentRequests,
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
  final Duration requestBodyTimeout;
  final int maxSessions;
  final int maxConcurrentRequests;
  final McpServer Function(String sessionId) serverFactory;

  HttpServer? _http;
  Set<String>? _boundOrigins;
  final Map<String, StreamableHTTPServerTransport> _transports = {};
  final Map<String, McpServer> _servers = {};
  int _pendingSessionInitializations = 0;
  int _activeRequests = 0;

  QuotabotStreamableHttpServer({
    required this.host,
    required this.port,
    required this.path,
    required this.bearerToken,
    required this.serverFactory,
    this.allowedOrigins,
    this.requestBodyTimeout = defaultMcpHttpRequestBodyTimeout,
    this.maxSessions = defaultMaxMcpHttpSessions,
    this.maxConcurrentRequests = defaultMaxMcpHttpConcurrentRequests,
  }) {
    if (!isLoopbackMcpHost(host)) {
      throw ArgumentError.value(
        host,
        'host',
        'Streamable HTTP MCP must bind to localhost, 127.0.0.1, or ::1',
      );
    }
    if (requestBodyTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestBodyTimeout,
        'requestBodyTimeout',
        'must be greater than zero',
      );
    }
    if (maxSessions < 1) {
      throw ArgumentError.value(
          maxSessions, 'maxSessions', 'must be at least 1');
    }
    if (maxConcurrentRequests < 1) {
      throw ArgumentError.value(
        maxConcurrentRequests,
        'maxConcurrentRequests',
        'must be at least 1',
      );
    }
  }

  Future<void> start() async {
    if (_http != null) {
      throw StateError('Server already started');
    }
    final http = await HttpServer.bind(host, port);
    _http = http;
    _boundOrigins = allowedOrigins ?? defaultMcpAllowedOrigins(http.port);
    http.listen(_admitRequest);
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
    for (final transport in _transports.values.toList()) {
      await transport.close();
    }
    _transports.clear();
    _servers.clear();
  }

  void _admitRequest(HttpRequest request) {
    if (_activeRequests >= maxConcurrentRequests) {
      unawaited(
        _rejectPlain(
          request,
          status: HttpStatus.serviceUnavailable,
          body: 'Request capacity reached',
          headers: {HttpHeaders.retryAfterHeader: '1'},
        ).catchError((_) {}),
      );
      return;
    }
    _activeRequests++;
    unawaited(
      _handleRequest(request)
          .whenComplete(() => _activeRequests--)
          .catchError((_) {}),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method == 'OPTIONS') {
      await _rejectPlain(request, status: HttpStatus.ok, body: '');
      return;
    }
    if (request.uri.path != path) {
      await _rejectPlain(
        request,
        status: HttpStatus.notFound,
        body: 'Not Found',
      );
      return;
    }
    if (request.method != 'GET' &&
        request.method != 'POST' &&
        request.method != 'DELETE') {
      await _rejectPlain(
        request,
        status: HttpStatus.methodNotAllowed,
        body: 'Method Not Allowed',
        headers: {
          HttpHeaders.allowHeader: 'GET, POST, DELETE, OPTIONS',
        },
      );
      return;
    }
    if (!_hasBearerToken(request, bearerToken)) {
      await _rejectUnauthorized(request);
      return;
    }
    if (request.method == 'POST' &&
        (request.contentLength < 0 ||
            request.contentLength > maxMcpHttpRequestBytes)) {
      await _rejectPayloadTooLarge(request);
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

  bool _requestMayHaveBody(HttpRequest request) =>
      request.contentLength > 0 || request.headers.chunkedTransferEncoding;

  Future<void> _rejectPlain(
    HttpRequest request, {
    required int status,
    required String body,
    Map<String, String> headers = const {},
    bool bodyConsumed = false,
  }) =>
      _rejectResponse(
        request,
        status: status,
        body: body,
        headers: headers,
        bodyConsumed: bodyConsumed,
      );

  Future<void> _rejectResponse(
    HttpRequest request, {
    required int status,
    required String body,
    Map<String, String> headers = const {},
    ContentType? contentType,
    bool bodyConsumed = false,
  }) async {
    final bytes = utf8.encode(body);
    request.response
      ..statusCode = status
      ..headers.contentLength = bytes.length;
    if (contentType != null) request.response.headers.contentType = contentType;
    for (final entry in headers.entries) {
      request.response.headers.set(entry.key, entry.value);
    }
    if (!bodyConsumed && _requestMayHaveBody(request)) {
      request.response.headers.set(HttpHeaders.connectionHeader, 'close');
      Socket? socket;
      try {
        socket = await request.response.detachSocket(writeHeaders: true);
        if (request.method != 'HEAD' && bytes.isNotEmpty) socket.add(bytes);
        await socket.flush();
        unawaited(socket.close());
        Timer(_rejectedRequestSocketDestroyDelay, socket.destroy);
      } catch (_) {
        socket?.destroy();
      }
      return;
    }
    if (request.method != 'HEAD' && bytes.isNotEmpty) {
      request.response.add(bytes);
    }
    await request.response.close();
  }

  Future<void> _rejectUnauthorized(HttpRequest request) async {
    await _rejectPlain(
      request,
      status: HttpStatus.unauthorized,
      body: 'Unauthorized',
      headers: {
        HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="$mcpHttpBearerRealm"',
      },
    );
  }

  Future<void> _rejectPayloadTooLarge(HttpRequest request) async {
    final declared = request.contentLength;
    var bodyConsumed = false;
    if (declared > 0 && declared <= maxMcpHttpDrainBytes) {
      try {
        await request.drain<void>().timeout(requestBodyTimeout);
        bodyConsumed = true;
      } on TimeoutException {
        bodyConsumed = false;
      }
    }
    await _rejectPlain(
      request,
      status: HttpStatus.requestEntityTooLarge,
      body: 'Payload Too Large',
      bodyConsumed: bodyConsumed,
    );
  }

  Future<void> _jsonRpcError(
    HttpRequest request, {
    required int httpStatus,
    required ErrorCode errorCode,
    required String message,
    bool bodyConsumed = false,
  }) =>
      _rejectResponse(
        request,
        status: httpStatus,
        body: jsonEncode(
          JsonRpcError(
            id: null,
            error: JsonRpcErrorData(
              code: errorCode.value,
              message: message,
            ),
          ).toJson(),
        ),
        contentType: ContentType.json,
        bodyConsumed: bodyConsumed,
      );

  Future<void> _handlePost(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId != null && !_transports.containsKey(sessionId)) {
      await _jsonRpcError(
        request,
        httpStatus: HttpStatus.notFound,
        errorCode: ErrorCode.connectionClosed,
        message: 'Session not found',
      );
      return;
    }

    BytesBuilder bodyBytes;
    try {
      bodyBytes = await request.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) {
          builder.add(chunk);
          return builder;
        },
      ).timeout(requestBodyTimeout);
    } on TimeoutException {
      request.response.headers.set(HttpHeaders.connectionHeader, 'close');
      await _jsonRpcError(
        request,
        httpStatus: HttpStatus.requestTimeout,
        errorCode: ErrorCode.invalidRequest,
        message: 'Request body timed out',
      );
      return;
    }
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(bodyBytes.takeBytes()));
    } catch (_) {
      await _jsonRpcError(
        request,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.parseError,
        message: 'Parse error',
        bodyConsumed: true,
      );
      return;
    }
    if (body is List) {
      await _jsonRpcError(
        request,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.invalidRequest,
        message: 'Invalid Request: Batch JSON-RPC payloads are not supported',
        bodyConsumed: true,
      );
      return;
    }
    if (body is! Map) {
      await _jsonRpcError(
        request,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.invalidRequest,
        message:
            'Invalid Request: POST body must contain a JSON-RPC message object',
        bodyConsumed: true,
      );
      return;
    }

    if (sessionId != null) {
      await _transports[sessionId]!.handleRequest(request, body);
      return;
    }
    if (body['method'] == 'initialize') {
      if (_transports.length + _pendingSessionInitializations >= maxSessions) {
        request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
        await _jsonRpcError(
          request,
          httpStatus: HttpStatus.serviceUnavailable,
          errorCode: ErrorCode.connectionClosed,
          message: 'Session capacity reached',
          bodyConsumed: true,
        );
        return;
      }
      final transport = _createTransport();
      _pendingSessionInitializations++;
      try {
        await transport.handleRequest(request, body);
      } finally {
        _pendingSessionInitializations--;
      }
      return;
    }
    await _jsonRpcError(
      request,
      httpStatus: HttpStatus.badRequest,
      errorCode: ErrorCode.connectionClosed,
      message:
          'Bad Request: No valid session ID provided or not an initialization request',
      bodyConsumed: true,
    );
  }

  Future<void> _handleSessionRequest(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId == null) {
      await _rejectPlain(
        request,
        status: HttpStatus.badRequest,
        body: 'Missing session ID',
      );
      return;
    }
    final transport = _transports[sessionId];
    if (transport == null) {
      await _rejectPlain(
        request,
        status: HttpStatus.notFound,
        body: 'Session not found',
      );
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
          // Protocol.connect owns transport.onclose. Chain session bookkeeping
          // at the server callback so it survives connection and still disposes
          // the quota subscription hub when a session closes.
          // ignore: deprecated_member_use
          final onClose = server.server.onclose;
          // ignore: deprecated_member_use
          server.server.onclose = () {
            try {
              onClose?.call();
            } finally {
              _transports.remove(sessionId);
              _servers.remove(sessionId);
            }
          };
          server.connect(transport).catchError((_) {
            _transports.remove(sessionId);
            _servers.remove(sessionId);
          });
        },
      ),
    );
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
  Set<String> providersWithUsageCooldowns = const {},
  RefreshTimerFactory? subscriptionTimerFactory,
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
  if (config.requestBodyTimeout <= Duration.zero) {
    throw ArgumentError.value(
      config.requestBodyTimeout,
      'requestBodyTimeout',
      'must be greater than zero',
    );
  }
  if (config.maxSessions < 1) {
    throw ArgumentError.value(
      config.maxSessions,
      'maxSessions',
      'must be at least 1',
    );
  }
  if (config.maxConcurrentRequests < 1) {
    throw ArgumentError.value(
      config.maxConcurrentRequests,
      'maxConcurrentRequests',
      'must be at least 1',
    );
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

  final usageCooldownProviders =
      Set<String>.unmodifiable(providersWithUsageCooldowns);
  return QuotabotStreamableHttpServer(
    host: config.host,
    port: config.port,
    path: path,
    bearerToken: bearerToken,
    allowedOrigins: config.allowedOrigins,
    requestBodyTimeout: config.requestBodyTimeout,
    maxSessions: config.maxSessions,
    maxConcurrentRequests: config.maxConcurrentRequests,
    serverFactory: (_) => buildQuotabotMcpServer(
      snapshot: snapshot,
      burnByProvider: burnByProvider,
      cachedSnapshot: cachedSnapshot,
      leaseStore: leaseStore,
      enableSubscriptionTimers: enableSubscriptionTimers,
      providersWithUsageCooldowns: usageCooldownProviders,
      subscriptionTimerFactory: subscriptionTimerFactory,
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
