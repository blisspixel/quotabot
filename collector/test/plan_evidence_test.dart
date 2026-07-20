import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/plan_evidence.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:test/test.dart';

const _now = kClaudeFableIncludedQuotaEffectiveAt + 86400;

ProviderQuota _fableQuota({
  String? plan,
  ProviderPlanEvidenceSource? source,
  int? planAsOf,
  bool stale = false,
}) =>
    ProviderQuota(
      provider: claudeProviderId,
      displayName: claudeProviderName,
      account: 'opaque',
      plan: plan,
      planEvidenceSource: source,
      planEvidenceAsOf: planAsOf,
      asOf: _now,
      stale: stale,
      windows: [
        QuotaWindow(label: 'weekly', usedPercent: 20),
      ],
      modelQuotas: const [
        ModelQuota(model: 'Fable', usedPercent: 26),
      ],
    );

void main() {
  test('host Max label never proves included Fable quota', () {
    final evidence = claudeFableSpendEvidenceAt(
      _fableQuota(
        plan: 'max',
        source: ProviderPlanEvidenceSource.hostCredential,
        planAsOf: _now,
      ),
      'Fable',
      _now,
    );

    expect(evidence?.kind, ScopedModelSpendKind.includedQuotaNotProven);
    expect(evidence?.compactLabel, 'included quota not proven');
    expect(evidence?.detail, contains('stored Claude credential'));
  });

  test('current provider Max evidence proves included Fable quota', () {
    final evidence = claudeFableSpendEvidenceAt(
      _fableQuota(
        plan: 'max',
        source: ProviderPlanEvidenceSource.providerMetadata,
        planAsOf: _now,
      ),
      'Claude Fable 5',
      _now,
    );

    expect(evidence?.kind, ScopedModelSpendKind.includedQuota);
    expect(evidence?.includedQuota, isTrue);
    expect(evidence?.compactLabel, 'included quota');
  });

  test('provider plan evidence cannot classify spend before policy starts', () {
    const before = kClaudeFableIncludedQuotaEffectiveAt - 1;
    for (final plan in const ['max', 'pro']) {
      final evidence = claudeFableSpendEvidenceAt(
        ProviderQuota(
          provider: claudeProviderId,
          displayName: claudeProviderName,
          account: 'opaque',
          plan: plan,
          planEvidenceSource: ProviderPlanEvidenceSource.providerMetadata,
          planEvidenceAsOf: before,
          asOf: before,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
          modelQuotas: const [ModelQuota(model: 'Fable', usedPercent: 26)],
        ),
        'Fable',
        before,
      );

      expect(evidence?.kind, ScopedModelSpendKind.includedQuotaNotProven);
      expect(evidence?.detail, contains('begins July 20, 2026'));
    }
  });

  test('stale or mismatched provider plan evidence fails closed', () {
    for (final quota in [
      _fableQuota(
        plan: 'max',
        source: ProviderPlanEvidenceSource.providerMetadata,
        planAsOf: _now - 1,
      ),
      _fableQuota(
        plan: 'max',
        source: ProviderPlanEvidenceSource.providerMetadata,
        planAsOf: _now,
        stale: true,
      ),
    ]) {
      final evidence = claudeFableSpendEvidenceAt(
        quota,
        'Fable',
        _now,
      );
      expect(evidence?.kind, ScopedModelSpendKind.includedQuotaNotProven);
    }
  });

  test('current provider Pro and Team Standard are explicitly credit-backed',
      () {
    for (final plan in const ['pro', 'Team Standard']) {
      final evidence = claudeFableSpendEvidenceAt(
        _fableQuota(
          plan: plan,
          source: ProviderPlanEvidenceSource.providerMetadata,
          planAsOf: _now,
        ),
        'Fable',
        _now,
      );
      expect(evidence?.kind, ScopedModelSpendKind.creditBacked);
      expect(evidence?.compactLabel, 'credit-backed availability');
      expect(evidence?.includedQuota, isFalse);
    }
  });

  test('host and stale Pro labels do not prove credit-backed spend', () {
    for (final quota in [
      _fableQuota(
        plan: 'pro',
        source: ProviderPlanEvidenceSource.hostCredential,
        planAsOf: _now,
      ),
      _fableQuota(
        plan: 'pro',
        source: ProviderPlanEvidenceSource.providerMetadata,
        planAsOf: _now,
        stale: true,
      ),
    ]) {
      final evidence = claudeFableSpendEvidenceAt(quota, 'Fable', _now);
      expect(evidence?.kind, ScopedModelSpendKind.includedQuotaNotProven);
      expect(evidence?.includedQuota, isFalse);
    }
  });
}
