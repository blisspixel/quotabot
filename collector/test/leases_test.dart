import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  test('file store treats malformed lease files as empty', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File('${dir.path}/route_leases.json').writeAsStringSync('{not json');
    final store = FileRouteLeaseStore(dirFactory: () => dir);
    expect(store.active(100), isEmpty);
  });

  test('random lease ids are url-safe tokens', () {
    final id = randomLeaseId();
    expect(id, isNotEmpty);
    expect(id, isNot(contains('=')));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), isTrue);
  });
}
