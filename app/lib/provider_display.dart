/// Pure display derivation for the desktop dashboard: how the fleet is grouped,
/// the route glance and detail lines, the per-provider trust line, setup copy,
/// row visibility, and the trusted-pool headroom. No widgets and no state - all
/// functions take a snapshot and return strings/values, so they are unit tested
/// directly. Extracted from main.dart to keep the dashboard state file focused.
library;

import 'dart:async';

import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/webhook.dart';

import 'profile_ui.dart';
import 'quota_labels.dart';

String _desktopSourceLabel(ProviderSourceClass sourceClass) =>
    sourceClass == ProviderSourceClass.authoritativeLive
    ? 'account-wide'
    : sourceClass.label;

class ProviderDisplayGroup {
  final String? account;
  final List<ProviderQuota> quotas;

  const ProviderDisplayGroup({required this.account, required this.quotas});
}

List<ProviderDisplayGroup> groupProvidersForDisplay(List<ProviderQuota> data) {
  // Group by account only when it is genuinely meaningful: some provider is
  // signed in under more than one account (a real work/personal split on the
  // same service). Signing into different providers with different emails - the
  // common case - is not multi-account, so account headers there would just be
  // noise, and the fleet stays one ungrouped list. A local runtime's account
  // field is a model summary ("3 models"), not an identity, so locals never
  // define a group and land in the account-less bucket.
  final accountsByProvider = <String, Set<String>>{};
  for (final q in data) {
    if (!q.isLocal && quotaHasSpecificAccount(q)) {
      accountsByProvider
          .putIfAbsent(q.provider, () => <String>{})
          .add(q.account);
    }
  }
  final hasDuplicatedAccount = accountsByProvider.values.any(
    (accounts) => accounts.length > 1,
  );
  if (!hasDuplicatedAccount) {
    return [ProviderDisplayGroup(account: null, quotas: List.of(data))];
  }

  final grouped = <String, List<ProviderQuota>>{};
  final groupAccounts = <String, String?>{};
  for (final q in data) {
    final account = !q.isLocal && quotaHasSpecificAccount(q) ? q.account : null;
    final key = account ?? '';
    grouped.putIfAbsent(key, () => <ProviderQuota>[]).add(q);
    groupAccounts.putIfAbsent(key, () => account);
  }
  return [
    for (final entry in grouped.entries)
      ProviderDisplayGroup(
        account: groupAccounts[entry.key],
        quotas: List.of(entry.value),
      ),
  ];
}

(ProviderQuota?, String, String) _routeDisplay(
  RouteCandidate candidate,
  List<ProviderQuota> snapshot,
  bool showAccounts,
) {
  ProviderQuota? quota;
  for (final q in snapshot) {
    if (q.provider == candidate.provider && q.account == candidate.account) {
      quota = q;
      break;
    }
  }
  final display = quota?.displayName ?? candidate.provider;
  final counts = <String, int>{};
  for (final q in snapshot) {
    counts[q.provider] = (counts[q.provider] ?? 0) + 1;
  }
  final accountLabel =
      quota != null &&
          showAccounts &&
          quotaShouldShowAccountLabel(quota, counts)
      ? ' (${quotaAccountDisplayLabel(quota.account)})'
      : '';
  return (quota, display, accountLabel);
}

/// The compact glance line: just the route and how much is free (or that it is a
/// local fallback), so it never truncates mid-word. The provenance, burn, and
/// confidence detail lives in [desktopRouteDetailLine], shown on hover.
String? desktopRouteSignalLine(
  RouteSuggestion suggestion,
  List<ProviderQuota> snapshot,
  int now, {
  bool showAccounts = false,
}) {
  final candidate = suggestion.recommended;
  if (candidate == null) return null;
  final (_, display, accountLabel) = _routeDisplay(
    candidate,
    snapshot,
    showAccounts,
  );
  final buf = StringBuffer('Next: $display$accountLabel');
  if (candidate.isLocal) {
    buf.write(' - local fallback');
  } else if (candidate.headroom != null) {
    final prefix = candidate.stale ? 'cached ' : '';
    buf.write(' - $prefix${candidate.headroom!.round()}% free');
  }
  return buf.toString();
}

