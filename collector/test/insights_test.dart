import 'dart:convert';

import 'package:quotabot_collector/insights.dart';
import 'package:test/test.dart';

void main() {
  group('contribution calendar legend', () {
    ContributionDay day(double meanFree, int samples, int spentSamples) =>
        ContributionDay(
          dayStart: 0,
          samples: samples,
          meanFreePercent: meanFree,
          spentSamples: spentSamples,
        );

    test('every glyph a day can emit has exactly one legend entry', () {
      // Cover each branch of ContributionDay.marker so the legend can never
      // drift from the glyphs a surface actually prints.
      final emitted = {
        day(90, 4, 0).marker, // . light
        day(65, 4, 0).marker, // + moderate
        day(40, 4, 0).marker, // * moderate-high
        day(10, 4, 0).marker, // # heavy
        day(50, 4, 2).marker, // ! mixed
        day(0, 4, 4).marker, // x spent
      };
      final legendGlyphs = kContributionCalendarLegend.map((e) => e.$1).toSet();
      expect(emitted, equals(legendGlyphs));
      expect(kContributionCalendarLegend.length, legendGlyphs.length,
          reason: 'no duplicate glyphs in the legend');
    });
  });

  group('HeadroomBucket', () {
    test('add accumulates mean, extremes, and exhausted count', () {
      final b = HeadroomBucket(start: 0);
      for (final h in [100.0, 50.0, 0.0]) {
        b.add(h);
      }
      expect(b.count, 3);
      expect(b.mean, closeTo(50, 0.001));
      expect(b.min, 0);
      expect(b.max, 100);
      expect(b.exhausted, 1); // only the 0.0 sample is spent
    });

    test('counts rounded-one-percent headroom as exhausted', () {
      final b = HeadroomBucket(start: 0)..add(1.4);

      expect(b.exhausted, 1);
    });

    test('stddev is zero for identical samples and positive otherwise', () {
      final flat = HeadroomBucket(start: 0)
        ..add(40)
        ..add(40);
      expect(flat.stddev, closeTo(0, 0.001));
      final spread = HeadroomBucket(start: 0)
        ..add(0)
        ..add(100);
      expect(spread.stddev, closeTo(50, 0.001));
    });

    test('round-trips through json', () {
      final b = HeadroomBucket(start: 3600)
        ..add(80)
        ..add(20);
      final back = HeadroomBucket.fromJson(b.toJson());
      expect(back.start, 3600);
      expect(back.count, 2);
      expect(back.mean, closeTo(50, 0.001));
      expect(back.max, 80);
    });

    test('fromJson normalizes a wrong-length histogram to kHistBins', () {
      // A short array (a corrupt file or a future change to kHistBins) must not
      // make add() index out of range or silently keep the wrong length.
      final short = HeadroomBucket.fromJson({
        's': 3600,
        'n': 1,
        'sum': 50.0,
        'sq': 2500.0,
        'h': [1, 2],
      });
      expect(short.hist.length, kHistBins);
      expect(short.hist.take(2), [1, 2]);
      expect(() => short.add(95), returnsNormally);

      final long = HeadroomBucket.fromJson({
        's': 3600,
        'h': List<int>.filled(kHistBins + 5, 1),
      });
      expect(long.hist.length, kHistBins);
    });

    test('fromJson sanitizes non-finite and negative fields from a bad file',
        () {
      // A corrupt or hostile cache file: 1e400 decodes to Infinity, which would
      // otherwise make the mean Infinity and throw when the analytics are later
      // serialized, or throw directly in .toInt().
      final b = HeadroomBucket.fromJson({
        's': 3600,
        'n': double.infinity,
        'sum': double.infinity,
        'sq': double.nan,
        'min': double.nan,
        'max': double.infinity,
        'x': -5,
        'h': [double.infinity, -3, 4],
      });
      expect(b.mean.isFinite, isTrue);
      expect(b.stddev.isFinite, isTrue);
      expect(b.count, 0);
      expect(b.exhausted, 0);
      expect(b.hist.length, kHistBins);
      expect(b.hist.take(3), [0, 0, 4]);
      // The whole analytics path must be JSON-encodable, not just this bucket.
      expect(
        () => jsonEncode(Insights.from([b], 7200).toJson()),
        returnsNormally,
      );
    });
  });

  group('mergeBuckets', () {
    test('sums counts and histograms', () {
      final a = HeadroomBucket(start: 0)..add(90);
      final b = HeadroomBucket(start: 3600)..add(10);
      final m = mergeBuckets([a, b]);
      expect(m.count, 2);
      expect(m.min, 10);
      expect(m.max, 90);
      expect(m.start, 0); // earliest
    });

    test('empty input yields a zero-count aggregate', () {
      expect(mergeBuckets(const []).count, 0);
    });
  });

  group('percentile', () {
    test('median of a uniform 0..100 spread is near 50', () {
      final b = HeadroomBucket(start: 0);
      for (var h = 0; h <= 100; h += 5) {
        b.add(h.toDouble());
      }
      expect(percentile(b, 50), closeTo(50, 7));
      expect(percentile(b, 10), lessThan(percentile(b, 90)!));
    });

    test('is null with no samples', () {
      expect(percentile(HeadroomBucket(start: 0), 50), isNull);
    });
  });

  group('trend', () {
    test('detects a steady decline with high confidence', () {
      final series = [
        (day: 0, mean: 100.0),
        (day: 86400, mean: 90.0),
        (day: 172800, mean: 80.0),
        (day: 259200, mean: 70.0),
      ];
      final t = trend(series)!;
      expect(t.slopePerDay, closeTo(-10, 0.001));
      expect(t.r2, closeTo(1, 0.001));
    });

    test('is null with fewer than two days', () {
      expect(trend([(day: 0, mean: 50.0)]), isNull);
    });
  });

  group('currentDayStreaks', () {
    test('counts usable days through the latest contiguous sampled day', () {
      final buckets = [
        HeadroomBucket(start: 0)..add(0),
        HeadroomBucket(start: 86400)..add(80),
        HeadroomBucket(start: 2 * 86400)..add(60),
        HeadroomBucket(start: 2 * 86400 + 3600)..add(50),
      ];
      final streaks = currentDayStreaks(buckets);
      expect(streaks.sampledDays, 3);
      expect(streaks.usableDays, 2);
      expect(streaks.spentDays, 0);
    });

    test('counts spent days and stops both streaks on gaps or mixed days', () {
      final mixed = currentDayStreaks([
        HeadroomBucket(start: 0)..add(80),
        HeadroomBucket(start: 2 * 86400)
          ..add(0)
          ..add(40),
      ]);
      expect(mixed.sampledDays, 2);
      expect(mixed.usableDays, 0);
      expect(mixed.spentDays, 0);

      final spent = currentDayStreaks([
        HeadroomBucket(start: 0)..add(90),
        HeadroomBucket(start: 86400)..add(0),
        HeadroomBucket(start: 2 * 86400)..add(0),
      ]);
      expect(spent.usableDays, 0);
      expect(spent.spentDays, 2);
    });
  });

  group('hourOfDayProfile', () {
    test('buckets headroom by local hour', () {
      // Two samples in hour 0 (low) and hour 12 (high), UTC.
      final buckets = [
        HeadroomBucket(start: 0)..add(10),
        HeadroomBucket(start: 12 * 3600)..add(90),
      ];
      final p = hourOfDayProfile(buckets);
      expect(p[0], closeTo(10, 0.001));
      expect(p[12], closeTo(90, 0.001));
      expect(p[5], isNull);
    });
  });

  group('burnRatePerHour', () {
    test('positive when headroom is falling', () {
      final now = 10 * 3600;
      final buckets = [
        for (var i = 0; i < 6; i++)
          HeadroomBucket(start: (4 + i) * 3600)..add(100.0 - i * 5),
      ];
      final burn = burnRatePerHour(buckets, now);
      expect(burn, isNotNull);
      expect(burn, closeTo(5, 0.001)); // 5% per hour
    });

    test('null with too little recent data', () {
      expect(
        burnRatePerHour([HeadroomBucket(start: 0)..add(50)], 3600),
        isNull,
      );
    });

    test('non-positive when headroom recovers', () {
      // A provider whose reported usage drops without a reset (Grok can revise
      // its shared weekly pool percent downward mid-window) reads as rising
      // headroom. Burn must be treated as recovery, never as consumption, so
      // it cannot fabricate a strand risk from a usage decrease.
      final now = 10 * 3600;
      final buckets = [
        for (var i = 0; i < 6; i++)
          HeadroomBucket(start: (4 + i) * 3600)..add(0.0 + i * 5),
      ];
      final burn = burnRatePerHour(buckets, now);
      expect(burn, isNotNull);
      expect(burn, lessThanOrEqualTo(0));
    });
  });

  group('computePace', () {
    test('warns when on track to exhaust before reset', () {
      final now = 0;
      final pace = computePace(
        headroom: 20,
        resetsAt: 5 * 3600,
        burnPerHour: 10,
        now: now,
      );
      expect(pace, isNotNull);
      expect(pace!.hoursEarlyExhaust, isNotNull); // runway 2h < 5h to reset
      expect(pace.verdict, contains('run dry'));
    });

    test('reports projected waste when pace is under budget', () {
      final now = 0;
      final pace = computePace(
        headroom: 90,
        resetsAt: 10 * 3600,
        burnPerHour: 2,
        now: now,
      );
      // used 10 + 2*10 = 30 projected -> 70 wasted
      expect(pace!.projectedUsedAtReset, closeTo(30, 0.001));
      expect(pace.wastedAtReset, closeTo(70, 0.001));
      expect(pace.verdict, contains('expire unused'));
    });

    test('reports steady when not drawing down', () {
      final pace = computePace(
        headroom: 80,
        resetsAt: 3600,
        burnPerHour: 0.05,
        now: 0,
      );
      expect(pace!.burnPerHour, 0);
      expect(pace.verdict, contains('steady'));
    });

    test('is null without a burn estimate', () {
      expect(
        computePace(headroom: 50, resetsAt: 100, burnPerHour: null, now: 0),
        isNull,
      );
    });
  });

  group('portfolioInsight', () {
    Insights insightsWithPeak(double peakUsed, int spanDays) {
      // p10 free = 100 - peakUsed; build a bucket series that yields it.
      final freeP10 = 100 - peakUsed;
      final buckets = <HeadroomBucket>[];
      for (var d = 0; d < spanDays; d++) {
        buckets.add(HeadroomBucket(start: d * 86400)..add(freeP10));
      }
      return Insights.from(buckets, spanDays * 86400);
    }

    test('ranks heaviest first and flags an underused provider', () {
      final p = portfolioInsight({
        'claude': insightsWithPeak(85, 30), // heavily used
        'grok': insightsWithPeak(12, 30), // barely used, long span
        'codex': insightsWithPeak(50, 30),
      });
      expect(p.mostUsed!.provider, 'claude');
      expect(p.leastUsed!.provider, 'grok');
      expect(p.underused.map((u) => u.provider), contains('grok'));
      expect(p.underused.map((u) => u.provider), isNot(contains('codex')));
    });

    test('does not flag a barely-used but brand-new account', () {
      final p = portfolioInsight({
        'grok': insightsWithPeak(5, 2), // low use but only 2 days of history
      });
      expect(p.underused, isEmpty);
    });

    test('is empty without data', () {
      expect(portfolioInsight({}).ranked, isEmpty);
      expect(portfolioInsight({}).mostUsed, isNull);
    });
  });

  group('tierFitAnalysis', () {
    test('recommends the cheapest explicit plan under breach risk', () {
      final bucket = HeadroomBucket(start: 0);
      for (var i = 0; i < 18; i++) {
        bucket.add(60); // 40% used fits a half-size plan.
      }
      for (var i = 0; i < 2; i++) {
        bucket.add(30); // 70% used breaches a half-size plan.
      }

      final fit = tierFitAnalysis(
        [bucket],
        const [
          TierPlanOption(
            name: 'Starter',
            capPercentOfCurrent: 30,
            monthlyPrice: 5,
          ),
          TierPlanOption(
            name: 'Lite',
            capPercentOfCurrent: 50,
            monthlyPrice: 10,
          ),
          TierPlanOption(
            name: 'Current',
            capPercentOfCurrent: 100,
            monthlyPrice: 20,
          ),
        ],
        currentMonthlyPrice: 20,
        maxBreachProbability: 0.15,
      );

      expect(fit.sampleCount, 20);
      expect(fit.recommended?.name, 'Lite');
      expect(fit.recommended?.breachProbability, closeTo(0.1, 0.001));
      expect(fit.recommended?.monthlyDelta, -10);
      final starter =
          fit.options.firstWhere((option) => option.name == 'Starter');
      expect(starter.meetsRiskTolerance, isFalse);
    });

    test('does not recommend a tier without history', () {
      final fit = tierFitAnalysis(
        const [],
        const [TierPlanOption(name: 'Lite', capPercentOfCurrent: 50)],
      );

      expect(fit.sampleCount, 0);
      expect(fit.recommended, isNull);
      expect(fit.options.single.meetsRiskTolerance, isFalse);
    });
  });

  group('weekHourHeatmap', () {
    test('places samples in the right weekday and hour cells', () {
      // 1970-01-01 00:00 UTC is a Thursday (row index 3), hour 0.
      final grid = weekHourHeatmap([
        HeadroomBucket(start: 0)..add(80), // Thu 00:00
        HeadroomBucket(start: 13 * 3600)..add(40), // Thu 13:00
      ]);
      expect(grid.length, 7);
      expect(grid[0].length, 24);
      expect(grid[3][0], closeTo(80, 0.001));
      expect(grid[3][13], closeTo(40, 0.001));
      expect(grid[3][5], isNull);
      expect(grid[0][0], isNull); // Monday untouched
    });

    test('smoothed heatmap wraps weekday and hour neighbors', () {
      // Sunday 23:00 and Monday 00:00 are adjacent on the local week/hour torus.
      final sunday23 = 3 * 86400 + 23 * 3600;
      final monday00 = 4 * 86400;
      final grid = smoothedWeekHourHeatmap([
        HeadroomBucket(start: sunday23)
          ..add(90)
          ..add(90),
        HeadroomBucket(start: monday00)
          ..add(70)
          ..add(70),
      ]);

      expect(grid[6][23], closeTo(85, 1));
      expect(grid[0][0], closeTo(75, 1));
      expect(grid[3][12], isNull);
    });

    test('weekday-hour windows carry beta-binomial usable-rate shrinkage', () {
      final thinSpent = HeadroomBucket(start: 0)
        ..add(0)
        ..add(100);
      final steadyA = HeadroomBucket(start: 3600)
        ..add(80)
        ..add(80)
        ..add(80)
        ..add(80);
      final steadyB = HeadroomBucket(start: 7200)
        ..add(70)
        ..add(70)
        ..add(70)
        ..add(70);

      final windows = weekHourWindows([thinSpent, steadyA, steadyB]);
      final thin = windows.firstWhere((window) => window.hour == 0);
      final steady = windows.firstWhere((window) => window.hour == 1);

      expect(thin.usableRate, 0.5);
      expect(thin.shrunkUsableRate, closeTo(0.767, 0.001));
      expect(steady.usableRate, 1);
      expect(steady.shrunkUsableRate, closeTo(0.95, 0.01));
      expect(thin.toJson()['shrunk_usable_rate'], isA<double>());
    });
  });

  group('shrinkInsightsReliability', () {
    test('pulls thin reliability rates toward the fleet rate', () {
      final shrunk = shrinkInsightsReliability(const {
        'thin': Insights(samples: 2, spanDays: 1, reliability: 0),
        'steady-a': Insights(samples: 20, spanDays: 10, reliability: 0.8),
        'steady-b': Insights(samples: 20, spanDays: 10, reliability: 0.9),
      });

      expect(shrunk['thin']!.reliability, greaterThan(0.5));
      expect(shrunk['thin']!.reliability, lessThan(0.6));
      expect(shrunk['steady-a']!.reliability, closeTo(0.802, 0.002));
      expect(shrunk['steady-a']!.samples, 20);
    });

    test('does not invent reliability without a rate or pool', () {
      final noPool = shrinkInsightsReliability(const {
        'a': Insights(samples: 2, spanDays: 1, reliability: 0),
        'b': Insights(samples: 20, spanDays: 10, reliability: 0.8),
      });
      expect(noPool['a']!.reliability, 0);

      final withNull = shrinkInsightsReliability(const {
        'none': Insights(samples: 1, spanDays: 1),
        'a': Insights(samples: 2, spanDays: 1, reliability: 0),
        'b': Insights(samples: 20, spanDays: 10, reliability: 0.8),
        'c': Insights(samples: 20, spanDays: 10, reliability: 0.9),
      });
      expect(withNull['none']!.reliability, isNull);
      expect(withNull['none']!.samples, 1);
    });
  });

  group('Insights.from', () {
    test('summarizes a multi-day declining series', () {
      final now = 4 * 86400;
      final buckets = <HeadroomBucket>[];
      for (var day = 0; day < 4; day++) {
        buckets.add(HeadroomBucket(start: day * 86400)..add(100.0 - day * 10));
      }
      final ins = Insights.from(buckets, now);
      expect(ins.samples, 4);
      expect(ins.sampledDays, 4);
      expect(ins.mean, closeTo(85, 0.001)); // (100+90+80+70)/4
      expect(ins.trendPerDay, lessThan(0)); // declining
      expect(ins.reliability, 1); // never spent
      expect(ins.usableDayStreak, 4);
      expect(ins.spentDayStreak, 0);
      expect(ins.spanDays, inInclusiveRange(4, 5));
      expect(ins.toJson()['sampled_days'], 4);
      expect(ins.toJson()['usable_day_streak'], 4);
    });

    test('reports zero samples for an empty series', () {
      final ins = Insights.from(const [], 1000);
      expect(ins.samples, 0);
      expect(ins.mean, isNull);
    });

    test('reliability drops when samples are spent', () {
      final b = HeadroomBucket(start: 0)
        ..add(0) // spent
        ..add(0) // spent
        ..add(100);
      final ins = Insights.from([b], 86400);
      expect(ins.reliability, closeTo(1 / 3, 0.001));
    });
  });
}
