import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/provider_id_migration.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 5) {
    exitCode = 64;
    return;
  }
  final root = Directory(arguments[0]);
  final oldProvider = arguments[1];
  final newProvider = arguments[2];
  final ready = File(arguments[3]);
  final release = File(arguments[4]);
  setProviderIdMigrationObserverForTesting((phase) {
    if (phase != 'coordinator_locked') return;
    ready.writeAsStringSync('ready');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!release.existsSync() && DateTime.now().isBefore(deadline)) {
      sleep(const Duration(milliseconds: 10));
    }
    if (!release.existsSync()) exit(70);
  });
  final report = await coordinateProviderIdCacheMigration(
    aliases: {oldProvider: newProvider},
    root: root,
    limits: const ProviderIdMigrationLimits(
      maxDuration: Duration(seconds: 30),
      lockTimeout: Duration(seconds: 10),
    ),
  );
  stdout.write(jsonEncode(report.toJson()));
}
