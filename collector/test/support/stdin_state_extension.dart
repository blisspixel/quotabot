import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'dart:mirrors';

import 'stdin_state_schema.dart';

// JIT-only test support. Keep this import outside compiled fixture graphs.
void registerStdinStateExtension() {
  if (!Platform.environment.containsKey('QUOTABOT_TEST_VM_SERVICE_INFO')) {
    return;
  }
  registerExtension(stdinStateExtension, readStdinStateExtension);
}

Future<ServiceExtensionResponse> readStdinStateExtension(
  String method,
  Map<String, String> parameters,
) async {
  try {
    final isolate = Service.getIsolateId(Isolate.current);
    if (method != stdinStateExtension ||
        isolate == null ||
        parameters.length != 1 ||
        parameters['isolateId'] != isolate) {
      return ServiceExtensionResponse.result('{"available":false}');
    }
    return ServiceExtensionResponse.result(jsonEncode(snapshotStdinState()));
  } catch (_) {
    // Extension dispatch otherwise serializes exceptions and stack traces.
    return ServiceExtensionResponse.result('{"available":false}');
  }
}

Map<String, Object?> snapshotStdinState() {
  try {
    final library = reflectClass(Stdin).owner as LibraryMirror;
    InstanceMirror field(InstanceMirror object, String name) =>
        object.getField(MirrorSystem.getSymbol(name, library));
    final socket = field(reflect(stdin), '_stream');
    final result = <String, Object?>{};
    for (final name in ['_closed', '_controllerClosed']) {
      final value = field(socket, name).reflectee;
      if (value is! bool) return {'available': false};
      result[name.substring(1)] = value;
    }
    final raw = field(socket, '_raw');
    result['raw_present'] = raw.reflectee != null;
    if (raw.reflectee == null) return {'available': true, ...result};
    final native = field(raw, '_socket');
    for (final name in [
      'isClosing',
      'isClosed',
      'isClosedRead',
      'isClosedWrite'
    ]) {
      final value = native.getField(Symbol(name)).reflectee;
      if (value is! bool) return {'available': false};
      result[name] = value;
    }
    result['event_port_present'] =
        native.getField(const Symbol('eventPort')).reflectee != null;
    return {'available': true, ...result};
  } catch (_) {
    return {'available': false};
  }
}
