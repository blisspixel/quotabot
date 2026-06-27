import 'package:quotabot_collector/insights.dart';
import 'package:test/test.dart';

void main() {
  const now = 1000000;

  group('computePace', () {
    test('returns null without a burn estimate', () {
      expect(
        computePace(headroom: 50, resetsAt: null, burnPerHour: null, now: now),
        isNull,
      );
    });

    test('reads as steady when barely drawing down', () {
      final p = computePace(
        headroom: 50,
        resetsAt: null,
        burnPerHour: 0.1,
        now: now,
      );
      expect(p!.burnPerHour, 0);
      expect(p.runwayHours, isNull);
      expect(p.verdict, contains('steady'));
    });

    test('reports runway when there is no reset', () {
      final p = computePace(
        headroom: 50,
        resetsAt: null,
        burnPerHour: 10,
        now: now,
      );
      expect(p!.runwayHours, closeTo(5, 0.001));
      expect(p.verdict, contains('runway'));
      final json = p.toJson();
      expect(json['burn_percent_per_hour'], 10);
      expect(json['runway_hours'], isNotNull);
    });

    test('warns when on pace to run dry before reset', () {
      final p = computePace(
        headroom: 10,
        resetsAt: now + 3600, // 1h away
        burnPerHour: 20, // runway 0.5h < 1h
        now: now,
      );
      expect(p!.projectedUsedAtReset, 100);
      expect(p.hoursEarlyExhaust, isNotNull);
      expect(p.verdict, contains('run dry'));
    });

    test('flags quota that would expire unused', () {
      final p = computePace(
        headroom: 90,
        resetsAt: now + 36000, // 10h away
        burnPerHour: 2, // uses ~20% over 10h
        now: now,
      );
      expect(p!.wastedAtReset, isNotNull);
      expect(p.wastedAtReset, greaterThan(0));
      expect(p.verdict, contains('expire unused'));
    });
  });
}
