import 'dart:async';
import 'dart:io';

import 'package:quotabot_collector/mcp_server_entrypoint.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';

/// Exercises the server lifecycle with synthetic metadata only, including
/// subscription polling. It never invokes a real provider collector.
Future<void> main(List<String> args) async {
  final http = args.contains('--http');
  await runQuotabotMcpServer(
    args,
    // Keep stdin open after requesting shutdown. The server must cancel the
    // signal listener to exit, including when duplicate signals arrive.
    shutdownSignals: http ? _shutdownSignals() : null,
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
  if (http) stderr.writeln('fixture MCP main returned');
}

/// Transparently forwards the same duplicate signals and cancellation while
/// making shutdown phases visible if an open Windows stdin pipe holds the VM.
Stream<ProcessSignal> _shutdownSignals() {
  late StreamSubscription<ProcessSignal> subscription;
  late final StreamController<ProcessSignal> controller;
  controller = StreamController<ProcessSignal>(
    sync: true,
    onListen: () {
      subscription = stdin
          .expand((_) => [ProcessSignal.sigint, ProcessSignal.sigint])
          .listen((signal) {
        stderr.writeln('fixture signal observed');
        controller.add(signal);
      }, onError: controller.addError, onDone: controller.close);
    },
    onPause: () => subscription.pause(),
    onResume: () => subscription.resume(),
    onCancel: () async {
      stderr.writeln('fixture signal cancellation started');
      await subscription.cancel();
      stderr.writeln('fixture signal cancellation completed');
    },
  );
  return controller.stream;
}
