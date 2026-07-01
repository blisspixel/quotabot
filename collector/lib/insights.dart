import 'dart:math' as math;

import 'models.dart';

/// Historical quota analytics over compact, mergeable aggregate buckets.
///
/// Storing every raw snapshot for 90 days is wasteful, so headroom samples are
/// folded into fixed hourly buckets. Each bucket is a monoid: two buckets
/// combine by adding their fields, so any date range is just the sum of its
/// buckets and finer buckets roll up into coarser ones without loss of the
/// statistics we report. All logic here is pure and side-effect free.

const int kBucketSpan = 3600; // one hour
const int kHistBins = 20; // 5 percent per bin across 0..100
const int kRetentionDays = 90;
const int kBurnShrinkagePriorSamples = 4;
const int kReliabilityShrinkagePriorSamples = 4;

/// Aligns an epoch second to the start of its hour bucket.
int bucketStart(int epoch) => epoch - (epoch % kBucketSpan);

/// One hour of headroom samples reduced to a fixed-size aggregate.
///
/// Tracks enough to recover mean, variance, extremes, an approximate
/// distribution (the histogram), and how often the provider was spent, none of
/// which need the original samples.
class HeadroomBucket {
  final int start; // aligned hour start, epoch seconds
  int count;
  double sum; // sum of headroom percents
  double sumSq; // sum of squares, for variance
  double min;
  double max;
  int exhausted; // samples with headroom at or below the spent floor
  final List<int> hist; // kHistBins counts across headroom 0..100

  HeadroomBucket({
    required this.start,
    this.count = 0,
    this.sum = 0,
    this.sumSq = 0,
    this.min = double.infinity,
    this.max = double.negativeInfinity,
    this.exhausted = 0,
    List<int>? hist,
  }) : hist = hist ?? List<int>.filled(kHistBins, 0);

  /// Folds one headroom reading (0..100) into the bucket.
  void add(double headroom, {double spentFloor = 0.5}) {
    final h = headroom.clamp(0.0, 100.0);
    count++;
    sum += h;
    sumSq += h * h;
    if (h < min) min = h;
    if (h > max) max = h;
    if (h <= spentFloor) exhausted++;
    final bin = (h / (100 / kHistBins)).floor().clamp(0, kHistBins - 1);
    hist[bin]++;
  }

  double get mean => count == 0 ? 0 : sum / count;

  double get variance {
    if (count == 0) return 0;
    final v = (sumSq / count) - (mean * mean);
    return v < 0 ? 0 : v; // guard floating-point error
  }

  double get stddev => math.sqrt(variance);

  Map<String, dynamic> toJson() => {
        's': start,
        'n': count,
        'sum': sum,
        'sq': sumSq,
        'min': count == 0 ? null : min,
        'max': count == 0 ? null : max,
        'x': exhausted,
        'h': hist,
      };

