import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(String id, double usedPercent) => ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: [QuotaWindow(label: 'w', usedPercent: usedPercent)],
    );

HeadroomBucket _bucket(int start, double value) =>
    HeadroomBucket(start: start)..add(value);

void main() {
  group('burnRateWithError', () {
    test('a clean linear decline gives the slope with ~zero error', () {
      final buckets = [
        _bucket(_now - 3 * 3600, 100),
        _bucket(_now - 2 * 3600, 90),
        _bucket(_now - 1 * 3600, 80),
        _bucket(_now, 70),
      ];
      final s = burnRateWithError(buckets, _now);
      expect(s.perHour, closeTo(10, 1e-6)); // headroom falls 10/h -> burn +10
      expect(s.sePerHour, isNotNull);
      expect(s.sePerHour!, lessThan(1e-6));
      expect(s.samples, 4);
    });

    test('a noisy decline gives a positive standard error', () {
      final buckets = [
        _bucket(_now - 3 * 3600, 100),
        _bucket(_now - 2 * 3600, 86),
        _bucket(_now - 1 * 3600, 82),
        _bucket(_now, 70),
      ];
      final s = burnRateWithError(buckets, _now);
      expect(s.perHour, greaterThan(0));
      expect(s.sePerHour!, greaterThan(0));
    });

    test('fewer than three points leaves the error undefined', () {
      final s = burnRateWithError(
        [_bucket(_now - 3600, 100), _bucket(_now, 90)],
        _now,
      );
      expect(s.perHour, closeTo(10, 1e-6));
      expect(s.sePerHour, isNull);
      expect(s.samples, 2);
    });

    test('one point yields no burn at all', () {
      final s = burnRateWithError([_bucket(_now, 90)], _now);
      expect(s.perHour, isNull);
    });
  });

  group('shrinkBurnStats', () {
    test('pulls thin burn estimates toward the fleet mean', () {
      final shrunk = shrinkBurnStats(const {
        'thin': BurnStat(perHour: 30, samples: 2),
        'steady-a': BurnStat(perHour: 10, sePerHour: 0.5, samples: 20),
        'steady-b': BurnStat(perHour: 12, sePerHour: 0.5, samples: 20),
      });

      expect(shrunk['thin']!.perHour, lessThan(30));
      expect(shrunk['thin']!.perHour, greaterThan(10));
      expect(shrunk['thin']!.sePerHour, isNotNull);
      expect(shrunk['steady-a']!.perHour, closeTo(10.32, 0.05));
      expect(shrunk['steady-a']!.sePerHour, 0.5);
      expect(shrunk['steady-a']!.samples, 20);
    });

    test('does not invent burn without a fitted slope or pool', () {
      final noPool = shrinkBurnStats(const {
        'a': BurnStat(perHour: 30, samples: 2),
        'b': BurnStat(perHour: 10, samples: 20),
      });
      expect(noPool['a']!.perHour, 30);

      final withNull = shrinkBurnStats(const {
        'none': BurnStat(samples: 1),
        'a': BurnStat(perHour: 30, samples: 2),
        'b': BurnStat(perHour: 10, samples: 20),
        'c': BurnStat(perHour: 12, samples: 20),
      });
      expect(withNull['none']!.perHour, isNull);
      expect(withNull['none']!.samples, 1);
    });
  });

  group('contributionCalendarDays', () {
    test('groups sampled local days oldest first with compact markers', () {
      final days = contributionCalendarDays([
        _bucket(_now - 2 * Duration.secondsPerDay, 95),
        _bucket(_now - Duration.secondsPerDay, 60),
        _bucket(_now, 0),
      ]);

      expect(days, hasLength(3));
      expect(days.map((day) => day.state).toList(), [
        'usable',
        'usable',
        'spent',
      ]);
      expect(contributionCalendarMarkers(days), '.+x');
      expect(days.last.toJson()['intensity'], 4);
    });

    test('marks mixed days and caps to the requested recent window', () {
      final mixed = HeadroomBucket(start: _now - Duration.secondsPerDay)
        ..add(0)
        ..add(80);
      final days = contributionCalendarDays(
        [
          _bucket(_now - 2 * Duration.secondsPerDay, 90),
          mixed,
          _bucket(_now, 40),
        ],
        maxDays: 2,
      );

      expect(days, hasLength(2));
      expect(days.first.state, 'mixed');
      expect(contributionCalendarMarkers(days), '!*');
      expect(contributionCalendarMarkers(days, maxDays: 1), '*');
    });
  });

  group('bestWeekHourWindows', () {
    test('prefers the freest supported local weekday-hour cells', () {
      final supported = HeadroomBucket(start: 0)
        ..add(80)
        ..add(70);
      final sparseHigh = HeadroomBucket(start: 13 * Duration.secondsPerHour)
        ..add(95);
      final supportedLow = HeadroomBucket(start: Duration.secondsPerHour)
        ..add(40)
        ..add(50);

      final best = bestWeekHourWindows([
        sparseHigh,
        supportedLow,
        supported,
      ]);

      expect(best, hasLength(2));
      expect(best.first.dayLabel, 'Thu');
      expect(best.first.hour, 0);
      expect(best.first.samples, 2);
      expect(best.first.meanFreePercent, closeTo(75, 0.001));
      expect(best.first.smoothedFreePercent, isNotNull);
      expect(best.first.supportSamples, 4);
      expect(
        best.first.summary,
        startsWith('Thu 00:00 (~'),
      );
      expect(best.first.toJson()['label'], 'Thu 00:00');
      expect(best.first.toJson()['smoothed_free_percent'], isA<double>());
      expect(best.first.toJson()['usable_rate'], 1);
      expect(best.first.toJson()['shrunk_usable_rate'], 1);
      expect(best.first.toJson()['scheduling_score'], isA<double>());
    });

    test('falls back to sparse cells when no cell meets the sample floor', () {
      final best = bestWeekHourWindows([
        _bucket(13 * Duration.secondsPerHour, 95),
      ]);

      expect(best, hasLength(1));
      expect(best.single.hour, 13);
      expect(best.single.meanFreePercent, closeTo(95, 0.001));
      expect(best.single.smoothedFreePercent, isNull);
    });

    test('ranks smoothed supported neighborhoods before isolated highs', () {
      final isolatedHigh = HeadroomBucket(start: 13 * Duration.secondsPerHour)
        ..add(99)
        ..add(99);
      final clusterLate = HeadroomBucket(start: 23 * Duration.secondsPerHour)
        ..add(80)
        ..add(80);
      final clusterNextDay = HeadroomBucket(start: 24 * Duration.secondsPerHour)
        ..add(70)
        ..add(70);

      final best = bestWeekHourWindows([
        isolatedHigh,
        clusterNextDay,
        clusterLate,
      ], limit: 1);

      expect(best.single.timeLabel, 'Thu 23:00');
      expect(best.single.smoothedFreePercent, closeTo(78, 1));
      expect(best.single.supportSamples, 4);
    });

    test('uses shrunk usable rate to demote risky quiet cells', () {
      final riskyHigh = HeadroomBucket(start: 0)
        ..add(100)
        ..add(100)
        ..add(40)
        ..add(0);
      final steady = HeadroomBucket(start: Duration.secondsPerHour)
        ..add(58)
        ..add(58)
        ..add(58)
        ..add(58);
      final steadyNeighbor = HeadroomBucket(start: 2 * Duration.secondsPerHour)
        ..add(58)
        ..add(58)
        ..add(58)
        ..add(58);

      final best = bestWeekHourWindows([
        riskyHigh,
        steady,
        steadyNeighbor,
      ], limit: 1);

      expect(best.single.timeLabel, 'Thu 01:00');
      expect(best.single.shrunkUsableRate, greaterThan(0.9));
      expect(best.single.schedulingScore, greaterThan(54));
    });

    test('schedules the next strong slot before reset', () {
      const windows = [
        WeekHourWindow(
          dayOfWeek: 3,
          hour: 2,
          samples: 3,
          meanFreePercent: 80,
          smoothedFreePercent: 78,
          supportSamples: 5,
          supportCells: 2,
        ),
        WeekHourWindow(
          dayOfWeek: 3,
          hour: 5,
          samples: 3,
          meanFreePercent: 90,
          smoothedFreePercent: 88,
          supportSamples: 5,
          supportCells: 2,
        ),
      ];

      final hint = weekHourScheduleHint(
        windows,
        0,
        resetsAt: 3 * Duration.secondsPerHour,
      );

      expect(hint, isNotNull);
      expect(hint!.scheduledAt, 2 * Duration.secondsPerHour);
      expect(hint.waitSeconds, 2 * Duration.secondsPerHour);
      expect(hint.summary, contains('Thu 02:00 in 2h0m'));
      expect(hint.toJson()['window'], isA<Map<String, dynamic>>());
    });

    test('does not schedule at or after the reset boundary', () {
      const windows = [
        WeekHourWindow(
          dayOfWeek: 3,
          hour: 2,
          samples: 3,
          meanFreePercent: 80,
        ),
      ];

      expect(
        weekHourScheduleHint(
          windows,
          0,
          resetsAt: 2 * Duration.secondsPerHour,
        ),
        isNull,
      );
    });
  });

  group('riskAdjustedHeadroom', () {
    test('z=0 is the risk-neutral mean (today behavior)', () {
      expect(riskAdjustedHeadroom(100, 10, 2, 1, 0), 90);
    });
    test('z>0 subtracts z standard deviations of forecast error', () {
      expect(riskAdjustedHeadroom(100, 10, 2, 1, 1), 88);
      expect(riskAdjustedHeadroom(100, 10, 2, 2, 1), 100 - 20 - 4);
    });
    test('clamps to 0..100 and ignores a null/easing burn for the mean', () {
      expect(riskAdjustedHeadroom(5, 10, 2, 1, 0), 0);
      expect(riskAdjustedHeadroom(100, null, null, 1, 1), 100);
    });
  });

  group('strandProbability', () {
    test('rises as headroom thins relative to burn', () {
      final safe = strandProbability(20, 10, 2, _now + 3600, _now)!;
      final risky = strandProbability(5, 10, 2, _now + 3600, _now)!;
      expect(safe, lessThan(0.1));
      expect(risky, greaterThan(0.9));
    });
    test('is null without burn, error, or a future reset', () {
      expect(strandProbability(50, null, 2, _now + 3600, _now), isNull);
      expect(strandProbability(50, 10, null, _now + 3600, _now), isNull);
      expect(strandProbability(50, 10, 2, null, _now), isNull);
      expect(strandProbability(50, 10, 2, _now - 10, _now), isNull);
    });
  });

  group('suggestRoute risk awareness', () {
    // A: 30% free, burn 10/h, tiny error. B: 32% free, burn 10/h, big error.
    final providers = [_q('a', 70), _q('b', 68)];
    const stats = {
      'a': BurnStat(perHour: 10, sePerHour: 0.5, samples: 10),
      'b': BurnStat(perHour: 10, sePerHour: 8, samples: 10),
    };

    test('z=0 ranks on the mean: B (more raw headroom) wins', () {
      final s = suggestRoute(providers, _now, burnStatsByProvider: stats);
      expect(s.recommended?.provider, 'b');
      expect(s.riskZ, 0);
    });

    test('z>0 prefers the lower-uncertainty A', () {
      final s = suggestRoute(
        providers,
        _now,
        burnStatsByProvider: stats,
        riskZ: 1,
      );
      expect(s.recommended?.provider, 'a');
    });

    test('candidates carry burn error, strand, and confidence', () {
      final s = suggestRoute(
        [
          ProviderQuota(
            provider: 'a',
            displayName: 'a',
            account: 'a',
            asOf: _now,
            windows: [
              QuotaWindow(label: 'w', usedPercent: 70, resetsAt: _now + 3600),
            ],
          ),
        ],
        _now,
        burnStatsByProvider: const {
          'a': BurnStat(perHour: 10, sePerHour: 1, samples: 12),
        },
      );
      final c = s.ranked.first;
      expect(c.burnSe, 1);
      expect(c.strandProbability, isNotNull);
      expect(c.confidence, closeTo(12 / 16, 1e-9)); // fresh * 12/(12+4)
    });

    test('account-scoped burn stats are preferred over provider fallback', () {
      final s = suggestRoute(
        [
          ProviderQuota(
            provider: 'claude',
            displayName: 'Claude',
            account: 'work',
            asOf: _now,
            windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
          ),
        ],
        _now,
        burnStatsByProvider: {
          'claude': const BurnStat(perHour: 20, samples: 4),
          quotaIdentityKey('claude', 'work'):
              const BurnStat(perHour: 2, samples: 4),
        },
      );

      expect(s.ranked.single.burnPerHour, 2);
    });

    test('a stale read is trusted less than a fresh one', () {
      final fresh = suggestRoute(
        [_q('a', 70)],
        _now,
        burnStatsByProvider: const {
          'a': BurnStat(perHour: 5, sePerHour: 1, samples: 10),
        },
      ).ranked.first.confidence!;
      final staleQ = ProviderQuota(
        provider: 'a',
        displayName: 'a',
        account: 'a',
        asOf: _now,
        stale: true,
        windows: [QuotaWindow(label: 'w', usedPercent: 30)],
      );
      final cached = suggestRoute(
        [staleQ],
        _now,
        burnStatsByProvider: const {
          'a': BurnStat(perHour: 5, sePerHour: 1, samples: 10),
        },
      ).ranked.first.confidence!;
      expect(cached, lessThan(fresh));
    });

    test('the payload carries provenance (as_of, risk_z)', () {
      final json = suggestRoute([_q('a', 70)], _now, riskZ: 1.5).toJson();
      expect(json['as_of'], _now);
      expect(json['risk_z'], 1.5);
    });
  });
}
