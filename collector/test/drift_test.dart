import 'dart:convert';

import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:test/test.dart';

void main() {
  ProviderQuota snap(String provider, List<QuotaWindow> windows) =>
      ProviderQuota(
        provider: provider,
        displayName: provider,
        account: 'a',
        asOf: 0,
        windows: windows,
      );
  QuotaWindow win(String label, double used, int reset) =>
      QuotaWindow(label: label, usedPercent: used, resetsAt: reset);

  group('detectQuotaDrift', () {
    test('normal consumption within a window is not flagged', () {
      final prev = snap(claudeProviderId, [win('5h', 20, 1000)]);
      final fresh = snap(claudeProviderId, [win('5h', 35, 1000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('a reset that moved earlier is flagged for any provider', () {
      final prev = snap(claudeProviderId, [win('weekly', 40, 2000)]);
      final fresh = snap(claudeProviderId, [win('weekly', 41, 1000)]);
      expect(detectQuotaDrift(fresh, prev), contains('reset moved earlier'));
    });

    test('usage falling with no reset is flagged for a normal provider', () {
      final prev = snap(codexProviderId, [win('5h', 60, 1000)]);
      final fresh = snap(codexProviderId, [win('5h', 10, 1000)]);
      final reason = detectQuotaDrift(fresh, prev);
      expect(reason, contains('usage fell'));
      expect(reason, contains('no reset'));
    });

    test('a clean reset rollover (reset advances, usage drops) is not flagged',
        () {
      final prev = snap(claudeProviderId, [win('5h', 90, 1000)]);
      final fresh = snap(claudeProviderId, [win('5h', 0, 5000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('Grok pool re-rating (usage drops, no reset) is accepted, not flagged',
        () {
      // xAI re-rates the credit pool, so headroom can grow with no reset.
      final prev = snap(grokProviderId, [win('weekly', 27, 1000)]);
      final fresh = snap(grokProviderId, [win('weekly', 0, 1000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('a Grok reset that moved earlier is still flagged', () {
      // Re-rating exempts headroom gains, not an implausible reset.
      final prev = snap(grokProviderId, [win('weekly', 20, 2000)]);
      final fresh = snap(grokProviderId, [win('weekly', 20, 1000)]);
      expect(detectQuotaDrift(fresh, prev), contains('reset moved earlier'));
    });

    test('Antigravity is exempt: its window is a max over a changing set', () {
      final prev = snap(antigravityProviderId, [win('5h', 80, 2000)]);
      // Both a headroom gain and a reset regression, yet not flagged.
      final fresh = snap(antigravityProviderId, [win('5h', 5, 1000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('small reset jitter and rounding stay within tolerance', () {
      final prev = snap(claudeProviderId, [win('5h', 40, 2000)]);
      final fresh = snap(claudeProviderId, [win('5h', 39, 1900)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('a window with no counterpart in the previous read is skipped', () {
      final prev = snap(claudeProviderId, [win('5h', 40, 1000)]);
      final fresh = snap(claudeProviderId, [win('weekly', 5, 9000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('the flagged reason names the window', () {
      final prev = snap(codexProviderId, [win('weekly', 50, 1000)]);
      final fresh = snap(codexProviderId, [win('weekly', 5, 1000)]);
      expect(detectQuotaDrift(fresh, prev), startsWith('weekly '));
    });
  });

  group('ProviderQuota.suspect', () {
    test('withSuspect annotates without hiding the reading', () {
      final q = snap(claudeProviderId, [win('5h', 40, 1000)]);
      final flagged = q.withSuspect('5h reset moved earlier');
      expect(flagged.suspect, '5h reset moved earlier');
      expect(flagged.windows.single.usedPercent, 40);
      expect(q.suspect, isNull); // original untouched
    });

    test('suspect round-trips through JSON and survives asStale', () {
      final q = snap(claudeProviderId, [win('5h', 40, 1000)])
          .withSuspect('5h usage fell 60% to 10% with no reset');
      final back = ProviderQuota.fromJson(
        jsonDecode(jsonEncode(q.toJson())) as Map<String, dynamic>,
      );
      expect(back.suspect, q.suspect);
      expect(back.asStale('cached').suspect, q.suspect);
    });
  });
}
