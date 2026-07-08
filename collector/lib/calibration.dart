/// Calibration: does quotabot's strand prediction actually come true?
///
/// quotabot predicts the probability that a provider's window is spent within a
/// horizon. This module grades those predictions against what really happened, by
/// replaying the predictor over the headroom history we already keep. No new
/// storage and no provider calls: it reads the same hourly buckets the analytics
/// use, so a user can ask "how often is quotabot right?" and get an honest,
/// data-backed answer instead of a marketing claim.
///
/// All functions are pure. The method is a standard reliability analysis: bin
/// predictions by probability, compare each bin's mean predicted probability to
/// the observed frequency of the event, and summarize with the Brier score and
/// the expected calibration error (ECE). Calibration is reported as `1 - ECE`.
library;

import 'analysis.dart';
import 'insights.dart';
import 'models.dart';

/// One bucket of a reliability diagram: predictions whose probability fell in a
/// [0.1)-wide band, with the mean predicted probability, the observed frequency
/// of the event, and how many predictions landed here.
class CalibrationBin {
  final double meanPredicted;
  final double observedFrequency;
  final int count;

  const CalibrationBin({
    required this.meanPredicted,
    required this.observedFrequency,
    required this.count,
  });

  Map<String, dynamic> toJson() => {
        'mean_predicted': meanPredicted,
        'observed_frequency': observedFrequency,
        'count': count,
      };
}

/// How well the strand predictor is calibrated over a history. [samples] is the
/// number of resolved predictions; [brier] the Brier score (lower is better, 0 is
/// perfect); [ece] the expected calibration error; [calibration] is `1 - ece`
/// (higher is better, 1 is perfect). All score fields are null when there were no
/// resolvable predictions.
class CalibrationReport {
  final int samples;
  final double? brier;
  final double? ece;
  final double? calibration;
  final int spanDays;
  final int horizonHours;
  final List<CalibrationBin> bins;

  const CalibrationReport({
    required this.samples,
    required this.brier,
    required this.ece,
    required this.calibration,
    required this.spanDays,
    required this.horizonHours,
    required this.bins,
  });

  Map<String, dynamic> toJson() => {
        'samples': samples,
        if (brier != null) 'brier_score': brier,
        if (ece != null) 'expected_calibration_error': ece,
        if (calibration != null) 'calibration': calibration,
        'span_days': spanDays,
        'horizon_hours': horizonHours,
        'bins': bins.map((b) => b.toJson()).toList(),
      };
}

/// The (prediction, outcome) pairs a replay produced, kept separate from scoring
/// so several providers' pairs can be pooled before grading (merging their raw
/// headroom series would corrupt the per-provider burn estimate).
class _Samples {
  final List<double> predicted;
  final List<int> outcomes;
  final int spanDays;
  const _Samples(this.predicted, this.outcomes, this.spanDays);
}

/// Replays the strand predictor over one provider's [buckets]. For each historical
/// hour with enough prior data to estimate burn and a fully elapsed horizon
/// ahead, it records the predicted probability the window is spent within
/// [horizonHours] (the same [strandProbability] routing uses) and the actual
/// outcome (did mean headroom fall to [spentFloor] or below within that horizon).
_Samples _replay(
  List<HeadroomBucket> buckets,
  int now,
  int horizonHours,
  int burnLookbackHours,
  double spentFloor,
) {
  final usable = buckets.where((b) => b.count > 0).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final spanDays = usable.length < 2
      ? 0
      : ((usable.last.start - usable.first.start) / 86400).round();
  final horizonSecs = horizonHours * 3600;
  final predicted = <double>[];
  final outcomes = <int>[];
  for (var i = 0; i < usable.length; i++) {
    final t = usable[i].start;
    // The horizon must be fully in the past to resolve the outcome honestly.
    if (t + horizonSecs > now) break;
    final past = usable.where((b) => b.start <= t).toList();
    final burn = burnRateWithError(past, t, lookbackHours: burnLookbackHours);
    final p = strandProbability(
      usable[i].mean,
      burn.perHour,
      burn.sePerHour,
      t + horizonSecs,
      t,
    );
    if (p == null) continue; // no burn signal: nothing to grade
    final ahead =
        usable.where((b) => b.start > t && b.start <= t + horizonSecs).toList();
    if (ahead.isEmpty) continue; // unobserved horizon: cannot resolve
    predicted.add(p);
    outcomes.add(ahead.any((b) => b.mean <= spentFloor) ? 1 : 0);
  }
  return _Samples(predicted, outcomes, spanDays);
}