/// The full route detail (provenance, burn-adjusted headroom, confidence, age),
/// kept off the compact glance line so it never overflows. Shown on hover and
/// carried into machine-readable surfaces.
String? desktopRouteDetailLine(
  RouteSuggestion suggestion,
  List<ProviderQuota> snapshot,
  int now, {
  bool showAccounts = false,
}) {
  final candidate = suggestion.recommended;
  if (candidate == null) return null;
  final (_, display, accountLabel) = _routeDisplay(
    candidate,
    snapshot,
    showAccounts,
  );
  final parts = <String>[
    'Next: $display$accountLabel',
    _desktopSourceLabel(candidate.sourceClass),
  ];
  if (candidate.isLocal) {
    parts.add('fallback');
  } else if (candidate.headroom != null) {
    final prefix = candidate.stale ? 'cached ' : '';
    parts.add('$prefix${candidate.headroom!.round()}% free');
    final effective = candidate.effectiveHeadroom;
    if (effective != null && candidate.headroom! - effective >= 1) {
      final burnActive =
          candidate.burnPerHour != null && candidate.burnPerHour! > 0;
      final forecastRiskActive =
          suggestion.riskZ > 0 &&
          candidate.burnSe != null &&
          candidate.burnSe! > 0;
      final causes = <String>[
        if (burnActive && forecastRiskActive)
          'burn/forecast risk'
        else if (burnActive)
          'burn'
        else if (forecastRiskActive)
          'forecast risk',
        if (candidate.leaseDiscount > 0) 'leases',
        if (candidate.pipeDiscount > 0) 'pipe',
      ];
      if (causes.isNotEmpty) {
        parts.add('${effective.round()}% after ${causes.join('/')}');
      }
    }
  }
  final confidence = candidate.confidence;
  if (confidence != null) {
    final pct = (confidence * 100).round().clamp(0, 100);
    final label = confidence >= 0.8
        ? 'high confidence'
        : confidence >= 0.55
        ? 'medium confidence'
        : 'low confidence';
    parts.add('$label ($pct%)');
  }
  final ageSeconds = now - candidate.asOf;
  if (ageSeconds >= 60) {
    parts.add('as of ${ageLabel(candidate.asOf, now)} ago');
  }
  parts.add('Receipt: ${suggestion.receipt.decisionId}');
  parts.add('Decision: ${suggestion.explanation}');
  return parts.join(' | ');
}

String desktopProviderTrustLine(ProviderQuota quota, int now) {
  final parts = <String>[
    _desktopProviderReadState(quota, now),
    _desktopSourceLabel(quota.sourceClass),
  ];
  final spendClass = _desktopProviderSpendClass(quota);
  if (spendClass != null) parts.add(spendClass);
  final captured = _desktopCaptureAgeLabel(quota.asOf, now);
  if (captured.isNotEmpty) parts.add(captured);
  return parts.join(' | ');
}

String _desktopProviderReadState(ProviderQuota quota, int now) {
  // Provenance violations are more fundamental than transport or cache state.
  // Name them first so a rejected observation is never softened to a generic
  // "error" or mistaken for an ordinary provider drift response.
  if (quota.sourceClassViolation != null) return 'invalid evidence';
  if (quota.isLocal) {
    if (!quota.ok || quota.error != null) return 'error';
    if (quota.stale) return 'cached';
    if (quota.asOf <= 0 || quota.asOf > now + kQuotaEvidenceClockSkewSeconds) {
      return 'unverified';
    }
    if (!isLocalRuntimeAvailableAt(quota, now)) return 'unavailable';
    return quota.active ? 'in use' : 'available';
  }
  if (quota.driftReason != null) return 'provider drift';
  if (!quota.ok) return 'error';
  if (quota.stale) return 'cached';
  if (quota.suspect != null) return 'review reading';
  if (quota.asOf <= 0 || quota.asOf > now + kQuotaEvidenceClockSkewSeconds) {
    return 'unverified';
  }
  if (quota.windows.isNotEmpty && !isTrustedQuotaEvidenceAt(quota, now)) {
    return 'unverified';
  }
  if (quota.windows.isEmpty && (quota.status ?? '').isEmpty) {
    return 'no live data';
  }
  if (quota.windows.isEmpty) return 'metadata';
  return 'live';
}

