/// Presentation for the human `suggest` glance, kept separate from the routing
/// logic in analysis.dart and testable without spawning the CLI.
library;

import 'analysis.dart';
import 'ansi.dart';
import 'labels.dart';
import 'models.dart';
import 'provider_ids.dart';

/// The one-line human summary of a metered route candidate for the `suggest`
/// candidates list. It states only what a person acts on: how much headroom
/// remains, whether the route is usable now, and how the number reads (free,
/// last known/trusted, spent).
///
/// The model's internal scores - confidence, strand probability, and cost
/// weighting - are deliberately omitted here and reserved for the
/// machine-readable JSON (`suggest --json`), where they remain in full. The
/// raw scores read as jargon on a glance ("strand 98%" on the recommended
/// provider is alarming and needs a paragraph to interpret), so keeping them
/// out of the plain surface is what makes the advisor self-explanatory
/// (ROADMAP 0.9). This renders one metered candidate; local runtimes are a
/// distinct "runtime fallback" line handled by the caller.
///
/// [provenance] is the already-formatted trust and source tag, and [style]
/// applies color (or is a no-color style). The leading indent matches the rest
/// of the candidates block.
String routeCandidateGlanceLine(
  RouteCandidate c, {
  required AnsiStyle style,
  required String provenance,
}) {
  final pct = c.headroom == null
      ? '   ? '
      : '${c.headroom!.round().toString().padLeft(3)}%';
  final head = c.headroom == null
      ? pct
      : c.stale
          ? style.dim(pct)
          : style.health(c.headroom!, pct);
  var qualifier = c.driftReason != null
      ? c.headroom == null
          ? 'no trusted quota'
          : 'free, last trusted'
      : c.headroom == null
          ? c.stale
              ? 'last known'
              : 'free'
          : c.stale
              ? 'free, last known'
              : 'free';
  if (c.leaseDiscount > 0) {
    qualifier += ' (-${c.leaseDiscount.round()}% reserved)';
  }
  if (c.pipeDiscount > 0) {
    qualifier += ' (-${c.pipeDiscount.round()}% degraded)';
  }
  // Model-budget headroom is the open pool, not the account card. An available
  // Antigravity route can read 100% here while its tightest weekly pool is spent.
  if (c.available &&
      c.bindingPool == 'model_budget' &&
      qualifier.startsWith('free')) {
    qualifier = 'open pool${qualifier.substring('free'.length)}';
  }
  // A candidate can be unroutable for reasons other than being spent. Show the
  // real one, matching the distinctions suggestRoute's reason draws: drift or
  // staleness reads "unavailable"; a provider with headroom but no catalog model
  // meeting the capability floor reads "no capable model"; one whose capable
  // model exists but whose model-budget gate is closed reads "model budget
  // spent"; only a genuinely depleted window reads "spent".
  final hasHeadroom = (c.headroom ?? 0) > kSpentHeadroomFloor;
  final state = c.available
      ? ''
      : c.driftReason != null || c.stale
          ? style.dim('  unavailable')
          : c.capabilityLimited && hasHeadroom
              ? style.dim('  no capable model')
              : c.capabilityBudgetLimited && hasHeadroom
                  ? style.dim('  model budget spent')
                  : style.red('  spent');
  return '    ${c.provider.padRight(12)} $head $qualifier  $provenance$state';
}

/// The shared human route line for doctor, suggest, and top.
///
/// [accountLabel] is an already-formatted suffix such as ` @home@example.com`.
/// The machine-readable [RouteSuggestion.explanation] stays untouched.
class HumanRouteGlance {
  final String providerLabel;
  final String accountLabel;
  final String detail;
  final String reasonTail;
  final String? fit;
  final String? note;

  const HumanRouteGlance({
    required this.providerLabel,
    required this.accountLabel,
    required this.detail,
    required this.reasonTail,
    this.fit,
    this.note,
  });

