import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/util.dart'
    show enforceOwnerOnlyDirectoryAsync;

const _nativeBegin = 'QUOTABOT_NATIVE_STACK_BEGIN';
const _nativeEnd = 'QUOTABOT_NATIVE_STACK_END';

class _NativeInspectionDeadline implements Exception {
  const _NativeInspectionDeadline();
}

/// Export-only, moving-thread observations are suggestive labels, not proof
/// of a particular Dart thread, descriptor, call site, or completed operation.
Map<String, Object?>? projectNativeStackLabels(String text) {
  final lines =
      const LineSplitter().convert(text).map((line) => line.trim()).toList();
  final start = lines.indexOf(_nativeBegin);
  final end = lines.indexOf(_nativeEnd);
  if (start < 0 ||
      end <= start ||
      lines.lastIndexOf(_nativeBegin) != start ||
      lines.lastIndexOf(_nativeEnd) != end) {
    return null;
  }
  final counts = <String, int>{
    'read_family': 0,
    'close_family': 0,
    'completion_wait': 0,
    'other_wait': 0,
    'unclassified': 0,
  };
  final frame = RegExp(
    r'^\s*(?:[0-9a-fA-F]{1,3}\s+)?([A-Za-z0-9_.-]{1,80})!([A-Za-z0-9_:$<>~.?-]{1,200})(?:\+0x[0-9a-fA-F]+)?\s*$',
  );
  var observed = 0;
  for (final line in lines.sublist(start + 1, end)) {
    final match = frame.firstMatch(line);
    if (match == null) continue;
    if (++observed > 512) return null;
    final module = match.group(1)!.toLowerCase();
    final symbol = match.group(2)!;
    final category = const {'ntdll', 'kernelbase', 'kernel32'}.contains(module)
        ? switch (symbol) {
            'NtReadFile' || 'ReadFile' => 'read_family',
            'NtClose' || 'CloseHandle' => 'close_family',
            'NtRemoveIoCompletion' ||
            'NtRemoveIoCompletionEx' ||
            'GetQueuedCompletionStatus' ||
            'GetQueuedCompletionStatusEx' =>
              'completion_wait',
            'NtWaitForSingleObject' ||
            'NtWaitForMultipleObjects' ||
            'WaitForSingleObject' ||
            'WaitForSingleObjectEx' ||
            'WaitForMultipleObjects' ||
            'WaitForMultipleObjectsEx' ||
            'NtWaitForAlertByThreadId' ||
            'RtlSleepConditionVariableSRW' ||
            'SleepConditionVariableSRW' =>
              'other_wait',
            _ => 'unclassified',
          }
        : 'unclassified';
    counts[category] = counts[category]! + 1;
  }
  if (observed == 0) return null;
  return {
    'command_sequence_completed': true,
    'export_labels_only': true,
    'frame_labels': counts
  };
}