/// Full plain-language provenance for hover and assistive technology. The
/// visible trust line stays compact, while this detail makes the key distinction
/// between account-wide provider data and evidence limited to this machine.
String desktopProviderTrustDetail(ProviderQuota quota, int now) {
  final state = _desktopProviderReadState(quota, now);
  final scope = switch (quota.sourceClass) {
    ProviderSourceClass.authoritativeLive =>
      'Account-wide quota read from provider metadata.',
    ProviderSourceClass.thisMachineFallback =>
      'Fallback quota evidence from this machine only; other devices may not be included.',
    ProviderSourceClass.passiveLocalEvidence =>
      'Passive quota evidence from this machine only; other devices may not be included.',
    ProviderSourceClass.localRuntime =>
      'Local runtime availability observed on this machine.',
    ProviderSourceClass.statusOnly =>
      'Provider availability metadata without a numeric quota balance.',
    ProviderSourceClass.manual =>
      'Quota entered manually; it is not provider-measured evidence.',
  };
  final detail = <String>['State: $state.', scope];
  final violation = quota.sourceClassViolation;
  if (violation != null) detail.add('Evidence rejected: $violation.');
  if (quota.suspect != null) {
    detail.add('Reading needs review: ${quota.suspect}.');
  }
  if (quota.stale &&
      quota.driftReason == null &&
      quota.error?.isNotEmpty == true) {
    final throttled =
        quota.pipeHealth == providerPipeHealthThrottled ||
        quota.pipeHealth == providerPipeHealthDegraded;
    if (throttled) {
      detail.add(
        'Provider is responding slowly (throttled): ${quota.error}. Showing '
        'last-known quota and backing off; it retries automatically.',
      );
    } else {
      detail.add(
        quota.hasWindows
            ? 'Latest live read failed: ${quota.error}. Showing last-known quota; '
                  'routing is disabled until recovery.'
            : 'Latest live read failed: ${quota.error}. No current quota is available.',
      );
    }
  }
  if (quota.asOf > 0) {
    detail.add(
      quota.asOf > now
          ? 'Capture time is ahead of this machine clock.'
          : 'Captured ${ageLabel(quota.asOf, now)} ago.',
    );
  } else {
    detail.add('Capture time is unavailable.');
  }
  return detail.join(' ');
}

String? _desktopProviderSpendClass(ProviderQuota quota) {
  if (!quota.sourceClass.carriesMeasuredQuota || quota.windows.isEmpty) {
    return null;
  }
  return kQuotaPlanProviders.contains(quota.provider)
      ? 'quota plan'
      : 'metered plan';
}

String _desktopCaptureAgeLabel(int asOf, int now) {
  if (asOf <= 0) return 'capture time unknown';
  if (asOf > now) return 'captured in the future';
  return 'captured ${ageLabel(asOf, now)} ago';
}

