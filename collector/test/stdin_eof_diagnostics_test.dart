import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/stdin_eof_diagnostics.dart';

void main() {
  for (final retainPort in [false, true]) {
    test('post-failure EOF observes recovery with retained port=$retainPort',
        () async {
      final temp =
          Directory.systemTemp.createTempSync('quotabot_stdin_eof_probe_');
      final script = File('${temp.path}/wait.dart')..writeAsStringSync('''
import 'dart:io';
import 'dart:isolate';
Future<void> main() async {
  ${retainPort ? "RawReceivePort((_) {}, 'quotabot EOF retained probe');" : ''}
  stderr.writeln('ready');
  await stdin.drain<void>();
  stderr.writeln('EOF observed');
}
''');
      final child =
          await Process.start(Platform.resolvedExecutable, [script.path]);
      final ready = Completer<void>();
      final eof = Completer<void>();
      final errors = utf8.decoder
          .bind(child.stderr)
          .transform(const LineSplitter())
          .listen((line) {
        if (line == 'ready' && !ready.isCompleted) ready.complete();
        if (line == 'EOF observed' && !eof.isCompleted) eof.complete();
      });
      final output = child.stdout.drain<void>();
      try {
        await ready.future.timeout(const Duration(seconds: 15));
        // Establish the same open-writer timeout precondition independently of
        // the helper. The original failing assertion is never made successful.
        await expectLater(
          child.exitCode.timeout(const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );
        final elapsed = Stopwatch()..start();
        final result = await observeStdinEofAfterFailure(child);
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
        expect(
          result,
          retainPort
              ? 'stdin EOF writer closed; process exit not observed'
              : 'stdin EOF writer closed; process exited with code 0',
        );
        await eof.future.timeout(const Duration(seconds: 5));
      } finally {
        child.kill();
        await child.exitCode.timeout(const Duration(seconds: 10));
        await output.timeout(const Duration(seconds: 5));
        await errors.cancel();
        temp.deleteSync(recursive: true);
      }
    });
  }
}
