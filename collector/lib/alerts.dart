import 'analysis.dart';
import 'drift.dart';
import 'insights.dart';
import 'models.dart';

/// Free-headroom thresholds (percent of quota remaining) that grade a window's
/// alert severity. A window with less free than [kAlertRedBelow] is effectively
/// spent; below [kAlertAmberBelow] it is low. These mirror the scale the UI
/// colors use, so the words match the bars.
const double kAlertAmberBelow = 25.0;
const double kAlertRedBelow = 10.0;

/// How urgent a low-quota condition is, by remaining free headroom.
enum AlertSeverity {
  none,
  amber,
  red;

  String get label => name;
}

/// Grades a window's remaining free percent. Lower free is more severe.
AlertSeverity alertSeverity(double freePercent) {
  if (freePercent < kAlertRedBelow) return AlertSeverity.red;
  if (freePercent < kAlertAmberBelow) return AlertSeverity.amber;
  return AlertSeverity.none;
}

/// The severities that raise an alert by default. Red only: warn when a window
/// is spent or nearly so, the point at which routing elsewhere actually matters.
const Set<AlertSeverity> kDefaultAlertOn = {AlertSeverity.red};

/// What condition raised a quota alert.
enum QuotaAlertKind {
  lowQuota('low_quota'),
  projectedWaste('projected_waste');

  final String wireName;

  const QuotaAlertKind(this.wireName);
}

/// A single quota alert: a provider's binding window has crossed a threshold
/// worth acting on. Metadata only; it never carries prompts, code, or content.
/// Serializes as `quotabot.alert.v1`.
class QuotaAlert {
  final QuotaAlertKind kind;
  final String provider;
  final String displayName;
  final String account;
  final ProviderSourceClass sourceClass;

  /// Label of the binding window that crossed (for example `5h` or `weekly`).
  final String window;
  final AlertSeverity severity;

  /// Remaining free headroom percent on the binding window at the crossing.
  final double freePercent;

  /// The provider to route to next, when a better one exists; null otherwise.
  final String? routeTo;
  final String? routeDisplayName;
  final String? routeAccount;
  final ProviderSourceClass? routeSourceClass;
  final double? routeFreePercent;
  final bool routeIsLocal;
  final double? projectedWastePercent;
  final double? burnPercentPerHour;
  final int asOf;

  QuotaAlert({
    this.kind = QuotaAlertKind.lowQuota,
    required this.provider,
    required this.displayName,
    this.account = 'default',
    required this.sourceClass,
    required this.window,
    required this.severity,
    required this.freePercent,
    required this.asOf,
    this.routeTo,
    this.routeDisplayName,
    this.routeAccount,
    this.routeSourceClass,
    this.routeFreePercent,
    this.routeIsLocal = false,
    this.projectedWastePercent,
    this.burnPercentPerHour,
  }) {
    if ((routeTo == null) != (routeSourceClass == null)) {
      throw ArgumentError(
        'routeSourceClass must identify the route when and only when routeTo is set',
      );
    }
  }

  /// A one-line human message, e.g.
  /// "Claude 5h at 8% free - route next to Grok (74% free)".
  String get message {
    final head =
        '${_displayLabel(displayName, account)} $window at ${freePercent.round()}% free';
    if (kind == QuotaAlertKind.projectedWaste) {
      final waste = projectedWastePercent == null
          ? 'quota'
          : '${projectedWastePercent!.round()}%';
      final burn = burnPercentPerHour == null
          ? ''
          : ' at ${burnPercentPerHour!.toStringAsFixed(1)}%/h';
      return '$head - projected $waste would expire unused$burn; use it before reset';
    }
    if (routeTo == null) return head;
    final name = _displayLabel(routeDisplayName ?? routeTo!, routeAccount);
    final detail = routeIsLocal
        ? ' (local)'
        : routeFreePercent != null
            ? ' (${routeFreePercent!.round()}% free)'
            : '';
    return '$head - route next to $name$detail';
  }

