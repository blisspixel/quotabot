import 'dart:io';
import 'dart:isolate';

import 'fixture_vm_service.dart';

final _heldPorts = <RawReceivePort>[];

Future<void> main() async {
  await startFixtureVmService();
  _heldPorts.addAll([
    RawReceivePort(null, 'quotabot diagnostic held port'),
    RawReceivePort(null, 'PRIVATE_VM_NAME_MUST_NOT_LEAK'),
  ]);
  stderr.writeln('fixture VM pid: $pid');
  stderr.writeln('fixture probe main returned');
}
