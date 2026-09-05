import 'dart:async';

typedef RefreshTimerFactory = Timer Function(
  Duration delay,
  void Function() callback,
);

/// A cancellable one-shot refresh delay that cannot overflow [Duration].
///
/// Provider Retry-After values may exceed the duration's microsecond range.
/// Keep the full seconds count and wait in chunks of at most one day. A chunk
/// boundary only arms the next timer; it never invokes the refresh callback.
class RefreshTimer implements Timer {
  RefreshTimer.seconds(
    int seconds,
    this._callback, {
    RefreshTimerFactory? timerFactory,
  })  : _remainingSeconds = seconds < 0 ? 0 : seconds,
        _timerFactory = timerFactory ?? Timer.new {
    _arm();
  }

  final void Function() _callback;
  final RefreshTimerFactory _timerFactory;
  int _remainingSeconds;
  Timer? _timer;
  bool _active = true;
  int _tick = 0;

  void _arm() {
    final chunk = _remainingSeconds > Duration.secondsPerDay
        ? Duration.secondsPerDay
        : _remainingSeconds;
    _timer = _timerFactory(Duration(seconds: chunk), () {
      if (!_active) return;
      _timer = null;
      _remainingSeconds -= chunk;
      if (_remainingSeconds > 0) {
        _arm();
        return;
      }
      _active = false;
      _tick = 1;
      _callback();
    });
  }

  @override
  void cancel() {
    _active = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}