  factory HeadroomBucket.fromJson(Map<String, dynamic> j) => HeadroomBucket(
        start: j['s'] as int,
        count: (j['n'] as num?)?.toInt() ?? 0,
        sum: (j['sum'] as num?)?.toDouble() ?? 0,
        sumSq: (j['sq'] as num?)?.toDouble() ?? 0,
        min: (j['min'] as num?)?.toDouble() ?? double.infinity,
        max: (j['max'] as num?)?.toDouble() ?? double.negativeInfinity,
        exhausted: (j['x'] as num?)?.toInt() ?? 0,
        hist: ((j['h'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
      );
}

/// Sums a set of buckets into one aggregate (the monoid fold). The result
/// carries the earliest start; callers use it only for distribution stats.
HeadroomBucket mergeBuckets(Iterable<HeadroomBucket> buckets) {
  final hist = List<int>.filled(kHistBins, 0);
  var count = 0, exhausted = 0, start = 0x7fffffffffffffff;
  var sum = 0.0,
      sumSq = 0.0,
      min = double.infinity,
      max = double.negativeInfinity;
  for (final b in buckets) {
    if (b.count == 0) continue;
    count += b.count;
    sum += b.sum;
    sumSq += b.sumSq;
    exhausted += b.exhausted;
    if (b.min < min) min = b.min;
    if (b.max > max) max = b.max;
    if (b.start < start) start = b.start;
    for (var i = 0; i < kHistBins && i < b.hist.length; i++) {
      hist[i] += b.hist[i];
    }
  }
  return HeadroomBucket(
    start: count == 0 ? 0 : start,
    count: count,
    sum: sum,
    sumSq: sumSq,
    min: min,
    max: max,
    exhausted: exhausted,
    hist: hist,
  );
}

/// Approximate percentile (0..100) of headroom from a merged histogram, using
/// linear interpolation inside the bin the rank falls in. Returns null when
/// there are no samples.
double? percentile(HeadroomBucket agg, double p) {
  if (agg.count == 0) return null;
  final target = (p / 100) * agg.count;
  const binWidth = 100 / kHistBins;
  var cumulative = 0;
  for (var i = 0; i < kHistBins; i++) {
    final next = cumulative + agg.hist[i];
    if (next >= target) {
      final within =
          agg.hist[i] == 0 ? 0.0 : (target - cumulative) / agg.hist[i];
      return (i + within) * binWidth;
    }
    cumulative = next;
  }
  return 100;
}

/// Mean headroom per calendar-day-aligned bucket, oldest first. Used as the
/// series for trend fitting.
List<({int day, double mean})> dailyMeans(Iterable<HeadroomBucket> buckets) {
  final byDay = <int, HeadroomBucket>{};
  for (final b in buckets) {
    if (b.count == 0) continue;
    final day = b.start - (b.start % 86400);
    (byDay[day] ??= HeadroomBucket(start: day))
      ..count += b.count
      ..sum += b.sum;
  }
  final out = byDay.entries
      .map((e) => (day: e.key, mean: e.value.sum / e.value.count))
      .toList()
    ..sort((a, b) => a.day.compareTo(b.day));
  return out;
}

/// Current consecutive sampled-day streaks through the latest sample.
///
/// A usable day has at least one sample and no spent samples. A spent day has at
/// least one sample and every sample spent. Mixed days or gaps break both
/// streaks. The result is based on local calendar days after [tzOffset].
({int sampledDays, int usableDays, int spentDays}) currentDayStreaks(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
}) {
  final byDay = <int, ({int count, int exhausted})>{};
  final offset = tzOffset.inSeconds;
  for (final b in buckets) {
    if (b.count == 0) continue;
    final day = (b.start + offset) ~/ 86400;
    final existing = byDay[day];
    byDay[day] = (
      count: (existing?.count ?? 0) + b.count,
      exhausted: (existing?.exhausted ?? 0) + b.exhausted,
    );
  }
  if (byDay.isEmpty) return (sampledDays: 0, usableDays: 0, spentDays: 0);

  final latest = byDay.keys.reduce(math.max);
  var usable = 0;
  for (var day = latest;; day--) {
    final sampled = byDay[day];
    if (sampled == null || sampled.exhausted != 0) break;
    usable++;
  }

  var spent = 0;
  for (var day = latest;; day--) {
    final sampled = byDay[day];
    if (sampled == null ||
        sampled.count == 0 ||
        sampled.exhausted != sampled.count) {
      break;
    }
    spent++;
  }

  return (sampledDays: byDay.length, usableDays: usable, spentDays: spent);
}

/// One sampled local day for the contribution calendar.
///
/// The day start is the UTC epoch second corresponding to local midnight under
/// the supplied fixed [tzOffset]. The calendar is intentionally based on the
/// existing hourly aggregate buckets, not raw logs.
class ContributionDay {
  final int dayStart;
  final int samples;
  final double meanFreePercent;
  final int spentSamples;

  const ContributionDay({
    required this.dayStart,
    required this.samples,
    required this.meanFreePercent,
    required this.spentSamples,
  });

  double get usedPercent => (100 - meanFreePercent).clamp(0.0, 100.0);

  bool get spent => samples > 0 && spentSamples == samples;

  bool get mixed => spentSamples > 0 && spentSamples < samples;

  String get state {
    if (spent) return 'spent';
    if (mixed) return 'mixed';
    return 'usable';
  }

  /// ASCII intensity marker for compact terminal and markdown calendars.
  String get marker {
    if (spent) return 'x';
    if (mixed) return '!';
    final used = usedPercent;
    if (used >= 75) return '#';
    if (used >= 50) return '*';
    if (used >= 25) return '+';
    return '.';
  }

  int get intensity {
    if (spent) return 4;
    if (mixed) return 3;
    final used = usedPercent;
    if (used >= 75) return 4;
    if (used >= 50) return 3;
    if (used >= 25) return 2;
    if (used > 0) return 1;
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'day_start': dayStart,
        'samples': samples,
        'mean_free_percent': double.parse(meanFreePercent.toStringAsFixed(2)),
        'spent_samples': spentSamples,
        'state': state,
        'intensity': intensity,
      };
}

/// Sampled local-day calendar, oldest first, capped to [maxDays].
List<ContributionDay> contributionCalendarDays(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
  int maxDays = kRetentionDays,
}) {
  final byDay = <int, ({int count, double sum, int exhausted})>{};
  final offset = tzOffset.inSeconds;
  for (final b in buckets) {
    if (b.count == 0) continue;
    final day = (b.start + offset) ~/ 86400;
    final existing = byDay[day];
    byDay[day] = (
      count: (existing?.count ?? 0) + b.count,
      sum: (existing?.sum ?? 0) + b.sum,
      exhausted: (existing?.exhausted ?? 0) + b.exhausted,
    );
  }
  final entries = byDay.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final capped = maxDays <= 0 || entries.length <= maxDays
      ? entries
      : entries.sublist(entries.length - maxDays);
  return [
    for (final entry in capped)
      ContributionDay(
        dayStart: entry.key * 86400 - offset,
        samples: entry.value.count,
        meanFreePercent: entry.value.sum / entry.value.count,
        spentSamples: entry.value.exhausted,
      ),
  ];
}

String contributionCalendarMarkers(
  List<ContributionDay> days, {
  int maxDays = kRetentionDays,
}) {
  if (days.isEmpty) return '';
  final visible = maxDays <= 0 || days.length <= maxDays
      ? days
      : days.sublist(days.length - maxDays);
  return visible.map((day) => day.marker).join();
}

/// Ordinary least squares fit of headroom against day index. Returns the slope
/// in percent-per-day, the intercept, and the coefficient of determination
/// (R squared, 0..1) as a confidence in the trend. Null with fewer than two
/// days of data.
({double slopePerDay, double intercept, double r2})? trend(
  List<({int day, double mean})> series,
) {
  if (series.length < 2) return null;
  final n = series.length;
  final x0 = series.first.day;
  final xs = series.map((e) => (e.day - x0) / 86400.0).toList();
  final ys = series.map((e) => e.mean).toList();
  final meanX = xs.reduce((a, b) => a + b) / n;
  final meanY = ys.reduce((a, b) => a + b) / n;
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = xs[i] - meanX, dy = ys[i] - meanY;
    sxx += dx * dx;
    sxy += dx * dy;
    syy += dy * dy;
  }
  if (sxx == 0) return null;
  final slope = sxy / sxx;
  final intercept = meanY - slope * meanX;
  final r2 = syy == 0 ? 1.0 : (sxy * sxy) / (sxx * syy);
  return (slopePerDay: slope, intercept: intercept, r2: r2);
}

