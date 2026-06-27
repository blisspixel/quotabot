import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/util.dart';

/// Optional local HTTP endpoint serving the normalized quota JSON.
///
/// Run: dart run bin/local_server.dart [port]
/// Default port 8721. Visit http://localhost:8721/ for snapshot.
/// Also: /suggest (routing recommendation), /health, /providers/<name>
/// Complements MCP (stdio primary; Streamable HTTP for remote possible per
/// 2026 research). Useful for external consumers (e.g. ESP32, dashboards).
/// Zero token metadata reads only. Use Ctrl-C to stop. Not for production (no
/// auth, local only). It never serves tokens, but the snapshot does include
/// account identifiers (e.g. emails), so treat the loopback port as trusted.
Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) : 8721;
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('Usage: dart run bin/local_server.dart [1-65535]');
    exitCode = 64;
    return;
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  print('quotabot local server listening on http://localhost:$port/');
  print('serves current quota snapshot as JSON on every request');
  print('press ctrl-c to stop\n');

  // Throttle: every endpoint runs collectAll(), which makes authenticated
  // provider calls. Cache the snapshot briefly so a busy local client cannot
  // drive repeated outbound calls and trip provider rate limits.
  List<ProviderQuota>? cached;
  var cachedAt = 0;
  Future<List<ProviderQuota>> snapshot() async {
    final now = nowEpoch();
    if (cached != null && now - cachedAt < 5) return cached!;
    cached = await collectAll();
    cachedAt = now;
    return cached!;
  }

  void writeJson(HttpRequest req, Object data, [int status = HttpStatus.ok]) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(const JsonEncoder.withIndent('  ').convert(data));
  }

  await for (final request in server) {
    final path = request.uri.path;
    try {
      if (request.method != 'GET') {
        writeJson(
            request,
            {
              'error': 'method not allowed',
            },
            HttpStatus.methodNotAllowed);
      } else if (path == '/') {
        final results = await snapshot();
        writeJson(request, {
          'schema': 'quotabot.v1',
          'generated_at': nowEpoch(),
          'providers': results.map((r) => r.toJson()).toList(),
        });
      } else if (path == '/suggest') {
        final snap = await snapshot();
        final now = nowEpoch();
        writeJson(
          request,
          suggestRoute(
            snap,
            now,
            burnByProvider: recentBurnByProvider(snap.map((q) => q.provider), now),
          ).toJson(),
        );
      } else if (path == '/health') {
        writeJson(request, {'ok': true, 'generated_at': nowEpoch()});
      } else if (path.startsWith('/providers/')) {
        final name = path.substring('/providers/'.length).toLowerCase();
        final match = (await snapshot()).where((r) => r.provider == name);
        if (match.isEmpty) {
          writeJson(
              request,
              {
                'error': 'unknown provider',
              },
              HttpStatus.notFound);
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
          {
            'error': 'internal error',
          },
          HttpStatus.internalServerError);
    }
    await request.response.close();
  }
}
