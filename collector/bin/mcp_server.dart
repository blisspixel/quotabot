import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/util.dart';

/// MCP server exposing AI subscription quota as a primitive other agents can
/// query before routing work. Communicates over stdio, speaks MCP 2025-11-25
/// (tool annotations plus output schemas via mcp_dart), and every tool runs the
/// same metadata reads as the collector and costs no usage tokens.
///
/// All tool shapes, schemas, and behavior live in `lib/mcp.dart`; this is a thin
/// wiring shell that supplies the live snapshot and burn sources.
Future<void> main() async {
  List<ProviderQuota>? cached;
  var cachedAt = 0;
  Future<List<ProviderQuota>> snapshot() async {
    final now = nowEpoch();
    if (cached != null && now - cachedAt < 5) return cached!;
    cached = await collectAll();
    cachedAt = now;
    return cached!;
  }

  final server = McpServer(
    Implementation(name: 'quotabot', version: '0.5.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
        resources: ServerCapabilitiesResources(),
      ),
    ),
  );

  registerQuotabotTools(
    server,
    snapshot: snapshot,
    burnByProvider: recentBurnStatsByProvider,
  );

  await server.connect(StdioServerTransport());
}
