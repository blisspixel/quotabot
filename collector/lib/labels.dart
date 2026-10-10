/// Shared human-facing time and recovery labels. Pure and side-effect free, so
/// collector and desktop surfaces render the same evidence without duplicating
/// arithmetic or failure classification.
library;

import 'analysis.dart';
import 'models.dart';
import 'util.dart';

/// A coarse "resets in ..." label for an optional reset time: `soon` when
/// unknown, `now` when already reached, else the largest useful whole unit
/// (`3d`, `5h`, `45m`).
/// Used by the passive-local adapters (Cursor, Kiro, Windsurf) whose state files
/// carry a single reset boundary.
String resetCountdownLabel(int? resetsAt, int now) {
  if (resetsAt == null) return 'soon';
  final secs = resetsAt - now;
  if (secs <= 0) return 'now';
  final days = secs ~/ 86400;
  if (days > 0) return '${days}d';
  final hours = secs ~/ 3600;
  if (hours > 0) return '${hours}h';
  final minutes = secs ~/ 60;
  return minutes > 0 ? '${minutes}m' : '<1m';
}

/// A compact single-unit age for [seconds] elapsed, rounded to the nearest unit:
/// `45s`, `12m`, `3h`, `2d`. With [suffix] the unit is followed by it (e.g.
/// ` ago`). With [floorNow], anything under a minute reads `now` instead of
/// seconds - used by the terse `top` tag where a raw seconds count is noise.
/// This is the collector's rounding age policy, shared by the CLI, `top`, and the
/// report so a captured-age reads the same on every terminal surface.
String compactAge(int seconds, {String suffix = '', bool floorNow = false}) {
  if (floorNow) {
    if (seconds < 60) return 'now';
  } else if (seconds < 90) {
    return '${seconds}s$suffix';
  }
  if (seconds < 5400) return '${(seconds / 60).round()}m$suffix';
  if (seconds < 129600) return '${(seconds / 3600).round()}h$suffix';
  return '${(seconds / 86400).round()}d$suffix';
}

const capturedInFutureLabel = 'captured in the future';

/// A complete capture-age phrase for provenance and trust labels.
///
/// Exact current evidence reads naturally as `captured just now`; older
/// evidence keeps the compact elapsed unit, and clock skew stays explicit.
String capturedAgeLabel(int capturedAt, int now) {
  if (capturedAt <= 0) return '';
  if (capturedAt > now) return capturedInFutureLabel;
  final elapsed = now - capturedAt;
  if (elapsed == 0) return 'captured just now';
  return 'captured ${compactAge(elapsed, suffix: ' ago')}';
}

/// Access evidence is separate from the measured balance of a quota pool.
String? requestAdmissionLabel(RequestAdmission admission) =>
    switch (admission) {
      RequestAdmission.denied => 'requests denied',
      RequestAdmission.unresolved => 'request status unverified',
      _ => null,
    };

String? requestAdmissionDetail(RequestAdmission admission) =>
    switch (admission) {
      RequestAdmission.denied =>
        'The provider denies requests for this pool. Remaining quota is still shown as measured.',
      RequestAdmission.unresolved =>
        'Request availability could not be verified. Remaining quota alone does not establish availability.',
      _ => null,
    };

/// True when [message] is a sign-in or credential repair, not a quota reading.
bool quotaFailureNeedsSignIn(String? message) {
  final value = (message ?? '').toLowerCase();
  if (value.isEmpty) return false;
  return const [
    'auth',
    'credential',
    'forbidden',
    'login',
    'sign in',
    'signed out',
    'signed-out',
    'signed_out',
    'token',
    'unauthorized',
    '401',
    '403',
  ].any(value.contains);
}

/// True when the binding window is spent and its reset is still ahead.
bool spentResetStillAhead(ProviderQuota quota, int now) {
  final binding = bindingWindow(quota, now);
  final headroom = providerHeadroom(quota, now);
  if (binding == null || headroom == null || headroom > kSpentHeadroomFloor) {
    return false;
  }
  final reset = binding.resetsAt;
  return reset != null && reset > now;
}

