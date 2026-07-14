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
