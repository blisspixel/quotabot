import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/mcp_http.dart';
import 'package:quotabot_collector/mcp_server_entrypoint.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';

const _token = '0123456789abcdef0123456789abcdef';

Future<void> main(List<String> args) async {
  if (args.length != 2 || home() != '${args[0]}/profile') {
    throw StateError('isolated subscription profile required');
  }
  setQuotabotDirOverrideForTesting(Directory('${args[0]}/data'));
  setMcpLogHandler((name, level, message) {
    if (level == LogLevel.warn || level == LogLevel.error) {
      stderr.writeln('[$name] $message');
    }
  });
  final scenario = args[1];
  final timers = _Timers();
  final result = await _run(scenario, timers);
  stdout.writeln(jsonEncode(result));
}

Future<Map<String, Object>> _run(String scenario, _Timers timers) async {
  final epoch = nowEpoch();
  final extreme = scenario.endsWith('-extreme');
  final multiday = scenario.endsWith('-multiday');
  final covered = scenario.endsWith('-covered');
  final entrypoint = scenario.startsWith('entrypoint-');
  final retry =
      extreme ? 0x7fffffffffffffff : (multiday ? 2 * 86400 + 7 : 7200);
  var reads = 0;
  Future<List<ProviderQuota>> snapshot() async {
    reads++;
    return [
      ProviderQuota.error('claude', 'Claude', 'HTTP 429', epoch,
          pipeHealth: providerPipeHealthThrottled, retryAfterSeconds: retry),
      if (!extreme && !multiday)
        ProviderQuota(
          provider: 'codex',
          displayName: 'Codex',
          account: 'synthetic-account',
          asOf: epoch,
          windows: [
            QuotaWindow(
                label: 'weekly', usedPercent: 20, resetsAt: epoch + 86400),
          ],
        ),
    ];
  }

  final sourceCoverage = covered ? <String>{'claude'} : null;
  McpServer? server;
  Future<void>? serverRun;
  StreamController<ProcessSignal>? signals;
  final client = McpClient(
      const Implementation(name: 'subscription-fixture', version: '1'));
  try {
    if (entrypoint) {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      signals = StreamController<ProcessSignal>();
      serverRun = runQuotabotMcpServer(
        ['--http', '--port=$port', '--token-env=QUOTABOT_MCP_FIXTURE_TOKEN'],
        snapshotSource: snapshot,
        providersWithUsageCooldowns: sourceCoverage,
        subscriptionTimerFactory: timers.create,
        shutdownSignals: signals.stream,
      );
      // The only socket is this synthetic loopback MCP server. Retry connection
      // until its asynchronous bind finishes, using real scheduling outside
      // the captured subscription timers.
      await _waitForPort(port);
      await client.connect(StreamableHttpClientTransport(
        Uri.parse('http://127.0.0.1:$port/mcp'),
        opts: StreamableHttpClientTransportOptions(requestInit: {
          'headers': {'Authorization': 'Bearer $_token'},
        }),
      ));
    } else {
      server = _server(scenario.startsWith('http-'), snapshot, sourceCoverage,
          epoch, timers);
      // HTTP sessions may be created after their wrapper factory returns.
      // Neither factory nor the hub may retain a mutable capability input.
      sourceCoverage?.clear();
      final serverTransport = _PairedTransport();
      final clientTransport = _PairedTransport();
      serverTransport.peer = clientTransport;
      clientTransport.peer = serverTransport;
      await server.connect(serverTransport);
      await client.connect(clientTransport);
    }
    final readsBefore = reads;
    await client.subscribeResource(
        const SubscribeRequest(uri: quotasCurrentResourceUri));
    timers.fire(Duration.zero);

    if (extreme || multiday) {
      await timers.waitFor(const Duration(days: 1));
      final chunks = extreme ? 3 : 2;
      for (var index = 0; index < chunks; index++) {
        timers.fire(const Duration(days: 1));
        await timers.waitFor(index == chunks - 1 && multiday
            ? const Duration(seconds: 7)
            : const Duration(days: 1));
      }
      final readsAtBoundaries = reads;
      if (multiday) {
        timers.fire(const Duration(seconds: 7));
        await timers.waitFor(const Duration(days: 1));
      }
      await client.unsubscribeResource(
          const UnsubscribeRequest(uri: quotasCurrentResourceUri));
      return extreme
          ? {
              'positive_day_chunks': timers.created
                  .where((timer) => timer.delay.inSeconds >= 86400)
                  .every((timer) => timer.delay == const Duration(days: 1)),
              'reads_after_three_chunks': readsAtBoundaries,
              'cancelled': !timers.hasActive(const Duration(days: 1)),
            }
          : {
              'reads_at_day_boundaries': readsAtBoundaries,
              'remainder_seconds': 7,
              'reads_at_full_deadline': reads,
              'cancelled': !timers.hasActive(const Duration(days: 1)),
            };
    }

    final delay = Duration(seconds: covered ? 300 : 7200);
    await timers.waitFor(delay);
    await client.unsubscribeResource(
        const UnsubscribeRequest(uri: quotasCurrentResourceUri));
    return {
      'reads_before_subscription': readsBefore,
      'reads_after_first_poll': reads,
      'next_delay_seconds': delay.inSeconds,
      'cancelled': !timers.hasActive(delay),
    };
  } finally {
    await client.close();
    await server?.close();
    if (signals != null) {
      signals.add(ProcessSignal.sigint);
      await serverRun;
      await signals.close();
    }
  }
}

