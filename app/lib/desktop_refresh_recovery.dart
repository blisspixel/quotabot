/// Decides when returning to an old dashboard warrants an early quota refresh.
/// The dashboard keeps ownership of collection, timers, and backoff policy.
class DesktopRefreshRecovery {
  DesktopRefreshRecovery({
    DateTime Function()? clock,
    bool screenshotCapture = false,
    bool readinessProbe = false,
  }) : _clock = clock ?? DateTime.now,
       enabled = !screenshotCapture && !readinessProbe {
    _lastDisplayTick = _clock();
  }

  static const returnAge = Duration(minutes: 5);
  static const pauseGap = Duration(minutes: 2);

  final DateTime Function() _clock;
  final bool enabled;
  late DateTime _lastDisplayTick;
  DateTime? _lastCompletedAttempt;
  BigInt? _nextScheduledDueMicros;

  void recordCompletedAttempt() {
    _lastCompletedAttempt = _clock();
  }

  /// Records the delay chosen by the existing adaptive or fixed cadence.
  /// Changing cadence does not change the age of the last quota attempt.
  void recordSchedule(Duration delay) {
    _nextScheduledDueMicros =
        BigInt.from(_clock().microsecondsSinceEpoch) +
        BigInt.from(delay.inMicroseconds);
  }

  /// Provider deadlines can exceed DateTime and Duration's native ranges.
  void recordScheduleSeconds(int seconds) {
    _nextScheduledDueMicros =
        BigInt.from(_clock().microsecondsSinceEpoch) +
        BigInt.from(seconds) * BigInt.from(Duration.microsecondsPerSecond);
  }

  bool shouldRefreshOnReturn({required bool backingOff}) {
    if (!enabled || _lastCompletedAttempt == null) return false;
    final now = _clock();
    // A backward clock adjustment is not evidence of an old snapshot.
    if (now.difference(_lastCompletedAttempt!) < returnAge) return false;
    final due = _nextScheduledDueMicros;
    if (backingOff &&
        due != null &&
        BigInt.from(now.microsecondsSinceEpoch) < due) {
      return false;
    }
    return true;
  }

  /// Always advances the baseline, including while hidden or after a backward
  /// clock adjustment. The caller must check visibility before refreshing.
  bool observeDisplayTick() {
    final now = _clock();
    final gap = now.difference(_lastDisplayTick);
    _lastDisplayTick = now;
    return enabled && gap > pauseGap;
  }
}