  Map<String, dynamic> toJson() => {
        'schema': 'quotabot.alert.v1',
        'kind': kind.wireName,
        'provider': provider,
        'account': account,
        'source_class': sourceClass.wireName,
        'window': window,
        'severity': severity.label,
        'free_percent': double.parse(freePercent.toStringAsFixed(1)),
        if (routeTo != null) 'route_to': routeTo,
        if (routeDisplayName != null) 'route_display_name': routeDisplayName,
        if (routeAccount != null) 'route_account': routeAccount,
        if (routeSourceClass != null)
          'route_source_class': routeSourceClass!.wireName,
        if (routeFreePercent != null)
          'route_free_percent':
              double.parse(routeFreePercent!.toStringAsFixed(1)),
        'route_is_local': routeIsLocal,
        if (projectedWastePercent != null)
          'projected_waste_percent':
              double.parse(projectedWastePercent!.toStringAsFixed(1)),
        if (burnPercentPerHour != null)
          'burn_percent_per_hour':
              double.parse(burnPercentPerHour!.toStringAsFixed(2)),
        'as_of': asOf,
      };
}

/// A pure, edge-triggered alert pass. Given the current [snapshot], the routing
/// [suggestion] for where to send work next, and the set of provider/account
/// identities already alerting ([armed]), it returns the alerts that newly
/// crossed into a triggering severity this cycle and the updated armed set. An
/// identity fires once on the crossing and re-arms only after it recovers, so a
/// steady spent window never re-fires. A stale or integrity-rejected identity
/// holds its prior armed state without firing because it is not trusted current
/// evidence. Local runtimes are never alerted on; they have no quota to spend.
({List<QuotaAlert> fired, Set<String> armed}) computeAlerts({
  required List<ProviderQuota> snapshot,
  required RouteSuggestion suggestion,
  required int now,
  Set<String> armed = const {},
  Set<AlertSeverity> alertOn = kDefaultAlertOn,
}) {
  final fired = <QuotaAlert>[];
  final next = <String>{};
  final rec = suggestion.recommended;
  for (final q in snapshot) {
    if (q.isLocal) continue;
    final key = quotaIdentityKeyFor(q);
    if (!isTrustedQuotaEvidenceAt(q, now)) {
      if (armed.contains(key)) next.add(key);
      continue;
    }
    final bw = bindingWindow(q, now);
    // providerHeadroom also validates every window parses; keep it as the guard,
    // but grade and report the binding window's own headroom so the alert's
    // window label and its free-percent always describe the same window (they
    // could diverge for a spent provider, where the binding window is the one
    // that resets last, not the one with the least headroom).
    if (bw == null || providerHeadroom(q, now) == null) continue;
    final free = quotaWindowHeadroom(q, bw, now);
    final sev = alertSeverity(free);
    if (!alertOn.contains(sev)) continue; // calm or recovered: disarm
    next.add(key);
    if (armed.contains(key)) continue; // already alerting: no re-fire
    final route =
        (rec != null && quotaIdentityKey(rec.provider, rec.account) != key)
            ? rec
            : null;
    fired.add(QuotaAlert(
      provider: q.provider,
      displayName: q.displayName,
      account: q.account,
      sourceClass: q.sourceClass,
      window: bw.label,
      severity: sev,
      freePercent: free,
      asOf: q.asOf,
      routeTo: route?.provider,
      routeDisplayName: route == null
          ? null
          : _displayNameOf(snapshot, route.provider, route.account),
      routeAccount: route?.account,
      routeSourceClass: route?.sourceClass,
      routeFreePercent: route?.headroom,
      routeIsLocal: route?.isLocal ?? false,
    ));
  }
  return (fired: fired, armed: next);
}