String providerSetupText(String provider) {
  switch (provider) {
    case 'codex':
      return 'Sign in to the Codex CLI (run codex once). quotabot reads the '
          'account-wide ChatGPT usage endpoint with that credential. If the '
          'credential is unavailable or expired, quotabot shows no current '
          'quota instead of inferring usage from this machine\'s sessions. You '
          'can also run quotabot login codex to keep the metadata read '
          'refreshable.';
    case 'claude':
      return 'Sign in to Claude Code. quotabot reads its account-wide usage '
          'endpoint automatically while that credential is current. If this '
          'idle machine shows cached data, re-run claude or use quotabot login '
          'claude once to keep the metadata read refreshable.';
    case 'grok':
      return 'Grok shows live while the Grok CLI token is fresh. To keep it '
          'live without reopening the CLI, connect quotabot once with a device '
          'code (works on Windows, macOS, and Linux).';
    case 'antigravity':
      return 'Antigravity shows live while the IDE token is fresh. To keep it '
          'live without reopening the IDE, connect quotabot once and sign in '
          'with the account you want shown.';
    case 'nvidia':
      return 'Set NVIDIA_API_KEY or nvapi to check NVIDIA NIM trial access. '
          'quotabot only calls /v1/models and shows availability without a '
          'numeric balance.';
    case 'kiro':
    case 'cursor':
    case 'windsurf':
      return 'Detected from the app\'s local data. If it shows no data, open '
          'the app once and sign in, then refresh.';
    case 'ollama':
    case 'lmstudio':
    case 'lemonade':
      return 'Local runtime. Start its server and load a model; quotabot '
          'detects what is installed and loaded automatically. No login '
          'needed.';
    default:
      return 'quotabot reads this provider from local or provider metadata; '
          'no setup needed here.';
  }
}

bool providerRowShouldBeVisible(
  ProviderQuota quota,
  Set<String> detectedProviders,
) {
  if (quota.windows.isNotEmpty || quota.stale) return true;
  if ((quota.status ?? '').isNotEmpty) return true;
  final err = (quota.error ?? '').toLowerCase();
  final passiveStub =
      err.contains('installed') ||
      err.contains('no data') ||
      err.contains('free tier') ||
      err.contains('not configured') ||
      err.contains('not installed');
  if (passiveStub) return detectedProviders.contains(quota.provider);
  return true;
}

List<ProviderQuota> visibleProviderRows(
  List<ProviderQuota> results,
  Set<String> detectedProviders,
) => [
  for (final quota in results)
    if (providerRowShouldBeVisible(quota, detectedProviders)) quota,
];

List<ProviderQuota> providerSetupRows(List<ProviderQuota> results) {
  final seen = <String>{};
  final rows = <ProviderQuota>[];
  for (final quota in results) {
    if (seen.add(quotaDisplayKey(quota))) rows.add(quota);
  }
  return rows;
}

String refreshFailureMessage(Object error, {required bool hasPreviousData}) {
  final outcome = hasPreviousData
      ? 'showing previous data'
      : 'retrying automatically';
  return error is TimeoutException
      ? 'Refresh timed out; $outcome'
      : 'Refresh failed; $outcome';
}

/// A completed collection can still contain no trustworthy current evidence,
/// for example when every provider returned a cache fallback or an error row.
/// Treat that as a degraded refresh rather than silently presenting the check
/// time as if it were the quota capture time.
String refreshNoCurrentDataMessage({required bool hasRows}) => hasRows
    ? 'No current quota data; showing cached or unavailable providers'
    : 'No current quota data; retrying automatically';

String webhookDeliveryStatus(WebhookResult result) {
  if (result.ok) return 'Last delivery succeeded';
  final statusCode = result.statusCode;
  return statusCode == null
      ? 'Last delivery failed'
      : 'Last delivery failed (HTTP $statusCode)';
}

double? trustedPoolHeadroom(Iterable<ProviderQuota> quotas, int now) {
  double sum = 0;
  int count = 0;
  for (final quota in quotas) {
    if (!isTrustedQuotaEvidenceAt(quota, now)) continue;
    final headroom = providerHeadroom(quota, now);
    if (headroom == null) continue;
    sum += headroom;
    count++;
  }
  return count == 0 ? null : sum / count;
}

/// Scheduled reset claims and reset-credit notifications require the same
/// current, trusted provider evidence as routing. A future reset timestamp does
/// not make a rejected snapshot safe to notify from.
bool canScheduleQuotaResetAlert(ProviderQuota quota, int now) =>
    isTrustedQuotaEvidenceAt(quota, now);

