import 'dart:io';

import 'package:quotabot_collector/mcp_server_entrypoint.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';

/// Exercises the server lifecycle with synthetic metadata only, including
/// subscription polling. It never invokes a real provider collector.
Future<void> main(List<String> args) => runQuotabotMcpServer(
      args,
      // Keep stdin open after requesting shutdown. The server must cancel the
      // signal listener to exit, including when duplicate signals arrive.
      shutdownSignals: args.contains('--http')
          ? stdin.expand((_) => [ProcessSignal.sigint, ProcessSignal.sigint])
          : null,
      snapshotSource: () async => [
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Fixture runtime',
          account: 'default',
          kind: ProviderQuotaKind.local,
          asOf: nowEpoch(),
          perMachine: true,
          active: true,
          models: const [
            ModelInfo(id: 'fixture-model', local: true, loaded: true),
          ],
        ),
      ],
    );
