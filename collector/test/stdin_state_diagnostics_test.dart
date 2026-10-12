import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:quotabot_collector/util.dart'
    show enforceOwnerOnlyDirectoryAsync;
import 'package:test/test.dart';

import 'support/stdin_state_extension.dart';
import 'support/stdin_state_schema.dart';
import 'support/vm_exit_diagnostics.dart';

void main() {
  test('stdin projection rejects additional fields and invalid types', () {
    expect(projectStdinState({'available': false}), {'available': false});
    expect(projectStdinState({'available': false, 'private': 'PRIVATE_DATA'}),
        isNull);
    const closed = {
      'available': true,
      'closed': true,
      'controllerClosed': true,
      'raw_present': false,
    };
    expect(projectStdinState(closed), closed);
    expect(projectStdinState({...closed, 'closed': 1}), isNull);
    expect(projectStdinState({...closed, 'event_port_present': true}), isNull);
    expect(projectStdinState({...closed, 'raw_present': true}), isNull);
  });

  test('extension rejects arbitrary method, parameters, and isolate', () async {
    final id = Service.getIsolateId(Isolate.current)!;
    for (final (method, parameters) in [
      ('ext.private', {'isolateId': id}),
      (stdinStateExtension, <String, String>{}),
      (stdinStateExtension, {'isolateId': 'isolates/0'}),
      (stdinStateExtension, {'isolateId': id, 'expression': 'PRIVATE_DATA'}),
    ]) {
      final response = await readStdinStateExtension(method, parameters);
      expect(response.result, '{"available":false}');
      expect(response.errorDetail, isNull);
    }
  });

  for (final active in [true, false]) {
    test('timeout-time stdin projection distinguishes active=$active',
        () async {
      final temp = Directory.systemTemp.createTempSync('quotabot_stdin_state_');
      await enforceOwnerOnlyDirectoryAsync(temp);
      final handoff = File('${temp.path}/service.json');
      final child = await Process.start(
          Platform.resolvedExecutable,
          [
            '--no-dds',
            'test/support/stdin_state_probe.dart',
            if (active) '--active',
          ],
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
            'QUOTABOT_TEST_VM_SERVICE_INFO': handoff.path,
          });
      final ready = Completer<void>();
      final returned = Completer<void>();
      int? vmPid;
      final lines = <String>[];
      final errors = utf8.decoder
          .bind(child.stderr)
          .transform(const LineSplitter())
          .listen((line) {
        lines.add(line);
        if (line.startsWith('fixture VM pid: ')) {
          vmPid = int.tryParse(line.substring('fixture VM pid: '.length));
        }
        if (line == 'fixture stdin probe ready' && !ready.isCompleted) {
          ready.complete();
        }
        if (line == 'fixture stdin probe main returned' &&
            !returned.isCompleted) {
          returned.complete();
        }
      });
      final output = child.stdout.toList();
      try {
        await ready.future.timeout(const Duration(seconds: 15));
        child.stdin.writeln('synthetic');
        await child.stdin.flush();
        await returned.future.timeout(const Duration(seconds: 10));
        await expectLater(
            child.exitCode.timeout(const Duration(milliseconds: 200)),
            throwsA(isA<TimeoutException>()));
        final text =
            await snapshotTimedOutVm(handoff, vmPid!, inspectStdin: true);
        final snapshot = jsonDecode(text) as Map;
        expect(snapshot['inspection_complete'], isTrue);
        final state = snapshot['stdin_state'] as Map;
        expect(state['available'], isTrue);
        expect(state['controllerClosed'], !active);
        expect(state['raw_present'], isTrue);
        expect(state['isClosing'], !active);
        expect(state['isClosed'], !active);
        expect(state['event_port_present'], active);
        expect(text, isNot(contains('http')));
        expect(lines, everyElement(isNot(contains('http'))));
      } finally {
        child.kill();
        await child.exitCode.timeout(const Duration(seconds: 10));
        await errors.cancel();
        await output.timeout(const Duration(seconds: 3));
        temp.deleteSync(recursive: true);
      }
    }, skip: !Platform.isWindows);
  }
}