/// Scores pooled prediction/outcome pairs into a [CalibrationReport] (Brier, ECE,
/// and a [bins]-bucket reliability diagram). Null scores when there is nothing to
/// grade. Pure.
CalibrationReport _score(_Samples s, int horizonHours, int bins) {
  final predicted = s.predicted;
  final outcomes = s.outcomes;
  final n = predicted.length;
  if (n == 0) {
    return CalibrationReport(
      samples: 0,
      brier: null,
      ece: null,
      calibration: null,
      spanDays: s.spanDays,
      horizonHours: horizonHours,
      bins: const [],
    );
  }
  var brierSum = 0.0;
  for (var i = 0; i < n; i++) {
    final d = predicted[i] - outcomes[i];
    brierSum += d * d;
  }
  final sumP = List<double>.filled(bins, 0);
  final sumO = List<int>.filled(bins, 0);
  final cnt = List<int>.filled(bins, 0);
  for (var i = 0; i < n; i++) {
    var idx = (predicted[i] * bins).floor();
    if (idx >= bins) idx = bins - 1; // p == 1.0 lands in the last bin
    sumP[idx] += predicted[i];
    sumO[idx] += outcomes[i];
    cnt[idx]++;
  }
  final diagram = <CalibrationBin>[];
  var ece = 0.0;
  for (var b = 0; b < bins; b++) {
    if (cnt[b] == 0) continue;
    final meanP = sumP[b] / cnt[b];
    final obs = sumO[b] / cnt[b];
    ece += (cnt[b] / n) * (meanP - obs).abs();
    diagram.add(CalibrationBin(
      meanPredicted: meanP,
      observedFrequency: obs,
      count: cnt[b],
    ));
  }
  return CalibrationReport(
    samples: n,
    brier: brierSum / n,
    ece: ece,
    calibration: (1 - ece).clamp(0.0, 1.0).toDouble(),
    spanDays: s.spanDays,
    horizonHours: horizonHours,
    bins: diagram,
  );
}

/// Grades the strand predictor over one provider's history. Pure.
CalibrationReport calibrationFromHistory(
  List<HeadroomBucket> buckets,
  int now, {
  int horizonHours = 5,
  int burnLookbackHours = 6,
  double spentFloor = kSpentHeadroomFloor,
  int bins = 10,
}) =>
    _score(
      _replay(buckets, now, horizonHours, burnLookbackHours, spentFloor),
      horizonHours,
      bins,
    );

/// Grades the predictor across providers, pooling each provider's prediction
/// pairs (not its raw series) so the headline "how often is quotabot right"
/// reflects every prediction it has made. Pure.
CalibrationReport calibrationAcross(
  Map<String, List<HeadroomBucket>> byProvider,
  int now, {
  int horizonHours = 5,
  int burnLookbackHours = 6,
  double spentFloor = kSpentHeadroomFloor,
  int bins = 10,
}) {
  final predicted = <double>[];
  final outcomes = <int>[];
  var spanDays = 0;
  for (final list in byProvider.values) {
    final s = _replay(list, now, horizonHours, burnLookbackHours, spentFloor);
    predicted.addAll(s.predicted);
    outcomes.addAll(s.outcomes);
    if (s.spanDays > spanDays) spanDays = s.spanDays;
  }
  return _score(_Samples(predicted, outcomes, spanDays), horizonHours, bins);
}
