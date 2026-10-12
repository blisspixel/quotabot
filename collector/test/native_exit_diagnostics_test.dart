import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/native_exit_diagnostics.dart';
import 'support/process_exit_diagnostics.dart';

class _StalledNativeInspector implements Process {
  _StalledNativeInspector({required List<int> output, required int exitStatus})
      : exitCode = Future<int>.value(exitStatus) {
    _output.onListen = () => _outputWasListened = true;
    _errors.onListen = () => _errorsWereListened = true;
    _output.add(output);
    _input.stream.listen((_) {});
    stdin = IOSink(_input.sink);
  }

  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _errors = StreamController<List<int>>();
  var _outputWasListened = false;
  var _errorsWereListened = false;
  @override
  final Future<int> exitCode;
  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _errors.stream;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;

  Future<void> dispose() async {
    if (!_outputWasListened) _output.stream.listen((_) {});
    if (!_errorsWereListened) _errors.stream.listen((_) {});
    await Future.wait([stdin.close(), _output.close(), _errors.close()])
        .timeout(const Duration(seconds: 1));
  }
}

void main() {
  test('stalled native inspector disposal owns never-listened streams',
      () async {
    final inspector = _StalledNativeInspector(output: [], exitStatus: 0);
    await inspector.dispose().timeout(const Duration(seconds: 2));
  });

  test('native projection keeps only bounded fixed label categories', () {
    const text = '''
PRIVATE_PATH
QUOTABOT_NATIVE_STACK_BEGIN
00 ntdll!NtReadFile+0x14
01 KERNELBASE!ReadFile+0x1
02 ntdll!NtClose+0x22
03 KERNEL32!GetQueuedCompletionStatus+0x1
04 ntdll!NtWaitForSingleObject+0x11
05 private_module!PRIVATE_FUNCTION+0x99
QUOTABOT_NATIVE_STACK_END
PRIVATE_ERROR
''';
    final projected = projectNativeStackLabels(text)!;
    expect(projected['command_sequence_completed'], isTrue);
    expect(projected['export_labels_only'], isTrue);
    expect(projected['frame_labels'], {
      'read_family': 2,
      'close_family': 1,
      'completion_wait': 1,
      'other_wait': 1,
      'unclassified': 1,
    });
    expect(jsonEncode(projected), isNot(contains('PRIVATE')));
    expect(
        projectNativeStackLabels(
            text.replaceAll('QUOTABOT_NATIVE_STACK_END', '')),
        isNull);
    expect(
        projectNativeStackLabels('$text\nQUOTABOT_NATIVE_STACK_END'), isNull);
    expect(
        projectNativeStackLabels(
            'QUOTABOT_NATIVE_STACK_BEGIN\nQUOTABOT_NATIVE_STACK_END'),
        isNull);
    expect(
        projectNativeStackLabels(
            'QUOTABOT_NATIVE_STACK_BEGIN\n${'00 ntdll!NtReadFile\n' * 513}QUOTABOT_NATIVE_STACK_END'),
        isNull);
  });

  for (final mode in [
    'normal',
    'nonzero',
    'malformed',
    'stdout-overflow',
    'stderr-overflow',
    'hang',
    'late',
    'start-timeout-error'
  ]) {
    test('native inspector contains and owns $mode completion', () async {
      final vm =
          File('${File(Platform.resolvedExecutable).parent.path}/dartvm.exe');
      final target = await Process.start(
          vm.path, ['test/support/native_stack_probe.dart']);
      final targetOutput = target.stdout.toList();
      final targetErrors = target.stderr.toList();
      Process? inspector;
      Directory? owned;
      final elapsed = Stopwatch()..start();
      try {
        final state = jsonEncode({
          'launcher_pid': target.pid,
          'launcher_present': true,
          'vm_pid': target.pid,
          'vm_present': true,
          'processes': [
            {'pid': target.pid, 'parent': target.pid, 'name': 'dartvm.exe'}
          ],
        });
        final projected = await snapshotTimedOutNative(target, state,
            startInspectorForTesting: (arguments, directory) async {
          owned = directory;
          expect(
              arguments,
              containsAll(
                  ['-pvr', '-sins', '-netsyms:no', '-noshell', '-nosqm']));
          expect(arguments, isNot(contains('-pd')));
          final script = File(arguments[arguments.indexOf('-cf') + 1]);
          expect(script.readAsStringSync(), contains('~* kcL 8'));
          expect(script.readAsStringSync(), endsWith('qd\n'));
          expect(File('${directory.path}/ntsd.ini').existsSync(), isFalse);
          if (mode == 'start-timeout-error') {
            throw TimeoutException('injected launch failure');
          }
          final child = await Process.start(vm.path, [
            'test/support/native_inspector_probe.dart',
            mode == 'late' ? 'hang' : mode,
          ]);
          inspector = child;
          if (mode == 'late') {
            await Future<void>.delayed(const Duration(milliseconds: 3300));
          }
          return child;
        });
        if (mode == 'normal') {
          expect(jsonDecode(projected), isA<Map<String, dynamic>>());
          expect(projected, isNot(contains('PRIVATE')));
        } else if (mode == 'hang' || mode == 'late') {
          expect(projected, 'native inspection unavailable (deadline)');
        } else if (mode == 'start-timeout-error') {
          expect(projected, 'native inspection unavailable');
        } else {
          expect(projected, 'native inspection incomplete');
        }
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 6)));
        if (mode == 'late') {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (inspector != null) {
          await inspector!.exitCode.timeout(const Duration(seconds: 3));
        }
        expect(owned!.existsSync(), isFalse);
        await expectLater(
            target.exitCode.timeout(const Duration(milliseconds: 100)),
            throwsA(isA<TimeoutException>()));
      } finally {
        target.kill();
        await target.exitCode.timeout(const Duration(seconds: 3));
        if (inspector != null) {
          inspector!.kill();
          await inspector!.exitCode.timeout(const Duration(seconds: 3));
        }
        await targetOutput;
        await targetErrors;
      }
    }, skip: !Platform.isWindows);
  }

  for (final failure in ['overflow', 'nonzero']) {
    test('native inspector keeps $failure ahead of stalled-output deadline',
        () async {
      final vm =
          File('${File(Platform.resolvedExecutable).parent.path}/dartvm.exe');
      final target = await Process.start(
          vm.path, ['test/support/native_stack_probe.dart']);
      final output = target.stdout.toList();
      final errors = target.stderr.toList();
      final inspector = _StalledNativeInspector(
          output: failure == 'overflow' ? List<int>.filled(70 * 1024, 120) : [],
          exitStatus: failure == 'nonzero' ? 9 : 0);
      Directory? owned;
      final elapsed = Stopwatch()..start();
      try {
        final state = jsonEncode({
          'launcher_pid': target.pid,
          'launcher_present': true,
          'vm_pid': target.pid,
          'vm_present': true,
          'processes': [
            {'pid': target.pid, 'parent': target.pid, 'name': 'dartvm.exe'}
          ],
        });
        final result = await snapshotTimedOutNative(target, state,
            startInspectorForTesting: (_, directory) async {
          owned = directory;
          return inspector;
        });
        expect(result, 'native inspection incomplete');
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 6)));
        expect(owned!.existsSync(), isFalse);
        await expectLater(
            target.exitCode.timeout(const Duration(milliseconds: 100)),
            throwsA(isA<TimeoutException>()));
      } finally {
        target.kill();
        await target.exitCode.timeout(const Duration(seconds: 3));
        await output;
        await errors;
        await inspector.dispose();
      }
    }, skip: !Platform.isWindows);
  }

  final cdb = File(
      '${Platform.environment['ProgramFiles(x86)']}/Windows Kits/10/Debuggers/x64/cdb.exe');
  test('native debugger bounds observation and preserves an owned child',
      () async {
    final child = await Process.start(
        Platform.resolvedExecutable, ['test/support/native_stack_probe.dart']);
    final ready = Completer<void>();
    final lines = <String>[];
    final errors = utf8.decoder
        .bind(child.stderr)
        .transform(const LineSplitter())
        .listen((line) {
      lines.add(line);
      if (line == 'fixture native probe ready' && !ready.isCompleted) {
        ready.complete();
      }
    });
    final output = child.stdout.toList();
    Process? inspector;
    Directory? owned;
    try {
      await ready.future.timeout(const Duration(seconds: 15));
      final processState = await snapshotTimedOutProcess(child, lines);
      final elapsed = Stopwatch()..start();
      final projected = await snapshotTimedOutNative(child, processState,
          onInspectorStartedForTesting: (process, directory) {
        inspector = process;
        owned = directory;
      });
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 6)));
      if (projected != 'native inspection unavailable (deadline)') {
        expect(projected, isNot(startsWith('native inspection ')));
        final observation = jsonDecode(projected) as Map<String, dynamic>;
        expect(observation['command_sequence_completed'], isTrue);
        expect(observation['export_labels_only'], isTrue);
        expect(observation['frame_labels'], isA<Map<String, dynamic>>());
      }
      stdout.writeln(projected == 'native inspection unavailable (deadline)'
          ? 'native debugger observation: deadline'
          : 'native debugger observation: labels');
      await inspector!.exitCode.timeout(const Duration(seconds: 1));
      expect(owned!.existsSync(), isFalse);
      await expectLater(
          child.exitCode.timeout(const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()));
    } finally {
      child.kill();
      await child.exitCode.timeout(const Duration(seconds: 10));
      await errors.cancel();
      await output;
    }
  }, skip: !Platform.isWindows || !cdb.existsSync());
}
