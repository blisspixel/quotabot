import 'package:quotabot_collector/calibration.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:test/test.dart';

const _t0 = 1700000000;

HeadroomBucket _bucket(int start, double headroom) =>
    HeadroomBucket(start: start)..add(headroom);

/// A sawtooth history: headroom falls from 100 to 0 over [declineHours], sits at
/// 0 for [flatHours], then resets, repeated [cycles] times. Hourly buckets.
List<HeadroomBucket> _sawtooth({
  int cycles = 5,
  int declineHours = 10,
  int flatHours = 2,
}) {
  final period = declineHours + flatHours;
  final out = <HeadroomBucket>[];
  for (var h = 0; h < cycles * period; h++) {
    final inCycle = h % period;
    final headroom =
        inCycle < declineHours ? 100.0 * (1 - inCycle / declineHours) : 0.0;
    out.add(_bucket(_t0 + h * 3600, headroom));
  }
  return out;
}

void main() {
  test('no history grades nothing, honestly', () {
    final r = calibrationFromHistory(const [], _t0);
    expect(r.samples, 0);
    expect(r.brier, isNull);
    expect(r.calibration, isNull);
    expect(r.bins, isEmpty);
  });

  test('a flat, idle history makes no gradable predictions (no burn)', () {
    final flat = [for (var h = 0; h < 24; h++) _bucket(_t0 + h * 3600, 100)];
    final r = calibrationFromHistory(flat, _t0 + 48 * 3600);
    expect(r.samples, 0);
  });

  test('a tracking predictor scores well on a clean declining history', () {
    final buckets = _sawtooth();
    final now = buckets.last.start + 6 * 3600; // horizons fully elapsed
    final r = calibrationFromHistory(buckets, now);
    expect(r.samples, greaterThan(0));
    expect(
        r.brier, lessThan(0.2)); // near-deterministic decline -> sharp, right
    expect(r.calibration!, greaterThan(0.8));
    expect(r.ece! + r.calibration!, closeTo(1.0, 1e-9));
    expect(r.spanDays, greaterThan(0));
  });

  test('reliability bins partition the samples', () {
    final buckets = _sawtooth();
    final now = buckets.last.start + 6 * 3600;
    final r = calibrationFromHistory(buckets, now);
    final counted = r.bins.fold<int>(0, (s, b) => s + b.count);
    expect(counted, r.samples);
    for (final b in r.bins) {
      expect(b.meanPredicted, inInclusiveRange(0, 1));
      expect(b.observedFrequency, inInclusiveRange(0, 1));
    }
  });

  test('the horizon must be elapsed: a too-recent now grades less', () {
    final buckets = _sawtooth();
    final full = calibrationFromHistory(buckets, buckets.last.start + 6 * 3600);
    final recent = calibrationFromHistory(buckets, buckets.first.start + 3600);
    expect(recent.samples, lessThan(full.samples));
  });

  test('calibrationAcross pools providers without merging their series', () {
    final a = _sawtooth(cycles: 4);
    final b = _sawtooth(cycles: 4);
    final now = _t0 + (4 * 12 + 6) * 3600;
    final pooled = calibrationAcross({'a': a, 'b': b}, now);
    final single = calibrationFromHistory(a, now);
    expect(pooled.samples, single.samples * 2);
  });
}