/// Mean headroom by hour of day (local), length 24, null where no data. Reveals
/// the times a provider is typically tightest.
List<double?> hourOfDayProfile(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
}) {
  final sum = List<double>.filled(24, 0);
  final cnt = List<int>.filled(24, 0);
  final offsetSecs = tzOffset.inSeconds;
  for (final b in buckets) {
    if (b.count == 0) continue;
    final localHour = (((b.start + offsetSecs) % 86400) ~/ 3600) % 24;
    sum[localHour] += b.sum;
    cnt[localHour] += b.count;
  }
  return List<double?>.generate(
    24,
    (h) => cnt[h] == 0 ? null : sum[h] / cnt[h],
  );
}

/// Recent burn rate: how fast headroom is being drawn down, in percent of quota
/// per hour, estimated by least squares over the most recent [lookbackHours] of
/// hourly means. Positive means consuming; zero or negative means flat or
/// recovering. Null with fewer than two recent buckets.
double? burnRatePerHour(
  List<HeadroomBucket> buckets,
  int now, {
  int lookbackHours = 6,
}) =>
    burnRateWithError(buckets, now, lookbackHours: lookbackHours).perHour;

/// Recent burn rate with an uncertainty estimate, from the last [lookbackHours]
/// of hourly buckets. Returns the burn (percent of quota per hour; negative when
/// headroom is easing) as the negated least-squares slope of headroom over time,
/// the standard error of that slope (`se = sqrt( (SSR / (n - 2)) / Sxx )`, the
/// textbook OLS slope error; null with fewer than three points, where it is
/// undefined), and the sample count. Pure.
BurnStat burnRateWithError(
  List<HeadroomBucket> buckets,
  int now, {
  int lookbackHours = 6,
}) {
  final cutoff = now - lookbackHours * 3600;
  final recent =
      buckets.where((b) => b.count > 0 && b.start >= cutoff).toList();
  final n = recent.length;
  if (n < 2) return BurnStat(samples: n);
  final x0 = recent.first.start;
  var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (final b in recent) {
    final x = (b.start - x0) / 3600.0;
    final y = b.mean;
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
    syy += y * y;
  }
  final sxxC = sxx - sx * sx / n; // centered sum of squares in x
  if (sxxC <= 0) return BurnStat(samples: n);
  final slope = (sxy - sx * sy / n) / sxxC;
  double? se;
  if (n >= 3) {
    final syyC = syy - sy * sy / n;
    final ssr = (syyC - slope * slope * sxxC).clamp(0.0, double.infinity);
    se = math.sqrt(ssr / (n - 2) / sxxC);
  }
  return BurnStat(perHour: -slope, sePerHour: se, samples: n);
}

/// Empirical-Bayes shrinkage for recent burn estimates.
///
/// Each fitted provider/account burn is partially pooled toward the
/// sample-weighted fleet mean. Thin histories move more; large histories mostly
/// speak for themselves. The function is intentionally conservative: it needs a
/// real cross-provider/account pool, never invents a burn estimate for a stat
/// with no fitted slope, and keeps the original sample count so routing
/// confidence still reflects how much direct history the candidate has.
Map<String, BurnStat> shrinkBurnStats(
  Map<String, BurnStat> stats, {
  int priorSamples = kBurnShrinkagePriorSamples,
}) {
  if (priorSamples <= 0) return Map<String, BurnStat>.of(stats);
  final usable = stats.entries.where((entry) {
    final burn = entry.value.perHour;
    return burn != null && burn.isFinite && entry.value.samples > 0;
  }).toList();
  if (usable.length < 3) return Map<String, BurnStat>.of(stats);

  var totalWeight = 0.0;
  var weightedBurn = 0.0;
  for (final entry in usable) {
    final weight = entry.value.samples.toDouble();
    totalWeight += weight;
    weightedBurn += entry.value.perHour! * weight;
  }
  if (totalWeight <= 0) return Map<String, BurnStat>.of(stats);
  final poolMean = weightedBurn / totalWeight;

  var between = 0.0;
  for (final entry in usable) {
    final diff = entry.value.perHour! - poolMean;
    between += entry.value.samples * diff * diff;
  }
  final betweenStd = math.sqrt(between / totalWeight);

  return {
    for (final entry in stats.entries)
      entry.key: _shrinkBurnStat(
        entry.value,
        poolMean,
        betweenStd,
        priorSamples,
      ),
  };
}

BurnStat _shrinkBurnStat(
  BurnStat stat,
  double poolMean,
  double betweenStd,
  int priorSamples,
) {
  final burn = stat.perHour;
  if (burn == null || !burn.isFinite || stat.samples <= 0) return stat;
  final directWeight = stat.samples / (stat.samples + priorSamples);
  final shrunk = directWeight * burn + (1 - directWeight) * poolMean;
  final se = stat.sePerHour ??
      (betweenStd > 0
          ? betweenStd / math.sqrt(stat.samples + priorSamples)
          : null);
  return BurnStat(perHour: shrunk, sePerHour: se, samples: stat.samples);
}

