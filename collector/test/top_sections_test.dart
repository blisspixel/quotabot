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

    test('a spent live window drops to cached', () {
      expect(topSectionFor(_q('codex', [_w(100)]), _now), TopSection.cached);
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

    test('a hard error with no windows is idle', () {
      expect(
        topSectionFor(_q('windsurf', const [], ok: false, error: 'boom'), _now),
        TopSection.idle,
      );
    });
  });

  group('partitionTopSections', () {
    test('groups into the three bands and preserves input order', () {
      final claude = _q('claude', [_w(3)]); // active
      final grok = _q('grok', [_w(12)]); // active
      final codex = _q('codex', [_w(100)]); // cached (spent)
      final kiro = _q('kiro', [_w(0)], stale: true); // cached (stale)
      final cursor = _q('cursor', const [], status: 'no live data'); // idle
      final nvidia = _q('nvidia', const [], status: 'metadata'); // idle

      final groups = partitionTopSections(
        [claude, grok, codex, kiro, cursor, nvidia],
        _now,
      );

      expect(groups.active.map((q) => q.provider), ['claude', 'grok']);
      expect(groups.cached.map((q) => q.provider), ['codex', 'kiro']);
      expect(groups.idle.map((q) => q.provider), ['cursor', 'nvidia']);
      // Cursor navigation walks active then cached; idle is not selectable.
      expect(
        groups.selectable.map((q) => q.provider),
        ['claude', 'grok', 'codex', 'kiro'],
      );
    });
  });
}
