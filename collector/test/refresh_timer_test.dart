import 'dart:async';

import 'package:quotabot_collector/refresh_timer.dart';
import 'package:test/test.dart';

void main() {
  test('a short delay fires once at its deadline with one-shot Timer state',
      () {
    final clock = _Clock();
    var calls = 0;
    late final Timer timer;
    timer = RefreshTimer.seconds(45, () {
      calls++;
      expect(timer.isActive, isFalse);
      expect(timer.tick, 1);
    }, timerFactory: clock.create);

    expect(timer.isActive, isTrue);
    expect(timer.tick, 0);
    clock.elapse(const Duration(seconds: 44));
    expect(calls, 0);
    expect(timer.tick, 0);
    clock.elapse(const Duration(seconds: 1));
    expect(calls, 1);
    expect(clock.active, isEmpty);
    clock.elapse(const Duration(days: 10));
    timer.cancel();
    expect(calls, 1);
    expect(timer.tick, 1);
  });

  test('day boundaries never dispatch a refresh before the entire delay', () {
    final clock = _Clock();
    var calls = 0;
    final timer = RefreshTimer.seconds(2 * 86400 + 7, () => calls++,
        timerFactory: clock.create);

    for (var day = 0; day < 2; day++) {
      expect(clock.active.single.delay, const Duration(days: 1));
      clock.elapse(const Duration(days: 1));
      expect(calls, 0);
      expect(timer.isActive, isTrue);
      expect(timer.tick, 0);
      expect(clock.active, hasLength(1));
    }
    expect(clock.active.single.delay, const Duration(seconds: 7));
    clock.elapse(const Duration(seconds: 6));
    expect(calls, 0);
    clock.elapse(const Duration(seconds: 1));
    expect(calls, 1);
    expect(timer.isActive, isFalse);
    expect(timer.tick, 1);
    expect(clock.created.map((timer) => timer.delay), [
      const Duration(days: 1),
      const Duration(days: 1),
      const Duration(seconds: 7),
    ]);
  });

  test('maximum integer delay stays positive and cannot become an early timer',
      () {
    final clock = _Clock();
    var calls = 0;
    final timer = RefreshTimer.seconds(0x7fffffffffffffff, () => calls++,
        timerFactory: clock.create);

    clock.elapse(const Duration(days: 3));
    expect(calls, 0);
    expect(timer.tick, 0);
    expect(timer.isActive, isTrue);
    expect(clock.active, hasLength(1));
    expect(clock.created, hasLength(4));
    expect(
        clock.created.every((timer) => timer.delay == const Duration(days: 1)),
        isTrue);
    timer.cancel();
    expect(timer.isActive, isFalse);
    expect(clock.active, isEmpty);
  });

  test('cancellation before or between chunks removes the whole pending delay',
      () {
    for (final afterFirstChunk in [false, true]) {
      final clock = _Clock();
      var calls = 0;
      final timer = RefreshTimer.seconds(2 * 86400, () => calls++,
          timerFactory: clock.create);
      if (afterFirstChunk) {
        clock.elapse(const Duration(days: 1));
      }
      final createdBeforeCancel = clock.created.length;
      timer.cancel();
      timer.cancel();
      expect(timer.isActive, isFalse);
      expect(timer.tick, 0);
      expect(clock.active, isEmpty);
      clock.elapse(const Duration(days: 3));
      expect(clock.created, hasLength(createdBeforeCancel));
      expect(calls, 0);
    }
  });

  test('zero and negative delays remain asynchronous', () {
    for (final delay in [0, -1, -0x7fffffffffffffff]) {
      final clock = _Clock();
      var calls = 0;
      final timer = RefreshTimer.seconds(delay, () => calls++,
          timerFactory: clock.create);
      expect(calls, 0);
      expect(timer.isActive, isTrue);
      expect(clock.active.single.delay, Duration.zero);
      clock.elapse(Duration.zero);
      expect(calls, 1);
      expect(timer.isActive, isFalse);
      expect(timer.tick, 1);
    }
  });

  test('a callback failure still completes the one-shot timer', () {
    final clock = _Clock();
    final timer = RefreshTimer.seconds(1, () => throw StateError('fixture'),
        timerFactory: clock.create);
    expect(() => clock.elapse(const Duration(seconds: 1)), throwsStateError);
    expect(timer.isActive, isFalse);
    expect(timer.tick, 1);
    expect(clock.active, isEmpty);
    timer.cancel();
    expect(timer.tick, 1);
  });

  test('the default scheduler preserves asynchronous dispatch and the zone',
      () async {
    final completed = Completer<void>();
    var returned = false;
    late final RefreshTimer timer;
    runZoned(() {
      timer = RefreshTimer.seconds(0, () {
        expect(returned, isTrue);
        expect(Zone.current[#refreshFixture], 'isolated');
        expect(timer.isActive, isFalse);
        expect(timer.tick, 1);
        completed.complete();
      });
    }, zoneValues: {#refreshFixture: 'isolated'});
    returned = true;
    await completed.future;
  });
}

/// Deterministic timer scheduling, with an independent clock and no real wait.
class _Clock {
  int _elapsedMicros = 0;
  final created = <_PendingTimer>[];

  Iterable<_PendingTimer> get active =>
      created.where((timer) => timer.isActive);

  Timer create(Duration delay, void Function() callback) {
    expect(delay.isNegative, isFalse);
    final timer =
        _PendingTimer(delay, _elapsedMicros + delay.inMicroseconds, callback);
    created.add(timer);
    return timer;
  }

  void elapse(Duration duration) {
    final end = _elapsedMicros + duration.inMicroseconds;
    while (true) {
      final due = active.where((timer) => timer.dueMicros <= end).toList()
        ..sort((a, b) => a.dueMicros.compareTo(b.dueMicros));
      if (due.isEmpty) break;
      final next = due.first;
      _elapsedMicros = next.dueMicros;
      next.fire();
    }
    _elapsedMicros = end;
  }
}

class _PendingTimer implements Timer {
  _PendingTimer(this.delay, this.dueMicros, this.callback);

  final Duration delay;
  final int dueMicros;
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