/// Beta-binomial shrinkage for provider/account reliability rates.
///
/// Reliability is a success rate: samples with any headroom left over total
/// samples. Thin histories are partially pooled toward the current fleet rate,
/// while mature histories mostly keep their direct observation. Unknown
/// reliability stays unknown, and the helper waits for a real pool before it
/// changes anything.
Map<String, Insights> shrinkInsightsReliability(
  Map<String, Insights> insights, {
  int priorSamples = kReliabilityShrinkagePriorSamples,
}) {
  if (priorSamples <= 0) return Map<String, Insights>.of(insights);
  final usable = insights.entries.where((entry) {
    final reliability = entry.value.reliability;
    return reliability != null &&
        reliability.isFinite &&
        entry.value.samples > 0;
  }).toList();
  if (usable.length < 3) return Map<String, Insights>.of(insights);

  var totalSamples = 0;
  var successes = 0.0;
  for (final entry in usable) {
    final samples = entry.value.samples;
    final reliability = entry.value.reliability!.clamp(0.0, 1.0).toDouble();
    totalSamples += samples;
    successes += reliability * samples;
  }
  if (totalSamples <= 0) return Map<String, Insights>.of(insights);
  final poolRate = successes / totalSamples;

  return {
    for (final entry in insights.entries)
      entry.key: _shrinkInsightsReliability(
        entry.value,
        poolRate,
        priorSamples,
      ),
  };
}

Insights _shrinkInsightsReliability(
  Insights insights,
  double poolRate,
  int priorSamples,
) {
  final reliability = insights.reliability;
  if (reliability == null || !reliability.isFinite || insights.samples <= 0) {
    return insights;
  }
  final observed = reliability.clamp(0.0, 1.0).toDouble();
  final shrunk = (observed * insights.samples + poolRate * priorSamples) /
      (insights.samples + priorSamples);
  return _insightsWithReliability(insights, shrunk);
}

Insights _insightsWithReliability(Insights insights, double reliability) =>
    Insights(
      samples: insights.samples,
      spanDays: insights.spanDays,
      sampledDays: insights.sampledDays,
      mean: insights.mean,
      stddev: insights.stddev,
      p10: insights.p10,
      p50: insights.p50,
      p90: insights.p90,
      reliability: reliability,
      trendPerDay: insights.trendPerDay,
      trendConfidence: insights.trendConfidence,
      tightestHour: insights.tightestHour,
      tightestDay: insights.tightestDay,
      usableDayStreak: insights.usableDayStreak,
      spentDayStreak: insights.spentDayStreak,
      contributionCalendar: insights.contributionCalendar,
      bestTimeWindows: insights.bestTimeWindows,
      burnPerHour: insights.burnPerHour,
      burnSePerHour: insights.burnSePerHour,
    );

/// Mean headroom by local day of week (0 = Monday .. 6 = Sunday), null where no
/// data. Surfaces which days a provider runs tightest.
List<double?> dayOfWeekProfile(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
}) {
  final sum = List<double>.filled(7, 0);
  final cnt = List<int>.filled(7, 0);
  final off = tzOffset.inSeconds;
  for (final b in buckets) {
    if (b.count == 0) continue;
    // 1970-01-01 was a Thursday (weekday index 3 in a Mon..Sun scale).
    final day = (((b.start + off) ~/ 86400) + 3) % 7;
    sum[day] += b.sum;
    cnt[day] += b.count;
  }
  return List<double?>.generate(7, (d) => cnt[d] == 0 ? null : sum[d] / cnt[d]);
}

/// Mean headroom for every (weekday, hour) cell as a 7x24 grid, rows Monday..
/// Sunday and columns 0..23 local hour. Null cells have no data. This is the
/// "best time to run" map: where the grid is greenest, the provider is usually
/// freest. None of the comparable tools show both dimensions at once.
List<List<double?>> weekHourHeatmap(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
}) {
  final agg = _weekHourAggregates(buckets, tzOffset);
  return List.generate(
    7,
    (d) => List<double?>.generate(
      24,
      (h) => agg.count[d][h] == 0 ? null : agg.sum[d][h] / agg.count[d][h],
    ),
  );
}

/// A smoothed weekday/hour heatmap over the same 7x24 torus as
/// [weekHourHeatmap]. The smoothing is conservative: a target cell is populated
/// only when nearby sampled cells provide enough support, so sparse history does
/// not masquerade as a precise weekly pattern.
List<List<double?>> smoothedWeekHourHeatmap(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
  int dayRadius = 1,
  int hourRadius = 2,
  double daySigma = 0.75,
  double hourSigma = 1.25,
  int minSupportSamples = 2,
  int minSupportCells = 2,
}) {
  final agg = _weekHourAggregates(buckets, tzOffset);
  return List.generate(
    7,
    (day) => List<double?>.generate(
      24,
      (hour) => _smoothedCell(
        agg,
        day,
        hour,
        dayRadius: dayRadius,
        hourRadius: hourRadius,
        daySigma: daySigma,
        hourSigma: hourSigma,
        minSupportSamples: minSupportSamples,
        minSupportCells: minSupportCells,
      )?.meanFreePercent,
    ),
  );
}

const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// One populated local weekday/hour cell from the sampled history heatmap.
class WeekHourWindow {
  /// 0 = Monday .. 6 = Sunday.
  final int dayOfWeek;

  /// Local hour of day, 0..23.
  final int hour;

  final int samples;
  final double meanFreePercent;
  final double? smoothedFreePercent;
  final int supportSamples;
  final int supportCells;

  const WeekHourWindow({
    required this.dayOfWeek,
    required this.hour,
    required this.samples,
    required this.meanFreePercent,
    this.smoothedFreePercent,
    this.supportSamples = 0,
    this.supportCells = 0,
  });

  String get dayLabel => _weekdayLabels[dayOfWeek % 7];

