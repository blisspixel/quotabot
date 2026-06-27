import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(
  String id,
  List<QuotaWindow> windows, {
  bool stale = false,
  String kind = 'subscription',
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: windows,
      stale: stale,
      kind: kind,
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

  test('providerHeadroom treats a passed reset as fresh', () {
    final q = _q('codex', [
      QuotaWindow(label: '5h', usedPercent: 100, resetsAt: _now - 10),
    ]);
    expect(providerHeadroom(q, _now), 100);
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
  });
}
