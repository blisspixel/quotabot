import 'dart:io';

import '../../bin/collect.dart' as cli;
import 'fixture_vm_service.dart';

/// Adds one fixed lifecycle marker after the real CLI has fully returned.
/// It does not close stdin or force the VM to exit.
Future<void> main(List<String> args) async {
  if (Platform.environment.containsKey('QUOTABOT_TEST_VM_SERVICE_INFO')) {
    await startFixtureVmService();
  }
  stderr.writeln('fixture VM pid: $pid');
  await cli.main(args);
  stderr.writeln('fixture CLI main returned');
}
