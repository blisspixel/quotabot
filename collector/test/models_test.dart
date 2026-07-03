import 'dart:convert';

import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

void main() {
  group('QuotaWindow', () {
    test('uses usedPercent directly when present', () {
      expect(QuotaWindow(label: '5h', usedPercent: 42).percent, 42);
    });

    test('derives percent from used and limit', () {
      expect(QuotaWindow(label: 'w', used: 30, limit: 120).percent, 25);
    });

    test('returns null percent with no usable inputs', () {
      expect(QuotaWindow(label: 'w').percent, isNull);
      expect(QuotaWindow(label: 'w', used: 5, limit: 0).percent, isNull);
    });

    test('exhausted at or above 99.5 percent', () {
      expect(QuotaWindow(label: 'w', usedPercent: 100).exhausted, isTrue);
      expect(QuotaWindow(label: 'w', usedPercent: 99.6).exhausted, isTrue);
      expect(QuotaWindow(label: 'w', usedPercent: 90).exhausted, isFalse);
    });

    test('toJson omits null fields', () {
      final json = QuotaWindow(
        label: '5h',
        usedPercent: 7,
        resetsAt: 100,
      ).toJson();
      expect(json, {'label': '5h', 'used_percent': 7, 'resets_at': 100});
      expect(json.containsKey('used'), isFalse);
    });

    test('round-trips through json', () {
      final w = QuotaWindow(label: 'w', used: 3, limit: 10, resetsAt: 50);
      final back = QuotaWindow.fromJson(w.toJson());
      expect(back.used, 3);
      expect(back.limit, 10);
      expect(back.resetsAt, 50);
    });

    test('fromJson drops non-finite numbers from a corrupt cache file', () {
      // 1e400 decodes to Infinity; left raw, it survives to crash jsonEncode.
      final w = QuotaWindow.fromJson({
        'label': '5h',
        'used_percent': double.infinity,
        'used': double.nan,
        'limit': double.negativeInfinity,
        'resets_at': double.infinity,
      });
      expect(w.usedPercent, isNull);
      expect(w.used, isNull);
      expect(w.limit, isNull);
      expect(w.resetsAt, isNull);
      expect(() => jsonEncode(w.toJson()), returnsNormally);
    });

    test('fromJson bounds an out-of-range percent to 0..100', () {
      final w = QuotaWindow.fromJson({'label': 'w', 'used_percent': 250});
      expect(w.usedPercent, 100);
    });
  });

  group('ProviderQuota', () {
    test('error factory marks not ok with no windows', () {
      final q = ProviderQuota.error('grok', 'Grok', 'boom', 99);
      expect(q.ok, isFalse);
      expect(q.error, 'boom');
      expect(q.hasWindows, isFalse);
    });

    test('asStale preserves windows, capture time, and kind', () {
      final q = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'pro',
        asOf: 1000,
        kind: 'local',
        windows: [QuotaWindow(label: '5h', usedPercent: 10)],
      );
      final stale = q.asStale('cached');
      expect(stale.stale, isTrue);
      expect(stale.asOf, 1000);
      expect(stale.error, 'cached');
      expect(stale.hasWindows, isTrue);
      expect(stale.kind, 'local');
    });

    test('asStale can preserve cached windows with fresh metadata', () {
      final cached = ProviderQuota(
        provider: 'antigravity',
        displayName: 'Antigravity',
        account: 'blisspixel@gmail.com',
        plan: 'Antigravity',
        asOf: 1000,
        status: 'old status',
        windows: [QuotaWindow(label: '5h', usedPercent: 20)],
      );
      final fresh = ProviderQuota(
        provider: 'antigravity',
        displayName: 'Antigravity',
        account: 'blisspixel@gmail.com',
        plan: 'Google AI Pro',
        asOf: 2000,
        status: 'Gemini 3.1 Pro (High)',
        details: const ['Local Antigravity status reports higher rate limits'],
      );

      final stale =
          cached.asStale('fresh metadata, cached quota', metadataFrom: fresh);

      expect(stale.stale, isTrue);
      expect(stale.asOf, 1000);
      expect(stale.plan, 'Google AI Pro');
      expect(stale.status, 'Gemini 3.1 Pro (High)');
      expect(stale.details, fresh.details);
      expect(stale.windows.single.usedPercent, 20);
      expect(stale.error, 'fresh metadata, cached quota');
    });

    test('defaults to subscription kind and exposes isLocal', () {
      final sub = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'a',
        asOf: 0,
      );
      expect(sub.kind, 'subscription');
      expect(sub.isLocal, isFalse);
      final local = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'local',
        asOf: 0,
        kind: 'local',
      );
      expect(local.isLocal, isTrue);
    });

    test('round-trips through json', () {
      final q = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'max',
        plan: 'max',
        asOf: 123,
        windows: [QuotaWindow(label: '5h', usedPercent: 18, resetsAt: 456)],
      );
      final back = ProviderQuota.fromJson(q.toJson());
      expect(back.provider, 'claude');
      expect(back.plan, 'max');
      expect(back.asOf, 123);
      expect(back.kind, 'subscription');
      expect(back.windows.single.usedPercent, 18);
    });

    test('round-trips local kind through json', () {
      final q = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: '3 models',
        plan: 'local',
        kind: 'local',
        asOf: 1,
        windows: [QuotaWindow(label: 'local', usedPercent: 0)],
      );
      expect(ProviderQuota.fromJson(q.toJson()).kind, 'local');
    });
  });
}