  String get timeLabel => '$dayLabel ${hour.toString().padLeft(2, '0')}:00';

  double get scoreFreePercent => smoothedFreePercent ?? meanFreePercent;

  String get summary {
    final smooth = smoothedFreePercent;
    if (smooth == null) {
      return '$timeLabel (${meanFreePercent.round()}% free, n=$samples)';
    }
    return '$timeLabel (~${smooth.round()}% free, '
        'raw ${meanFreePercent.round()}%, n=$samples, support=$supportSamples)';
  }

  Map<String, dynamic> toJson() => {
        'day_of_week': dayOfWeek,
        'day_label': dayLabel,
        'hour_local': hour,
        'samples': samples,
        'mean_free_percent': double.parse(meanFreePercent.toStringAsFixed(2)),
        if (smoothedFreePercent != null)
          'smoothed_free_percent':
              double.parse(smoothedFreePercent!.toStringAsFixed(2)),
        if (supportSamples > 0) 'support_samples': supportSamples,
        if (supportCells > 0) 'support_cells': supportCells,
        'label': timeLabel,
      };
}

class WeekHourScheduleHint {
  final WeekHourWindow window;
  final int scheduledAt;
  final int waitSeconds;
  final int resetsAt;

  const WeekHourScheduleHint({
    required this.window,
    required this.scheduledAt,
    required this.waitSeconds,
    required this.resetsAt,
  });

  String get summary {
    final score = window.smoothedFreePercent == null
        ? '${window.meanFreePercent.round()}%'
        : '~${window.smoothedFreePercent!.round()}%';
    return '${window.timeLabel} in ${_compactWait(waitSeconds)} '
        '($score free before reset)';
  }

  Map<String, dynamic> toJson() => {
        'scheduled_at': scheduledAt,
        'wait_seconds': waitSeconds,
        'resets_at': resetsAt,
        'window': window.toJson(),
        'label': window.timeLabel,
        'summary': summary,
      };
}

/// Populated local weekday/hour cells, sorted Monday..Sunday then 00..23.
List<WeekHourWindow> weekHourWindows(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
}) {
  final agg = _weekHourAggregates(buckets, tzOffset);
  return _weekHourWindowsFromAggregates(agg);
}

/// Populated local weekday/hour cells with a neighborhood-smoothed score when
/// enough nearby samples exist. Raw `meanFreePercent` remains the observed
/// evidence; `smoothedFreePercent` is the scheduling score.
List<WeekHourWindow> smoothedWeekHourWindows(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
  int dayRadius = 1,
  int hourRadius = 2,
  double daySigma = 0.75,
  double hourSigma = 1.25,
  int minSupportSamples = 2,
  int minSupportCells = 2,
}) {
  final agg = _weekHourAggregates(buckets, tzOffset);
  return _weekHourWindowsFromAggregates(
    agg,
    smoothed: (day, hour) => _smoothedCell(
      agg,
      day,
      hour,
      dayRadius: dayRadius,
      hourRadius: hourRadius,
      daySigma: daySigma,
      hourSigma: hourSigma,
      minSupportSamples: minSupportSamples,
      minSupportCells: minSupportCells,
    ),
  );
}

List<WeekHourWindow> _weekHourWindowsFromAggregates(
  _WeekHourAggregates agg, {
  _SmoothedWeekHourCell? Function(int day, int hour)? smoothed,
}) {
  final out = <WeekHourWindow>[];
  for (var day = 0; day < 7; day++) {
    for (var hour = 0; hour < 24; hour++) {
      final samples = agg.count[day][hour];
      if (samples == 0) continue;
      final score = smoothed?.call(day, hour);
      out.add(
        WeekHourWindow(
          dayOfWeek: day,
          hour: hour,
          samples: samples,
          meanFreePercent: agg.sum[day][hour] / samples,
          smoothedFreePercent: score?.meanFreePercent,
          supportSamples: score?.supportSamples ?? 0,
          supportCells: score?.supportCells ?? 0,
        ),
      );
    }
  }
  return out;
}

/// Highest-headroom sampled local weekday/hour windows.
///
/// Cells with at least [minSamples] win when any exist; otherwise sparse history
/// falls back to ranking every populated cell so the caller can still show the
/// best available evidence with its sample count.
List<WeekHourWindow> bestWeekHourWindows(
  Iterable<HeadroomBucket> buckets, {
  Duration tzOffset = Duration.zero,
  int limit = 3,
  int minSamples = 2,
}) {
  if (limit <= 0) return const [];
  final all = smoothedWeekHourWindows(
    buckets,
    tzOffset: tzOffset,
    minSupportSamples: minSamples,
  );
  if (all.isEmpty) return const [];
  final smoothedEligible = all
      .where((cell) =>
          cell.samples >= minSamples && cell.smoothedFreePercent != null)
      .toList();
  final eligible = smoothedEligible.isNotEmpty
      ? smoothedEligible
      : all.where((cell) => cell.samples >= minSamples).toList();
  final ranked = (eligible.isEmpty ? all : eligible).toList()
    ..sort((a, b) {
      final mean = b.scoreFreePercent.compareTo(a.scoreFreePercent);
      if (mean != 0) return mean;
      final samples = b.samples.compareTo(a.samples);
      if (samples != 0) return samples;
      final support = b.supportSamples.compareTo(a.supportSamples);
      if (support != 0) return support;
      final day = a.dayOfWeek.compareTo(b.dayOfWeek);
      if (day != 0) return day;
      return a.hour.compareTo(b.hour);
    });
  return ranked.take(limit).toList();
}

