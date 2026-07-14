/// Shared human-facing time labels. Pure and side-effect free, so both the
/// collector surfaces (terminal `top`, the CLI, the report) and the adapters
/// render a reset or a countdown the same way rather than each keeping its own
/// copy of the arithmetic.
library;

/// A coarse "resets in ..." label for an optional reset time: `soon` when
/// unknown, `now` when already reached, else the largest whole unit (`3d`, `5h`).
/// Used by the passive-local adapters (Cursor, Kiro, Windsurf) whose state files
/// carry a single reset boundary.
String resetCountdownLabel(int? resetsAt, int now) {
  if (resetsAt == null) return 'soon';
  final secs = resetsAt - now;
  if (secs <= 0) return 'now';
  final days = secs ~/ 86400;
  if (days > 0) return '${days}d';
  return '${secs ~/ 3600}h';
}

/// A compact two-unit countdown to [resetsAt]: `now` when reached, `2d3h` when a
/// day or more away, otherwise `3h20m`. Used wherever a precise time-to-reset is
/// shown (the `top` view and the CLI).
String countdown(int resetsAt, int now) {
  var secs = resetsAt - now;
  if (secs <= 0) return 'now';
  final days = secs ~/ 86400;
  secs %= 86400;
  final hours = secs ~/ 3600;
  if (days > 0) return '${days}d${hours}h';
  return '${hours}h${(secs % 3600) ~/ 60}m';
}
