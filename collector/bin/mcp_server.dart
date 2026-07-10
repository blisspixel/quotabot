import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/expiring_single_flight.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/mcp_http.dart';
import 'package:quotabot_collector/mcp_server_options.dart';
import 'package:quotabot_collector/util.dart';

/// MCP server exposing AI subscription quota as a primitive other agents can
/// query before routing work. Communicates over stdio, speaks MCP 2025-11-25
/// (tool annotations plus output schemas via mcp_dart), and every tool runs the
/// same metadata reads as the collector and costs no usage tokens.
///
/// All tool shapes, schemas, and behavior live in `lib/mcp.dart`; this is a thin
/// wiring shell that supplies the live snapshot and burn sources.
Future<void> main(List<String> args) async {
  late final McpServerCliOptions options;
  try {
    options = McpServerCliOptions.parse(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(mcpServerUsage);
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.write(mcpServerUsage);
    return;
  }

  final liveSnapshots = ExpiringSingleFlight<List<ProviderQuota>>(
    load: collectAll,
    now: nowEpoch,
  );
  Future<List<ProviderQuota>> snapshot() => liveSnapshots.read();

  int? newestSnapshotAsOf(List<ProviderQuota> providers) {
    int? newest;
    for (final provider in providers) {
      newest =
          newest == null || provider.asOf > newest ? provider.asOf : newest;
    }
    return newest;
  }

  Future<CachedQuotaSnapshot> cachedDecisionSnapshot() async {
    final current = liveSnapshots.value;
    if (current != null) {
      return CachedQuotaSnapshot(
        providers: current,
        asOf: liveSnapshots.cachedAt,
        source: 'memory',
      );
    }
    final disk = loadCachedSnapshots();
    return CachedQuotaSnapshot(
      providers: disk,
      asOf: newestSnapshotAsOf(disk),
      source: disk.isEmpty ? 'empty' : 'disk',
    );
  }

  const leaseStore = FileRouteLeaseStore();

  if (options.http) {
    late final String? token;
    late final StreamableMcpServer server;
    try {
      token = await loadMcpBearerToken(options);
      server = buildQuotabotStreamableHttpServer(
        config: QuotabotMcpHttpConfig(
          host: options.host,
          port: options.port,
          path: options.path,
          bearerToken: token,
        ),
        snapshot: snapshot,
        burnByProvider: recentBurnStatsByQuota,
        cachedSnapshot: cachedDecisionSnapshot,
        leaseStore: leaseStore,
      );
    } on FormatException catch (error) {
      stderr.writeln(error.message);
      exitCode = 64;
      return;
    } on ArgumentError catch (error) {
      stderr.writeln(error.message);
      exitCode = 64;
      return;
    }
    await server.start();
    stderr.writeln(
      'quotabot MCP Streamable HTTP listening on '
      'http://${options.host}:${options.port}${normalizeMcpHttpPath(options.path)}',
    );
    stderr.writeln(token == null
        ? 'bearer token auth: disabled'
        : 'bearer token auth: enabled');
    final done = Completer<void>();
    ProcessSignal.sigint.watch().listen((_) async {
      await server.stop();
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    return;
  }

  final server = buildQuotabotMcpServer(
    snapshot: snapshot,
    burnByProvider: recentBurnStatsByQuota,
    cachedSnapshot: cachedDecisionSnapshot,
    leaseStore: leaseStore,
  );
  await server.connect(StdioServerTransport());
}