/// Nearest high-headroom weekly slot before the active reset boundary.
///
/// The input [windows] must already be ranked by scheduling quality, typically
/// from [bestWeekHourWindows]. The returned slot is the next occurrence of one
/// of those high-quality weekly cells that starts before [resetsAt].
WeekHourScheduleHint? weekHourScheduleHint(
  List<WeekHourWindow> windows,
  int now, {
  required int? resetsAt,
  Duration tzOffset = Duration.zero,
  int candidateLimit = 6,
}) {
  if (windows.isEmpty || resetsAt == null || resetsAt <= now) return null;
  final candidates = <WeekHourScheduleHint>[];
  final limit = candidateLimit < 0 ? 0 : candidateLimit;
  for (final window in windows.take(limit)) {
    final scheduledAt = _nextWeekHourOccurrence(
      window,
      now,
      tzOffset: tzOffset,
    );
    if (scheduledAt >= resetsAt) continue;
    candidates.add(
      WeekHourScheduleHint(
        window: window,
        scheduledAt: scheduledAt,
        waitSeconds: scheduledAt - now,
        resetsAt: resetsAt,
      ),
    );
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final wait = a.scheduledAt.compareTo(b.scheduledAt);
    if (wait != 0) return wait;
    final score =
        b.window.scoreFreePercent.compareTo(a.window.scoreFreePercent);
    if (score != 0) return score;
    return b.window.samples.compareTo(a.window.samples);
  });
  return candidates.first;
}

class _WeekHourAggregates {
  final List<List<double>> sum;
  final List<List<int>> count;

  const _WeekHourAggregates(this.sum, this.count);
}

class _SmoothedWeekHourCell {
  final double meanFreePercent;
  final int supportSamples;
  final int supportCells;

  const _SmoothedWeekHourCell({
    required this.meanFreePercent,
    required this.supportSamples,
    required this.supportCells,
  });
}

_WeekHourAggregates _weekHourAggregates(
  Iterable<HeadroomBucket> buckets,
  Duration tzOffset,
) {
  final sum = List.generate(7, (_) => List<double>.filled(24, 0));
  final cnt = List.generate(7, (_) => List<int>.filled(24, 0));
  final off = tzOffset.inSeconds;
  for (final b in buckets) {
    if (b.count == 0) continue;
    final local = b.start + off;
    final day = (((local ~/ 86400) + 3) % 7);
    final hour = (local % 86400) ~/ 3600;
    sum[day][hour] += b.sum;
    cnt[day][hour] += b.count;
  }
  return _WeekHourAggregates(sum, cnt);
}

_SmoothedWeekHourCell? _smoothedCell(
  _WeekHourAggregates agg,
  int targetDay,
  int targetHour, {
  required int dayRadius,
  required int hourRadius,
  required double daySigma,
  required double hourSigma,
  required int minSupportSamples,
  required int minSupportCells,
}) {
  var weightedSum = 0.0;
  var weightTotal = 0.0;
  var supportSamples = 0;
  var supportCells = 0;

  for (var dd = -dayRadius; dd <= dayRadius; dd++) {
    final day = (targetDay + dd) % 7;
    final wrappedDay = day < 0 ? day + 7 : day;
    for (var dh = -hourRadius; dh <= hourRadius; dh++) {
      final hour = (targetHour + dh) % 24;
      final wrappedHour = hour < 0 ? hour + 24 : hour;
      final samples = agg.count[wrappedDay][wrappedHour];
      if (samples == 0) continue;
      final weight = math.exp(
        -0.5 *
            ((dd.abs() / daySigma) * (dd.abs() / daySigma) +
                (dh.abs() / hourSigma) * (dh.abs() / hourSigma)),
      );
      weightedSum += agg.sum[wrappedDay][wrappedHour] * weight;
      weightTotal += samples * weight;
      supportSamples += samples;
      supportCells++;
    }
  }

  if (weightTotal == 0 ||
      supportSamples < minSupportSamples ||
      supportCells < minSupportCells) {
    return null;
  }
  return _SmoothedWeekHourCell(
    meanFreePercent: weightedSum / weightTotal,
    supportSamples: supportSamples,
    supportCells: supportCells,
  );
}

int _nextWeekHourOccurrence(
  WeekHourWindow window,
  int now, {
  required Duration tzOffset,
}) {
  const weekSeconds = 7 * 86400;
  final offset = tzOffset.inSeconds;
  final localNow = now + offset;
  final currentHourStart = localNow - (localNow % 3600);
  final currentDay = (((currentHourStart ~/ 86400) + 3) % 7);
  final currentHour = (currentHourStart % 86400) ~/ 3600;
  final currentWeekHour = currentDay * 24 + currentHour;
  final targetWeekHour = (window.dayOfWeek % 7) * 24 + window.hour;
  var hoursAhead = targetWeekHour - currentWeekHour;
  if (hoursAhead < 0) hoursAhead += 7 * 24;
  var localTarget = currentHourStart + hoursAhead * 3600;
  var utcTarget = localTarget - offset;
  if (utcTarget < now) {
    localTarget += weekSeconds;
    utcTarget = localTarget - offset;
  }
  return utcTarget;
}

String _compactWait(int seconds) {
  if (seconds <= 0) return 'now';
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) return '${days}d${hours}h';
  if (hours > 0) return '${hours}h${minutes}m';
  return '${math.max(1, minutes)}m';
}

/// A forward-looking pace read for the current rolling window: how fast quota is
/// being spent and whether the user is on track to exhaust it early or leave it
/// unused before the reset. Pure result of [computePace].
class Pace {
  /// Percent of quota consumed per hour (>= 0).
  final double burnPerHour;

