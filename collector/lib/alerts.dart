import 'analysis.dart';
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

/// A single low-quota alert: a provider's binding window has crossed into a
/// triggering severity, with where to route next instead. Metadata only; it
/// never carries prompts, code, or content. Serializes as `quotabot.alert.v1`.
class QuotaAlert {
  final String provider;
  final String displayName;

  /// Label of the binding window that crossed (for example `5h` or `weekly`).
  final String window;
  final AlertSeverity severity;

  /// Remaining free headroom percent on the binding window at the crossing.
  final double freePercent;

  /// The provider to route to next, when a better one exists; null otherwise.
  final String? routeTo;
  final String? routeDisplayName;
  final double? routeFreePercent;
  final bool routeIsLocal;
  final int asOf;

  const QuotaAlert({
    required this.provider,
    required this.displayName,
    required this.window,
    required this.severity,
    required this.freePercent,
    required this.asOf,
    this.routeTo,
    this.routeDisplayName,
    this.routeFreePercent,
    this.routeIsLocal = false,
  });

  /// A one-line human message, e.g.
  /// "Claude 5h at 8% free - route next to Grok (74% free)".
  String get message {
    final head = '$displayName $window at ${freePercent.round()}% free';
    if (routeTo == null) return head;
    final name = routeDisplayName ?? routeTo!;
    final detail = routeIsLocal
        ? ' (local)'
        : routeFreePercent != null
            ? ' (${routeFreePercent!.round()}% free)'
            : '';
    return '$head - route next to $name$detail';
  }

  Map<String, dynamic> toJson() => {
        'schema': 'quotabot.alert.v1',
        'provider': provider,
        'window': window,
        'severity': severity.label,
        'free_percent': double.parse(freePercent.toStringAsFixed(1)),
        if (routeTo != null) 'route_to': routeTo,
        if (routeDisplayName != null) 'route_display_name': routeDisplayName,
        if (routeFreePercent != null)
          'route_free_percent':
              double.parse(routeFreePercent!.toStringAsFixed(1)),
        'route_is_local': routeIsLocal,
        'as_of': asOf,
      };
}

/// A pure, edge-triggered alert pass. Given the current [snapshot], the routing
/// [suggestion] for where to send work next, and the set of provider ids already
/// alerting ([armed]), it returns the alerts that newly crossed into a
/// triggering severity this cycle and the updated armed set. A provider fires
/// once on the crossing and re-arms only after it recovers, so a steady spent
/// window never re-fires. A stale provider holds its prior armed state without
/// firing (a cached red is not a fresh crossing). Local runtimes are never
/// alerted on; they have no quota to spend.
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
    final bw = bindingWindow(q, now);
    final free = providerHeadroom(q, now);
    if (bw == null || free == null) continue;
    if (q.stale) {
      if (armed.contains(q.provider)) next.add(q.provider);
      continue;
    }
    final sev = alertSeverity(free);
    if (!alertOn.contains(sev)) continue; // calm or recovered: disarm
    next.add(q.provider);
    if (armed.contains(q.provider)) continue; // already alerting: no re-fire
    final route = (rec != null && rec.provider != q.provider) ? rec : null;
    fired.add(QuotaAlert(
      provider: q.provider,
      displayName: q.displayName,
      window: bw.label,
      severity: sev,
      freePercent: free,
      asOf: q.asOf,
      routeTo: route?.provider,
      routeDisplayName:
          route == null ? null : _displayNameOf(snapshot, route.provider),
      routeFreePercent: route?.headroom,
      routeIsLocal: route?.isLocal ?? false,
    ));
  }
  return (fired: fired, armed: next);
}

String? _displayNameOf(List<ProviderQuota> snapshot, String provider) {
  for (final q in snapshot) {
    if (q.provider == provider) return q.displayName;
  }
  return null;
}
