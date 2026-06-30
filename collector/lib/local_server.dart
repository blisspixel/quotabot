import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'analysis.dart';
import 'cache.dart';
import 'models.dart';
import 'provider_filters.dart';
import 'util.dart';

typedef LocalQuotaSnapshotProvider = Future<List<ProviderQuota>> Function();

Future<HttpServer> startLocalQuotabotServer({
  int port = 8721,
  InternetAddress? address,
  required LocalQuotaSnapshotProvider snapshotProvider,
  int Function() now = nowEpoch,
  void Function(String message)? log,
}) async {
  final server =
      await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
  log?.call(
    'quotabot local server listening on http://localhost:${server.port}/',
  );
  log?.call('serves current quota snapshot as JSON on every request');
  log?.call('press ctrl-c to stop\n');

  // Throttle: every endpoint can make authenticated provider calls. Cache the
  // snapshot briefly so a busy local client cannot drive repeated outbound calls
  // and trip provider rate limits.
  List<ProviderQuota>? cached;
  var cachedAt = 0;
  Future<List<ProviderQuota>> snapshot() async {
    final current = now();
    if (cached != null && current - cachedAt < 5) return cached!;
    cached = await snapshotProvider();
    cachedAt = current;
    return cached!;
  }

  void writeJson(HttpRequest req, Object data, [int status = HttpStatus.ok]) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(const JsonEncoder.withIndent('  ').convert(data));
  }

  Future<void> serve() async {
    await for (final request in server) {
      final path = request.uri.path;
      try {
        if (request.method != 'GET') {
          writeJson(
            request,
            {'error': 'method not allowed'},
            HttpStatus.methodNotAllowed,
          );
        } else if (path == '/') {
          final results = await snapshot();
          writeJson(request, {
            'schema': 'quotabot.v1',
            'generated_at': now(),
            'providers': results.map((r) => r.toJson()).toList(),
          });
        } else if (path == '/suggest') {
          final exclusions = parseProviderExclusions(
            request.uri.queryParametersAll['exclude'],
          );
          if (!exclusions.ok) {
            writeJson(
              request,
              {'error': exclusions.error},
              HttpStatus.badRequest,
            );
          } else {
            final snap =
                filterExcludedProviders(await snapshot(), exclusions.providers);
            final current = now();
            writeJson(
              request,
              suggestRoute(
                snap,
                current,
                burnStatsByProvider: recentBurnStatsByProvider(
                  snap.map((q) => q.provider),
                  current,
                ),
              ).toJson(),
            );
          }
        } else if (path == '/health') {
          writeJson(request, {'ok': true, 'generated_at': now()});
        } else if (path.startsWith('/providers/')) {
          final name = path.substring('/providers/'.length).toLowerCase();
          final match = (await snapshot()).where((r) => r.provider == name);
          if (match.isEmpty) {
            writeJson(
              request,
              {'error': 'unknown provider'},
              HttpStatus.notFound,
            );
          } else {
            writeJson(request, match.first.toJson());
          }
        } else {
          writeJson(request, {'error': 'not found'}, HttpStatus.notFound);
        }
      } catch (_) {
        // Do not leak internal exception detail to the client.
        writeJson(
          request,
          {'error': 'internal error'},
          HttpStatus.internalServerError,
        );
      }
      await request.response.close();
    }
  }

  unawaited(serve());
  return server;
}
