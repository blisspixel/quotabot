import 'dart:async';
import 'dart:io';

import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/local_http_auth.dart';
import 'package:quotabot_collector/local_server.dart';

/// Optional local HTTP endpoint serving the normalized quota JSON.
///
/// Run: dart run bin/local_server.dart [port]
/// Default port 8721. Visit http://localhost:8721/ for snapshot.
/// Also: /suggest (routing recommendation, optional ?exclude=a,b and
/// ?local_first=true), /health, `/providers/<name>`
/// Complements MCP (stdio primary; Streamable HTTP for remote possible per
/// 2026 research). Useful for external consumers (e.g. ESP32, dashboards).
/// Zero token metadata reads only. Use Ctrl-C to stop. Read endpoints are local
/// only. Lease mutations require a stable owner-only bearer token that is never
/// printed or served. Snapshots include bounded account identifiers, so treat
/// the loopback port as trusted.
Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) : 8721;
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('Usage: dart run bin/local_server.dart [1-65535]');
    exitCode = 64;
    return;
  }

  try {
    final mutationToken = loadOrCreateLocalHttpMutationToken();
    await startLocalQuotabotServer(
      port: port,
      snapshotProvider: collectAll,
      leaseStore: const FileRouteLeaseStore(),
      mutationToken: mutationToken,
      log: stdout.writeln,
    );
  } on FileSystemException {
    stderr.writeln(
      'Could not secure the local HTTP mutation token. The server was not started.',
    );
    exitCode = 74;
    return;
  }
  await Completer<void>().future;
}