McpServer _server(bool http, SnapshotProvider snapshot,
    Set<String>? sourceCoverage, int epoch, _Timers timers) {
  Map<String, BurnStat> burn(Iterable<ProviderQuota> providers, int now) => {};
  if (http) {
    final wrapper = sourceCoverage == null
        ? buildQuotabotStreamableHttpServer(
            config: const QuotabotMcpHttpConfig(bearerToken: _token),
            snapshot: snapshot,
            burnByProvider: burn,
            now: () => epoch,
            subscriptionTimerFactory: timers.create)
        : buildQuotabotStreamableHttpServer(
            config: const QuotabotMcpHttpConfig(bearerToken: _token),
            snapshot: snapshot,
            burnByProvider: burn,
            now: () => epoch,
            providersWithUsageCooldowns: sourceCoverage,
            subscriptionTimerFactory: timers.create);
    sourceCoverage?.clear();
    return wrapper.serverFactory('synthetic-session');
  }
  return sourceCoverage == null
      ? buildQuotabotMcpServer(
          snapshot: snapshot,
          burnByProvider: burn,
          now: () => epoch,
          subscriptionTimerFactory: timers.create)
      : buildQuotabotMcpServer(
          snapshot: snapshot,
          burnByProvider: burn,
          now: () => epoch,
          providersWithUsageCooldowns: sourceCoverage,
          subscriptionTimerFactory: timers.create);
}

Future<void> _waitForPort(int port) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.destroy();
      return;
    } on SocketException {
      await Zone.root
          .run(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
  }
  throw StateError('synthetic MCP server did not bind');
}

class _Timers {
  final created = <_CapturedTimer>[];
  final _waiting = <int, Completer<void>>{};

  Timer create(Duration delay, void Function() callback) {
    if (delay.isNegative) throw StateError('negative scheduling duration');
    final timer = _CapturedTimer(delay, callback);
    created.add(timer);
    _waiting.remove(delay.inMicroseconds)?.complete();
    return timer;
  }

  bool hasActive(Duration delay) =>
      created.any((timer) => timer.isActive && timer.delay == delay);

  Future<void> waitFor(Duration delay) {
    if (hasActive(delay)) return Future<void>.value();
    return (_waiting[delay.inMicroseconds] ??= Completer<void>()).future;
  }

  void fire(Duration delay) {
    created.lastWhere((timer) => timer.isActive && timer.delay == delay).fire();
  }
}

class _CapturedTimer implements Timer {
  _CapturedTimer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    callback();
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
}

class _PairedTransport implements Transport {
  _PairedTransport? peer;
  bool _closed = false;
  @override
  void Function()? onclose;
  @override
  void Function(Error error)? onerror;
  @override
  void Function(JsonRpcMessage message)? onmessage;
  @override
  String? get sessionId => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    final target = peer;
    if (target == null || target._closed) return;
    scheduleMicrotask(() => target.onmessage?.call(message));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onclose?.call();
    await peer?.close();
  }
}