Map<String, int> _notificationProviderCounts(Iterable<ProviderQuota> snapshot) {
  final counts = <String, int>{};
  for (final quota in snapshot) {
    counts[quota.provider] = (counts[quota.provider] ?? 0) + 1;
  }
  return counts;
}

ProviderQuota? _notificationQuota(
  Iterable<ProviderQuota> snapshot,
  String provider,
  String? account,
) {
  if (account != null) {
    for (final quota in snapshot) {
      if (quota.provider == provider && quota.account == account) return quota;
    }
  }
  for (final quota in snapshot) {
    if (quota.provider == provider) return quota;
  }
  return null;
}

String _notificationProviderLabel({
  required Iterable<ProviderQuota> snapshot,
  required Map<String, int> providerCounts,
  required String provider,
  required String displayName,
  required String? account,
  required bool showAccounts,
}) {
  final quota = _notificationQuota(snapshot, provider, account);
  if (!showAccounts ||
      quota == null ||
      !quotaShouldShowAccountLabel(quota, providerCounts)) {
    return displayName;
  }
  return '$displayName (${quotaAccountDisplayLabel(quota.account)})';
}

/// A native low-quota notification body that follows the desktop account-name
/// preference. The webhook keeps its stable machine-readable payload; only the
/// local human-facing text is privacy-filtered here.
String desktopQuotaAlertNotificationMessage(
  QuotaAlert alert,
  List<ProviderQuota> snapshot, {
  required bool showAccounts,
}) {
  final counts = _notificationProviderCounts(snapshot);
  final providerLabel = _notificationProviderLabel(
    snapshot: snapshot,
    providerCounts: counts,
    provider: alert.provider,
    displayName: alert.displayName,
    account: alert.account,
    showAccounts: showAccounts,
  );
  final head =
      '$providerLabel ${alert.window} at ${alert.freePercent.round()}% free';
  if (alert.kind == QuotaAlertKind.projectedWaste) {
    final waste = alert.projectedWastePercent == null
        ? 'quota'
        : '${alert.projectedWastePercent!.round()}%';
    final burn = alert.burnPercentPerHour == null
        ? ''
        : ' at ${alert.burnPercentPerHour!.toStringAsFixed(1)}%/h';
    return '$head - projected $waste would expire unused$burn; use it before reset';
  }
  if (alert.routeTo == null) return head;
  final routeLabel = _notificationProviderLabel(
    snapshot: snapshot,
    providerCounts: counts,
    provider: alert.routeTo!,
    displayName: alert.routeDisplayName ?? alert.routeTo!,
    account: alert.routeAccount,
    showAccounts: showAccounts,
  );
  final detail = alert.routeIsLocal
      ? ' (local)'
      : alert.routeFreePercent != null
      ? ' (${alert.routeFreePercent!.round()}% free)'
      : '';
  return '$head - route next to $routeLabel$detail';
}

/// Provider label used by native notification bodies and their Windows
/// subtitle. Account identities appear only when the preference is enabled and
/// more than one account for that provider needs disambiguation.
String desktopNotificationProviderLabel(
  ProviderQuota quota,
  List<ProviderQuota> snapshot, {
  required bool showAccounts,
}) => _notificationProviderLabel(
  snapshot: snapshot,
  providerCounts: _notificationProviderCounts(snapshot),
  provider: quota.provider,
  displayName: quota.displayName,
  account: quota.account,
  showAccounts: showAccounts,
);

/// Applies the same account-label policy to a reset-credit notification as to
/// scheduled reset and low-quota messages.
String desktopResetAvailableNotificationMessage(
  ResetSignal signal,
  List<ProviderQuota> snapshot, {
  required bool showAccounts,
}) {
  final label = _notificationProviderLabel(
    snapshot: snapshot,
    providerCounts: _notificationProviderCounts(snapshot),
    provider: signal.provider,
    displayName: signal.displayName,
    account: signal.account,
    showAccounts: showAccounts,
  );
  return signal.message.replaceFirst('in ${signal.displayName}', 'in $label');
}
