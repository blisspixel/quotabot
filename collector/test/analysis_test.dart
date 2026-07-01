import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(
  String id,
  List<QuotaWindow> windows, {
  bool stale = false,
  String kind = 'subscription',
  String? source,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: windows,
      stale: stale,
      kind: kind,
      source: source,
    );

// A local runtime carries no quota windows; it is available simply by running.
ProviderQuota _local(String id) => _q(id, const [], kind: 'local');

void main() {
  test('providerHeadroom is governed by the most constrained window', () {
    final q = _q('codex', [
      QuotaWindow(label: '5h', usedPercent: 10),
      QuotaWindow(label: 'weekly', usedPercent: 70),
    ]);
    expect(providerHeadroom(q, _now), 30); // 100 - 70
  });

  test('anyProviderUsable reflects whether there is anywhere to route', () {
    expect(anyProviderUsable(const [], _now), isFalse);
    final spent = _q('codex', [QuotaWindow(label: '5h', usedPercent: 100)]);
    expect(anyProviderUsable([spent], _now), isFalse);
    final healthy =
        _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]);
    expect(anyProviderUsable([spent, healthy], _now), isTrue);
    // A running local runtime is a usable fallback even with everything spent.
    expect(anyProviderUsable([spent, _local('ollama')], _now), isTrue);
  });

  test('window helpers treat reached resets as fresh', () {
    final w = QuotaWindow(label: '5h', usedPercent: 100, resetsAt: _now);
    expect(windowHasRolledOver(w, _now), isTrue);
    expect(windowUsedPercent(w, _now), 0);
    expect(windowHeadroom(w, _now), 100);
  });

  test('providerHeadroom treats a passed or reached reset as fresh', () {
    final q = _q('codex', [
      QuotaWindow(label: '5h', usedPercent: 100, resetsAt: _now),
    ]);
    expect(providerHeadroom(q, _now), 100);
    final availability = providerAvailability(q, _now);
    expect(availability.available, isTrue);
    expect(bindingWindow(q, _now), isNull);
  });

  test('providerHeadroom is null without windows', () {
    expect(providerHeadroom(_q('grok', const []), _now), isNull);
  });

  test('providerWithMostHeadroom picks the freest live provider', () {
    final best = providerWithMostHeadroom([
      _q('codex', [QuotaWindow(label: 'w', usedPercent: 90)]),
      _q('claude', [QuotaWindow(label: 'w', usedPercent: 20)]),
      _q('grok', const []), // no live data, ignored
    ], _now);
    expect(best?.provider, 'claude');
  });

  test('providerWithMostHeadroom is null when none are live', () {
    expect(providerWithMostHeadroom([_q('grok', const [])], _now), isNull);
  });

  test('providerAvailability reports usable and binding reset', () {
    final q = _q('codex', [
      QuotaWindow(label: '5h', usedPercent: 30, resetsAt: _now + 3600),
      QuotaWindow(label: 'weekly', usedPercent: 100, resetsAt: _now + 86400),
    ]);
    final a = providerAvailability(q, _now);
    expect(a.available, isFalse); // weekly is spent
    expect(a.headroom, 0);
    expect(a.resetsAt, _now + 86400);
  });

  test('providerAvailability handles no windows', () {
    final a = providerAvailability(_q('grok', const []), _now);
    expect(a.available, isFalse);
    expect(a.headroom, isNull);
  });

  test('bindingWindow returns the most constrained window', () {
    final q = _q('codex', [
      QuotaWindow(label: '5h', usedPercent: 10),
      QuotaWindow(label: 'weekly', usedPercent: 80),
    ]);
    final b = bindingWindow(q, _now);
    expect(b?.label, 'weekly');
  });

  test('bindingWindow returns null with no windows', () {
    expect(bindingWindow(_q('grok', const []), _now), isNull);
  });

  test('providerWithMostHeadroom excludes local runtimes', () {
    final best = providerWithMostHeadroom([
      _local('ollama'), // 100% but local, must not win
      _q('claude', [QuotaWindow(label: 'w', usedPercent: 40)]),
    ], _now);
    expect(best?.provider, 'claude');
  });

  test(
    'providerWithMostHeadroom prefers a live provider over a fuller stale one',
    () {
      final best = providerWithMostHeadroom([
        _q(
            'codex',
            [
              QuotaWindow(label: 'w', usedPercent: 1),
            ],
            stale: true), // 99% stale
        _q('claude', [QuotaWindow(label: 'w', usedPercent: 20)]), // 80% live
      ], _now);
      expect(best?.provider, 'claude');
    },
  );

  test('providerWithMostHeadroom falls back to stale when nothing is live', () {
    final best = providerWithMostHeadroom([
      _q('codex', [QuotaWindow(label: 'w', usedPercent: 10)], stale: true),
    ], _now);
    expect(best?.provider, 'codex');
  });

  test('providerHeadroom derives from used and limit when no percent', () {
    final q = _q('kiro', [QuotaWindow(label: 'credit', used: 30, limit: 120)]);
    expect(providerHeadroom(q, _now), closeTo(75, 0.001)); // 100 - 25
  });

  group('averageRecentHeadroom', () {
    test('averages headroom across snapshots', () {
      final hist = [
        _q('codex', [QuotaWindow(label: 'w', usedPercent: 20)]), // 80
        _q('codex', [QuotaWindow(label: 'w', usedPercent: 40)]), // 60
      ];
      expect(averageRecentHeadroom(hist, _now), closeTo(70, 0.001));
    });

    test('is null with no usable snapshots', () {
      expect(averageRecentHeadroom(const [], _now), isNull);
      expect(averageRecentHeadroom([_q('codex', const [])], _now), isNull);
    });
  });

  group('suggestRoute', () {
    test('recommends the freest comfortable subscription', () {
      final s = suggestRoute([
        _q('codex', [QuotaWindow(label: 'w', usedPercent: 80)]), // 20% free
        _q('claude', [QuotaWindow(label: 'w', usedPercent: 30)]), // 70% free
      ], _now);
      expect(s.recommended?.provider, 'claude');
      expect(s.usingLocalFallback, isFalse);
    });

    test(
      'falls back to local when every subscription is below the threshold',
      () {
        final s = suggestRoute([
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 95)]), // 5% free
          _local('ollama'),
        ], _now);
        expect(s.recommended?.provider, 'ollama');
        expect(s.recommended?.isLocal, isTrue);
        expect(s.usingLocalFallback, isTrue);
      },
    );

    test('local-first policy recommends local before comfortable cloud', () {
      final s = suggestRoute(
        [
          _q('claude', [QuotaWindow(label: 'w', usedPercent: 10)]),
          _local('ollama'),
        ],
        _now,
        preferLocal: true,
      );

      expect(s.recommended?.provider, 'ollama');
      expect(s.recommended?.isLocal, isTrue);
      expect(s.usingLocalFallback, isTrue);
      expect(s.routingPolicy, 'local_first');
      expect(s.toJson()['routing_policy'], 'local_first');
      expect(s.ranked.first.provider, 'ollama');
      expect(s.reason, contains('Local-first policy'));
    });

    test('local-first policy falls back to cloud when no local runtime exists',
        () {
      final s = suggestRoute(
        [
          _q('claude', [QuotaWindow(label: 'w', usedPercent: 10)]),
        ],
        _now,
        preferLocal: true,
      );

      expect(s.recommended?.provider, 'claude');
      expect(s.usingLocalFallback, isFalse);
      expect(s.routingPolicy, 'local_first');
    });

    test('without a local fallback, recommends the least-bad subscription', () {
      final s = suggestRoute([
        _q('codex', [QuotaWindow(label: 'w', usedPercent: 95)]), // 5% free
        _q('claude', [QuotaWindow(label: 'w', usedPercent: 98)]), // 2% free
      ], _now);
      expect(s.recommended?.provider, 'codex');
      expect(s.usingLocalFallback, isFalse);
    });

    test('when all spent, recommends nothing and names the soonest reset', () {
      final s = suggestRoute([
        _q('codex', [
          QuotaWindow(label: 'w', usedPercent: 100, resetsAt: _now + 7200),
        ]),
        _q('claude', [
          QuotaWindow(label: 'w', usedPercent: 100, resetsAt: _now + 3600),
        ]),
      ], _now);
      expect(s.recommended, isNull);
      expect(s.reason, contains('claude'));
    });

    test('reports no data when nothing is usable', () {
      final s = suggestRoute([_q('grok', const [])], _now);
      expect(s.recommended, isNull);
      expect(s.ranked, isEmpty);
    });

    test('prefers a live subscription over a fuller stale one', () {
      final s = suggestRoute([
        _q(
            'codex',
            [
              QuotaWindow(label: 'w', usedPercent: 5),
            ],
            stale: true), // 95% stale
        _q('claude', [QuotaWindow(label: 'w', usedPercent: 40)]), // 60% live
      ], _now);
      expect(s.recommended?.provider, 'claude');
    });

    test(
      'uses local fallback instead of a cached comfortable subscription',
      () {
        final s = suggestRoute([
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 5)], stale: true),
          _local('ollama'),
        ], _now);
        expect(s.recommended?.provider, 'ollama');
        expect(s.usingLocalFallback, isTrue);
      },
    );

    test(
      'uses stale subscription only when no live or local option exists',
      () {
        final s = suggestRoute([
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 5)], stale: true),
        ], _now);
        expect(s.recommended?.provider, 'codex');
        expect(s.reason, contains('cached'));
      },
    );

    test('manual entries carry lower routing confidence', () {
      final s = suggestRoute([
        _q(
          'manual-tool',
          [QuotaWindow(label: 'monthly', usedPercent: 10)],
          source: 'manual',
        ),
      ], _now);

      expect(s.recommended?.provider, 'manual-tool');
      expect(s.recommended?.confidence, 0.35);
    });
  });

  group('suggestRoute burn-aware effective headroom', () {
    test('discounts headroom by burn x lead and exposes it', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 20)]), // 80% free
        ],
        _now,
        burnByProvider: {'codex': 30},
        leadHours: 1.0,
      );
      final c = s.recommended!;
      expect(c.headroom, closeTo(80, 1e-9));
      expect(c.effectiveHeadroom, closeTo(50, 1e-9));
      expect(c.toJson()['effective_headroom_percent'], closeTo(50, 1e-9));
      expect(c.toJson()['burn_percent_per_hour'], 30);
    });

    test('ranks a hard-burned provider below a steadier one', () {
      // codex 70% free burning 40/h -> eff 30; claude 50% free at 2/h -> eff 48.
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 30)]),
          _q('claude', [QuotaWindow(label: 'w', usedPercent: 50)]),
        ],
        _now,
        burnByProvider: {'codex': 40, 'claude': 2},
      );
      expect(s.recommended?.provider, 'claude');
      expect(s.ranked.first.provider, 'claude');
    });

    test('a raw-comfortable provider falls back to local once burn applies',
        () {
      // codex 25% free is comfy raw, but burning 20/h over 1h -> eff 5 (< 15).
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 75)]),
          _local('ollama'),
        ],
        _now,
        burnByProvider: {'codex': 20},
      );
      expect(s.recommended?.provider, 'ollama');
      expect(s.usingLocalFallback, isTrue);
    });

    test('effective headroom never goes negative', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 90)]), // 10% free
          _local('ollama'),
        ],
        _now,
        burnByProvider: {'codex': 50}, // 10 - 50 -> clamped to 0
      );
      final codex = s.ranked.firstWhere((c) => c.provider == 'codex');
      expect(codex.effectiveHeadroom, 0);
    });

    test('a recovering (negative) burn does not change headroom', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 40)]), // 60% free
        ],
        _now,
        burnByProvider: {'codex': -5},
      );
      expect(s.recommended!.effectiveHeadroom, closeTo(60, 1e-9));
    });

    test('local runtimes are never discounted', () {
      final s = suggestRoute(
        [_local('ollama')],
        _now,
        burnByProvider: {'ollama': 99},
      );
      expect(s.recommended!.effectiveHeadroom, 100);
      expect(
        s.recommended!.toJson().containsKey('burn_percent_per_hour'),
        isFalse,
      );
    });

    test('without burn data, effective headroom equals raw headroom', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 35)]), // 65% free
        ],
        _now,
      );
      final c = s.recommended!;
      expect(c.effectiveHeadroom, c.headroom);
      expect(c.toJson().containsKey('burn_percent_per_hour'), isFalse);
    });

    test('routing score can prefer slower burn over higher raw headroom', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 10)]), // 90 free
          _q('claude', [QuotaWindow(label: 'w', usedPercent: 60)]), // 40 free
        ],
        _now,
        burnByProvider: {'codex': 10, 'claude': 1},
      );

      expect(s.recommended?.provider, 'claude');
      expect(s.ranked.first.provider, 'claude');
      expect(
        s.ranked.first.routingScore!,
        greaterThan(s.ranked.last.routingScore!),
      );
      expect(
        s.ranked.first.effectiveHeadroom!,
        lessThan(s.ranked.last.effectiveHeadroom!),
      );
    });

    test('routing score is additive JSON provenance', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 35)]),
        ],
        _now,
      );
      final c = s.recommended!;
      expect(c.routingScore, isNotNull);
      expect(c.runwayHours, closeTo(65, 1e-9));
      expect(c.routingScore, closeTo(c.runwayHours! * c.confidence!, 1e-9));
      expect(c.toJson()['routing_score'], c.routingScore);
      expect(c.toJson()['runway_hours'], c.runwayHours);
    });

    test('routing score breakdown is null for local runtimes', () {
      final score = routingScoreBreakdown(
        isLocal: true,
        effectiveHeadroom: 100,
        burnPerHour: null,
        confidence: 1,
      );

      expect(score, isNull);
    });

    test('routing score breakdown separates runway from confidence', () {
      final score = routingScoreBreakdown(
        isLocal: false,
        effectiveHeadroom: 48,
        burnPerHour: 2,
        confidence: 0.75,
      )!;

      expect(score.runwayHours, 24);
      expect(score.confidence, 0.75);
      expect(score.score, 18);
    });
  });

  group('suggestRoute fail-soft fallback and schema', () {
    test('stamps the suggestion schema version', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 30)]),
        ],
        _now,
      );
      expect(s.toJson()['schema'], 'quotabot.suggest.v1');
    });

    test('fallback is a local runtime when one is present', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 30)]),
          _local('ollama'),
        ],
        _now,
      );
      expect(s.fallback.kind, 'local');
      expect(s.fallback.provider, 'ollama');
      expect((s.toJson()['fallback'] as Map)['kind'], 'local');
    });

    test('fallback is the soonest reset when no local runtime exists', () {
      final s = suggestRoute(
        [
          _q('codex', [
            QuotaWindow(label: 'w', usedPercent: 100, resetsAt: _now + 7200),
          ]),
          _q('claude', [
            QuotaWindow(label: 'w', usedPercent: 100, resetsAt: _now + 3600),
          ]),
        ],
        _now,
      );
      expect(s.fallback.kind, 'soonest_reset');
      expect(s.fallback.provider, 'claude');
      expect(s.fallback.resetsAt, _now + 3600);
    });

    test('fallback is passthrough when there is no signal at all', () {
      final s = suggestRoute([_q('grok', const [])], _now);
      expect(s.fallback.kind, 'passthrough');
      expect(s.fallback.provider, isNull);
    });

    test('fallback is present on the happy path', () {
      final s = suggestRoute(
        [
          _q('codex', [QuotaWindow(label: 'w', usedPercent: 10)]), // 90% free
        ],
        _now,
      );
      expect(s.recommended?.provider, 'codex');
      expect(s.fallback.kind, 'passthrough'); // no local, no reset known
    });
  });

  group('nextRefreshSeconds', () {
    test('backs off after empty cycles', () {
      expect(nextRefreshSeconds(const [], _now, failStreak: 1), 3600);
      expect(nextRefreshSeconds(const [], _now, failStreak: 2), 6 * 3600);
    });

    test('polls fast when a reset is imminent', () {
      expect(
        nextRefreshSeconds([
          _q('codex',
              [QuotaWindow(label: '5h', usedPercent: 50, resetsAt: _now + 60)])
        ], _now),
        30,
      );
      expect(
        nextRefreshSeconds([
          _q('codex',
              [QuotaWindow(label: '5h', usedPercent: 50, resetsAt: _now + 300)])
        ], _now),
        60,
      );
    });

    test('watches closely near a cap', () {
      final far = _now + 5 * 86400;
      expect(
        nextRefreshSeconds([
          _q('codex',
              [QuotaWindow(label: 'weekly', usedPercent: 95, resetsAt: far)])
        ], _now),
        300, // 5% free
      );
      expect(
        nextRefreshSeconds([
          _q('codex',
              [QuotaWindow(label: 'weekly', usedPercent: 70, resetsAt: far)])
        ], _now),
        900, // 30% free
      );
    });

    test('relaxes when healthy and resets are far off', () {
      expect(
        nextRefreshSeconds([
          _q('claude', [
            QuotaWindow(
                label: 'weekly', usedPercent: 10, resetsAt: _now + 5 * 86400)
          ])
        ], _now),
        12 * 3600,
      );
    });
  });
}
