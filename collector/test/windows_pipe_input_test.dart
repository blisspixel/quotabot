import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/src/io/windows_pipe_input.dart';
import 'package:test/test.dart';

void main() {
  test('non-Windows input retains the SDK path', () {
    expect(openWindowsPipeStdin(), isNull);
    expect(usingWindowsPipeStdin, isFalse);
  }, skip: Platform.isWindows);

  for (final scenario in [
    'cancel_empty',
    'cancel_delivery',
    'pause',
    'eof',
    'cancel_before_ready',
    'late_start',
    'startup_failure',
    'startup_after_launch_failure',
    'startup_pending_failure',
    'close_before_listen',
    'registration_race',
  ]) {
    test('Windows owned pipe settles $scenario', () async {
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=.dart_tool/package_config.json',
        'test/support/windows_pipe_input_scenario.dart',
        scenario,
        '0',
      ]);
      addTearDown(() async {
        child.kill();
        await child.exitCode.timeout(const Duration(seconds: 5));
        await child.stdin
            .close()
            .timeout(const Duration(seconds: 3))
            .catchError((Object _) {});
      });
      final output = _boundedText(child.stdout);
      final errors = _boundedText(child.stderr);
      if (const {'cancel_delivery', 'pause', 'eof', 'startup_pending_failure'}
          .contains(scenario)) {
        final count = scenario == 'pause' ? 256 * 1024 : 16384;
        child.stdin.add(List<int>.generate(count, (index) => index % 251));
        await child.stdin.flush().timeout(const Duration(seconds: 5));
      }
      if (scenario == 'eof') {
        await child.stdin.close().timeout(const Duration(seconds: 3));
      }
      expect(await child.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await output.timeout(const Duration(seconds: 3)), isEmpty);
      expect(await errors.timeout(const Duration(seconds: 3)), 'settled\n');
    }, skip: !Platform.isWindows);
  }
}

Future<String> _boundedText(Stream<List<int>> input) async {
  final bytes = <int>[];
  await for (final chunk in input) {
    if (bytes.length + chunk.length > 8192) {
      throw StateError('fixture output exceeded bound');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes).replaceAll('\r\n', '\n');
}
