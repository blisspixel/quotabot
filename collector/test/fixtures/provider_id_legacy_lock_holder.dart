import 'dart:io';

import 'package:quotabot_collector/file_guard.dart';
import 'package:quotabot_collector/util.dart';

void main(List<String> args) {
  if (args.length != 4) {
    stderr.writeln('expected root, provider, scope, and release path');
    exitCode = 64;
    return;
  }
  final root = Directory(args[0]);
  final lock = File('${root.path}/evidence_${args[1]}_${args[2]}.lock');
  final release = File(args[3]);
  if (!root.existsSync()) root.createSync(recursive: true);
  if (!lock.existsSync()) lock.createSync();
  restrictOwnerOnlyFile(lock);
  final guard = acquireInterprocessFileGuardSync(
    lock,
    hardenClaim: restrictOwnerOnlyFile,
    acquisitionTimeout: const Duration(seconds: 90),
    reclaimSameProcessClaims: false,
  );
  try {
    stdout.writeln('locked');
    final elapsed = Stopwatch()..start();
    while (!release.existsSync()) {
      if (elapsed.elapsed >= const Duration(seconds: 90)) {
        throw StateError('timed out waiting for release');
      }
      sleep(const Duration(milliseconds: 10));
    }
  } finally {
    guard.release();
  }
}
