import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/top.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(
  String id,
  List<QuotaWindow> windows, {
  bool stale = false,
  bool ok = true,
  String? status,
  String? error,
  String? driftReason,
  int? httpStatus,
  int asOf = _now,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: asOf,
      windows: windows,
      stale: stale,
      ok: ok,
      status: status,
      error: error,
      driftReason: driftReason,
      httpStatus: httpStatus,
    );

QuotaWindow _w(int usedPercent) => QuotaWindow(
      label: 'weekly',
      usedPercent: usedPercent.toDouble(),
      resetsAt: _now + 86400,
    );

void main() {
  group('topSectionFor', () {
    test('live trusted quota with headroom is active', () {
      expect(topSectionFor(_q('claude', [_w(10)]), _now), TopSection.active);
    });

    test('a spent live window stays active', () {
      expect(topSectionFor(_q('codex', [_w(100)]), _now), TopSection.active);
    });

    test('stale last-known quota is cached even with headroom', () {
      expect(
        topSectionFor(_q('grok', [_w(10)], stale: true), _now),
        TopSection.cached,
      );
    });

    test('drifted evidence is cached, not active', () {
      expect(
        topSectionFor(
          _q('antigravity', [_w(5)], driftReason: 'moved backwards'),
          _now,
        ),
        TopSection.cached,
      );
    });

    test('a provider with no windows is idle', () {
      expect(
        topSectionFor(_q('cursor', const [], status: 'no live data'), _now),
        TopSection.idle,
      );
    });

    test('a not-configured metadata provider is idle', () {
      expect(
        topSectionFor(_q('nvidia', const [], status: 'not configured'), _now),
        TopSection.idle,
      );
    });

    test('a hard failure keeps its own row instead of collapsing to idle', () {
      // A failed read is the most actionable thing on screen, so it must not be
      // swept into the collapsed idle band where its error would be dropped.
      expect(
        topSectionFor(_q('windsurf', const [], ok: false, error: 'boom'), _now),
        TopSection.cached,
      );
    });

    test('a reachable-but-rejected read stays visible for its recovery hint',
        () {
      expect(
        topSectionFor(
          _q('antigravity', const [],
              status: 'Gemini 3 Pro',
              error: 'HTTP 403 - run: quotabot login antigravity',
              httpStatus: 403),
          _now,
        ),
        TopSection.cached,
      );
    });

    test('a passively detected tool with no quota API is idle', () {
      expect(
        topSectionFor(
          _q('cursor', const [],
              status: 'no live data',
              error: 'Cursor installed (free tier or no data)'),
          _now,
        ),
        TopSection.idle,
      );
    });
  });

  group('partitionTopSections', () {
    test('groups into the three bands and preserves input order', () {
      final claude = _q('claude', [_w(3)]); // active
      final grok = _q('grok', [_w(12)]); // active
      final codex = _q('codex', [_w(100)]); // active (spent live)
      final kiro = _q('kiro', [_w(0)], stale: true); // cached (stale)
      final cursor = _q('cursor', const [], status: 'no live data'); // idle
      final nvidia = _q('nvidia', const [], status: 'metadata'); // idle

      final groups = partitionTopSections(
        [claude, grok, codex, kiro, cursor, nvidia],
        _now,
      );

      expect(groups.active.map((q) => q.provider), ['claude', 'grok', 'codex']);
      expect(groups.cached.map((q) => q.provider), ['kiro']);
      expect(groups.idle.map((q) => q.provider), ['cursor', 'nvidia']);
      // Cursor navigation walks active then cached; idle is not selectable.
      expect(
        groups.selectable.map((q) => q.provider),
        ['claude', 'grok', 'codex', 'kiro'],
      );
    });
  });

  group('routine provenance tags', () {
    List<String> frame(List<ProviderQuota> providers, int width) {
      final suggestion = suggestRoute(providers, _now);
      return renderTopFrame(
        providers: providers,
        suggestion: suggestion,
        now: _now,
        width: width,
        color: false,
        clock: '12:00:00',
      );
    }

    ProviderQuota healthy() => _q('claude', [_w(20)]);

    ProviderQuota cached() => _q('kiro', [_w(20)], stale: true);

    test('a wide frame elides the routine tag so the meter can grow', () {
      final wide = frame([healthy()], 140).join('\n');
      expect(wide, isNot(contains('(live, authoritative')));
      // The meter is what the width buys back.
      expect(wide, contains('%'));
    });

    test('a narrow frame keeps the routine tag', () {
      expect(frame([healthy()], 90).join('\n'), contains('live'));
    });

    test('a tag with something to disclose survives any width', () {
      // Cached evidence is the case a reader must not miss, so unlike the
      // routine tag it is never traded away for meter width.
      expect(frame([cached()], 140).join('\n'), contains('cached'));
    });
  });
}
