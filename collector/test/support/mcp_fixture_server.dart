import 'dart:async';
import 'dart:io';

import 'package:quotabot_collector/mcp_server_entrypoint.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/src/io/windows_pipe_input.dart';
import 'package:quotabot_collector/util.dart';

import 'fixture_vm_service.dart';

/// Exercises the server lifecycle with synthetic metadata only, including
/// subscription polling. It never invokes a real provider collector.
Future<void> main(List<String> args) async {
  if (Platform.environment.containsKey('QUOTABOT_TEST_VM_SERVICE_INFO')) {
    await startFixtureVmService();
  }
  final http = args.contains('--http');
  if (http) stderr.writeln('fixture VM pid: $pid');
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
  // This portable test seam maps pipe bytes to signals. Production HTTP uses
  // ProcessSignal.watch and never reads stdin. Own this fixture's pipe exactly
  // as stdio does so the test seam cannot retain an unrelated SDK stdin socket.
  WindowsPipeInput? pipeInput;
  late StreamSubscription<ProcessSignal> subscription;
  late final StreamController<ProcessSignal> controller;
  controller = StreamController<ProcessSignal>(
    sync: true,
    onListen: () {
      pipeInput = openWindowsPipeStdin();
      subscription = (pipeInput?.stream ?? stdin)
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
      try {
        await subscription.cancel();
      } finally {
        await pipeInput?.close();
      }
      stderr.writeln('fixture signal cancellation completed');
    },
  );
  return controller.stream;
}
