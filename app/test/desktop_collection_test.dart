import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_collection.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/collector.dart'
    show collectAllWithRuntimeAccess, kAdapterDeadline;
import 'package:quotabot_collector/file_guard.dart';
import 'package:quotabot_collector/http_client.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_adapters.dart';
import 'package:quotabot_collector/provider_read_gate.dart';
import 'package:quotabot_collector/util.dart';

const _now = 1800000000;
int _readerCalls = 0;

ProviderQuota _quota(int generation) => ProviderQuota(
  provider: 'codex',
  displayName: 'Codex',
  account: 'synthetic-worker',
  asOf: _now + generation,
  windows: [
    QuotaWindow(label: 'weekly', usedPercent: 30, resetsAt: _now + 86400),
  ],
);

Future<List<ProviderQuota>> _controlledReader(
  int generation,
  Object? data,
) async {
  final parent = data! as SendPort;
  final release = ReceivePort();
  parent.send((generation, ++_readerCalls, release.sendPort));
  try {
    await release.first;
    return [_quota(generation)];
  } finally {
    release.close();
  }
}

Future<List<ProviderQuota>> _failingFirstReader(
  int generation,
  Object? data,
) async {
  _readerCalls++;
  if (_readerCalls == 1) throw StateError('synthetic private diagnostic');
  return [_quota(_readerCalls)];
}

Future<List<ProviderQuota>> _asynchronousErrorReader(
  int generation,
  Object? data,
) async {
  final release = ReceivePort();
  (data! as SendPort).send(release.sendPort);
  scheduleMicrotask(
    () => throw StateError('synthetic private async diagnostic'),
  );
  try {
    await release.first;
    return [_quota(generation)];
  } finally {
    release.close();
  }
}

void _noDirectoryHardening(Directory directory) {}
void _noFileHardening(File file) {}

ProviderReadGate _gate(String path) => ProviderReadGate(
  directory: Directory(path),
  clock: () => _now,
  jitter: (_) => 0,
  hardenDirectory: _noDirectoryHardening,
  hardenFile: _noFileHardening,
  acquisitionTimeout: const Duration(milliseconds: 10),
);

Future<Object> _readGuarded(
  ProviderReadGate gate, {
  Future<Object> Function(ProviderReadOperation)? attempt,
}) => gate.run<Object>(
  provider: 'claude',
  credentialIdentity: opaqueCredentialIdentity('claude', 'synthetic-worker'),
  purpose: ProviderReadPurpose.usage,
  attempt: attempt ?? (_) async => 'available',
  classify: (_) => const ProviderReadDisposition.completed(),
  deferred: (deferral) => deferral,
);

Future<List<ProviderQuota>> _guardedReader(int generation, Object? data) async {
  final (parent, directory) = data! as (SendPort, String);
  final gate = _gate(directory);
  if (generation == 1) {
    final entered = Completer<void>();
    final release = ReceivePort();
    final original = _readGuarded(
      gate,
      attempt: (operation) async {
        entered.complete();
        return operation.track(release.first.then((_) => 'available'));
      },
    ).whenComplete(release.close);
    await entered.future;
    parent.send(release.sendPort);
    // Models the bounded fleet result, without canceling the original read.
    await original.timeout(
      const Duration(milliseconds: 1),
      onTimeout: () => 'bounded-result',
    );
  } else {
    final result = await _readGuarded(gate);
    parent.send(result is ProviderReadDeferral ? result.reason.name : result);
  }
  // Independent provider metadata can still publish in each generation.
  return [_quota(generation)];
}

Future<List<ProviderQuota>> _httpReader(int generation, Object? data) async {
  await sharedHttpClient.get(Uri.parse(data! as String));
  return [_quota(generation)];
}

Future<List<ProviderQuota>> _ungatedDeadlineReader(
  int generation,
  Object? data,
) async {
  final (directory, endpoint) = data! as (String, String);
  setQuotabotDirOverrideForTesting(Directory(directory));
  final registration = ProviderAdapterRegistration(
    // A distinct synthetic ID prevents built-in current-account readers from
    // consulting host configuration during cache normalization.
    id: 'worker-fixture',
    displayName: 'Worker fixture',
    adapterClass: ProviderAdapterClass.subscription,
    sourceClasses: kAuthoritativeLiveSourceClasses,
    cached: false,
    fixtureKind: ProviderFixtureKind.codexUsage,
    fixtureFile: 'synthetic',
    collect: () async {
      final guard = await acquireInterprocessFileGuard(
        File('$directory/ungated.lock'),
        hardenClaim: _noFileHardening,
      );
      try {
        final response = await sharedHttpClient.get(Uri.parse(endpoint));
        if (response.statusCode != 200) {
          throw StateError('synthetic late metadata failure');
        }
        return const [];
      } finally {
        guard.release();
      }
    },
  );
  try {
    final snapshot = await runZoned(
      () => collectAllWithRuntimeAccess(registry: [registration]),
      zoneSpecification: ZoneSpecification(
        // Exercise the actual fleet deadline without a 30-second test wait.
        // Native guard retries and request futures keep their real lifetimes.
        createTimer: (self, parent, zone, duration, callback) =>
            parent.createTimer(
              zone,
              duration == kAdapterDeadline
                  ? const Duration(milliseconds: 1)
                  : duration,
              callback,
            ),
      ),
    );
    return snapshot.providers;
  } finally {
    setQuotabotDirOverrideForTesting(null);
  }
}

