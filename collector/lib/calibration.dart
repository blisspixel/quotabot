/// Calibration: does quotabot's strand prediction actually come true?
///
/// quotabot predicts the probability that a provider's window is spent within a
/// horizon. This module grades those predictions against what really happened, by
/// replaying the predictor over the headroom history we already keep. No new
/// storage and no provider calls: it reads the same hourly buckets the analytics
/// use, so a user can inspect how well predicted probabilities agree with
/// outcomes and get a data-backed answer instead of a marketing claim.
///
/// All functions are pure. The method is a standard reliability analysis: bin
/// predictions by probability, compare each bin's mean predicted probability to
/// the observed frequency of the event, and summarize with the Brier score and
/// the expected calibration error (ECE). `calibration` is the bounded agreement
/// score `1 - ECE`, not the percentage of individual forecasts that were right.
library;

import 'analysis.dart';
import 'insights.dart';
import 'models.dart';

/// A public calibration headline needs more than a merely computable score.
/// Detailed JSON remains available below this threshold with its exact sample
/// count, but casual surfaces withhold a percentage that would look conclusive.
const int kMinCalibrationHeadlineSamples = 40;

/// Tuning fits on the earlier history and must independently improve on this
/// later fraction. The forecast horizon is left as a gap between the partitions
/// so a fit outcome cannot consume an observation from the validation tail.
const double kCalibrationValidationFraction = 0.25;
const int kMinCalibrationFitSamples = 20;
const int kMinCalibrationValidationSamples = 10;

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
/// perfect); [ece] the expected calibration error; [calibration] is the
/// agreement score `1 - ece` (higher is better, 1 is perfect). It is not an
/// accuracy rate. All score fields are null when there were no resolvable
/// predictions.
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

  bool get headlineReady =>
      samples >= kMinCalibrationHeadlineSamples && calibration != null;

  /// The one-line headline shared by casual surfaces. It names the exact score
  /// instead of implying that `1 - ECE` is an individual-forecast hit rate, and
  /// remains absent until the minimum evidence threshold is met.
  String? get headline => headlineReady
      ? '${(calibration! * 100).round()}% calibration agreement across '
          '$samples resolved forecasts'
      : null;

  Map<String, dynamic> toJson() => {
        'samples': samples,
        if (brier != null) 'brier_score': brier,
        if (ece != null) 'expected_calibration_error': ece,
        if (calibration != null) 'calibration': calibration,
        'headline_ready': headlineReady,
        'minimum_headline_samples': kMinCalibrationHeadlineSamples,
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
  final List<int> predictedAt;
  final List<String> series;
  final int spanDays;
  const _Samples(
    this.predicted,
    this.outcomes,
    this.predictedAt,
    this.series,
    this.spanDays,
  );
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
  String series,
) {
  final usable = buckets.where((b) => b.count > 0).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final spanDays = usable.length < 2
      ? 0
      : ((usable.last.start - usable.first.start) / 86400).round();
  final horizonSecs = horizonHours * 3600;
  final predicted = <double>[];
  final outcomes = <int>[];
  final predictedAt = <int>[];
  final seriesKeys = <String>[];
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
    predictedAt.add(t);
    seriesKeys.add(series);
  }
  return _Samples(predicted, outcomes, predictedAt, seriesKeys, spanDays);
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
      _replay(
        buckets,
        now,
        horizonHours,
        burnLookbackHours,
        spentFloor,
        '',
      ),
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
  return _score(
    _replayAcross(
      byProvider,
      now,
      horizonHours,
      burnLookbackHours,
      spentFloor,
    ),
    horizonHours,
    bins,
  );
}

_Samples _replayAcross(
  Map<String, List<HeadroomBucket>> byProvider,
  int now,
  int horizonHours,
  int burnLookbackHours,
  double spentFloor,
) {
  final predicted = <double>[];
  final outcomes = <int>[];
  final predictedAt = <int>[];
  final series = <String>[];
  var spanDays = 0;
  for (final entry in byProvider.entries) {
    final s = _replay(
      entry.value,
      now,
      horizonHours,
      burnLookbackHours,
      spentFloor,
      entry.key,
    );
    predicted.addAll(s.predicted);
    outcomes.addAll(s.outcomes);
    predictedAt.addAll(s.predictedAt);
    series.addAll(s.series);
    if (s.spanDays > spanDays) spanDays = s.spanDays;
  }
  return _Samples(predicted, outcomes, predictedAt, series, spanDays);
}

/// The shipped default burn lookback, in hours: the window `burnRateWithError`
/// fits recent burn over, and the parameter [tuneBurnLookback] fits on local
/// history.
const int kDefaultBurnLookbackHours = 6;

