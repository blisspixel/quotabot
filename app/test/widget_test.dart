import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot_collector/collector.dart';

void main() {
  test('QuotaWindow derives percent from used/limit', () {
    final w = QuotaWindow(label: '5h', used: 25, limit: 100);
    expect(w.percent, 25);
    expect(w.exhausted, isFalse);
  });

  test('QuotaWindow flags an exhausted window', () {
    final w = QuotaWindow(label: 'weekly', usedPercent: 100);
    expect(w.exhausted, isTrue);
  });

  test('ProviderQuota round-trips through JSON', () {
    final q = ProviderQuota(
      provider: 'codex',
      displayName: 'Codex',
      account: 'pro',
      plan: 'pro',
      asOf: 1782046566,
      windows: [QuotaWindow(label: '5h', usedPercent: 7, resetsAt: 1782050000)],
    );
    final back = ProviderQuota.fromJson(q.toJson());
    expect(back.provider, 'codex');
    expect(back.windows.single.usedPercent, 7);
    expect(back.windows.single.resetsAt, 1782050000);
  });

  group('Prefs', () {
    test('round-trips through JSON including window position', () {
      const p = Prefs(
        hidden: {'grok', 'codex'},
        compact: true,
        cadence: Cadence.h1,
        alwaysOnTop: true,
        showInTaskbar: false,
        enableNotifications: false,
        sort: ProviderSort.mostUsed,
        webhookUrl: 'http://127.0.0.1:9000/quota',
        webhookAllowExternal: true,
        windowX: 100,
        windowY: 200,
      );
      final back = Prefs.fromJson(p.toJson());
      expect(back.hidden, {'grok', 'codex'});
      expect(back.compact, isTrue);
      expect(back.cadence, Cadence.h1);
      expect(back.alwaysOnTop, isTrue);
      expect(back.showInTaskbar, isFalse);
      expect(back.enableNotifications, isFalse);
      expect(back.sort, ProviderSort.mostUsed);
      expect(back.showAccounts, isFalse);
      expect(back.webhookUrl, 'http://127.0.0.1:9000/quota');
      expect(back.webhookAllowExternal, isTrue);
      expect(back.windowX, 100);
      expect(back.windowY, 200);
    });

    test('defaults are sane and tolerant of bad input', () {
      final p = Prefs.fromJson({'cadence': 'nonsense'});
      expect(p.hidden, isEmpty);
      expect(p.compact, isFalse);
      expect(p.cadence, Cadence.smart);
      expect(p.alwaysOnTop, isFalse);
      expect(p.showInTaskbar, isTrue);
      expect(p.enableNotifications, isTrue);
      expect(p.sort, ProviderSort.defaultOrder);
      expect(p.showAccounts, isFalse);
      expect(p.webhookUrl, isNull);
      expect(p.webhookAllowExternal, isFalse);
      expect(p.windowX, isNull);
    });

    test('copyWith can clear the stored window position', () {
      const p = Prefs(windowX: 100, windowY: 200);
      final back = p.copyWith(clearWindowPosition: true);
      expect(back.windowX, isNull);
      expect(back.windowY, isNull);
    });
  });
}
