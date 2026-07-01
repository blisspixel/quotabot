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

  bool queryFlag(Uri uri, String snakeName, String kebabName) {
    final values = [
      ...?uri.queryParametersAll[snakeName],
      ...?uri.queryParametersAll[kebabName],
    ];
    return values.any((value) {
      final normalized = value.trim().toLowerCase();
      return normalized.isEmpty ||
          normalized == '1' ||
          normalized == 'true' ||
          normalized == 'yes' ||
          normalized == 'on';
    });
  }

  List<String>? queryValues(Uri uri, String snakeName, String kebabName) {
    final values = [
      ...?uri.queryParametersAll[snakeName],
      ...?uri.queryParametersAll[kebabName],
    ];
    return values.isEmpty ? null : values;
  }

  ({double weight, String? error}) queryCostWeight(
    Uri uri,
    bool hasPenalties,
  ) {
    final values = queryValues(uri, 'cost_weight', 'cost-weight');
    if (values == null) return (weight: hasPenalties ? 1.0 : 0.0, error: null);
    final raw = values.last.trim();
    final weight = double.tryParse(raw);
    if (weight == null ||
        !weight.isFinite ||
        weight < 0 ||
        weight > kMaxRoutingCostWeight) {
      return (
        weight: 0.0,
        error: 'cost_weight must be between 0 and 10',
      );
    }
    return (weight: weight, error: null);
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
            final costPenalties = parseProviderCostPenalties(
              queryValues(request.uri, 'cost_penalty', 'cost-penalty'),
            );
            if (!costPenalties.ok) {
              writeJson(
                request,
                {'error': costPenalties.error},
                HttpStatus.badRequest,
              );
              await request.response.close();
              continue;
            }
            final costWeight = queryCostWeight(
              request.uri,
              costPenalties.penalties.isNotEmpty,
            );
            if (costWeight.error != null) {
              writeJson(
                request,
                {'error': costWeight.error},
                HttpStatus.badRequest,
              );
              await request.response.close();
              continue;
            }
            final snap =
                filterExcludedProviders(await snapshot(), exclusions.providers);
            final current = now();
            writeJson(
              request,
              suggestRoute(
                snap,
                current,
                burnStatsByProvider: recentBurnStatsByQuota(snap, current),
                preferLocal:
                    queryFlag(request.uri, 'local_first', 'local-first'),
                costPenaltyByProvider: costPenalties.penalties,
                costWeight: costWeight.weight,
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
