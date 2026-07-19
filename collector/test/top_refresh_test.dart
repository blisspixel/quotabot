import 'dart:async';

import 'package:quotabot_collector/top_refresh.dart';
import 'package:test/test.dart';

class _FakeTimer implements Timer {
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  _FakeTimer(this.callback);

  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

class _TimerHarness {
  final timers = <_FakeTimer>[];

  Timer create(Duration delay, void Function() callback) {
    final timer = _FakeTimer(callback);
    timers.add(timer);
    return timer;
  }

  Iterable<_FakeTimer> get active => timers.where((timer) => timer.isActive);
}

void main() {
  test('repeated refresh requests coalesce into one queued follow-up',
      () async {
    final pending = <Completer<int>>[];
    final applied = <int>[];
    final timers = _TimerHarness();
    final coordinator = TopRefreshCoordinator<int>(
      collect: () {
        final next = Completer<int>();
        pending.add(next);
        return next.future;
      },
      apply: applied.add,
      nextDelay: () => const Duration(seconds: 10),
      timerFactory: timers.create,
    );

    final first = coordinator.refreshNow();
    final second = coordinator.refreshNow();
    final third = coordinator.refreshNow();
    expect(pending, hasLength(1));
    expect(identical(first, second), isTrue);
    expect(identical(second, third), isTrue);

    pending.first.complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(2));
    pending.last.complete(2);
    await first;

    expect(applied, [1, 2]);
    expect(timers.active, hasLength(1));
  });

  test('disposing rejects a late result and never schedules another timer',
      () async {
    final pending = Completer<int>();
    final applied = <int>[];
    final timers = _TimerHarness();
    var collections = 0;
    final coordinator = TopRefreshCoordinator<int>(
      collect: () {
        collections++;
        return pending.future;
      },
      apply: applied.add,
      nextDelay: () => const Duration(seconds: 10),
      timerFactory: timers.create,
    );

    final refresh = coordinator.refreshNow();
    coordinator.dispose();
    pending.complete(1);
    await refresh;
    await coordinator.refreshNow();

    expect(applied, isEmpty);
    expect(collections, 1);
    expect(timers.active, isEmpty);
    expect(coordinator.isDisposed, isTrue);
  });

  test('a scheduled refresh owns one timer and replaces it after firing',
      () async {
    var value = 0;
    final timers = _TimerHarness();
    final coordinator = TopRefreshCoordinator<int>(
      collect: () async => ++value,
      apply: (_) {},
      nextDelay: () => const Duration(seconds: 10),
      timerFactory: timers.create,
    );

    await coordinator.refreshNow();
    expect(timers.active, hasLength(1));
    timers.active.single.fire();
    await Future<void>.delayed(Duration.zero);

    expect(value, 2);
    expect(timers.active, hasLength(1));
    coordinator.dispose();
    expect(timers.active, isEmpty);
  });
}
