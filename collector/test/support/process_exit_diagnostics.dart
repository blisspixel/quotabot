import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> _reapInspector(Process inspector) async {
  try {
    inspector.kill();
    await inspector.exitCode.timeout(const Duration(seconds: 1));
  } catch (_) {
    // Preserve the target's original timeout even if diagnostic cleanup fails.
  }
}

Future<void> _cancelInspectorStream(
  StreamSubscription<List<int>>? subscription,
) async {
  try {
    await subscription?.cancel().timeout(const Duration(seconds: 1));
  } catch (_) {
    // Cancellation is diagnostic-only and must not become another unbounded wait.
  }
}

Future<void> _reapLateInspector(Process inspector) async {
  final output = inspector.stdout.listen((_) {}, onError: (Object _) {});
  final errors = inspector.stderr.listen((_) {}, onError: (Object _) {});
  await _reapInspector(inspector);
  await _cancelInspectorStream(output);
  await _cancelInspectorStream(errors);
}

/// Observes only the owned launcher, fixture VM, and direct launcher children.
/// Inspection happens after failure and never changes the target's stdin.
Future<String> snapshotTimedOutProcess(
  Process target,
  List<String> diagnostics,
) async {
  if (!Platform.isWindows) return 'process snapshot unavailable on this OS';
  final vmLine =
      diagnostics.where((line) => line.startsWith('fixture VM pid: '));
  if (vmLine.length != 1) return 'process snapshot missing fixture VM pid';
  final vmId = int.tryParse(vmLine.single.substring('fixture VM pid: '.length));
  final systemRoot = Platform.environment['SystemRoot'];
  if (vmId == null || vmId <= 0 || systemRoot == null) {
    return 'process snapshot unavailable';
  }
  Process? inspector;
  StreamSubscription<List<int>>? output;
  StreamSubscription<List<int>>? errors;
  final bytes = <int>[];
  var oversized = false;
  var exited = false;
  final elapsed = Stopwatch()..start();
  try {
    var launchTimedOut = false;
    final starting = Process.start(
      '$systemRoot/System32/WindowsPowerShell/v1.0/powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-File',
        'test/support/windows_process_snapshot.ps1',
        '-LauncherId',
        '${target.pid}',
        '-VmId',
        '$vmId',
      ],
    );
    unawaited(starting.then((late) async {
      if (launchTimedOut) {
        try {
          await _reapLateInspector(late);
        } catch (_) {
          // Late diagnostic failures must not escape into the test harness.
        }
      }
    }, onError: (Object _, StackTrace __) {}));
    inspector =
        await starting.timeout(const Duration(seconds: 3), onTimeout: () {
      launchTimedOut = true;
      throw TimeoutException('process inspector launch timed out');
    });
    output = inspector.stdout.listen((chunk) {
      if (bytes.length + chunk.length > 4096) {
        oversized = true;
      } else if (!oversized) {
        bytes.addAll(chunk);
      }
    });
    errors = inspector.stderr.listen((_) {}, onError: (Object _) {});
    final outputDone = output.asFuture<void>();
    final exit = inspector.exitCode.then((code) {
      exited = true;
      return code;
    });
    final remaining = 3000 - elapsed.elapsedMilliseconds;
    if (remaining <= 0) return 'process snapshot unavailable';
    await Future.wait([exit, outputDone])
        .timeout(Duration(milliseconds: remaining));
    if (await exit != 0 || oversized) return 'process snapshot unavailable';
    final result = jsonDecode(utf8.decode(bytes));
    if (result is! Map ||
        result['launcher_present'] is! bool ||
        result['vm_present'] is! bool ||
        result['processes'] is! List) {
      return 'process snapshot invalid';
    }
    // Return selected fields only, even if the inspector unexpectedly changes.
    final rows = <Map<String, Object?>>[];
    for (final row in (result['processes'] as List).take(8)) {
      if (row is! Map ||
          row['pid'] is! int ||
          row['parent'] is! int ||
          row['name'] is! String ||
          !(row['pid'] == target.pid ||
              row['pid'] == vmId ||
              row['parent'] == target.pid)) {
        return 'process snapshot invalid';
      }
      final name = row['name'] as String;
      if (!RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(name)) {
        return 'process snapshot invalid';
      }
      rows.add({'pid': row['pid'], 'parent': row['parent'], 'name': name});
    }
    return jsonEncode({
      'launcher_pid': target.pid,
      'vm_pid': vmId,
      'launcher_present': result['launcher_present'],
      'vm_present': result['vm_present'],
      'processes': rows,
    });
  } catch (_) {
    return 'process snapshot unavailable';
  } finally {
    if (inspector != null && !exited) {
      await _reapInspector(inspector);
    }
    await _cancelInspectorStream(output);
    await _cancelInspectorStream(errors);
  }
}
