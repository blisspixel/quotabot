import 'dart:io';

import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/provider_read_gate.dart';

/// Synthetic metadata coordination fixture. No credentials or network reads.
Future<void> main(List<String> arguments) async {
  final directory = Directory(arguments.single);
  final counter = File('${directory.path}/attempts');
  final gate = ProviderReadGate(
      directory: directory,
      hardenDirectory: (_) {},
      hardenFile: (_) {},
      acquisitionTimeout: const Duration(seconds: 10),
      minimumLiveInterval: const Duration(seconds: 30));
  final result = await gate.run<String>(
    provider: 'claude',
    credentialIdentity:
        opaqueCredentialIdentity('claude', 'synthetic-shared-generation'),
    purpose: ProviderReadPurpose.usage,
    loadShared: (_) => counter.existsSync() ? 'shared' : null,
    saveShared: (_) => SharedReadCapture(
        DateTime.now().millisecondsSinceEpoch ~/ 1000, 'a' * 64),
    attempt: (operation) async {
      counter.writeAsStringSync('attempt\n',
          mode: FileMode.append, flush: true);
      await operation
          .track(Future<void>.delayed(const Duration(milliseconds: 300)));
      return 'live';
    },
    classify: (_) => const ProviderReadDisposition.completed(),
    deferred: (_) => 'deferred',
  );
  stdout.writeln(result);
}
