import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_refresh_recovery.dart';

void main() {
  test('an extreme retry deadline cannot wrap into foreground recovery', () {
    var now = DateTime.utc(2026, 9, 5, 12);
    final recovery = DesktopRefreshRecovery(clock: () => now);
    recovery.recordCompletedAttempt();
    recovery.recordScheduleSeconds(0x7fffffffffffffff);
    now = now.add(const Duration(days: 365));
    expect(recovery.shouldRefreshOnReturn(backingOff: true), isFalse);
    recovery.recordScheduleSeconds(60);
    now = now.add(const Duration(seconds: 60));
    expect(recovery.shouldRefreshOnReturn(backingOff: true), isTrue);
  });

  test('only completed quota attempts establish the return age', () {
    var now = DateTime.utc(2026, 9, 5, 12);
    final recovery = DesktopRefreshRecovery(clock: () => now);
    recovery.recordSchedule(const Duration(hours: 1));
    now = now.add(const Duration(hours: 2));
    expect(recovery.shouldRefreshOnReturn(backingOff: false), isFalse);

    recovery.recordCompletedAttempt();
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(recovery.shouldRefreshOnReturn(backingOff: false), isFalse);
    now = now.add(const Duration(seconds: 1));
    recovery.recordSchedule(const Duration(hours: 1));
    expect(recovery.shouldRefreshOnReturn(backingOff: false), isTrue);
    expect(recovery.shouldRefreshOnReturn(backingOff: true), isFalse);

    // A cadence change replaces the scheduled due time without pretending
    // that quota was read again.
    recovery.recordSchedule(const Duration(minutes: 15));
    now = now.add(const Duration(minutes: 15));
    expect(recovery.shouldRefreshOnReturn(backingOff: true), isTrue);
    recovery.recordCompletedAttempt();
    expect(recovery.shouldRefreshOnReturn(backingOff: false), isFalse);
  });

  test(
    'pause detection advances its baseline after backward clock changes',
    () {
      final start = DateTime.utc(2026, 9, 5, 12);
      var now = start;
      final recovery = DesktopRefreshRecovery(clock: () => now);
      recovery.recordCompletedAttempt();
      now = start.add(const Duration(minutes: 2));
      expect(recovery.observeDisplayTick(), isFalse);
      now = now.add(const Duration(minutes: 2, seconds: 1));
      expect(recovery.observeDisplayTick(), isTrue);
      expect(recovery.observeDisplayTick(), isFalse);

      now = start.subtract(const Duration(hours: 1));
      expect(recovery.observeDisplayTick(), isFalse);
      expect(recovery.shouldRefreshOnReturn(backingOff: false), isFalse);
      now = now.add(const Duration(seconds: 30));
      expect(recovery.observeDisplayTick(), isFalse);
      now = start.add(const Duration(minutes: 5));
      expect(recovery.observeDisplayTick(), isTrue);
      expect(recovery.shouldRefreshOnReturn(backingOff: false), isTrue);
    },
  );
}
