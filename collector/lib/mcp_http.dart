import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
const minMcpHttpBearerTokenCharacters = 32;

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

StreamableMcpServer buildQuotabotStreamableHttpServer({
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

  return StreamableMcpServer(
    host: config.host,
    port: config.port,
    path: path,
    enableDnsRebindingProtection: true,
    allowedHosts: const {'localhost', '127.0.0.1', '::1'},
    allowedOrigins:
        config.allowedOrigins ?? defaultMcpAllowedOrigins(config.port),
    strictProtocolVersionHeaderValidation: true,
    rejectBatchJsonRpcPayloads: true,
    authenticationHandler: _requestAdmissionFor(bearerToken),
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

FutureOr<StreamableMcpAuthenticationResult> Function(dynamic)
    _requestAdmissionFor(String bearerToken) {
  return (request) {
    if (request is! HttpRequest || !_hasBearerToken(request, bearerToken)) {
      return const StreamableMcpAuthenticationResult.unauthorized(
        errorDescription: 'missing or invalid bearer token',
      );
    }
    if (request.method == 'POST' &&
        (request.contentLength < 0 ||
            request.contentLength > maxMcpHttpRequestBytes)) {
      return const StreamableMcpAuthenticationResult.unauthorized(
        errorDescription: 'request body length is missing or too large',
      );
    }
    return const StreamableMcpAuthenticationResult.allow();
  };
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