  /// `next  Antigravity  79% free, resets Thu 6:11 PM`.
  String get signature {
    if (providerLabel == 'your usual model') {
      return 'next  your usual model ($detail)';
    }
    final account = accountLabel;
    final middle = detail.isEmpty ? '' : '  $detail';
    return 'next  $providerLabel$account$middle';
  }

  List<String> get lines => [
        signature,
        if (reasonTail.isNotEmpty) reasonTail,
        if (fit != null) 'fit  $fit',
        if (note != null) 'note  $note',
      ];
}

HumanRouteGlance humanRouteGlance(
  RouteSuggestion suggestion,
  int now, {
  String accountLabel = '',
}) {
  final recommended = suggestion.recommended;
  if (recommended == null) {
    final fallback = suggestion.fallback;
    if (fallback.kind == RouteFallbackKind.soonestReset &&
        fallback.provider != null) {
      final reset = fallback.resetsAt == null
          ? 'spent'
          : 'spent, ${spentResetPhrase(fallback.resetsAt!, now)}';
      return HumanRouteGlance(
        providerLabel: providerDisplayName(fallback.provider!),
        accountLabel: '',
        detail: reset,
        reasonTail: suggestion.reason,
      );
    }
    // Stale, drifted, and otherwise blocked snapshots still have a read.
    // Naming that provider keeps the login prompt for a fleet with no read.
    final evidence = _blockedEvidence(suggestion.ranked);
    if (evidence != null) {
      return HumanRouteGlance(
        providerLabel: providerDisplayName(evidence.provider),
        accountLabel: '',
        detail: _blockedDetail(suggestion.decisionCode),
        reasonTail: suggestion.reason,
      );
    }
    return const HumanRouteGlance(
      providerLabel: 'your usual model',
      accountLabel: '',
      detail: 'no quota read yet; quotabot login claude',
      reasonTail: '',
    );
  }
  final parts = <String>[];
  final headroom = recommended.headroom;
  if (headroom != null) {
    parts.add(
      recommended.available || headroom > kSpentHeadroomFloor
          ? '${headroom.round()}% free'
          : 'spent',
    );
  }
  final resetsAt = recommended.resetsAt;
  if (resetsAt != null) parts.add(spentResetPhrase(resetsAt, now));
  final local = recommended.localModel;
  String? fit;
  if (local != null) {
    final bits = <String>[
      if (local.hardwareFit != null && local.hardwareFit != 'unknown')
        local.hardwareFit!,
      if (local.contextTokens != null) '${local.contextTokens} context',
      if (local.localReadiness != null) local.localReadiness!,
    ];
    if (bits.isNotEmpty) fit = bits.join(', ');
  }
  return HumanRouteGlance(
    providerLabel: providerDisplayName(recommended.provider),
    accountLabel: accountLabel,
    detail: parts.join(', '),
    reasonTail: _routeReasonTail(suggestion),
    fit: fit,
    note: recommended.isLocal
        ? 'execution location and cost are not independently verified'
        : null,
  );
}

/// The candidate the blocked glance should name. Drift and cached headroom
/// outrank a later local row, because those are the reads the reason describes.
RouteCandidate? _blockedEvidence(List<RouteCandidate> ranked) {
  if (ranked.isEmpty) return null;
  for (final candidate in ranked) {
    if (candidate.driftReason != null) return candidate;
  }
  for (final candidate in ranked) {
    if (candidate.stale && candidate.headroom != null) return candidate;
  }
  return ranked.first;
}

String _blockedDetail(RouteDecisionCode code) => switch (code) {
      RouteDecisionCode.staleEvidence => 'cached',
      RouteDecisionCode.providerDrift => 'not routable',
      _ => 'unavailable',
    };

String _routeReasonTail(RouteSuggestion suggestion) {
  final recommended = suggestion.recommended;
  final reason = suggestion.reason;
  if (recommended == null) return reason;
  final prefix = 'Use ${recommended.provider} - ';
  if (reason.startsWith(prefix)) return reason.substring(prefix.length);
  return reason;
}