  /// Hours until headroom reaches zero at the current burn, null when not
  /// drawing down.
  final double? runwayHours;

  /// Projected percent used at the next reset (0..100), null when unknown.
  final double? projectedUsedAtReset;

  /// Hours the window is on track to run dry before its reset (> 0 means it
  /// will exhaust early), null when it will not exhaust.
  final double? hoursEarlyExhaust;

  /// Percent of quota on track to expire unused at reset, null when none.
  final double? wastedAtReset;

  /// One-line human read.
  final String verdict;

  const Pace({
    required this.burnPerHour,
    required this.runwayHours,
    required this.projectedUsedAtReset,
    required this.hoursEarlyExhaust,
    required this.wastedAtReset,
    required this.verdict,
  });

  Map<String, dynamic> toJson() => {
        'burn_percent_per_hour': double.parse(burnPerHour.toStringAsFixed(2)),
        'runway_hours': runwayHours,
        'projected_used_at_reset': projectedUsedAtReset,
        'hours_early_exhaust': hoursEarlyExhaust,
        'wasted_at_reset': wastedAtReset,
        'verdict': verdict,
      };
}

/// Projects the current rolling window forward. [headroom] is the live remaining
/// percent, [resetsAt] the binding window reset (epoch seconds, may be null),
/// [burnPerHour] the recent burn estimate, [now] the current epoch.
Pace? computePace({
  required double headroom,
  required int? resetsAt,
  required double? burnPerHour,
  required int now,
}) {
  if (burnPerHour == null) return null;
  final burn = burnPerHour < 0 ? 0.0 : burnPerHour;
  String fmtH(double h) {
    if (h < 1) return '${(h * 60).round()}m';
    final hh = h.floor();
    final mm = ((h - hh) * 60).round();
    return mm == 0 ? '${hh}h' : '${hh}h${mm}m';
  }

  if (burn < 0.2) {
    return const Pace(
      burnPerHour: 0,
      runwayHours: null,
      projectedUsedAtReset: null,
      hoursEarlyExhaust: null,
      wastedAtReset: null,
      verdict: 'steady; not drawing down right now',
    );
  }
  final runway = headroom / burn;
  if (resetsAt == null || resetsAt <= now) {
    return Pace(
      burnPerHour: burn,
      runwayHours: runway,
      projectedUsedAtReset: null,
      hoursEarlyExhaust: null,
      wastedAtReset: null,
      verdict: 'about ${fmtH(runway)} of runway at this pace',
    );
  }
  final toReset = (resetsAt - now) / 3600.0;
  final used = 100 - headroom;
  final projected = (used + burn * toReset).clamp(0.0, 100.0);
  if (runway < toReset) {
    final early = toReset - runway;
    return Pace(
      burnPerHour: burn,
      runwayHours: runway,
      projectedUsedAtReset: 100,
      hoursEarlyExhaust: early,
      wastedAtReset: null,
      verdict:
          'on pace to run dry ~${fmtH(early)} before reset; spread work or slow down',
    );
  }
  final wasted = 100 - projected;
  return Pace(
    burnPerHour: burn,
    runwayHours: runway,
    projectedUsedAtReset: projected,
    hoursEarlyExhaust: null,
    wastedAtReset: wasted,
    verdict:
        'on pace to use ${projected.round()}% by reset; ~${wasted.round()}% would expire unused',
  );
}

/// Cross-provider ("portfolio") read: which subscriptions you lean on and which
/// you barely touch, to spot ones worth downgrading or cancelling. Pure result
/// of [portfolioInsight].
class PortfolioInsight {
  /// Providers ranked by typical peak usage, heaviest first.
  final List<({String provider, double peakUsed, int spanDays})> ranked;

  /// Providers used so little over a meaningful span that a lower tier may do.
  final List<({String provider, double peakUsed})> underused;

  const PortfolioInsight({required this.ranked, required this.underused});

  ({String provider, double peakUsed, int spanDays})? get mostUsed =>
      ranked.isEmpty ? null : ranked.first;
  ({String provider, double peakUsed, int spanDays})? get leastUsed =>
      ranked.isEmpty ? null : ranked.last;

  Map<String, dynamic> toJson() => {
        'ranked': [
          for (final r in ranked)
            {
              'provider': r.provider,
              'typical_peak_used': r.peakUsed,
              'span_days': r.spanDays,
            },
        ],
        'underused': [
          for (final u in underused)
            {'provider': u.provider, 'typical_peak_used': u.peakUsed},
        ],
      };
}

/// Ranks metered providers by how hard they are typically pushed and flags ones
/// barely used. A provider counts as underused when its typical peak usage is
/// below [underusedPeak] percent and it has at least [minDays] of history (so a
/// brand-new account is not prematurely flagged).
PortfolioInsight portfolioInsight(
  Map<String, Insights> byProvider, {
  double underusedPeak = 25,
  int minDays = 7,
}) {
  final entries = <({String provider, double peakUsed, int spanDays})>[];
  byProvider.forEach((provider, ins) {
    final peak = ins.typicalPeakUsed;
    if (peak != null && ins.samples > 0) {
      entries.add((provider: provider, peakUsed: peak, spanDays: ins.spanDays));
    }
  });
  entries.sort((a, b) => b.peakUsed.compareTo(a.peakUsed));
  final underused = [
    for (final e in entries)
      if (e.peakUsed < underusedPeak && e.spanDays >= minDays)
        (provider: e.provider, peakUsed: e.peakUsed),
  ];
  return PortfolioInsight(ranked: entries, underused: underused);
}

