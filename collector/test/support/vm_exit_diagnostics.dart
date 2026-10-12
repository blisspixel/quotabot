import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'fixture_vm_service.dart';
import 'stdin_state_schema.dart';

/// Reads only selected VM metadata after the original process deadline fires.
/// Never emits URI/auth, names, ids, objects, errors, source, or heap contents.
Future<String> snapshotTimedOutVm(File handoff, int expectedPid,
    {bool inspectStdin = false}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 1)
    ..findProxy = (_) => 'DIRECT';
  final elapsed = Stopwatch()..start();
  final result = <String, Object?>{};
  Duration remaining() {
    final milliseconds = 3000 - elapsed.elapsedMilliseconds;
    if (milliseconds <= 0) throw TimeoutException('VM inspection expired');
    return Duration(milliseconds: milliseconds);
  }

  try {
    if (FileSystemEntity.typeSync(handoff.path, followLinks: false) !=
            FileSystemEntityType.file ||
        handoff.lengthSync() > 2048) {
      return 'VM inspection unavailable';
    }
    final info = jsonDecode(handoff.readAsStringSync());
    handoff.deleteSync();
    if (info is! Map ||
        info['uri'] is! String ||
        info['pid'] != expectedPid ||
        info['isolate_id'] is! String) {
      return 'VM inspection unavailable';
    }
    final uri = Uri.parse(info['uri'] as String);
    final isolateId = info['isolate_id'] as String;
    if (!isFixtureVmServiceUri(uri) ||
        !RegExp(r'^isolates/[0-9]{1,24}$').hasMatch(isolateId)) {
      return 'VM inspection unavailable';
    }

    Future<Map<String, dynamic>> read(
      String method, [
      Map<String, String>? parameters,
    ]) async {
      if (!const {'getVM', 'getIsolate', 'getPorts', stdinStateExtension}
          .contains(method)) {
        throw StateError('Unsupported VM inspection');
      }
      final target = uri.resolve(method).replace(queryParameters: parameters);
      final request = await client.getUrl(target).timeout(remaining());
      request.followRedirects = false;
      final response = await request.close().timeout(remaining());
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('VM inspection unavailable');
      }
      final bytes = <int>[];
      await (() async {
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 64 * 1024) {
            throw StateError('VM inspection response too large');
          }
          bytes.addAll(chunk);
        }
      })()
          .timeout(remaining());
      final envelope = jsonDecode(utf8.decode(bytes));
      if (envelope is! Map || envelope['result'] is! Map<String, dynamic>) {
        throw StateError('VM inspection unavailable');
      }
      return envelope['result'] as Map<String, dynamic>;
    }

    final vm = await read('getVM');
    if (vm['pid'] != expectedPid ||
        vm['isolates'] is! List ||
        vm['systemIsolates'] is! List) {
      return 'VM inspection unavailable';
    }
    final application = vm['isolates'] as List;
    final system = vm['systemIsolates'] as List;
    final present =
        application.any((entry) => entry is Map && entry['id'] == isolateId);
    result.addAll({
      'vm_pid_verified': true,
      'application_isolates': math.min(application.length, 64),
      'system_isolates': math.min(system.length, 64),
      'isolate_counts_capped': application.length > 64 || system.length > 64,
      'main_isolate_present': present,
    });
    if (!present) {
      result['inspection_complete'] = true;
      return jsonEncode(result);
    }
    final isolate = await read('getIsolate', {'isolateId': isolateId});
    if (isolate['type'] == 'Sentinel') {
      result['main_isolate_present'] = false;
      result['inspection_complete'] = true;
      return jsonEncode(result);
    }
    final livePorts = isolate['livePorts'];
    if (isolate['runnable'] is! bool ||
        isolate['pauseOnExit'] is! bool ||
        livePorts is! int ||
        livePorts < 0) {
      return 'VM inspection unavailable';
    }
    result.addAll({
      'runnable': isolate['runnable'],
      'pause_on_exit': isolate['pauseOnExit'],
      'live_ports': math.min(livePorts, 1024),
      'live_ports_capped': livePorts > 1024,
    });
    final pause = isolate['pauseEvent'];
    final kind = pause is Map ? pause['kind'] : null;
    result['pause_kind'] = const {
      'Resume',
      'PauseStart',
      'PauseExit',
      'PauseBreakpoint',
      'PauseException',
      'PauseInterrupted',
      'None',
    }.contains(kind)
        ? kind
        : 'unknown';
    final ports = await read('getPorts', {'isolateId': isolateId});
    final entries = ports['ports'];
    if (entries is! List) throw StateError('VM ports unavailable');
    final categories = <String, int>{
      'socket': 0,
      'timer': 0,
      'held_probe': 0,
      'unknown': 0
    };
    for (final entry in entries.take(128)) {
      final name = entry is Map ? entry['debugName'] : null;
      final category = switch (name) {
        'Socket Event Handler' => 'socket',
        'Timer' => 'timer',
        'quotabot diagnostic held port' => 'held_probe',
        _ => 'unknown',
      };
      categories[category] = categories[category]! + 1;
    }
    result['port_categories'] = categories;
    result['port_count_capped'] = entries.length > 128;
    if (inspectStdin) {
      final state = await read(stdinStateExtension, {'isolateId': isolateId});
      final projected = projectStdinState(state);
      if (projected == null) throw StateError('Stdin state unavailable');
      result['stdin_state'] = projected;
    }
    result['inspection_complete'] = true;
    return jsonEncode(result);
  } catch (_) {
    if (result.isNotEmpty) {
      result['inspection_complete'] = false;
      return jsonEncode(result);
    }
    return 'VM inspection unavailable';
  } finally {
    // Own every pending request and connection, including late completions.
    client.close(force: true);
    try {
      if (handoff.existsSync()) handoff.deleteSync();
    } catch (_) {
      // Parent teardown still owns the private directory.
    }
  }
}
