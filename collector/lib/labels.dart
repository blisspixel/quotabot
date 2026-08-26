/// Shared human-facing time and recovery labels. Pure and side-effect free, so
/// collector and desktop surfaces render the same evidence without duplicating
/// arithmetic or failure classification.
library;

import 'models.dart';

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

/// Concise temporary-provider recovery copy derived only from bounded quota
/// diagnostics. A timeout is not called a rate limit, and a 5xx is not called
/// throttling. Returns null for auth, parsing, setup, and other failures.
String? providerRetrySummary(
  ProviderQuota quota, {
  bool showingLastKnown = false,
}) {
  final cause = switch (quota.pipeHealth) {
    // gRPC RESOURCE_EXHAUSTED (status 8) is a rate limit that arrives over
    // HTTP 200, so the 429 check alone would mislabel it "provider slow".
    providerPipeHealthThrottled => quota.httpStatus == 429 ||
            (quota.error?.contains('gRPC status 8') ?? false)
        ? 'rate limited'
        : 'provider slow',
    providerPipeHealthDegraded => 'provider error',
    _ => null,
  };
  if (cause == null) return null;
  final retryAfter = quota.retryAfterSeconds;
  final retry = retryAfter == null
      ? ''
      : retryAfter <= 0
          ? ' now'
          : ' in ${compactAge(retryAfter)}';
  final evidence = showingLastKnown ? ', showing last known' : '';
  return '$cause - retrying$retry$evidence';
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
  if (quota.httpStatus == 401 || quota.httpStatus == 403) {
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