/// A pure, edge-triggered projected-waste alert pass. A provider fires when its
/// projected unused quota at reset is at or above [thresholdPercent], then stays
/// armed until the projection falls below the threshold. Stale or
/// integrity-rejected providers hold their prior state without firing because
/// they are not trusted current evidence. Local runtimes are never alerted on;
/// they have no paid quota to lose at reset.
({List<QuotaAlert> fired, Set<String> armed}) computeProjectedWasteAlerts({
  required List<ProviderQuota> snapshot,
  required Map<String, Pace> paceByProvider,
  required int now,
  required double thresholdPercent,
  Set<String> armed = const {},
}) {
  final threshold = thresholdPercent.clamp(0.0, 100.0).toDouble();
  final fired = <QuotaAlert>[];
  final next = <String>{};
  for (final q in snapshot) {
    if (q.isLocal || q.isManual) continue;
    final key = quotaIdentityKeyFor(q);
    if (!isTrustedQuotaEvidenceAt(q, now)) {
      if (armed.contains(key)) next.add(key);
      continue;
    }
    final bw = bindingWindow(q, now);
    final free = providerHeadroom(q, now);
    if (bw == null || bw.resetsAt == null || free == null) continue;
    final pace = paceByProvider[key] ?? paceByProvider[q.provider];
    final waste = pace?.wastedAtReset;
    if (waste == null || waste < threshold) continue;
    next.add(key);
    if (armed.contains(key)) continue;
    fired.add(QuotaAlert(
      kind: QuotaAlertKind.projectedWaste,
      provider: q.provider,
      displayName: q.displayName,
      account: q.account,
      sourceClass: q.sourceClass,
      window: bw.label,
      severity: AlertSeverity.amber,
      freePercent: free,
      projectedWastePercent: waste,
      burnPercentPerHour: pace!.burnPerHour,
      asOf: q.asOf,
      routeSourceClass: null,
    ));
  }
  return (fired: fired, armed: next);
}

String? _displayNameOf(
  List<ProviderQuota> snapshot,
  String provider, [
  String? account,
]) {
  if (account != null) {
    for (final q in snapshot) {
      if (q.provider == provider && q.account == account) return q.displayName;
    }
  }
  for (final q in snapshot) {
    if (q.provider == provider) return q.displayName;
  }
  return null;
}

String _displayLabel(String displayName, String? account) =>
    account != null && account.contains('@') && hasSpecificQuotaAccount(account)
        ? '$displayName ($account)'
        : displayName;

/// A newly available redeemable reset for one provider account: the escape
/// hatch worth telling the user about once, the moment it appears.
class ResetSignal {
  final String provider;
  final String account;
  final String displayName;

  /// The shared escape-hatch message (see [resetAvailableMessage]).
  final String message;

  const ResetSignal({
    required this.provider,
    required this.account,
    required this.displayName,
    required this.message,
  });
}

/// Edge-triggers reset-available signals across a snapshot. Mirrors
/// [computeAlerts]: given the provider identity keys already notified ([armed]),
/// it returns the signals that newly appeared this cycle and the updated armed
/// set, so a caller fires each reset exactly once.
///
/// A provider stays armed while it keeps reporting a redeemable reset. It
/// disarms (so a later new reset can fire again) only on a fresh, account-wide
/// read that genuinely reports none: a this-machine session snapshot or a
/// stale/drifted/suspect read leaves the armed state unchanged, so a live
/// endpoint flapping to a fallback never re-notifies about the same reset.
({List<ResetSignal> fired, Set<String> armed}) computeResetSignals({
  required List<ProviderQuota> snapshot,
  Set<String> armed = const {},
}) {
  final next = <String>{};
  final fired = <ResetSignal>[];
  for (final q in snapshot) {
    final key = quotaIdentityKeyFor(q);
    final message = resetAvailableMessage(q);
    if (message != null) {
      next.add(key);
      if (!armed.contains(key)) {
        fired.add(ResetSignal(
          provider: q.provider,
          account: q.account,
          displayName: q.displayName,
          message: message,
        ));
      }
      continue;
    }
    // No message. Keep a prior armed state unless a fresh account-wide read
    // genuinely reports no reset; that alone proves the reset is gone.
    final genuinelyGone = !q.perMachine &&
        !q.stale &&
        q.driftReason == null &&
        q.suspect == null &&
        q.resetCreditsAvailable == 0;
    if (!genuinelyGone && armed.contains(key)) next.add(key);
  }
  return (fired: fired, armed: next);
}
