import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:quotabot_collector/leases.dart';
import 'package:test/test.dart';

LeaseIdFactory _idFactory() {
  var i = 0;
  return () => 'lease-${++i}';
}

const _workerReady = 'quotabot-lease-worker-ready';
const _workerResult = 'quotabot-lease-worker-result:';

class _LeaseSelectionWorker {
  final Process process;
  final StreamIterator<String> output;
  final Future<String> stderrText;

  _LeaseSelectionWorker(this.process, this.output, this.stderrText);

  static Future<_LeaseSelectionWorker> start(
    String script,
    String directory,
    String leaseId,
  ) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=.dart_tool/package_config.json',
        script,
        directory,
        leaseId,
      ],
      workingDirectory: Directory.current.path,
    );
    return _LeaseSelectionWorker(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      process.stderr.transform(utf8.decoder).join(),
    );
  }

  Future<void> waitUntilReady() async {
    while (await output.moveNext()) {
      if (output.current == _workerReady) return;
    }
    final exit = await process.exitCode;
    final stderr = await stderrText;
    throw StateError('lease worker exited before ready: $exit $stderr');
  }

  Future<Map<String, dynamic>> releaseAndRead() async {
    process.stdin.writeln('start');
    await process.stdin.flush();
    await process.stdin.close();
    Map<String, dynamic>? result;
    while (await output.moveNext()) {
      final line = output.current;
      if (!line.startsWith(_workerResult)) continue;
      final decoded = jsonDecode(line.substring(_workerResult.length));
      if (decoded is Map<Object?, Object?>) {
        result = decoded.cast<String, dynamic>();
      }
    }
    final exit = await process.exitCode;
    final stderr = await stderrText;
    if (exit != 0 || result == null) {
      throw StateError('lease worker failed: $exit $stderr');
    }
    return result;
  }

  Future<void> stop() async {
    try {
      await process.stdin.close();
    } catch (_) {}
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        // The test is already unwinding. Leave directory cleanup to report a
        // still-active worker rather than blocking the suite indefinitely.
      }
    }
    try {
      await output.cancel();
    } catch (_) {}
    try {
      await stderrText.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // The process pipes should close with the process. Do not let diagnostics
      // prevent bounded cleanup on an abnormal platform failure.
    }
  }
}

Future<void> _reserveLeaseInIsolate(List<Object?> arguments) async {
  final id = arguments[0] as String;
  final directory = Directory(arguments[1] as String);
  final releasePath = arguments[2] as String?;
  final events = arguments[3] as SendPort;
  final commands = ReceivePort();
  events.send(<Object>[id, 'ready', commands.sendPort]);
  await commands.first;
  try {
    final store = FileRouteLeaseStore(
      dirFactory: () => directory,
      idFactory: () => 'lease-$id',
    );
    final reservation = store.selectAndReserve(
      select: (active) {
        events.send(<Object>[id, 'select', active.length]);
        if (releasePath != null) {
          final release = File(releasePath);
          while (!release.existsSync()) {
            sleep(const Duration(milliseconds: 2));
          }
        }
        final provider = active.any((lease) => lease.provider == 'claude')
            ? 'codex'
            : 'claude';
        return RouteLeaseSelection.selected(
          RouteLeaseTarget(provider: provider, account: 'a'),
        );
      },
      now: 100,
      leaseSeconds: 60,
      weightPercent: 30,
    );
    events.send(<Object>[
      id,
      'result',
      reservation.reserved,
      reservation.lease?.provider ?? '',
    ]);
  } catch (error) {
    events.send(<Object>[id, 'error', error.toString()]);
  } finally {
    commands.close();
  }
}

