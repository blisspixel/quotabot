/// Structured, content-blind provenance for one routing decision.
///
/// The receipt is deliberately made only from quota metadata, bounded account
/// identifiers, policy settings, and routing factors. It never accepts task
/// text, prompts, source code, model responses, credentials, or exceptions.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

enum RouteDecisionCode {
  noData('no_data'),
  localFirst('local_first'),
  preferredProvider('preferred_provider'),
  bestRunway('best_runway'),
  localFallback('local_fallback'),
  lowQuota('low_quota'),
  adjustedHeadroomDepleted('adjusted_headroom_depleted'),
  capabilityBudgetBlocked('capability_budget_blocked'),
  capabilityBlocked('capability_blocked'),
  providerDrift('provider_drift'),
  staleEvidence('stale_evidence'),
  spentWait('spent_wait'),
  spentUnknownReset('spent_unknown_reset');

  final String wireName;

  const RouteDecisionCode(this.wireName);
}

enum RouteCandidateVerdict {
  selected('selected', 'selected by the active routing policy'),
  lowerRunway('lower_runway', 'another viable route had a stronger runway'),
  lowerPreference(
    'lower_preference',
    'another viable route ranked earlier in the provider preference',
  ),
  localFallbackOnly(
    'local_fallback_only',
    'kept as a local fallback while a subscription route is comfortable',
  ),
  belowComfort(
    'below_comfort',
    'effective headroom is below the comfort threshold',
  ),
  adjustedHeadroomDepleted(
    'adjusted_headroom_depleted',
    'routing adjustments consumed the usable effective headroom',
  ),
  unavailable('unavailable', 'current evidence does not prove availability'),
  spent('spent', 'the binding quota pool is spent'),
  stale('stale', 'cached evidence is not current enough to route from'),
  providerDrift(
    'provider_drift',
    'fresh evidence was rejected by provider drift checks',
  ),
  noCapableModel(
    'no_capable_model',
    'no catalog model meets the active capability floor',
  ),
  modelBudgetSpent(
    'model_budget_spent',
    'a capable model exists but its budget gate is unavailable',
  );

  final String wireName;
  final String explanation;

  const RouteCandidateVerdict(this.wireName, this.explanation);
}

enum RouteAdjustmentKind {
  burnRisk('burn_risk', 'subtract_percent'),
  lease('lease', 'subtract_percent'),
  pipeHealth('pipe_health', 'subtract_percent'),
  confidence('confidence', 'multiply'),
  projectedWaste('projected_waste', 'multiply'),
  cost('cost', 'multiply');

  final String wireName;
  final String operation;

  const RouteAdjustmentKind(this.wireName, this.operation);
}

double _receiptNumber(double value) => double.parse(value.toStringAsFixed(4));

class RouteAdjustmentReceipt {
  final RouteAdjustmentKind kind;
  final double value;

  const RouteAdjustmentReceipt({required this.kind, required this.value});

  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'operation': kind.operation,
        'value': _receiptNumber(value),
      };
}

class RouteCandidateReceipt {
  final String provider;
  final String account;
  final String sourceClass;
  final String spendClass;
  final String spendRisk;
  final String? bindingPool;
  final double? rawHeadroomPercent;
  final double? effectiveHeadroomPercent;
  final int evidenceAsOf;
  final int evidenceAgeSeconds;
  final int? resetsAt;
  final bool available;
  final bool stale;
  final double? confidence;
  final List<String> confidenceReasons;
  final RouteCandidateVerdict verdict;
  final List<RouteAdjustmentReceipt> adjustments;

  const RouteCandidateReceipt({
    required this.provider,
    required this.account,
    required this.sourceClass,
    required this.spendClass,
    required this.spendRisk,
    required this.bindingPool,
    required this.rawHeadroomPercent,
    required this.effectiveHeadroomPercent,
    required this.evidenceAsOf,
    required this.evidenceAgeSeconds,
    required this.resetsAt,
    required this.available,
    required this.stale,
    required this.confidence,
    required this.confidenceReasons,
    required this.verdict,
    required this.adjustments,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'account': account,
        'source_class': sourceClass,
        'spend_class': spendClass,
        'spend_risk': spendRisk,
        if (bindingPool != null) 'binding_pool': bindingPool,
        'raw_headroom_percent': rawHeadroomPercent,
        'effective_headroom_percent': effectiveHeadroomPercent,
        'evidence_as_of': evidenceAsOf,
        'evidence_age_seconds': evidenceAgeSeconds,
        if (resetsAt != null) 'resets_at': resetsAt,
        'available': available,
        'stale': stale,
        if (confidence != null) 'confidence': _receiptNumber(confidence!),
        'confidence_reasons': confidenceReasons,
        'verdict': verdict.wireName,
        'verdict_reason': verdict.explanation,
        'adjustments': adjustments.map((entry) => entry.toJson()).toList(),
      };
}

class RouteSnapshotReceipt {
  final String source;
  final int? asOf;
  final int? ageSeconds;
  final bool stale;

