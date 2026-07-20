import 'dart:convert';

import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/util.dart';

/// Simple worked example of an agent using quotabot as a routing primitive.
///
/// This demonstrates the core idea: before routing work to an AI coding tool,
/// query quota headroom and pick the provider with the most available budget.
/// Uses the same collect and analysis logic as the MCP server and widget.
/// In a real MCP client setup, this would call the server tools over stdio
/// (preferred for local) or Streamable HTTP (for remote per 2026 MCP).
///
/// Run with: dart run bin/example_routing_agent.dart
Future<void> main() async {
  print('quotabot routing example agent');
  print('collecting current quotas (local metadata only, zero tokens)...\n');

  final results = await collectAll();
  final now = nowEpoch();

  final best = providerWithMostHeadroom(results, now);
  if (best == null) {
    print('no live quota data available');
    print(
      'suggestions: run logins for Grok/Antigravity or open tools to refresh',
    );
    return;
  }

  final h = providerHeadroom(best, now) ?? 0;
  final a = providerAvailability(best, now);

  print('routing decision:');
  print(
    '  provider: ${best.displayName} '
    '(${quotaAccountDisplayLabel(best.account)})',
  );
  print('  headroom: ${h.toStringAsFixed(1)}%');
  if (a.resetsAt != null) {
    final resetsIn = a.resetsAt! - now;
    print('  binding reset: ${_formatDuration(resetsIn)}');
  }
  print('  stale: ${best.stale}');
  print('');
  print('use this provider for next work item');
  print('full snapshot:');
  print(
    const JsonEncoder.withIndent('  ').convert({
      'generated_at': now,
      'best': {
        'provider': best.provider,
        'account': best.account,
        'headroom_percent': h,
        'resets_at': a.resetsAt,
      },
      'all': results.map((r) => r.toJson()).toList(),
    }),
  );
}

String _formatDuration(int seconds) {
  if (seconds <= 0) return 'now';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '${h}h${m}m';
  return '${m}m';
}
