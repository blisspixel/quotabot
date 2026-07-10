import 'dart:async';

import 'package:quotabot_collector/expiring_single_flight.dart';
import 'package:test/test.dart';

void main() {
  test('shares one in-progress load across concurrent readers', () async {
    final release = Completer<int>();
    var loads = 0;
    final cache = ExpiringSingleFlight<int>(
      load: () {
        loads++;
        return release.future;
      },
      now: () => 100,
    );

    final reads = List.generate(8, (_) => cache.read());
    expect(loads, 1);
    release.complete(42);

    expect(await Future.wait(reads), everyElement(42));
    expect(loads, 1);
    expect(cache.value, 42);
    expect(cache.cachedAt, 100);
  });

  test('reuses a fresh value and refreshes it after expiry', () async {
    var now = 100;
    var loads = 0;
    final cache = ExpiringSingleFlight<int>(
      load: () async => ++loads,
      now: () => now,
    );

    expect(await cache.read(), 1);
    now = 104;
    expect(await cache.read(), 1);
    now = 105;
    expect(await cache.read(), 2);
  });

  test('does not cache failures and permits a later retry', () async {
    var loads = 0;
    final cache = ExpiringSingleFlight<int>(
      load: () async {
        loads++;
        if (loads == 1) throw StateError('first load failed');
        return 7;
      },
      now: () => 100,
    );

    await expectLater(cache.read(), throwsStateError);
    expect(cache.value, isNull);
    expect(cache.cachedAt, isNull);
    expect(await cache.read(), 7);
    expect(loads, 2);
  });

  test('clears the in-flight slot after a synchronous loader failure',
      () async {
    var loads = 0;
    final cache = ExpiringSingleFlight<int>(
      load: () {
        loads++;
        if (loads == 1) throw StateError('synchronous failure');
        return Future.value(9);
      },
      now: () => 100,
    );

    await expectLater(cache.read(), throwsStateError);
    expect(await cache.read(), 9);
    expect(loads, 2);
  });

  test('rejects a non-positive cache lifetime', () {
    expect(
      () => ExpiringSingleFlight<int>(
        load: () async => 1,
        now: () => 100,
        ttlSeconds: 0,
      ),
      throwsArgumentError,
    );
  });
}
