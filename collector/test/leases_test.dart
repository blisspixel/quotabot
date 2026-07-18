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

Future<void> _fileSelectionWorker(List<Object?> message) async {
  final directory = message[0]! as String;
  final leaseId = message[1]! as String;
  final replies = message[2]! as SendPort;
  final start = ReceivePort();
  replies.send(start.sendPort);
  await start.first;
  try {
    final store = FileRouteLeaseStore(
      dirFactory: () => Directory(directory),
      idFactory: () => leaseId,
    );
    final reservation = store.selectAndReserve(
      select: (active) {
        // Widen the old read-then-write race. With the selector inside the file
        // lock, only the first worker can observe an empty ledger.
        if (active.isEmpty) sleep(const Duration(milliseconds: 150));
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
    replies.send({
      'reserved': reservation.reserved,
      'provider': reservation.lease?.provider,
      'reason': reservation.reason,
    });
  } catch (error) {
    replies.send({'reserved': false, 'error': error.toString()});
  } finally {
    start.close();
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

  test('file store atomically selects concurrent reservation targets',
      () async {
    final dir = Directory.systemTemp.createTempSync('quotabot-leases-test-');
    final replies = ReceivePort();
    final starts = <SendPort>[];
    final results = <Map<String, dynamic>>[];
    final completed = Completer<void>();
    final subscription = replies.listen((message) {
      if (message is SendPort) {
        starts.add(message);
        if (starts.length == 2) {
          for (final start in starts) {
            start.send(null);
          }
        }
        return;
      }
      if (message is Map<Object?, Object?>) {
        results.add(message.cast<String, dynamic>());
        if (results.length == 2 && !completed.isCompleted) {
          completed.complete();
        }
      }
    });
    final workers = <Isolate>[];
    try {
      workers.add(await Isolate.spawn(
        _fileSelectionWorker,
        <Object?>[dir.path, 'lease-a', replies.sendPort],
      ));
      workers.add(await Isolate.spawn(
        _fileSelectionWorker,
        <Object?>[dir.path, 'lease-b', replies.sendPort],
      ));
      await completed.future.timeout(const Duration(seconds: 10));

      expect(results.map((result) => result['reserved']), everyElement(isTrue));
      expect(
        results.map((result) => result['provider']),
        unorderedEquals(['claude', 'codex']),
      );
      final persisted = FileRouteLeaseStore(dirFactory: () => dir).active(100);
      expect(
        persisted.map((lease) => lease.provider),
        unorderedEquals(['claude', 'codex']),
      );
    } finally {
      for (final worker in workers) {
        worker.kill(priority: Isolate.immediate);
      }
      await subscription.cancel();
      replies.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
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
