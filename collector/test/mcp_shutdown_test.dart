import 'dart:async';
import 'dart:io';

import 'package:quotabot_collector/expiring_single_flight.dart';
import 'package:quotabot_collector/http_client.dart';
import 'package:quotabot_collector/mcp_server_entrypoint.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

const _token = '0123456789abcdef0123456789abcdef';

ProviderQuota _localQuota() => ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: 'local',
      asOf: nowEpoch(),
      kind: ProviderQuotaKind.local,
    );

void main() {
  tearDown(resetSharedHttpClientForTesting);

  test('help path closes the shared client without retiring it', () async {
    await runQuotabotMcpServer(['--help']);
    expect(isSharedHttpClientRetired, isFalse);
    expect(sharedHttpClient, isNotNull);
    closeSharedHttpClient();
  });

  test('a late snapshot cannot recreate a retired HTTP client', () async {
    final release = Completer<void>();
    var loads = 0;
    var continuationRecreatedClient = false;
    final snapshots = ExpiringSingleFlight<List<ProviderQuota>>(
      load: () async {
        loads++;
        await release.future;
        try {
          sharedHttpClient;
          continuationRecreatedClient = true;
        } on StateError {
          continuationRecreatedClient = false;
        }
        return [_localQuota()];
      },
      now: nowEpoch,
    );

    final read = snapshots.read();
    expect(loads, 1);
    await shutDownMcpCollection(
      snapshots,
      drainTimeout: const Duration(milliseconds: 20),
    );
    expect(snapshots.isAdmitting, isFalse);
    expect(isSharedHttpClientRetired, isTrue);
    expect(() => sharedHttpClient, throwsStateError);
    expect(loads, 1);

    release.complete();
    await read.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(continuationRecreatedClient, isFalse);
    expect(loads, 1);
  });

  test('MCP HTTP shutdown retires the shared HTTP client', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final signals = StreamController<ProcessSignal>();
    addTearDown(signals.close);

    final serverRun = runQuotabotMcpServer(
      ['--http', '--port=$port', '--token', _token],
      snapshotSource: () async => [_localQuota()],
      shutdownSignals: signals.stream,
      shutdownDrainTimeout: const Duration(milliseconds: 50),
    );

    await _waitForPort(port);
    signals.add(ProcessSignal.sigint);
    await serverRun.timeout(const Duration(seconds: 2));
    expect(isSharedHttpClientRetired, isTrue);
    expect(() => sharedHttpClient, throwsStateError);
  });

  test('rejects a non-positive shutdown drain timeout', () {
    expect(
      () => runQuotabotMcpServer(
        ['--help'],
        shutdownDrainTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
}

Future<void> _waitForPort(int port) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.destroy();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  throw StateError('synthetic MCP server did not bind');
}