void main() {
  test('lease normalization bounds ttl and weight', () {
    expect(normalizeLeaseSeconds(1), minLeaseSeconds);
    expect(normalizeLeaseSeconds(999999), maxLeaseSeconds);
    expect(normalizeLeaseSeconds(null), defaultLeaseSeconds);
    expect(normalizeLeaseWeight(0), minLeaseWeightPercent);
    expect(normalizeLeaseWeight(99), maxLeaseWeightPercent);
    expect(normalizeLeaseWeight(null), defaultLeaseWeightPercent);
    expect(normalizeLeaseProvider(' Claude! '), 'claude_');
    expect(normalizeLeaseAccount(''), 'default');
    expect(
      normalizeLeaseAccount(' nick+work@example.com '),
      'nick+work@example.com',
    );
    expect(normalizeLeaseText(123), isNull);
    expect(normalizeLeaseText('  '), isNull);
    expect(normalizeLeaseText('abcdef', maxLength: 3), 'abc');
  });

  test('noop store is a safe unavailable implementation', () {
    const store = NoopRouteLeaseStore();
    expect(store.active(100), isEmpty);
    // A disabled store has definitively no leases, so its read is complete and
    // trusted even though its mutations are unavailable.
    final state = store.activeState(100);
    expect(state.available, isTrue);
    expect(state.reason, isNull);
    expect(state.activeLeases, isEmpty);
    final reservation = store.reserve(
      provider: 'claude',
      account: 'work',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 10,
    );
    expect(reservation.reserved, isFalse);
    expect(reservation.reason, 'lease store unavailable');
    final release = store.release(leaseId: 'missing', now: 100);
    expect(release.released, isFalse);
    expect(release.reason, 'lease store unavailable');
  });

  test('memory store reuses idempotent reservations and releases them', () {
    final store = InMemoryRouteLeaseStore(idFactory: _idFactory());
    final first = store.reserve(
      provider: 'claude',
      account: 'work',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-1',
    );
    expect(first.reserved, isTrue);
    expect(first.reused, isFalse);
    expect(first.lease!.id, 'lease-1');

    final retry = store.reserve(
      provider: 'claude',
      account: 'work',
      now: 101,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-1',
    );
    expect(retry.reserved, isTrue);
    expect(retry.reused, isTrue);
    expect(retry.lease!.id, 'lease-1');
    expect(retry.activeLeases, hasLength(1));

    final release = store.release(leaseId: 'lease-1', now: 102);
    expect(release.released, isTrue);
    expect(release.activeLeases, isEmpty);
    expect(store.release(leaseId: 'lease-1', now: 103).released, isFalse);
  });

  test('memory store rejects an idempotency key for a different target', () {
    final store = InMemoryRouteLeaseStore(idFactory: _idFactory());
    final first = store.reserve(
      provider: 'claude',
      account: 'work',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-1',
    );

    final conflict = store.reserve(
      provider: 'codex',
      account: 'home',
      now: 101,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-1',
    );

    expect(first.reserved, isTrue);
    expect(conflict.reserved, isFalse);
    expect(conflict.reused, isFalse);
    expect(conflict.lease, isNull);
    expect(conflict.reason, contains('different lease target'));
    expect(conflict.activeLeases, hasLength(1));
  });

  test('auto reservation rejects an idempotency key outside reuse scope', () {
    final store = InMemoryRouteLeaseStore(idFactory: _idFactory());
    store.reserve(
      provider: 'claude',
      account: 'work',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-1',
    );
    var selections = 0;

    final conflict = store.selectAndReserve(
      select: (active) {
        selections += 1;
        return const RouteLeaseSelection.selected(
          RouteLeaseTarget(provider: 'codex', account: 'home'),
        );
      },
      now: 101,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-1',
      reuseWhere: (lease) => lease.provider == 'codex',
    );

    expect(conflict.reserved, isFalse);
    expect(conflict.reused, isFalse);
    expect(conflict.lease, isNull);
    expect(conflict.reason, contains('outside this request'));
    expect(conflict.activeLeases, hasLength(1));
    expect(selections, 0);
  });

  test('memory store retains other leases during release', () {
    final store = InMemoryRouteLeaseStore(idFactory: _idFactory());
    store.reserve(
      provider: 'claude',
      account: 'work',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 10,
    );
    store.reserve(
      provider: 'codex',
      account: 'home',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 20,
    );

    final release = store.release(leaseId: 'lease-1', now: 101);
    expect(release.released, isTrue);
    expect(release.activeLeases.single.id, 'lease-2');
  });

  test('memory store selects against leases from the same transaction', () {
    final store = InMemoryRouteLeaseStore(idFactory: _idFactory());
    RouteLeaseReservation reserveBest() => store.selectAndReserve(
          select: (active) {
            final provider = active.any((lease) => lease.provider == 'claude')
                ? 'codex'
                : 'claude';
            return RouteLeaseSelection.selected(
              RouteLeaseTarget(provider: provider, account: 'a'),
            );
          },
          now: 100,
          leaseSeconds: 60,
          weightPercent: 30,
        );

    expect(reserveBest().lease!.provider, 'claude');
    expect(reserveBest().lease!.provider, 'codex');
    expect(store.active(100), hasLength(2));
    final state = store.activeState(100);
    expect(state.available, isTrue);
    expect(state.reason, isNull);
    expect(state.activeLeases, hasLength(2));
  });

  test('memory store rejects reservations after the active lease cap', () {
    final store = InMemoryRouteLeaseStore(idFactory: _idFactory());
    for (var i = 0; i < maxActiveLeases; i++) {
      final reservation = store.reserve(
        provider: 'claude',
        account: 'account-$i',
        now: 100,
        leaseSeconds: 60,
        weightPercent: 1,
      );
      expect(reservation.reserved, isTrue);
    }

    final rejected = store.reserve(
      provider: 'claude',
      account: 'overflow',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 1,
    );
    expect(rejected.reserved, isFalse);
    expect(rejected.reason, 'too many active leases');
    expect(rejected.activeLeases, hasLength(maxActiveLeases));
  });

  test('expired leases are pruned before discounting', () {
    final store = InMemoryRouteLeaseStore(idFactory: _idFactory());
    store.reserve(
      provider: 'codex',
      account: 'default',
      now: 100,
      leaseSeconds: 15,
      weightPercent: 10,
    );
    expect(store.active(114), hasLength(1));
    expect(store.active(116), isEmpty);
  });

  test('discounts group by provider account and cap at 100', () {
    final leases = [
      RouteLease(
        id: 'c',
        provider: 'codex',
        account: 'home',
        createdAt: 100,
        expiresAt: 200,
        weightPercent: 5,
      ),
      RouteLease(
        id: 'a',
        provider: 'claude',
        account: 'work',
        createdAt: 100,
        expiresAt: 200,
        weightPercent: 60,
      ),
      RouteLease(
        id: 'b',
        provider: 'claude',
        account: 'work',
        createdAt: 100,
        expiresAt: 190,
        weightPercent: 60,
      ),
    ];
    final discounts = leaseDiscounts(leases);
    expect(discounts.map((discount) => discount.provider), ['claude', 'codex']);
    expect(discounts.first.discountPercent, 100);
    expect(discounts.first.leases, 2);
    expect(discounts.first.expiresAt, 190);
    expect(leaseDiscountFor(leases, 'claude', 'work'), 100);
    expect(leaseDiscountFor(leases, 'codex', 'home'), 5);
    expect(leaseDiscountFor(leases, 'codex', 'work'), 0);
  });

  test('colliding legacy account stems keep independent lease discounts', () {
    const plus = 'nick+work@example.com';
    const underscore = 'nick_work@example.com';
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = FileRouteLeaseStore(
      dirFactory: () => dir,
      idFactory: _idFactory(),
    );
    store.reserve(
      provider: 'grok',
      account: plus,
      now: 100,
      leaseSeconds: 60,
      weightPercent: 11,
    );
    store.reserve(
      provider: 'grok',
      account: underscore,
      now: 100,
      leaseSeconds: 60,
      weightPercent: 29,
    );

    final active = FileRouteLeaseStore(dirFactory: () => dir).active(100);
    expect(active.map((lease) => lease.account).toSet(), {plus, underscore});
    expect(leaseDiscountFor(active, 'grok', plus), 11);
    expect(leaseDiscountFor(active, 'grok', underscore), 29);
    final discounts = leaseDiscounts(active);
    expect(discounts, hasLength(2));
    expect(discounts.map((discount) => discount.account).toSet(), {
      plus,
      underscore,
    });
  });

  test('file store fails soft when the lease directory is unavailable', () {
    // Leases are advisory; a lock/IO failure must degrade like the noop store
    // rather than break the read-only routing tools that consult active().
    final store = FileRouteLeaseStore(
      dirFactory: () => throw const FileSystemException('no lease dir'),
      idFactory: _idFactory(),
    );
    expect(store.activeState(100).available, isFalse);
    expect(store.active(100), isEmpty);
    final reservation = store.reserve(
      provider: 'grok',
      account: 'home',
      now: 100,
      leaseSeconds: 30,
      weightPercent: 15,
    );
    expect(reservation.reserved, isFalse);
    expect(reservation.reason, 'lease store unavailable');
    final release = store.release(leaseId: 'x', now: 100);
    expect(release.released, isFalse);
    expect(release.reason, 'lease store unavailable');
  });

  test('file store persists, reuses, releases, and prunes leases', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = FileRouteLeaseStore(
      dirFactory: () => dir,
      idFactory: _idFactory(),
    );
    final reservation = store.reserve(
      provider: 'grok',
      account: 'home',
      now: 100,
      leaseSeconds: 30,
      weightPercent: 15,
      client: 'test',
      idempotencyKey: 'retry-file',
    );
    expect(reservation.reserved, isTrue);
    expect(File('${dir.path}/route_leases.json').existsSync(), isTrue);

    final secondStore = FileRouteLeaseStore(dirFactory: () => dir);
    final retry = secondStore.reserve(
      provider: 'grok',
      account: 'home',
      now: 105,
      leaseSeconds: 30,
      weightPercent: 15,
      idempotencyKey: 'retry-file',
    );
    expect(retry.reused, isTrue);
    expect(retry.lease!.id, reservation.lease!.id);
    expect(secondStore.active(120), hasLength(1));

    final release =
        secondStore.release(leaseId: reservation.lease!.id, now: 120);
    expect(release.released, isTrue);
    expect(release.activeLeases, isEmpty);
    expect(
        secondStore.release(leaseId: reservation.lease!.id, now: 121).released,
        isFalse);

    secondStore.reserve(
      provider: 'grok',
      account: 'home',
      now: 122,
      leaseSeconds: 15,
      weightPercent: 15,
    );
    expect(secondStore.active(138), isEmpty);
  });

  test('file store rejects an idempotency key for a different target', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = FileRouteLeaseStore(
      dirFactory: () => dir,
      idFactory: _idFactory(),
    );
    final first = store.reserve(
      provider: 'claude',
      account: 'work',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-file',
    );

    final conflict = FileRouteLeaseStore(dirFactory: () => dir).reserve(
      provider: 'codex',
      account: 'home',
      now: 101,
      leaseSeconds: 60,
      weightPercent: 12,
      idempotencyKey: 'retry-file',
    );

    expect(first.reserved, isTrue);
    expect(conflict.reserved, isFalse);
    expect(conflict.reused, isFalse);
    expect(conflict.lease, isNull);
    expect(conflict.reason, contains('different lease target'));
    expect(conflict.activeLeases, hasLength(1));
  });

  test('file store selects against leases persisted in its transaction', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = FileRouteLeaseStore(
      dirFactory: () => dir,
      idFactory: _idFactory(),
    );
    RouteLeaseReservation reserveBest() => store.selectAndReserve(
          select: (active) {
            final provider = active.any((lease) => lease.provider == 'claude')
                ? 'codex'
                : 'claude';
            return RouteLeaseSelection.selected(
              RouteLeaseTarget(provider: provider, account: 'a'),
            );
          },
          now: 100,
          leaseSeconds: 60,
          weightPercent: 30,
        );

    expect(reserveBest().lease!.provider, 'claude');
    expect(reserveBest().lease!.provider, 'codex');
    expect(store.active(100), hasLength(2));
  });

  test('file store atomically selects concurrent reservation targets',
      () async {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    final workerScript = File(
      '${Directory.current.path}${Platform.pathSeparator}test'
      '${Platform.pathSeparator}support${Platform.pathSeparator}'
      'lease_selection_worker.dart',
    ).absolute.path;
    expect(File(workerScript).existsSync(), isTrue);
    final workers = <_LeaseSelectionWorker>[];
    try {
      workers.add(
        await _LeaseSelectionWorker.start(workerScript, dir.path, 'lease-a'),
      );
      workers.add(
        await _LeaseSelectionWorker.start(workerScript, dir.path, 'lease-b'),
      );
      await Future.wait(
        workers.map((worker) => worker.waitUntilReady()),
      ).timeout(const Duration(seconds: 15));
      final results = await Future.wait(
        workers.map((worker) => worker.releaseAndRead()),
      ).timeout(const Duration(seconds: 15));
      final diagnostics = jsonEncode(results);

      expect(
        results.map((result) => result['reserved']),
        everyElement(isTrue),
        reason: diagnostics,
      );
      expect(
        results.map((result) => result['provider']),
        unorderedEquals(['claude', 'codex']),
        reason: diagnostics,
      );
      final persisted = FileRouteLeaseStore(dirFactory: () => dir).active(100);
      expect(
        persisted.map((lease) => lease.provider),
        unorderedEquals(['claude', 'codex']),
        reason: diagnostics,
      );
    } finally {
      await Future.wait(workers.map((worker) => worker.stop()));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('file store atomically selects targets across POSIX isolates', () async {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-isolate-');
    final releaseA = File('${dir.path}/release-a');
    final events = ReceivePort();
    final ready = <String, Completer<SendPort>>{
      'a': Completer<SendPort>(),
      'b': Completer<SendPort>(),
    };
    final enteredSelection = <String>{};
    final selectionA = Completer<void>();
    final results = <String, Completer<String>>{
      'a': Completer<String>(),
      'b': Completer<String>(),
    };
    final subscription = events.listen((message) {
      final event = (message as List<Object>).cast<Object>();
      final id = event[0] as String;
      final kind = event[1] as String;
      if (kind == 'ready') ready[id]!.complete(event[2] as SendPort);
      if (kind == 'select') {
        enteredSelection.add(id);
        if (id == 'a' && !selectionA.isCompleted) selectionA.complete();
      }
      if (kind == 'result') {
        if (event[2] != true) {
          results[id]!.completeError(StateError('reservation failed'));
        } else {
          results[id]!.complete(event[3] as String);
        }
      }
      if (kind == 'error') {
        results[id]!.completeError(StateError(event[2] as String));
      }
    });
    Isolate? first;
    Isolate? second;
    try {
      first = await Isolate.spawn<List<Object?>>(
        _reserveLeaseInIsolate,
        <Object?>['a', dir.path, releaseA.path, events.sendPort],
      );
      second = await Isolate.spawn<List<Object?>>(
        _reserveLeaseInIsolate,
        <Object?>['b', dir.path, null, events.sendPort],
      );
      final firstCommands =
          await ready['a']!.future.timeout(const Duration(seconds: 3));
      final secondCommands =
          await ready['b']!.future.timeout(const Duration(seconds: 3));

      firstCommands.send('start');
      await selectionA.future.timeout(const Duration(seconds: 3));
      secondCommands.send('start');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(enteredSelection, {'a'});

      releaseA.writeAsStringSync('continue\n', flush: true);
      final providers = await Future.wait([
        results['a']!.future,
        results['b']!.future,
      ]).timeout(const Duration(seconds: 5));
      expect(providers, unorderedEquals(['claude', 'codex']));
      expect(enteredSelection, {'a', 'b'});
      expect(
        FileRouteLeaseStore(dirFactory: () => dir)
            .active(100)
            .map((lease) => lease.provider),
        unorderedEquals(['claude', 'codex']),
      );
    } finally {
      first?.kill(priority: Isolate.immediate);
      second?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      events.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('file store does not reuse a PID-only temporary path', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-temp-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final legacyTemporary = File('${dir.path}/route_leases.json.$pid.tmp')
      ..writeAsStringSync('sentinel', flush: true);

    final reservation = FileRouteLeaseStore(dirFactory: () => dir).reserve(
      provider: 'claude',
      account: 'a',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 10,
    );

    expect(reservation.reserved, isTrue);
    expect(legacyTemporary.readAsStringSync(), 'sentinel');
    final temporaryNames = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.tmp'))
        .map((file) => file.uri.pathSegments.last);
    expect(temporaryNames, ['route_leases.json.$pid.tmp']);
  });

  test('file store rejects reservations after pruning reaches the active cap',
      () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = FileRouteLeaseStore(
      dirFactory: () => dir,
      idFactory: _idFactory(),
    );
    final seeded = List.generate(
      maxActiveLeases,
      (i) => RouteLease(
        id: 'seed-$i',
        provider: 'claude',
        account: 'account-$i',
        createdAt: 100,
        expiresAt: 160,
        weightPercent: 1,
      ).toJson(),
    );
    File('${dir.path}/route_leases.json').writeAsStringSync(jsonEncode(seeded));

    final rejected = store.reserve(
      provider: 'claude',
      account: 'overflow',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 1,
    );
    expect(rejected.reserved, isFalse);
    expect(rejected.reason, 'too many active leases');
  });

  test('file store reports malformed ledgers and blocks mutation', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final ledger = File('${dir.path}/route_leases.json')
      ..writeAsStringSync('{not json');
    final store = FileRouteLeaseStore(dirFactory: () => dir);
    final state = store.activeState(100);

    expect(state.available, isFalse);
    expect(state.reason, 'lease store unavailable');
    expect(store.active(100), isEmpty);
    final reservation = store.reserve(
      provider: 'claude',
      account: 'work',
      now: 100,
      leaseSeconds: 60,
      weightPercent: 10,
    );
    expect(reservation.reserved, isFalse);
    expect(reservation.reason, 'lease store unavailable');
    expect(ledger.readAsStringSync(), '{not json');
  });

  test('file store reads an atomic ledger without creating lock artifacts', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File('${dir.path}/route_leases.json').writeAsStringSync(
      jsonEncode([
        const RouteLease(
          id: 'seed',
          provider: 'claude',
          account: 'work',
          createdAt: 100,
          expiresAt: 160,
          weightPercent: 10,
        ).toJson(),
      ]),
    );

    final state = FileRouteLeaseStore(dirFactory: () => dir).activeState(100);

    expect(state.available, isTrue);
    expect(state.reason, isNull);
    expect(state.activeLeases.map((lease) => lease.id), ['seed']);
    expect(File('${dir.path}/route_leases.lock').existsSync(), isFalse);
    expect(File('${dir.path}/route_leases.lock.claim').existsSync(), isFalse);
  });

  test('random lease ids are url-safe tokens', () {
    final id = randomLeaseId();
    expect(id, isNotEmpty);
    expect(id, isNot(contains('=')));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), isTrue);
  });
}
