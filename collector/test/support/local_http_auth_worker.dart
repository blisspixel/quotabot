import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/local_http_auth.dart';

void _waitForFile(File file, String label) {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!file.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $label');
    }
    sleep(const Duration(milliseconds: 5));
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 8) {
    stderr.writeln('expected token worker paths and token');
    exitCode = 64;
    return;
  }

  final directory = Directory(args[0]);
  final token = args[1];
  final readyFile = File(args[2]);
  final startFile = File(args[3]);
  final beforeCallFile = File(args[4]);
  final factoryFile = File(args[5]);
  final releaseFile = args[6] == '-' ? null : File(args[6]);
  final resultFile = File(args[7]);

  try {
    readyFile.writeAsStringSync('ready\n', flush: true);
    _waitForFile(startFile, 'start signal');
    beforeCallFile.writeAsStringSync('calling\n', flush: true);
    final result = loadOrCreateLocalHttpMutationToken(
      dirFactory: () => directory,
      tokenFactory: () {
        factoryFile.writeAsStringSync('factory\n', flush: true);
        if (releaseFile != null) {
          _waitForFile(releaseFile, 'factory release');
        }
        return token;
      },
    );
    resultFile.writeAsStringSync(
      jsonEncode({'ok': true, 'token': result}),
      flush: true,
    );
  } catch (error) {
    resultFile.writeAsStringSync(
      jsonEncode({'ok': false, 'error': error.toString()}),
      flush: true,
    );
    exitCode = 1;
  }
}
