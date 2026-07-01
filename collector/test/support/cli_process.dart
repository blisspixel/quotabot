import 'dart:io';

import 'package:test/test.dart';

/// Runs the collector CLI from process tests without rebundling native assets.
///
/// `dart run` copies native assets into `.dart_tool/lib` before every launch.
/// On Windows, sqlite3 3.x can leave `sqlite3.dll` locked by the parent test VM
/// after SQLite-backed adapter tests have loaded it. Invoking the entrypoint
/// directly with the package config exercises the same CLI code while avoiding
/// that locked-file rebuild path.
Future<ProcessResult> runCollectCli(
  List<String> args, {
  Map<String, String> environment = const {},
}) {
  final env = Map<String, String>.from(Platform.environment)
    ..addAll(environment)
    ..putIfAbsent('NO_COLOR', () => '1');
  return Process.run(
    Platform.resolvedExecutable,
    [
      '--packages=.dart_tool/package_config.json',
      'bin/collect.dart',
      ...args,
    ],
    workingDirectory: Directory.current.path,
    environment: env,
  );
}

void expectExitCode(ProcessResult result, int code) {
  expect(
    result.exitCode,
    code,
    reason: 'stderr:\n${result.stderr}\nstdout:\n${result.stdout}',
  );
}