/// True when a second "last known / refresh failed" line would only restate a
/// spent window whose reset is still ahead. The spend and the reset already
/// say what is usable. A rate limit, outage, or sign-in repair still names a
/// different next step, so those notes stay.
bool staleRefreshRepeatsSpentWindow(ProviderQuota quota, int now) {
  final error = quota.error?.trim();
  if (!quota.stale || quota.driftReason != null) return false;
  if (error == null || error.isEmpty) return false;
  if (providerRetrySummary(quota) != null) return false;
  if (quotaFailureNeedsSignIn(error)) return false;
  return spentResetStillAhead(quota, now);
}

/// The one refresh note under a spent window, without "last known". Null when
/// the spend and its reset already say everything a generic failure would.
String? spentWindowRefreshNote(ProviderQuota quota, int now) {
  if (!quota.stale || quota.driftReason != null) return null;
  if (!spentResetStillAhead(quota, now)) return null;
  return providerRetrySummary(quota);
}

/// Concise temporary-provider recovery copy derived only from bounded quota
/// diagnostics. A timeout is not called a rate limit, and a 5xx is not called
/// throttling. A provider Retry-After is an earliest allowed request, not the
/// actual schedule chosen by every caller, so this label never promises a retry
/// time. Returns null for auth, parsing, setup, and other failures.
String? providerRetrySummary(
  ProviderQuota quota, {
  bool showingLastKnown = false,
}) {
  final cause = switch (quota.pipeHealth) {
    // gRPC RESOURCE_EXHAUSTED (status 8) is a rate limit that arrives over
    // HTTP 200, so the 429 check alone would mislabel it "provider slow".
    providerPipeHealthThrottled => quota.httpStatus == 429 ||
            (quota.error?.contains('gRPC status 8') ?? false)
        ? 'quota check rate limited'
        : 'quota check delayed',
    providerPipeHealthDegraded => 'quota service error',
    _ => null,
  };
  if (cause == null) return null;
  final evidence = showingLastKnown ? ', showing last known' : '';
  return '$cause$evidence';
}

/// Primary failure copy for compact user surfaces. Exact request-stage and HTTP
/// evidence stays available in [ProviderQuota.error] for diagnostics.
String providerFailureSummary(
  ProviderQuota quota, {
  bool showingLastKnown = false,
}) {
  final retry = providerRetrySummary(
    quota,
    showingLastKnown: showingLastKnown,
  );
  if (retry != null) return retry;
  final error = quota.error?.trim();
  // An expired-login message carries its exact provider status and repair
  // steps; the generic reconnect line must not displace it.
  if (error != null && error.contains('token expired')) return error;
  if (quota.httpStatus == 401 ||
      (quota.provider == 'antigravity' && quota.httpStatus == 403)) {
    return 'live quota needs reconnecting';
  }
  return error == null || error.isEmpty ? 'no live data' : error;
}

/// A compact two-unit countdown to [resetsAt]: `now` when reached, `2d3h` when a
/// day or more away, otherwise `3h20m`. Used wherever a precise time-to-reset is
/// shown (the `top` view and the CLI). Sub-hour values omit a noisy zero-hour
/// prefix, and a positive sub-minute value stays distinct from an elapsed reset.
String countdown(int resetsAt, int now) {
  var secs = resetsAt - now;
  if (secs <= 0) return 'now';
  final days = secs ~/ 86400;
  secs %= 86400;
  final hours = secs ~/ 3600;
  if (days > 0) return '${days}d${hours}h';
  final minutes = (secs % 3600) ~/ 60;
  if (hours > 0) return '${hours}h${minutes}m';
  return minutes > 0 ? '${minutes}m' : '<1m';
}

/// Reset phrase for a spent window. A near reset stays a countdown (`resets
/// 3h20m`). Eighteen hours or more away, the local day and clock read more
/// clearly than a day-count (`resets Thu 3:00 PM`), and a reset a week out
/// adds the date.
String spentResetPhrase(int resetsAt, int now) {
  final secs = resetsAt - now;
  if (secs <= 0) return 'refresh to confirm';
  if (secs < 18 * 3600) return 'resets ${countdown(resetsAt, now)}';
  final dt = DateTime.fromMillisecondsSinceEpoch(resetsAt * 1000);
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final wd = days[dt.weekday - 1];
  final hour = dt.hour;
  final minute = dt.minute.toString().padLeft(2, '0');
  final suffix = hour >= 12 ? 'PM' : 'AM';
  final hour12 = hour % 12 == 0 ? 12 : hour % 12;
  final clock = '$hour12:$minute $suffix';
  final when =
      secs < 7 * 86400 ? '$wd $clock' : '$wd ${dt.month}/${dt.day} $clock';
  return 'resets $when';
}

