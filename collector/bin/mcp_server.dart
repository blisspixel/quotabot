import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/util.dart';

/// MCP server exposing AI subscription quota as a primitive other agents can
/// query before routing work. Communicates over stdio. Every tool runs the
/// same metadata reads as the collector and costs no usage tokens.
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
    Implementation(name: 'quotabot', version: '0.1.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
        resources: ServerCapabilitiesResources(),
      ),
    ),
  );

  server.registerTool(
    'list_quotas',
    description:
        'Return the current usage quota for every connected AI subscription '
        '(Codex, Claude, Grok, Antigravity, Kiro, Cursor, Windsurf) as JSON. Per provider: account, '
        'plan, ok/stale, and rolling windows (label, used_percent or used/limit, '
        'resets_at). Longer windows that are spent are the binding constraint.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      final results = await snapshot();
      return _json({
        'schema': 'quotabot.v1',
        'generated_at': nowEpoch(),
        'providers': results.map((r) => r.toJson()).toList(),
      });
    },
  );

  server.registerTool(
    'provider_with_most_headroom',
    description:
        'Return the connected provider that currently has the most remaining '
        'quota headroom, for choosing where to route work. The binding '
        '(most constrained) window governs availability. Returns provider, '
        'account, headroom_percent, resets_at of the binding window, and stale flag. '
        'A longer window that is spent blocks use even if shorter windows show headroom.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      final now = nowEpoch();
      final results = await snapshot();
      final best = providerWithMostHeadroom(results, now);
      if (best == null) {
        return _json({'provider': null, 'reason': 'no live quota available'});
      }
      final h = providerHeadroom(best, now);
      final a = providerAvailability(best, now);
      return _json({
        'provider': best.provider,
        'account': best.account,
        'headroom_percent': h,
        'resets_at': a.resetsAt,
        'stale': best.stale,
      });
    },
  );

  server.registerTool(
    'suggest_provider',
    description:
        'Recommend which provider to route the next request to. Prefers the '
        'metered subscription with the most remaining headroom (above a comfort '
        'threshold), and falls back to a local runtime (e.g. Ollama) when every '
        'subscription is low. Returns the recommended provider, a human reason, '
        'a using_local_fallback flag, and the full ranked candidate list. Local '
        'runtimes never win on headroom; they are fallbacks only.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      final now = nowEpoch();
      final results = await snapshot();
      return _json(suggestRoute(results, now).toJson());
    },
  );

  server.registerTool(
    'check_provider_availability',
    description:
        'Check whether a specific provider has quota available right now. '
        'Returns whether it is usable, its remaining headroom percent, and when '
        'the binding window resets. A longer window spent means unavailable.',
    inputSchema: JsonSchema.object(
      properties: {
        'provider': JsonSchema.string(
          description:
              'Provider id: codex, claude, grok, antigravity, kiro, cursor, or windsurf.',
        ),
      },
      required: ['provider'],
    ),
    callback: (args, extra) async {
      final now = nowEpoch();
      final name = (args['provider'] as String?)?.toLowerCase();
      final results = await snapshot();
      final match =
          results.where((q) => q.provider == name).cast<ProviderQuota?>();
      final q = match.isEmpty ? null : match.first;
      if (q == null) {
        return _json({'provider': name, 'error': 'unknown provider'});
      }
      final a = providerAvailability(q, now);
      return _json({
        'provider': q.provider,
        'account': q.account,
        'available': a.available,
        'headroom_percent': a.headroom,
        'resets_at': a.resetsAt,
        'stale': q.stale,
      });
    },
  );

  // Resource for the live snapshot. Clients that prefer resources over tools
  // can read this for the same normalized data used by routing helpers.
  server.registerResource(
    'quotas',
    'quotas://current',
    (
      description: 'Full live normalized quota snapshot across all providers. '
          'JSON object with generated_at and providers list. Each provider has '
          'account, plan, ok, stale, and windows (label, used_percent, resets_at). '
          'Binding longer windows override shorter ones for availability.',
      mimeType: 'application/json',
    ),
    (uri, extra) async {
      final results = await snapshot();
      final data = {
        'schema': 'quotabot.v1',
        'generated_at': nowEpoch(),
        'providers': results.map((r) => r.toJson()).toList(),
      };
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'application/json',
            text: const JsonEncoder.withIndent('  ').convert(data),
          ),
        ],
      );
    },
  );

  await server.connect(StdioServerTransport());
}

CallToolResult _json(Object data) => CallToolResult(
      content: [
        TextContent(text: const JsonEncoder.withIndent('  ').convert(data)),
      ],
    );
