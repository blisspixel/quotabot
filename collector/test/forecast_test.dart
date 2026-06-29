import 'package:quotabot_collector/analysis.dart';
import 'package:test/test.dart';

void main() {
  group('classifyForecast', () {
    test('a material strand probability leads at watch severity', () {
      final f = classifyForecast(
          strandProbability: 0.3, burnPerHour: 40, headroom: 30);
      expect(f, isNotNull);
      expect(f!.kind, ForecastKind.strand);
      expect(f.strandProbability, 0.3);
      expect(f.hoursToEmpty, isNull);
      expect(f.severity, 1);
    });

    test('a more-likely-than-not strand raises severity to urgent', () {
      final f = classifyForecast(
          strandProbability: 0.6, burnPerHour: 40, headroom: 30);
      expect(f!.kind, ForecastKind.strand);
      expect(f.severity, 2);
    });

    test('a strand below the materiality floor yields a runway instead', () {
      // 0.1 < 0.15 floor, but a visible burn still gives a time-to-empty.
      final f = classifyForecast(
          strandProbability: 0.1, burnPerHour: 10, headroom: 20);
      expect(f!.kind, ForecastKind.timeToEmpty);
      expect(f.hoursToEmpty, closeTo(2.0, 1e-9));
      expect(f.strandProbability, isNull);
      expect(f.severity, 0);
    });

    test('time-to-empty when burning but no strand probability is known', () {
      final f = classifyForecast(
          strandProbability: null, burnPerHour: 25, headroom: 50);
      expect(f!.kind, ForecastKind.timeToEmpty);
      expect(f.hoursToEmpty, closeTo(2.0, 1e-9));
    });

    test('no forecast is invented without a real burn signal', () {
      expect(
        classifyForecast(
            strandProbability: null, burnPerHour: null, headroom: 80),
        isNull,
      );
      // A burn at or below the visible-burn floor is too quiet to state.
      expect(
        classifyForecast(
            strandProbability: null, burnPerHour: 0.5, headroom: 80),
        isNull,
      );
      // No headroom left, and no material strand: nothing to forecast.
      expect(
        classifyForecast(strandProbability: 0.05, burnPerHour: 10, headroom: 0),
        isNull,
      );
    });
  });
}
