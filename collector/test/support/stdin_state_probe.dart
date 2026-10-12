import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'fixture_vm_service.dart';
import 'stdin_state_extension.dart';

Future<void> main(List<String> args) async {
  registerStdinStateExtension();
  await startFixtureVmService();
  // Intentionally retain one known test port after main returns. The parent
  // owns this synthetic child and kills/reaps it in teardown.
  RawReceivePort((_) {}, 'quotabot diagnostic held port');
  final received = Completer<void>();
  final subscription = stdin.listen((_) {
    if (!received.isCompleted) received.complete();
  });
  stderr.writeln('fixture VM pid: $pid');
  stderr.writeln('fixture stdin probe ready');
  await received.future;
  if (!args.contains('--active')) {
    await subscription.cancel();
    // A healthy cancellation reaches destruction before the later query.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  stderr.writeln('fixture stdin probe main returned');
}
