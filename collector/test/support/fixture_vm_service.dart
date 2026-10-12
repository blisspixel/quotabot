import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

/// Test-only diagnostics. The parent creates an owner-only handoff directory.
/// DDS stays disabled and the authenticated service URI never enters a log.
Future<void> startFixtureVmService() async {
  final path = Platform.environment['QUOTABOT_TEST_VM_SERVICE_INFO'];
  if (path == null) return;
  final info = await Service.controlWebServer(enable: true, silenceOutput: true)
      .timeout(const Duration(seconds: 5));
  final uri = info.serverUri;
  final isolate = Service.getIsolateId(Isolate.current);
  if (uri == null || !isFixtureVmServiceUri(uri) || isolate == null) {
    throw StateError('Fixture VM service scope unavailable');
  }
  File(path).writeAsStringSync(jsonEncode({
    'uri': uri.toString(),
    'pid': pid,
    'isolate_id': isolate,
  }));
}

bool isFixtureVmServiceUri(Uri uri) =>
    uri.scheme == 'http' &&
    uri.host == '127.0.0.1' &&
    uri.port > 0 &&
    uri.port <= 65535 &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment &&
    RegExp(r'^/[A-Za-z0-9_=-]{8,128}/$').hasMatch(uri.path);
