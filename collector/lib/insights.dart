import 'dart:math' as math;

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
}) {
  final cutoff = now - lookbackHours * 3600;
  final recent =
      buckets.where((b) => b.count > 0 && b.start >= cutoff).toList();
  if (recent.length < 2) return null;
  final x0 = recent.first.start;
  var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
  final n = recent.length;
  for (final b in recent) {
    final x = (b.start - x0) / 3600.0;
    final y = b.mean;
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
  }
  final denom = n * sxx - sx * sx;
  if (denom == 0) return null;
  final slope = (n * sxy - sx * sy) / denom;
  return -slope; // headroom falling -> positive burn
}

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
  final sum = List.generate(7, (_) => List<double>.filled(24, 0));
  final cnt = List.generate(7, (_) => List<int>.filled(24, 0));
  final off = tzOffset.inSeconds;
  for (final b in buckets) {
    if (b.count == 0) continue;
    final local = b.start + off;
    final day = (((local ~/ 86400) + 3) % 7); // 1970-01-01 was a Thursday
    final hour = (local % 86400) ~/ 3600;
    sum[day][hour] += b.sum;
    cnt[day][hour] += b.count;
  }
  return List.generate(
    7,
    (d) => List<double?>.generate(
      24,
      (h) => cnt[d][h] == 0 ? null : sum[d][h] / cnt[d][h],
    ),
  );
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

  /// Recent burn rate in percent of quota per hour (>= 0), null when unknown.
  final double? burnPerHour;

  /// Typical peak usage per cycle: the 90th percentile of used percent
  /// (100 - p10 free). How high usage usually climbs.
  double? get typicalPeakUsed => p10 == null ? null : 100 - p10!;

  /// Typical unused headroom at the tight end (the p10 of free). Money left on
  /// the table if a cycle ends here.
  double? get typicalUnused => p10;

  const Insights({
    required this.samples,
    required this.spanDays,
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
    this.burnPerHour,
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
    return Insights(
      samples: agg.count,
      spanDays: spanDays,
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
      burnPerHour: burnRatePerHour(used, now),
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
        'burn_percent_per_hour': burnPerHour,
        'typical_peak_used': typicalPeakUsed,
        'typical_unused': typicalUnused,
      };
}