/// The result of fitting the strand predictor's burn lookback on the user's own
/// recorded history. When there are too few resolved predictions to fit
/// responsibly, [tuned] is false and [burnLookbackHours] is the shipped default:
/// quotabot never overfits a thin history.
class TunedParameters {
  /// The fitted burn lookback in hours (the shipped default when not [tuned]).
  final int burnLookbackHours;

  /// True when a candidate other than the default was accepted on enough data.
  final bool tuned;

  /// Resolved predictions graded at the default lookback - the sample size the
  /// fit rests on.
  final int samples;

  /// Earlier resolved predictions used to choose a candidate and later
  /// predictions reserved to validate it. A horizon-sized gap separates them.
  final int fitSamples;
  final int validationSamples;

  /// True when [brierAtDefault] and [brierTuned] are scores on the later
  /// temporal holdout rather than the full in-sample history.
  final bool temporalValidation;

  /// Brier at the shipped default and at the fitted value (lower is better).
  /// Null when nothing could be graded.
  final double? brierAtDefault;
  final double? brierTuned;

  const TunedParameters({
    required this.burnLookbackHours,
    required this.tuned,
    required this.samples,
    required this.fitSamples,
    required this.validationSamples,
    required this.temporalValidation,
    required this.brierAtDefault,
    required this.brierTuned,
  });

  /// Brier improvement from tuning (`brierAtDefault - brierTuned`), or null when
  /// not gradable. Never negative: the default is always a candidate, so the fit
  /// can only match or beat it.
  double? get brierImprovement => (brierAtDefault == null || brierTuned == null)
      ? null
      : brierAtDefault! - brierTuned!;

  Map<String, dynamic> toJson() => {
        'burn_lookback_hours': burnLookbackHours,
        'tuned': tuned,
        'samples': samples,
        'fit_samples': fitSamples,
        'validation_samples': validationSamples,
        'temporal_validation': temporalValidation,
        if (brierAtDefault != null) 'brier_at_default': brierAtDefault,
        if (brierTuned != null) 'brier_tuned': brierTuned,
        if (brierImprovement != null) 'brier_improvement': brierImprovement,
      };
}

typedef _SampleKey = ({String series, int predictedAt});

class _TemporalSplit {
  final Set<_SampleKey> fit;
  final Set<_SampleKey> validation;

  const _TemporalSplit(this.fit, this.validation);
}

class _PairedBrier {
  final double baseline;
  final double candidate;
  final int samples;

  const _PairedBrier(this.baseline, this.candidate, this.samples);
}

Map<_SampleKey, int> _sampleIndex(_Samples samples) => {
      for (var i = 0; i < samples.predicted.length; i++)
        (
          series: samples.series[i],
          predictedAt: samples.predictedAt[i],
        ): i,
    };

_TemporalSplit _temporalSplit(_Samples samples, int horizonHours) {
  final bySeries = <String, List<int>>{};
  for (var i = 0; i < samples.predicted.length; i++) {
    bySeries.putIfAbsent(samples.series[i], () => []).add(i);
  }
  final fit = <_SampleKey>{};
  final validation = <_SampleKey>{};
  final horizonSeconds = horizonHours * 3600;
  for (final indices in bySeries.values) {
    indices.sort(
      (left, right) =>
          samples.predictedAt[left].compareTo(samples.predictedAt[right]),
    );
    final validationCount =
        (indices.length * kCalibrationValidationFraction).ceil().clamp(
              1,
              indices.length,
            );
    final splitAt = indices.length - validationCount;
    if (splitAt <= 0) continue;
    final validationStartsAt = samples.predictedAt[indices[splitAt]];
    for (var position = 0; position < indices.length; position++) {
      final index = indices[position];
      final key = (
        series: samples.series[index],
        predictedAt: samples.predictedAt[index],
      );
      if (position >= splitAt) {
        validation.add(key);
      } else if (samples.predictedAt[index] + horizonSeconds <
          validationStartsAt) {
        fit.add(key);
      }
    }
  }
  return _TemporalSplit(fit, validation);
}

double? _brierForKeys(_Samples samples, Set<_SampleKey> keys) {
  if (keys.isEmpty) return null;
  final index = _sampleIndex(samples);
  var sum = 0.0;
  var count = 0;
  for (final key in keys) {
    final sampleIndex = index[key];
    if (sampleIndex == null) continue;
    final difference =
        samples.predicted[sampleIndex] - samples.outcomes[sampleIndex];
    sum += difference * difference;
    count++;
  }
  return count == 0 ? null : sum / count;
}