/// A computed analytics summary for one provider over a window of buckets.
class Insights {
  final int samples;
  final int spanDays;
  final int sampledDays;
  final double? mean;
  final double? stddev;
  final double? p10;
  final double? p50;
  final double? p90;

  /// Fraction of samples that had any headroom left (1 - spent rate), 0..1.
  final double? reliability;

  /// Headroom drift in percent per day, with R squared confidence, when there
  /// are at least two days of data.
  final double? trendPerDay;
  final double? trendConfidence;

  /// Local hour of day (0..23) at which headroom is typically lowest, or null.
  final int? tightestHour;

  /// Local day of week (0 = Monday .. 6 = Sunday) that runs tightest, or null.
  final int? tightestDay;

  /// Consecutive sampled local days through the latest sample with no spent
  /// readings. Gaps or mixed days break the streak.
  final int usableDayStreak;

  /// Consecutive sampled local days through the latest sample where every
  /// reading was spent. Gaps or mixed days break the streak.
  final int spentDayStreak;

  /// Oldest-first sampled local days for compact contribution-calendar views.
  final List<ContributionDay> contributionCalendar;

  /// Highest-headroom sampled local weekday/hour windows for scheduling.
  final List<WeekHourWindow> bestTimeWindows;

  /// Recent burn rate in percent of quota per hour (>= 0), null when unknown.
  final double? burnPerHour;

  /// Standard error of [burnPerHour] (same units), null with fewer than three
  /// recent points where it is undefined. Carried so a consumer can turn the
  /// burn into a strand probability instead of a point estimate.
  final double? burnSePerHour;

  /// Typical peak usage per cycle: the 90th percentile of used percent
  /// (100 - p10 free). How high usage usually climbs.
  double? get typicalPeakUsed => p10 == null ? null : 100 - p10!;

  /// Typical unused headroom at the tight end (the p10 of free). Money left on
  /// the table if a cycle ends here.
  double? get typicalUnused => p10;

  const Insights({
    required this.samples,
    required this.spanDays,
    this.sampledDays = 0,
    this.mean,
    this.stddev,
    this.p10,
    this.p50,
    this.p90,
    this.reliability,
    this.trendPerDay,
    this.trendConfidence,
    this.tightestHour,
    this.tightestDay,
    this.usableDayStreak = 0,
    this.spentDayStreak = 0,
    this.contributionCalendar = const [],
    this.bestTimeWindows = const [],
    this.burnPerHour,
    this.burnSePerHour,
  });

  /// Computes insights from a provider's bucket series. [now] bounds the window
  /// and [tzOffset] localizes the hour-of-day profile (defaults to UTC).
  factory Insights.from(
    List<HeadroomBucket> buckets,
    int now, {
    Duration tzOffset = Duration.zero,
  }) {
    final used = buckets.where((b) => b.count > 0).toList();
    if (used.isEmpty) {
      return const Insights(samples: 0, spanDays: 0);
    }
    final agg = mergeBuckets(used);
    final earliest = used.map((b) => b.start).reduce(math.min);
    final spanDays = ((now - earliest) / 86400).ceil().clamp(1, kRetentionDays);
    final t = trend(dailyMeans(used));
    final tightest = _argMin(hourOfDayProfile(used, tzOffset: tzOffset));
    final tightestDay = _argMin(dayOfWeekProfile(used, tzOffset: tzOffset));
    final streaks = currentDayStreaks(used, tzOffset: tzOffset);
    final calendar = contributionCalendarDays(used, tzOffset: tzOffset);
    final bestTime = bestWeekHourWindows(used, tzOffset: tzOffset);
    final burn = burnRateWithError(used, now);
    return Insights(
      samples: agg.count,
      spanDays: spanDays,
      sampledDays: streaks.sampledDays,
      mean: agg.mean,
      stddev: agg.stddev,
      p10: percentile(agg, 10),
      p50: percentile(agg, 50),
      p90: percentile(agg, 90),
      reliability: 1 - (agg.exhausted / agg.count),
      trendPerDay: t?.slopePerDay,
      trendConfidence: t?.r2,
      tightestHour: tightest,
      tightestDay: tightestDay,
      usableDayStreak: streaks.usableDays,
      spentDayStreak: streaks.spentDays,
      contributionCalendar: calendar,
      bestTimeWindows: bestTime,
      burnPerHour: burn.perHour,
      burnSePerHour: burn.sePerHour,
    );
  }

  /// Index of the smallest non-null entry, or null when all are null.
  static int? _argMin(List<double?> values) {
    int? idx;
    double worst = double.infinity;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v != null && v < worst) {
        worst = v;
        idx = i;
      }
    }
    return idx;
  }

  Map<String, dynamic> toJson() => {
        'samples': samples,
        'span_days': spanDays,
        'sampled_days': sampledDays,
        'mean_free_percent': mean,
        'stddev': stddev,
        'p10_free': p10,
        'p50_free': p50,
        'p90_free': p90,
        'reliability': reliability,
        'trend_percent_per_day': trendPerDay,
        'trend_confidence_r2': trendConfidence,
        'tightest_hour_local': tightestHour,
        'tightest_day_local': tightestDay,
        'usable_day_streak': usableDayStreak,
        'spent_day_streak': spentDayStreak,
        'contribution_calendar':
            contributionCalendar.map((day) => day.toJson()).toList(),
        'best_time_windows':
            bestTimeWindows.map((window) => window.toJson()).toList(),
        'burn_percent_per_hour': burnPerHour,
        'burn_se_percent_per_hour': burnSePerHour,
        'typical_peak_used': typicalPeakUsed,
        'typical_unused': typicalUnused,
      };
}
