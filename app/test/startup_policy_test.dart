import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot_collector/collector.dart';

void main() {
  const now = 2000;

  test(
    'successful refresh evidence includes local and configured status data',
    () {
      ProviderQuota provider({
        required String id,
        ProviderQuotaKind kind = ProviderQuotaKind.subscription,
        String? status,
        bool ok = true,
        bool stale = false,
        int asOf = now,
        List<QuotaWindow> windows = const [],
      }) => ProviderQuota(
        provider: id,
        displayName: id,
        account: 'a',
        kind: kind,
        status: status,
        ok: ok,
        stale: stale,
        asOf: asOf,
        windows: windows,
      );

      expect(
        hasSuccessfulRefreshEvidence([
          provider(id: 'ollama', kind: ProviderQuotaKind.local),
        ], now),
        isTrue,
      );
      expect(
        hasSuccessfulRefreshEvidence([
          provider(id: 'nvidia', status: 'free trial available'),
        ], now),
        isTrue,
      );
      expect(
        hasSuccessfulRefreshEvidence([
          provider(id: 'nvidia', status: 'not configured; optional'),
        ], now),
        isFalse,
      );
      expect(
        hasSuccessfulRefreshEvidence([
          provider(id: 'ollama', kind: ProviderQuotaKind.local, stale: true),
          provider(
            id: 'claude',
            asOf: now + 1000,
            windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
          ),
        ], now),
        isFalse,
      );
    },
  );
}