/// Called only after failure and a process snapshot that verifies the VM as
/// a direct child of this owned launcher. Does not suspend or control target.
Future<String> snapshotTimedOutNative(
  Process target,
  String processState, {
  Future<Process> Function(List<String> arguments, Directory ownedDirectory)?
      startInspectorForTesting,
  void Function(Process inspector, Directory ownedDirectory)?
      onInspectorStartedForTesting,
}) async {
  if (!Platform.isWindows) return 'native inspection unavailable';
  final programFiles = Platform.environment['ProgramFiles(x86)'];
  if (programFiles == null) return 'native inspection unavailable';
  final debugger = File('$programFiles/Windows Kits/10/Debuggers/x64/cdb.exe');
  Directory? temp;
  Process? inspector;
  StreamSubscription<List<int>>? output;
  StreamSubscription<List<int>>? errors;
  var exited = false;
  int? inspectorExit;
  var oversized = false;
  var lateOwnsDirectory = false;
  String? ownedPath;
  String? tempRoot;
  final elapsed = Stopwatch()..start();
  Duration remaining() {
    final milliseconds = 3000 - elapsed.elapsedMilliseconds;
    if (milliseconds <= 0) throw const _NativeInspectionDeadline();
    return Duration(milliseconds: milliseconds);
  }

  Future<T> withinBudget<T>(Future<T> work) => work.timeout(remaining(),
      onTimeout: () => throw const _NativeInspectionDeadline());

  Future<void> reap(Process child) async {
    try {
      child.kill();
      await child.exitCode.timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  void removeDirectory(Directory directory) {
    try {
      final resolved = directory.resolveSymbolicLinksSync();
      if (tempRoot == null ||
          resolved != ownedPath ||
          !resolved.toLowerCase().startsWith(
              '${tempRoot.toLowerCase()}${Platform.pathSeparator}') ||
          !directory.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last
              .startsWith('quotabot_native_snapshot_')) {
        return;
      }
      directory.deleteSync(recursive: true);
    } catch (_) {}
  }

  try {
    if (startInspectorForTesting == null && !debugger.existsSync()) {
      return 'native inspection unavailable';
    }
    tempRoot = Directory.systemTemp.resolveSymbolicLinksSync();
    final state = jsonDecode(processState);
    if (state is! Map ||
        state['launcher_pid'] != target.pid ||
        state['launcher_present'] != true ||
        state['vm_present'] != true ||
        state['vm_pid'] is! int ||
        state['processes'] is! List) {
      return 'native inspection unavailable';
    }
    final vmPid = state['vm_pid'] as int;
    if (vmPid <= 0 ||
        !(state['processes'] as List).any((row) =>
            row is Map &&
            row['pid'] == vmPid &&
            row['parent'] == target.pid &&
            row['name'] == 'dartvm.exe')) {
      return 'native inspection unavailable';
    }
    temp = Directory.systemTemp.createTempSync('quotabot_native_snapshot_');
    ownedPath = temp.resolveSymbolicLinksSync();
    await withinBudget(enforceOwnerOnlyDirectoryAsync(temp));
    final symbols = Directory('${temp.path}/symbols')..createSync();
    final commands = File('${temp.path}/commands.txt')
      ..writeAsStringSync(
        '.echo $_nativeBegin\n~* kcL 8\n.echo $_nativeEnd\nqd\n',
      );
    final owned = temp;
    final launchBudget = remaining();
    final arguments = [
      // No invasive attachment means debugger exit cannot terminate the target.
      // Combining -pd with this mode rejects startup on supported CDB builds.
      '-pvr',
      '-sins',
      '-netsyms:no',
      '-noshell',
      '-nosqm',
      '-snul',
      '-cf',
      commands.path,
      '-y',
      symbols.path,
      '-srcpath',
      symbols.path,
      '-i',
      symbols.path,
      '-p',
      '$vmPid',
    ];
    final starting = startInspectorForTesting != null
        ? startInspectorForTesting(arguments, temp)
        : Process.start(debugger.path, arguments,
            workingDirectory: temp.path,
            includeParentEnvironment: false,
            environment: {
                for (final key in ['SystemRoot', 'WINDIR'])
                  if (Platform.environment[key] != null)
                    key: Platform.environment[key]!,
                'TEMP': temp.path,
                'TMP': temp.path,
              });
    unawaited(starting.then((late) async {
      if (lateOwnsDirectory) {
        StreamSubscription<List<int>>? stdout;
        StreamSubscription<List<int>>? stderr;
        try {
          stdout = late.stdout.listen((_) {}, onError: (Object _) {});
          stderr = late.stderr.listen((_) {}, onError: (Object _) {});
          await reap(late);
        } catch (_) {
          // Late diagnostic cleanup must not escape into the test harness.
          await reap(late);
        } finally {
          for (final subscription in [stdout, stderr]) {
            try {
              await subscription?.cancel().timeout(const Duration(seconds: 1));
            } catch (_) {}
          }
          removeDirectory(owned);
        }
      }
    }, onError: (Object _, StackTrace __) {
      if (lateOwnsDirectory) removeDirectory(owned);
    }));
    inspector = await starting.timeout(launchBudget, onTimeout: () {
      lateOwnsDirectory = true;
      throw const _NativeInspectionDeadline();
    });
    onInspectorStartedForTesting?.call(inspector, temp);
    final bytes = <int>[];
    var outputBytes = 0;
    void consume(List<int> chunk, {required bool retain}) {
      outputBytes += chunk.length;
      if (outputBytes > 64 * 1024) {
        oversized = true;
        try {
          inspector?.kill();
        } catch (_) {}
      } else if (!oversized && retain) {
        bytes.addAll(chunk);
      }
    }

    output = inspector.stdout.listen((chunk) => consume(chunk, retain: true),
        onError: (Object _) {});
    errors = inspector.stderr.listen((chunk) => consume(chunk, retain: false),
        onError: (Object _) {});
    final outputDone = output.asFuture<void>();
    final errorsDone = errors.asFuture<void>();
    final exit = inspector.exitCode.then((code) {
      exited = true;
      inspectorExit = code;
      return code;
    });
    final completed = Future.wait([exit, outputDone, errorsDone]);
    unawaited(
        completed.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    await withinBudget(inspector.stdin.close());
    await withinBudget(completed);
    if (oversized || await exit != 0) return 'native inspection incomplete';
    final projected = projectNativeStackLabels(utf8.decode(bytes));
    return projected == null
        ? 'native inspection incomplete'
        : jsonEncode(projected);
  } on _NativeInspectionDeadline {
    if (oversized || (inspectorExit != null && inspectorExit != 0)) {
      return 'native inspection incomplete';
    }
    return 'native inspection unavailable (deadline)';
  } catch (_) {
    return 'native inspection unavailable';
  } finally {
    if (inspector != null && !exited) await reap(inspector);
    for (final subscription in [output, errors]) {
      try {
        await subscription?.cancel().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    if (temp != null && !lateOwnsDirectory) removeDirectory(temp);
  }
}