/// One doctor window. A cached spend whose reset is still ahead reads as
/// `weekly spent; resets Thu 3:00 PM` and does not also say last known. A
/// percentage, a passed reset, and rejected evidence keep their qualifier.
String doctorWindowDetail(QuotaWindow window, int now, String state) {
  final percent = window.percent;
  final valid =
      percent != null && percent.isFinite && percent >= 0 && percent <= 100;
  final usage = !valid
      ? 'usage unavailable'
      : window.exhausted
          ? 'spent'
          : '${percent.round()}% used';
  final resetAt = window.resetsAt;
  final resetAhead = window.exhausted && resetAt != null && resetAt > now;
  final spentAhead = state == 'cached' && resetAhead;
  final qualifier = spentAhead
      ? null
      : switch (state) {
          'PROVIDER DRIFT' => 'last trusted',
          'cached' => 'last known',
          'NEEDS REVIEW' || 'UNVERIFIED' => 'unverified',
          _ => null,
        };
  final reset = resetAt == null
      ? ''
      : qualifier != null && resetAt <= now
          ? '; reset passed, refresh to confirm'
          : spentAhead || (qualifier == null && resetAhead)
              ? '; ${spentResetPhrase(resetAt, now)}'
              : qualifier == null
                  ? '; resets ${countdown(resetAt, now)}'
                  : '; reset ${countdown(resetAt, now)}';
  return '${window.label} $usage${qualifier == null ? '' : ' ($qualifier)'}$reset';
}

/// Compact glance line for remaining GPU memory when both total and available
/// bytes are known. Used-centric host lines stay in opened detail with RAM,
/// utilization, and inventory.
String? localRuntimeVramFreeLabel(LocalHardwareInfo? hardware) {
  if (hardware == null) return null;
  final total = hardware.gpuMemoryTotalBytes;
  final available = hardware.gpuMemoryAvailableBytes;
  if (total == null || total <= 0 || available == null) return null;
  final free = available.clamp(0, total);
  return 'VRAM ${formatCompactBytes(free)} free of ${formatCompactBytes(total)}';
}

bool _isLocalHostVramDetail(String detail) =>
    detail.trim().toLowerCase().startsWith('local host vram');

bool _isLocalRuntimeGlanceDetail(String detail) {
  final lower = detail.trim().toLowerCase();
  if (_isLocalHostVramDetail(detail)) return true;
  if (lower.contains('more loaded')) return true;
  if (lower.contains('upstream routing')) return true;
  return false;
}

/// A reachable runtime's headline from current normalized load evidence.
/// Legacy status text cannot prove cold residency after cache migration.
/// Callers handle reachability, stale evidence, and read errors separately.
String localRuntimeStatusLabel(ProviderQuota quota) {
  if (quota.hasEligibleLocalGenerationModel &&
      quota.localGenerationReadiness == null) {
    return 'reachable - load state unknown';
  }
  final status = quota.status;
  if (status != null && status.trim().isNotEmpty) return status;
  return switch (quota.localGenerationReadiness) {
    'loaded' => 'loaded',
    'cold' => 'ready - no model loaded',
    _ => 'No eligible generation model',
  };
}

/// Loaded-model extras and free VRAM for a collapsed local card or unselected
/// `top` row. Host RAM, utilization, disk inventory, and GPU-resident context
/// stay in [localRuntimeExpandedDetails].
List<String> localRuntimeGlanceDetails(ProviderQuota quota) {
  if (!quota.isLocal) return const [];
  final vram = localRuntimeVramFreeLabel(quota.localHardware);
  return [
    if (vram != null) vram,
    for (final detail in quota.details)
      if (_isLocalRuntimeGlanceDetail(detail) &&
          (vram == null || !_isLocalHostVramDetail(detail)))
        detail,
  ];
}

/// Host inventory and loaded-model context shown after a local card is opened
/// or its `top` row is selected.
List<String> localRuntimeExpandedDetails(ProviderQuota quota) {
  if (!quota.isLocal) return const [];
  final vram = localRuntimeVramFreeLabel(quota.localHardware);
  return [
    for (final detail in quota.details)
      if (!_isLocalRuntimeGlanceDetail(detail) ||
          (vram != null && _isLocalHostVramDetail(detail)))
        detail,
  ];
}
