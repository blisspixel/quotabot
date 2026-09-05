import 'dart:io';

import 'package:quotabot_collector/provider_read_gate.dart';

/// Synthetic process-death fixture. It opens no network or credential files.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    exitCode = 64;
    return;
  }
  final gate = ProviderReadGate(
    directory: Directory(arguments[0]),
    clock: () => int.parse(arguments[2]),
    hardenDirectory: (_) {},
    hardenFile: (_) {},
    jitter: (_) => 0,
  );
  await gate.run<bool>(
    provider: 'claude',
    credentialIdentity: arguments[1],
    purpose: ProviderReadPurpose.usage,
    attempt: (operation) async {
      stdout.writeln('metadata-held');
      await operation.track(stdin.drain<void>());
      return true;
    },
    classify: (_) => const ProviderReadDisposition.completed(),
    deferred: (_) => false,
  );
}
