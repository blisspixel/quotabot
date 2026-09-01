import 'dart:io';

import 'package:quotabot_collector/provider_id_migration.dart';
import 'package:quotabot_collector/provider_ids.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) exit(64);
  final root = Directory(arguments[0]);
  final oldProvider = arguments[1];
  final newProvider = arguments[2];
  final phase = arguments[3];
  setProviderIdAliasesForTesting({oldProvider: newProvider});
  setProviderIdMigrationObserverForTesting((observed) {
    if (observed == phase) exit(86);
  });
  await coordinateProviderIdCacheMigration(
    aliases: {oldProvider: newProvider},
    root: root,
    limits: const ProviderIdMigrationLimits(
      maxDuration: Duration(seconds: 30),
      lockTimeout: Duration(seconds: 10),
    ),
  );
}
