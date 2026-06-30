import 'dart:io';

import 'package:quotabot_collector/leases.dart';
import 'package:test/test.dart';

LeaseIdFactory _idFactory() {
  var i = 0;
  return () => 'lease-${++i}';
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
    for (var i = 0; i < maxActiveLeases; i++) {
      expect(
        store
            .reserve(
              provider: 'claude',
              account: 'account-$i',
              now: 100,
              leaseSeconds: 60,
              weightPercent: 1,
            )
            .reserved,
        isTrue,
      );
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
