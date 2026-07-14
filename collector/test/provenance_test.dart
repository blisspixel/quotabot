import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provenance.dart';
import 'package:test/test.dart';

ProviderQuota _q(
  String provider, {
  bool ok = true,
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
  bool active = false,
  bool perMachine = false,
  String? source,
  List<QuotaWindow> windows = const [],
}) =>
    ProviderQuota(
      provider: provider,
      displayName: provider,
      account: 'a',
      asOf: 1000,
      ok: ok,
      kind: kind,
      active: active,
      perMachine: perMachine,
      source: source,
      windows: windows,
    );

final _win = [QuotaWindow(label: 'weekly', usedPercent: 20)];

void main() {
  group('providerSpendClass', () {
    test('a local runtime reads loaded when active, cold when idle', () {
      expect(
        providerSpendClass(
            _q('ollama', kind: ProviderQuotaKind.local, active: true)),
        'loaded',
      );
      expect(
        providerSpendClass(_q('ollama', kind: ProviderQuotaKind.local)),
        'cold',
      );
    });

    test('manual and status-only providers carry no spend class', () {
      expect(
        providerSpendClass(_q('manual-x', source: providerQuotaManualSource)),
        isNull,
      );
      expect(providerSpendClass(_q('nvidia')), isNull); // status-only
    });

    test('a plan-quota provider reads quota plan, even when unavailable', () {
      expect(providerSpendClass(_q('claude', windows: _win)), 'quota plan');
      expect(providerSpendClass(_q('codex', ok: false)), 'quota plan');
    });

    test('a measured non-plan provider reads metered plan', () {
      expect(
        providerSpendClass(_q('cursor', perMachine: true, windows: _win)),
        'metered plan',
      );
    });

    test('a cloud provider with no measured window has no spend class', () {
      expect(providerSpendClass(_q('claude')), isNull);
    });
  });
}