  /// The [stale] flag covers the complete filtered snapshot, not the selected
  /// winner. It can be caused by envelope age or by any unsafe provider row.
  /// Candidate receipts carry their own provider-level `stale` flag.
  static const staleScope = 'snapshot';

  const RouteSnapshotReceipt({
    required this.source,
    required this.asOf,
    required this.ageSeconds,
    required this.stale,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'as_of': asOf,
        'age_seconds': ageSeconds,
        'stale': stale,
        'stale_scope': staleScope,
      };
}

class RoutePolicyReceipt {
  final String routing;
  final List<String> spendOrder;
  final double comfortThresholdPercent;
  final double leadHours;
  final double riskZ;

  const RoutePolicyReceipt({
    required this.routing,
    required this.spendOrder,
    required this.comfortThresholdPercent,
    required this.leadHours,
    required this.riskZ,
  });

  Map<String, dynamic> toJson() => {
        'routing': routing,
        'spend_order': spendOrder,
        'comfort_threshold_percent': _receiptNumber(comfortThresholdPercent),
        'lead_hours': _receiptNumber(leadHours),
        'risk_z': _receiptNumber(riskZ),
      };
}

class RouteFallbackReceipt {
  final String kind;
  final String? provider;
  final int? resetsAt;
  final String reason;

  const RouteFallbackReceipt({
    required this.kind,
    required this.provider,
    required this.resetsAt,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (provider != null) 'provider': provider,
        if (resetsAt != null) 'resets_at': resetsAt,
        'reason': reason,
      };
}

class RouteDecisionReceipt {
  static const schema = 'quotabot.receipt.v1';

  final String decisionId;
  final int asOf;
  final RouteDecisionCode outcome;
  final String explanation;
  final RouteSnapshotReceipt snapshot;
  final RoutePolicyReceipt policy;
  final RouteCandidateReceipt? winner;
  final List<RouteCandidateReceipt> alternatives;
  final RouteFallbackReceipt fallback;

  const RouteDecisionReceipt._({
    required this.decisionId,
    required this.asOf,
    required this.outcome,
    required this.explanation,
    required this.snapshot,
    required this.policy,
    required this.winner,
    required this.alternatives,
    required this.fallback,
  });

  factory RouteDecisionReceipt.create({
    required int asOf,
    required RouteDecisionCode outcome,
    required String explanation,
    required RouteSnapshotReceipt snapshot,
    required RoutePolicyReceipt policy,
    required RouteCandidateReceipt? winner,
    required List<RouteCandidateReceipt> alternatives,
    required RouteFallbackReceipt fallback,
  }) {
    // The digest makes a replayed decision stable without introducing random
    // state. Its input is the same bounded quota metadata exposed by the
    // receipt itself, never request content or credentials.
    final identity = jsonEncode({
      'as_of': asOf,
      'outcome': outcome.wireName,
      'snapshot': snapshot.toJson(),
      'policy': policy.toJson(),
      'winner': winner?.toJson(),
      'alternatives': alternatives.map((entry) => entry.toJson()).toList(),
      'fallback': fallback.toJson(),
    });
    final digest = sha256.convert(utf8.encode(identity)).toString();
    return RouteDecisionReceipt._(
      decisionId: 'qb-$asOf-${digest.substring(0, 16)}',
      asOf: asOf,
      outcome: outcome,
      explanation: explanation,
      snapshot: snapshot,
      policy: policy,
      winner: winner,
      alternatives: List.unmodifiable(alternatives),
      fallback: fallback,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'decision_id': decisionId,
        'as_of': asOf,
        'outcome': outcome.wireName,
        'explanation': explanation,
        'snapshot': snapshot.toJson(),
        'policy': policy.toJson(),
        'winner': winner?.toJson(),
        'alternatives': alternatives.map((entry) => entry.toJson()).toList(),
        'fallback': fallback.toJson(),
      };
}
