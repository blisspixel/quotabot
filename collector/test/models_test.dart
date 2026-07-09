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

    test('exhausted at or above the shared spent headroom floor', () {
      expect(QuotaWindow(label: 'w', usedPercent: 100).exhausted, isTrue);
      expect(QuotaWindow(label: 'w', usedPercent: 98.6).exhausted, isTrue);
      expect(QuotaWindow(label: 'w', usedPercent: 98.4).exhausted, isFalse);
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
      final q = ProviderQuota.error(
        'grok',
        'Grok',
        'boom',
        99,
        pipeHealth: providerPipeHealthThrottled,
        httpStatus: 429,
        retryAfterSeconds: 60,
      );
      expect(q.ok, isFalse);
      expect(q.error, 'boom');
      expect(q.hasWindows, isFalse);
      expect(q.toJson()['pipe_health'], providerPipeHealthThrottled);
      expect(q.toJson()['http_status'], 429);
      expect(q.toJson()['retry_after_seconds'], 60);
      final decoded = ProviderQuota.fromJson(q.toJson());
      expect(decoded.pipeHealth, providerPipeHealthThrottled);
      expect(decoded.httpStatus, 429);
      expect(decoded.retryAfterSeconds, 60);
    });

    test('asStale preserves windows, capture time, and kind', () {
      final q = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'pro',
        asOf: 1000,
        kind: ProviderQuotaKind.local,
        windows: [QuotaWindow(label: '5h', usedPercent: 10)],
      );
      final stale = q.asStale('cached');
      expect(stale.stale, isTrue);
      expect(stale.asOf, 1000);
      expect(stale.error, 'cached');
      expect(stale.hasWindows, isTrue);
      expect(stale.kind, ProviderQuotaKind.local);
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

    test('asStale carries fresh native pipe-health diagnostics', () {
      final cached = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'max',
        asOf: 1000,
        windows: [QuotaWindow(label: '5h', usedPercent: 20)],
      );
      final freshError = ProviderQuota.error(
        'claude',
        'Claude',
        'HTTP 429',
        2000,
        pipeHealth: providerPipeHealthThrottled,
        httpStatus: 429,
        retryAfterSeconds: 120,
      );

      final stale = cached.asStale('HTTP 429', metadataFrom: freshError);

      expect(stale.stale, isTrue);
      expect(stale.account, 'max');
      expect(stale.windows.single.usedPercent, 20);
      expect(stale.pipeHealth, providerPipeHealthThrottled);
      expect(stale.httpStatus, 429);
      expect(stale.retryAfterSeconds, 120);
    });

    test('defaults to subscription kind and exposes isLocal', () {
      final sub = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'a',
        asOf: 0,
      );
      expect(sub.kind, ProviderQuotaKind.subscription);
      expect(sub.isLocal, isFalse);
      final local = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'local',
        asOf: 0,
        kind: ProviderQuotaKind.local,
      );
      expect(local.isLocal, isTrue);
      expect(local.toJson()['kind'], providerQuotaLocalKind);
      expect(ProviderQuotaKind.fromWire(providerQuotaLocalKind),
          ProviderQuotaKind.local);
      expect(ProviderQuotaKind.fromWire(null), ProviderQuotaKind.subscription);
      expect(
        () => ProviderQuotaKind.fromWire('future-kind'),
        throwsFormatException,
      );
    });

    test('manual source exposes isManual while preserving the wire value', () {
      final q = ProviderQuota(
        provider: 'manual-ai',
        displayName: 'Manual AI',
        account: 'default',
        asOf: 0,
        source: providerQuotaManualSource,
      );

      expect(q.isManual, isTrue);
      expect(q.toJson()['source'], 'manual');
      expect(ProviderQuota.fromJson(q.toJson()).isManual, isTrue);
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
      expect(back.kind, ProviderQuotaKind.subscription);
      expect(back.windows.single.usedPercent, 18);
    });

    test('classifies reliable native HTTP pipe-health statuses', () {
      expect(providerPipeHealthForHttpStatus(429), providerPipeHealthThrottled);
      expect(providerPipeHealthForHttpStatus(503), providerPipeHealthDegraded);
      expect(providerPipeHealthForHttpStatus(529), providerPipeHealthDegraded);
      expect(providerPipeHealthForHttpStatus(401), isNull);
      expect(providerPipeHealthForHttpStatus(404), isNull);
    });

    test('drops malformed cached native pipe-health diagnostics', () {
      final q = ProviderQuota.fromJson({
        'provider': 'claude',
        'display_name': 'Claude',
        'account': 'max',
        'kind': providerQuotaSubscriptionKind,
        'ok': false,
        'as_of': 1000,
        'stale': false,
        'pipe_health': 'overheated',
        'http_status': 99,
        'retry_after_seconds': -1,
        'windows': const <Map<String, Object?>>[],
      });

      expect(q.pipeHealth, isNull);
      expect(q.httpStatus, isNull);
      expect(q.retryAfterSeconds, isNull);
      expect(q.toJson().containsKey('pipe_health'), isFalse);
      expect(q.toJson().containsKey('http_status'), isFalse);
      expect(q.toJson().containsKey('retry_after_seconds'), isFalse);
    });

    test('round-trips local kind through json', () {
      final q = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: '3 models',
        plan: 'local',
        kind: ProviderQuotaKind.local,
        asOf: 1,
        windows: [QuotaWindow(label: 'local', usedPercent: 0)],
      );
      expect(q.toJson()['kind'], providerQuotaLocalKind);
      expect(ProviderQuota.fromJson(q.toJson()).kind, ProviderQuotaKind.local);
    });
  });
}
