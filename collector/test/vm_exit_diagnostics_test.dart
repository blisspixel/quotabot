import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/util.dart'
    show enforceOwnerOnlyDirectoryAsync;
import 'package:test/test.dart';

import 'support/vm_exit_diagnostics.dart';

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_vm_snapshot_');
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File handoff(Uri uri, {int pid = 1234}) => File('${temp.path}/service.json')
    ..writeAsStringSync(jsonEncode({
      'uri': uri.toString(),
      'pid': pid,
      'isolate_id': 'isolates/1234',
    }));

  test('VM inspection projects an actual held port without its private name',
      () async {
    await enforceOwnerOnlyDirectoryAsync(temp);
    final file = File('${temp.path}/service.json');
    final child = await Process.start(
      Platform.resolvedExecutable,
      ['--no-dds', 'test/support/vm_diagnostic_probe.dart'],
      includeParentEnvironment: false,
      environment: {
        for (final key in ['PATH', 'SystemRoot', 'WINDIR'])
          if (Platform.environment[key] != null)
            key: Platform.environment[key]!,
        for (final key in [
          'HOME',
          'USERPROFILE',
          'LOCALAPPDATA',
          'APPDATA',
          'XDG_CONFIG_HOME',
          'TEMP',
          'TMP'
        ])
          key: temp.path,
        'QUOTABOT_TEST_VM_SERVICE_INFO': file.path,
      },
    );
    final ready = Completer<void>();
    int? vmPid;
    var privateOutputObserved = false;
    final errors = utf8.decoder
        .bind(child.stderr)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.contains('http') || line.contains('PRIVATE_VM_NAME')) {
        privateOutputObserved = true;
      }
      if (line.startsWith('fixture VM pid: ')) {
        vmPid = int.parse(line.substring('fixture VM pid: '.length));
      }
      if (line == 'fixture probe main returned' && !ready.isCompleted) {
        ready.complete();
      }
    });
    var stdoutObserved = false;
    final output = child.stdout.forEach((chunk) {
      if (chunk.isNotEmpty) stdoutObserved = true;
    });
    try {
      await ready.future.timeout(const Duration(seconds: 15));
      await expectLater(
        child.exitCode.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      final projected = await snapshotTimedOutVm(file, vmPid!);
      final snapshot = jsonDecode(projected) as Map;
      expect(snapshot['vm_pid_verified'], isTrue);
      expect(snapshot['main_isolate_present'], isTrue);
      expect(snapshot['runnable'], isTrue);
      expect(snapshot['live_ports'], greaterThanOrEqualTo(2));
      expect((snapshot['port_categories'] as Map)['held_probe'], 1);
      expect((snapshot['port_categories'] as Map)['unknown'],
          greaterThanOrEqualTo(1));
      expect(projected, isNot(contains('PRIVATE_VM_NAME')));
      expect(projected, isNot(contains('http')));
      expect(projected, isNot(contains('isolates/')));
      expect(file.existsSync(), isFalse);
      expect(privateOutputObserved, isFalse,
          reason: 'VM service output stays private');
      expect(stdoutObserved, isFalse,
          reason: 'VM service does not write stdout');
    } finally {
      child.kill();
      await child.exitCode.timeout(const Duration(seconds: 10));
      await errors.cancel();
      await output.timeout(const Duration(seconds: 3));
    }
  }, skip: !Platform.isWindows);

  test('VM inspection rejects a non-loopback handoff without connecting',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      await request.response.close();
    });
    try {
      final file =
          handoff(Uri.parse('http://localhost:${server.port}/PRIVATE_AUTH=/'));
      expect(await snapshotTimedOutVm(file, 1234), 'VM inspection unavailable');
      expect(requests, 0);
      expect(file.existsSync(), isFalse);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('VM inspection shares its deadline and retains only safe partial fields',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      if (request.uri.path.endsWith('/getPorts')) return;
      await Future<void>.delayed(const Duration(seconds: 1));
      final result = request.uri.path.endsWith('/getVM')
          ? <String, Object?>{
              'pid': 1234,
              'isolates': [
                {'id': 'isolates/1234', 'name': 'PRIVATE_NAME'}
              ],
              'systemIsolates': <Object?>[],
            }
          : <String, Object?>{
              'type': 'Isolate',
              'runnable': true,
              'pauseOnExit': false,
              'livePorts': 2,
              'pauseEvent': {'kind': 'PRIVATE_PAUSE'},
              'rootLib': {'uri': 'PRIVATE_SOURCE'},
            };
      request.response.write(jsonEncode({'result': result}));
      try {
        await request.response.close();
      } catch (_) {
        // The inspector can close the owned client when its total budget ends.
      }
    });
    try {
      final file =
          handoff(Uri.parse('http://127.0.0.1:${server.port}/PRIVATE_AUTH=/'));
      final elapsed = Stopwatch()..start();
      final projected = await snapshotTimedOutVm(file, 1234);
      final snapshot = jsonDecode(projected) as Map;
      expect(snapshot['vm_pid_verified'], isTrue);
      expect(snapshot['live_ports'], 2);
      expect(snapshot['inspection_complete'], isFalse);
      expect(snapshot['pause_kind'], 'unknown');
      expect(projected, isNot(contains('PRIVATE')));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
      expect(requests, 3);
      expect(file.existsSync(), isFalse);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('VM inspection rejects a mismatched VM before querying an isolate',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      request.response.write(jsonEncode({
        'result': {'pid': 4321}
      }));
      await request.response.close();
    });
    try {
      final file =
          handoff(Uri.parse('http://127.0.0.1:${server.port}/PRIVATE_AUTH=/'));
      expect(await snapshotTimedOutVm(file, 1234), 'VM inspection unavailable');
      expect(requests, 1);
      expect(file.existsSync(), isFalse);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('VM inspection cancels a stalled body and closes its owned socket',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final streams = <StreamSubscription<List<int>>>[];
    final connectionClosed = Completer<void>();
    final subscription = server.listen((socket) {
      sockets.add(socket);
      var responded = false;
      void closed() {
        if (!connectionClosed.isCompleted) connectionClosed.complete();
      }

      streams.add(socket.listen((_) {
        if (responded) return;
        responded = true;
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1024\r\n'
            'Connection: close\r\n\r\n{"result":');
        unawaited(socket.flush().catchError((Object _) {}));
      }, onDone: closed, onError: (Object _) => closed()));
    });
    try {
      final file =
          handoff(Uri.parse('http://127.0.0.1:${server.port}/PRIVATE_AUTH=/'));
      final elapsed = Stopwatch()..start();
      expect(await snapshotTimedOutVm(file, 1234), 'VM inspection unavailable');
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
      expect(file.existsSync(), isFalse);
      expect(sockets, hasLength(1));
      await connectionClosed.future.timeout(const Duration(seconds: 3));
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      for (final stream in streams) {
        await stream.cancel();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  for (final mode in ['redirect', 'oversized', 'stalled']) {
    test('VM inspection bounds $mode responses and removes its handoff',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        if (mode == 'stalled') return;
        if (mode == 'redirect') {
          request.response.statusCode = HttpStatus.temporaryRedirect;
          request.response.headers.set(HttpHeaders.locationHeader,
              'http://192.0.2.1:1234/PRIVATE_REDIRECT');
        } else {
          request.response.write('PRIVATE_RESPONSE' * 5000);
        }
        try {
          await request.response.close();
        } catch (_) {
          // An oversized-body inspector owns and closes its pending socket.
        }
      });
      try {
        final file = handoff(
            Uri.parse('http://127.0.0.1:${server.port}/PRIVATE_AUTH=/'));
        final elapsed = Stopwatch()..start();
        final result = await snapshotTimedOutVm(file, 1234);
        expect(result, 'VM inspection unavailable');
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
        expect(requests, 1);
        expect(file.existsSync(), isFalse);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    });
  }
}
