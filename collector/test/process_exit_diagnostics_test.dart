import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/process_exit_diagnostics.dart';

void main() {
  test(
      'Windows exit diagnostics observe only the owned live and exited process',
      () async {
    final temp = Directory.systemTemp.createTempSync('quotabot_exit_snapshot_');
    final script = File('${temp.path}/wait.dart')..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  stderr.writeln('fixture VM pid: \$pid');
  await stdin.drain<void>();
}
''');
    final child =
        await Process.start(Platform.resolvedExecutable, [script.path]);
    final diagnostics = <String>[];
    final ready = Completer<void>();
    final errors = utf8.decoder
        .bind(child.stderr)
        .transform(const LineSplitter())
        .listen((line) {
      diagnostics.add(line);
      if (line.startsWith('fixture VM pid: ') && !ready.isCompleted) {
        ready.complete();
      }
    });
    final output = child.stdout.drain<void>();
    try {
      await ready.future.timeout(const Duration(seconds: 15));
      final live = jsonDecode(await snapshotTimedOutProcess(child, diagnostics))
          as Map<String, dynamic>;
      expect(live['launcher_pid'], child.pid);
      expect(live['launcher_present'], isTrue);
      expect(live['vm_present'], isTrue);
      expect(live['processes'], isNotEmpty);
      for (final row in live['processes'] as List) {
        expect((row as Map).keys, unorderedEquals(['pid', 'parent', 'name']));
      }
      await child.stdin.close();
      expect(await child.exitCode.timeout(const Duration(seconds: 10)), 0);
      await output;
      final ended =
          jsonDecode(await snapshotTimedOutProcess(child, diagnostics))
              as Map<String, dynamic>;
      expect(ended['launcher_present'], isFalse);
      expect(ended['vm_present'], isFalse);
      expect(ended['processes'], isEmpty);
    } finally {
      child.kill();
      await child.exitCode.timeout(const Duration(seconds: 10));
      await errors.cancel();
      temp.deleteSync(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
