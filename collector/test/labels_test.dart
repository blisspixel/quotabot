import 'package:quotabot_collector/labels.dart';
import 'package:test/test.dart';

void main() {
  group('resetCountdownLabel', () {
    test('unknown, reached, and whole-unit labels', () {
      expect(resetCountdownLabel(null, 1000), 'soon');
      expect(resetCountdownLabel(1000, 1000), 'now');
      expect(resetCountdownLabel(500, 1000), 'now'); // already passed
      expect(resetCountdownLabel(1000 + 3 * 86400, 1000), '3d');
      expect(resetCountdownLabel(1000 + 5 * 3600, 1000), '5h');
      expect(resetCountdownLabel(1000 + 90 * 60, 1000), '1h'); // 1.5h floors
    });
  });

  group('compactAge', () {
    test('rounds to the nearest single unit with an optional suffix', () {
      expect(compactAge(45), '45s');
      expect(compactAge(45, suffix: ' ago'), '45s ago');
      expect(compactAge(100), '2m'); // 100s rounds to 2m
      expect(compactAge(3600), '60m'); // still under the 5400 cutoff
      expect(compactAge(7200), '2h');
      expect(compactAge(3 * 86400), '3d');
    });

    test('floorNow reads sub-minute as now and drops the seconds unit', () {
      expect(compactAge(30, floorNow: true), 'now');
      expect(compactAge(59, floorNow: true), 'now');
      expect(compactAge(75, floorNow: true), '1m');
    });
  });

  group('countdown', () {
    test('reached, day+hour, and hour+minute forms', () {
      expect(countdown(1000, 1000), 'now');
      expect(countdown(500, 1000), 'now');
      expect(countdown(1000 + 2 * 86400 + 3 * 3600, 1000), '2d3h');
      expect(countdown(1000 + 3 * 3600 + 20 * 60, 1000), '3h20m');
      expect(countdown(1000 + 45 * 60, 1000), '0h45m');
    });
  });
}
