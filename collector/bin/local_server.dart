import 'dart:async';
import 'dart:io';

import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/local_server.dart';

/// Optional local HTTP endpoint serving the normalized quota JSON.
///
/// Run: dart run bin/local_server.dart [port]
/// Default port 8721. Visit http://localhost:8721/ for snapshot.
/// Also: /suggest (routing recommendation, optional ?exclude=a,b and
/// ?local_first=true), /health, `/providers/<name>`
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

  await startLocalQuotabotServer(
    port: port,
    snapshotProvider: collectAll,
    log: stdout.writeln,
  );
  await Completer<void>().future;
}
