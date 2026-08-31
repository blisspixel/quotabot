import 'dart:io';

import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:quotabot_collector/util.dart';

void main(List<String> arguments) {
  if (arguments.length != 3) exitCode = 64;
  if (arguments.length != 3) return;
  final root = Directory(arguments[0]);
  final account = arguments[1];
  final holdMilliseconds = int.tryParse(arguments[2]);
  if (holdMilliseconds == null || holdMilliseconds < 0) {
    exitCode = 64;
    return;
  }
  setQuotabotDirOverrideForTesting(root);
  withCacheEvidenceLockForTesting(
    codexProviderId,
    account,
    () {
      stdout.writeln('locked');
      sleep(Duration(milliseconds: holdMilliseconds));
    },
  );
}
