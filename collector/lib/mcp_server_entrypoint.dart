import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'collector.dart';
import 'expiring_single_flight.dart';
import 'http_client.dart';
import 'mcp.dart';
import 'mcp_http.dart';
import 'mcp_server_options.dart';
import 'provider_id_migration.dart';
import 'refresh_timer.dart';
import 'util.dart';

/// MCP server exposing AI subscription quota as a primitive other agents can
/// query before routing work. Communicates over stdio, speaks MCP 2025-11-25
/// (tool annotations plus output schemas via mcp_dart), and every tool runs the
/// same metadata reads as the collector and costs no usage tokens.
///
/// All tool shapes, schemas, and behavior live in `lib/mcp.dart`; this is a thin
/// wiring shell that supplies the live snapshot and burn sources.
/// The default collector uses audited registration cooldown capabilities.
/// An injected [snapshotSource] has no such coverage unless the caller supplies
/// [providersWithUsageCooldowns] explicitly.
Future<void> runQuotabotMcpServer(
  List<String> args, {
  SnapshotProvider? snapshotSource,
  Set<String>? providersWithUsageCooldowns,
  RefreshTimerFactory? subscriptionTimerFactory,
  Stream<ProcessSignal>? shutdownSignals,
}) async {
  try {
    await _runMain(
      args,
      snapshotSource ?? collectAll,
      shutdownSignals,
      Set<String>.unmodifiable(providersWithUsageCooldowns ??
          (snapshotSource == null
              ? providersWithMetadataUsageCooldowns()
              : const <String>{})),
      subscriptionTimerFactory,
    );
  } finally {
    closeSharedHttpClient();
  }
}

Future<void> _runMain(
    List<String> args,
    SnapshotProvider snapshotSource,
    Stream<ProcessSignal>? shutdownSignals,
    Set<String> providersWithUsageCooldowns,
    RefreshTimerFactory? subscriptionTimerFactory) async {
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
    load: snapshotSource,
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
    await coordinateProviderIdCacheMigration();
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
    late final QuotabotStreamableHttpServer server;
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
        providersWithUsageCooldowns: providersWithUsageCooldowns,
        subscriptionTimerFactory: subscriptionTimerFactory,
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
    stderr.writeln('bearer token auth: required and enabled');
    final done = Completer<void>();
    StreamSubscription<ProcessSignal>? signals;
    try {
      signals = (shutdownSignals ?? ProcessSignal.sigint.watch()).listen((_) {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
    } finally {
      // One shutdown owns cleanup, even if several signals arrive together.
      // Cancel the signal socket so it cannot keep the process alive afterward.
      try {
        await signals?.cancel();
      } finally {
        await server.stop();
      }
    }
    return;
  }

  final server = buildQuotabotMcpServer(
    snapshot: snapshot,
    burnByProvider: recentBurnStatsByQuota,
    cachedSnapshot: cachedDecisionSnapshot,
    leaseStore: leaseStore,
    providersWithUsageCooldowns: providersWithUsageCooldowns,
    subscriptionTimerFactory: subscriptionTimerFactory,
  );
  final done = Completer<void>();
  // The high-level server does not expose its transport-close callback. Keep
  // main alive until stdio closes so the shared provider client can be released
  // by the entrypoint's finally block after the last request, not immediately
  // after the transport starts.
  // ignore: deprecated_member_use
  final onClose = server.server.onclose;
  // Preserve the resource subscription hub's timer cleanup on EOF.
  // ignore: deprecated_member_use
  server.server.onclose = () {
    try {
      onClose?.call();
    } finally {
      if (!done.isCompleted) done.complete();
    }
  };
  await server.connect(StdioServerTransport());
  await done.future;
}
