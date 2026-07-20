/// Spend-sensitive plan evidence for provider-scoped model allowances.
///
/// A measured model pool proves availability and headroom. It does not, by
/// itself, prove whether use is included in a subscription or charged against
/// credits. This module keeps those two questions separate.
library;

import 'drift.dart';
import 'models.dart';
import 'provider_ids.dart';

enum ScopedModelSpendKind {
  includedQuota,
  creditBacked,
  includedQuotaNotProven,
}

/// Anthropic's announced start for standard Fable inclusion on Max and Team
/// Premium plans. UTC keeps the spend policy deterministic across hosts.
const int kClaudeFableIncludedQuotaEffectiveAt = 1784505600;

class ScopedModelSpendEvidence {
  final ScopedModelSpendKind kind;
  final String compactLabel;
  final String detail;

  const ScopedModelSpendEvidence({
    required this.kind,
    required this.compactLabel,
    required this.detail,
  });

  bool get includedQuota => kind == ScopedModelSpendKind.includedQuota;
}

bool isClaudeFableModelLabel(String model) =>
    model.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').contains('fable');

/// Classifies the spend evidence for a Claude Fable scoped pool.
///
/// The local `subscriptionType` stored with a Claude host credential is useful
/// context but can outlive an entitlement change. It never proves included
/// quota. Only a plan label carried by a current accepted provider response at
/// or after the announced policy effective date can admit Max or Team Premium
/// to the no-surprise quota budget.
ScopedModelSpendEvidence? claudeFableSpendEvidenceAt(
  ProviderQuota quota,
  String model,
  int now,
) {
  if (quota.provider != claudeProviderId || !isClaudeFableModelLabel(model)) {
    return null;
  }

  final plan = _normalizedClaudePlan(quota.plan);
  final explicitPlanEvidence = quota.planEvidenceSource != null &&
      quota.planEvidenceAsOf != null &&
      quota.planEvidenceAsOf! > 0 &&
      quota.planEvidenceAsOf! <= now + kQuotaEvidenceClockSkewSeconds;
  final currentProviderPlan =
      quota.planEvidenceSource == ProviderPlanEvidenceSource.providerMetadata &&
          explicitPlanEvidence &&
          quota.planEvidenceAsOf == quota.asOf &&
          isTrustedQuotaEvidenceAt(quota, now);
  final includedPolicyEffective = now >= kClaudeFableIncludedQuotaEffectiveAt &&
      quota.asOf >= kClaudeFableIncludedQuotaEffectiveAt;
  if (currentProviderPlan &&
      includedPolicyEffective &&
      const {'max', 'team_premium'}.contains(plan)) {
    return ScopedModelSpendEvidence(
      kind: ScopedModelSpendKind.includedQuota,
      compactLabel: 'included quota',
      detail: 'Current provider metadata identifies ${_displayPlan(plan!)} as '
          'an included Fable plan.',
    );
  }

  if (currentProviderPlan &&
      includedPolicyEffective &&
      const {'pro', 'team_standard'}.contains(plan)) {
    return ScopedModelSpendEvidence(
      kind: ScopedModelSpendKind.creditBacked,
      compactLabel: 'credit-backed availability',
      detail:
          '${_displayPlan(plan!)} Fable access is treated as credit-backed. '
          'The plan label came from current provider metadata and is never admitted to the '
          'included-quota budget.',
    );
  }

  final reason = currentProviderPlan &&
          const {'max', 'team_premium', 'pro', 'team_standard'}
              .contains(plan) &&
          !includedPolicyEffective
      ? 'Anthropic\'s announced Fable plan policy begins '
          'July 20, 2026; this observation predates that policy boundary.'
      : quota.planEvidenceSource == ProviderPlanEvidenceSource.hostCredential
          ? 'The ${quota.plan ?? 'plan'} label came from this machine\'s stored '
              'Claude credential, which can outlive an entitlement change.'
          : 'No current provider plan entitlement accompanies this scoped pool.';
  return ScopedModelSpendEvidence(
    kind: ScopedModelSpendKind.includedQuotaNotProven,
    compactLabel: 'included quota not proven',
    detail: 'The provider-measured Fable pool proves availability and '
        'headroom, but not included subscription spend. $reason',
  );
}

String? _normalizedClaudePlan(String? raw) {
  if (raw == null ||
      raw.isEmpty ||
      raw.length > 64 ||
      raw.trim() != raw ||
      stripTerminalControl(raw) != raw) {
    return null;
  }
  return raw.toLowerCase().replaceAll(RegExp(r'[ _-]+'), '_');
}

String _displayPlan(String plan) => switch (plan) {
      'team_premium' => 'Team Premium',
      'team_standard' => 'Team Standard',
      'max' => 'Max',
      'pro' => 'Pro',
      _ => plan,
    };