_PairedBrier? _pairedBrier(
  _Samples baseline,
  _Samples candidate,
  Set<_SampleKey> keys, {
  required int minimumSamples,
}) {
  final baselineIndex = _sampleIndex(baseline);
  final candidateIndex = _sampleIndex(candidate);
  var baselineSum = 0.0;
  var candidateSum = 0.0;
  var count = 0;
  for (final key in keys) {
    final left = baselineIndex[key];
    final right = candidateIndex[key];
    if (left == null || right == null) continue;
    if (baseline.outcomes[left] != candidate.outcomes[right]) return null;
    final outcome = baseline.outcomes[left];
    final baselineDifference = baseline.predicted[left] - outcome;
    final candidateDifference = candidate.predicted[right] - outcome;
    baselineSum += baselineDifference * baselineDifference;
    candidateSum += candidateDifference * candidateDifference;
    count++;
  }
  final comparableMinimum =
      (keys.length * 0.8).ceil().clamp(minimumSamples, keys.length);
  if (count < comparableMinimum) return null;
  return _PairedBrier(
    baselineSum / count,
    candidateSum / count,
    count,
  );
}

/// Fits on earlier resolved forecasts, then accepts a non-default burn lookback
/// only when it also improves Brier on a later temporal holdout. The forecast
/// horizon is excluded between fit and validation, so fit outcomes never consume
/// observations from the holdout. Candidate and baseline scores use the same
/// provider/timestamp pairs, preventing an easier subset from winning.
///
/// Pure: it only grades recorded history through the same replay. It never
/// touches the live decision, sends anything, or spends a token; a caller decides
/// whether to adopt the fitted value.
TunedParameters tuneBurnLookback(
  Map<String, List<HeadroomBucket>> byProvider,
  int now, {
  List<int> lookbackCandidates = const [3, 6, 12, 24],
  int minSamples = 40,
  int defaultLookbackHours = kDefaultBurnLookbackHours,
  int horizonHours = 5,
}) {
  final baseline = _replayAcross(
    byProvider,
    now,
    horizonHours,
    defaultLookbackHours,
    kSpentHeadroomFloor,
  );
  final baseReport = _score(baseline, horizonHours, 10);
  if (baseReport.samples < minSamples || baseReport.brier == null) {
    return TunedParameters(
      burnLookbackHours: defaultLookbackHours,
      tuned: false,
      samples: baseReport.samples,
      fitSamples: 0,
      validationSamples: 0,
      temporalValidation: false,
      brierAtDefault: baseReport.brier,
      brierTuned: baseReport.brier,
    );
  }

  final split = _temporalSplit(baseline, horizonHours);
  final baseValidationBrier = _brierForKeys(baseline, split.validation);
  if (split.fit.length < kMinCalibrationFitSamples ||
      split.validation.length < kMinCalibrationValidationSamples ||
      baseValidationBrier == null) {
    return TunedParameters(
      burnLookbackHours: defaultLookbackHours,
      tuned: false,
      samples: baseReport.samples,
      fitSamples: split.fit.length,
      validationSamples: split.validation.length,
      temporalValidation: false,
      brierAtDefault: baseReport.brier,
      brierTuned: baseReport.brier,
    );
  }

  var bestLookback = defaultLookbackHours;
  _Samples? bestSamples;
  var bestFitImprovement = 0.0;
  for (final candidate in lookbackCandidates) {
    if (candidate <= 0 || candidate == defaultLookbackHours) continue;
    final candidateSamples = _replayAcross(
      byProvider,
      now,
      horizonHours,
      candidate,
      kSpentHeadroomFloor,
    );
    final fitComparison = _pairedBrier(
      baseline,
      candidateSamples,
      split.fit,
      minimumSamples: kMinCalibrationFitSamples,
    );
    if (fitComparison == null) continue;
    final improvement = fitComparison.baseline - fitComparison.candidate;
    if (improvement > bestFitImprovement) {
      bestFitImprovement = improvement;
      bestLookback = candidate;
      bestSamples = candidateSamples;
    }
  }

  if (bestSamples == null) {
    return TunedParameters(
      burnLookbackHours: defaultLookbackHours,
      tuned: false,
      samples: baseReport.samples,
      fitSamples: split.fit.length,
      validationSamples: split.validation.length,
      temporalValidation: true,
      brierAtDefault: baseValidationBrier,
      brierTuned: baseValidationBrier,
    );
  }

  final validationComparison = _pairedBrier(
    baseline,
    bestSamples,
    split.validation,
    minimumSamples: kMinCalibrationValidationSamples,
  );
  final accepted = validationComparison != null &&
      validationComparison.candidate < validationComparison.baseline;
  return TunedParameters(
    burnLookbackHours: accepted ? bestLookback : defaultLookbackHours,
    tuned: accepted,
    samples: baseReport.samples,
    fitSamples: split.fit.length,
    validationSamples: validationComparison?.samples ?? split.validation.length,
    temporalValidation: true,
    brierAtDefault: validationComparison?.baseline ?? baseValidationBrier,
    brierTuned: accepted
        ? validationComparison.candidate
        : validationComparison?.baseline ?? baseValidationBrier,
  );
}