Future<bool> _hasCompleted(Future<void> future) async {
  var completed = false;
  unawaited(future.then((_) => completed = true));
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return completed;
}

void main() {
  test('unused close is idempotent and never starts a reader', () async {
    final worker = DesktopCollectionWorker(reader: _failingFirstReader);
    final first = worker.close();
    expect(worker.close(), same(first));
    await first;
    await expectLater(worker.collect(), throwsStateError);
  });

  test('real worker coalesces a timed-out generation and is reused', () async {
    final events = ReceivePort();
    final messages = StreamIterator<Object?>(events);
    final worker = DesktopCollectionWorker(
      reader: _controlledReader,
      readerData: events.sendPort,
    );
    SendPort? release;
    try {
      final first = worker.collect();
      expect(worker.collect(), same(first));
      expect(await messages.moveNext(), isTrue);
      final started = messages.current! as (int, int, SendPort);
      expect((started.$1, started.$2), (1, 1));
      release = started.$3;
      await expectLater(
        first.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        worker.collect(),
        same(first),
        reason: 'caller timeout must not reset or spawn a generation',
      );
      release.send(null);
      release = null;
      expect((await first).single.asOf, _now + 1);

      final next = worker.collect();
      expect(await messages.moveNext(), isTrue);
      final second = messages.current! as (int, int, SendPort);
      expect(
        (second.$1, second.$2),
        (2, 2),
        reason: 'reader isolate state survives between generations',
      );
      release = second.$3;
      final closing = worker.close();
      expect(await _hasCompleted(closing), isFalse);
      await expectLater(worker.collect(), throwsStateError);
      release.send(null);
      release = null;
      expect((await next).single.asOf, _now + 2);
      await closing.timeout(const Duration(seconds: 5));
    } finally {
      release?.send(null);
      await worker.close().timeout(const Duration(seconds: 5));
      await messages.cancel();
      events.close();
    }
  });

  test(
    'reader failures are bounded and do not start a fallback worker',
    () async {
      final worker = DesktopCollectionWorker(reader: _failingFirstReader);
      try {
        await expectLater(
          worker.collect(),
          throwsA(
            isA<StateError>().having(
              (error) => error.toString(),
              'bounded message',
              isNot(contains('synthetic private diagnostic')),
            ),
          ),
        );
        expect(
          (await worker.collect()).single.asOf,
          _now + 2,
          reason: 'second read uses the same isolate after a handled failure',
        );
      } finally {
        await worker.close().timeout(const Duration(seconds: 5));
      }
    },
  );

  test('failed isolate startup never falls back to a local reader', () async {
    final unsendable = ReceivePort();
    final worker = DesktopCollectionWorker(
      reader: _failingFirstReader,
      readerData: unsendable,
    );
    try {
      await expectLater(worker.collect(), throwsStateError);
      await expectLater(worker.collect(), throwsStateError);
      await worker.close();
    } finally {
      unsendable.close();
    }
  });

  test('close during startup admits no collection generation', () async {
    final events = ReceivePort();
    var calls = 0;
    events.listen((Object? message) {
      calls++;
      (message! as (int, int, SendPort)).$3.send(null);
    });
    final worker = DesktopCollectionWorker(
      reader: _controlledReader,
      readerData: events.sendPort,
    );
    try {
      final reading = worker.collect();
      final closing = worker.close();
      await expectLater(reading, throwsStateError);
      await closing.timeout(const Duration(seconds: 5));
      expect(calls, 0);
    } finally {
      await worker.close().timeout(const Duration(seconds: 5));
      events.close();
    }
  });

  test(
    'unexpected async errors keep the active worker owned through close',
    () async {
      final events = ReceivePort();
      final worker = DesktopCollectionWorker(
        reader: _asynchronousErrorReader,
        readerData: events.sendPort,
      );
      SendPort? release;
      try {
        final result = worker.collect();
        final rejected = expectLater(
          result,
          throwsA(
            isA<StateError>().having(
              (error) => error.toString(),
              'bounded failure',
              isNot(contains('synthetic private async diagnostic')),
            ),
          ),
        );
        release = await events.first as SendPort;
        await rejected;
        await expectLater(worker.collect(), throwsStateError);
        final closing = worker.close();
        expect(await _hasCompleted(closing), isFalse);
        release.send(null);
        release = null;
        await closing.timeout(const Duration(seconds: 5));
      } finally {
        release?.send(null);
        await worker.close().timeout(const Duration(seconds: 5));
        events.close();
      }
    },
  );

  test(
    'bounded fleet publishes while real guarded requests retain their owner',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'desktop_gate_owner_',
      );
      final events = ReceivePort();
      final messages = StreamIterator<Object?>(events);
      final worker = DesktopCollectionWorker(
        reader: _guardedReader,
        readerData: (events.sendPort, '${directory.path}/gates'),
      );
      SendPort? release;
      try {
        final first = worker.collect();
        expect(await messages.moveNext(), isTrue);
        release = messages.current! as SendPort;
        expect(
          (await first.timeout(const Duration(seconds: 5))).single.asOf,
          _now + 1,
        );
        final next = worker.collect();
        expect(await messages.moveNext(), isTrue);
        expect(messages.current, 'busy');
        expect(
          (await next).single.asOf,
          _now + 2,
          reason:
              'independent quota can refresh while one raw read remains live',
        );
        final gate = _gate('${directory.path}/gates');
        expect(
          (await _readGuarded(gate) as ProviderReadDeferral).reason,
          ProviderReadDeferralReason.busy,
        );

        final closing = worker.close();
        expect(await _hasCompleted(closing), isFalse);
        var fullProcessExits = 0;
        await waitForDesktopCollectionBeforeExit(
          closing,
          grace: const Duration(milliseconds: 1),
          exitProcess: () => fullProcessExits++,
        );
        expect(
          fullProcessExits,
          1,
          reason: 'only the whole-process Quit callback may bound a drain',
        );
        expect(
          await _hasCompleted(closing),
          isFalse,
          reason: 'a timeout is not cancellation or worker termination',
        );
        expect(
          (await _readGuarded(gate) as ProviderReadDeferral).reason,
          ProviderReadDeferralReason.busy,
        );
        release.send(null);
        release = null;
        await closing.timeout(const Duration(seconds: 5));
        expect(
          await _readGuarded(gate),
          'available',
          reason: 'worker shutdown released the actual native guard',
        );
      } finally {
        release?.send(null);
        await worker.close().timeout(const Duration(seconds: 5));
        await messages.cancel();
        events.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('ordinary completed shutdown needs no forced process exit', () async {
    var exits = 0;
    await waitForDesktopCollectionBeforeExit(
      Future.value(),
      exitProcess: () => exits++,
    );
    await waitForDesktopCollectionBeforeExit(null, exitProcess: () => exits++);
    expect(exits, 0);
  });

  test(
    'ordinary close releases reused shared HTTP keep-alive sockets',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.idleTimeout = const Duration(minutes: 1);
      final peerPorts = <int>[];
      server.listen((request) async {
        peerPorts.add(request.connectionInfo!.remotePort);
        request.response.write('synthetic quota metadata');
        await request.response.close();
      });
      final worker = DesktopCollectionWorker(
        reader: _httpReader,
        readerData: 'http://127.0.0.1:${server.port}/usage',
      );
      try {
        await worker.collect();
        await worker.collect();
        expect(peerPorts, hasLength(2));
        expect(
          peerPorts.toSet(),
          hasLength(1),
          reason: 'the same pooled connection was actually reused',
        );
        await worker.close().timeout(const Duration(seconds: 2));
      } finally {
        await server.close(force: true);
        await worker.close().timeout(const Duration(seconds: 5));
      }
    },
  );

  for (final status in [200, 503]) {
    test(
      'ungated adapter drain preserves native ownership through HTTP $status',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'desktop_ungated_',
        );
        final lock = File('${directory.path}/ungated.lock')..createSync();
        final received = Completer<HttpRequest>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.idleTimeout = const Duration(minutes: 1);
        server.listen(received.complete);
        final worker = DesktopCollectionWorker(
          reader: _ungatedDeadlineReader,
          readerData: (directory.path, 'http://127.0.0.1:${server.port}/usage'),
        );
        Future<InterprocessFileGuard> acquire() => acquireInterprocessFileGuard(
          lock,
          hardenClaim: _noFileHardening,
          acquisitionTimeout: const Duration(milliseconds: 10),
        );
        try {
          final reading = worker.collect();
          final request = await received.future.timeout(
            const Duration(seconds: 5),
          );
          expect(request.method, 'GET');
          expect(request.uri.path, '/usage');
          final result = await reading.timeout(const Duration(seconds: 5));
          expect(result.single.ok, isFalse);
          expect(result.single.error, contains('timed out after 30s'));
          await expectLater(acquire(), throwsA(isA<FileSystemException>()));

          final closing = worker.close();
          expect(await _hasCompleted(closing), isFalse);
          await expectLater(
            acquire(),
            throwsA(isA<FileSystemException>()),
            reason: 'ordinary close must not cancel an ungated metadata read',
          );

          request.response.statusCode = status;
          request.response.write('synthetic quota metadata');
          await request.response.close();
          await closing.timeout(const Duration(seconds: 2));
          final after = await acquire();
          after.release();
        } finally {
          await server.close(force: true);
          await worker.close().timeout(const Duration(seconds: 5));
          directory.deleteSync(recursive: true);
        }
      },
    );
  }

  test(
    'failed shutdown also hands control to the whole-process exit callback',
    () async {
      var exits = 0;
      await waitForDesktopCollectionBeforeExit(
        Future<void>.error(StateError('synthetic unavailable worker')),
        exitProcess: () => exits++,
      );
      expect(exits, 1);
    },
  );
}
