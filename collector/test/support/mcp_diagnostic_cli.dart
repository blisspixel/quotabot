import 'dart:io';

import '../../bin/collect.dart' as cli;

/// Adds one fixed lifecycle marker after the real CLI has fully returned.
/// It does not close stdin or force the VM to exit.
Future<void> main(List<String> args) async {
  stderr.writeln('fixture VM pid: $pid');
  await cli.main(args);
  stderr.writeln('fixture CLI main returned');
}
