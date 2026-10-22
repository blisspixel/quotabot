part of '../../parsing.dart';

/// Documented Claude Code status-line plan window for the rolling five-hour cap.
const claudeStatusFiveHourId = 'five_hour';

/// Documented Claude Code status-line plan window for the seven-day cap.
const claudeStatusSevenDayId = 'seven_day';

/// Clock slack added to a documented window length.
///
/// A slightly slow local clock can make a real reset look a few minutes past
/// the nominal window. This slack does not extend quota. A later reset is
/// malformed evidence, not a longer plan.
const claudeStatusResetSlackSeconds = 10 * 60;

/// Longest accepted `resets_at` lead for the five-hour status-line window.
const claudeStatusFiveHourMaxSeconds = 5 * 3600 + claudeStatusResetSlackSeconds;

/// Longest accepted `resets_at` lead for the seven-day status-line window.
const claudeStatusSevenDayMaxSeconds =
    7 * 86400 + claudeStatusResetSlackSeconds;

const claudeStatusRejectionNotObject = 'not_object';
const claudeStatusRejectionRateLimitsType = 'rate_limits_type';
const claudeStatusRejectionUnknownRateLimit = 'unknown_rate_limit';
const claudeStatusRejectionMalformedWindow = 'malformed_window';

const _spendLimitKey = 'spend_limit';
const _allowedRateLimitKeys = {
  claudeStatusFiveHourId,
  claudeStatusSevenDayId,
  _spendLimitKey,
};

/// One allowlisted plan window from a Claude Code status-line payload.
class ClaudeStatusParsedWindow {
  const ClaudeStatusParsedWindow({
    required this.id,
    required this.usedPercent,
    required this.resetsAt,
  });

  final String id;
  final double usedPercent;
  final int resetsAt;
}

enum ClaudeStatusParseKind { leave, apply, reject }

/// Pure allowlist result for one status-line JSON value.
///
/// `leave` means the payload has no `rate_limits` object, so a previous local
/// projection must stay untouched. `apply` replaces that projection with the
/// current plan windows, which may be empty when Claude has dropped them.
/// `reject` means the payload is malformed and must not change stored evidence.
class ClaudeStatusParseResult {
  const ClaudeStatusParseResult._({
    required this.kind,
    required this.windows,
    this.rejection,
  });

  const ClaudeStatusParseResult.leave()
      : this._(kind: ClaudeStatusParseKind.leave, windows: const []);

  ClaudeStatusParseResult.apply(List<ClaudeStatusParsedWindow> windows)
      : this._(
          kind: ClaudeStatusParseKind.apply,
          windows: List.unmodifiable(windows),
        );

  const ClaudeStatusParseResult.reject(String rejection)
      : this._(
          kind: ClaudeStatusParseKind.reject,
          windows: const [],
          rejection: rejection,
        );

  final ClaudeStatusParseKind kind;
  final List<ClaudeStatusParsedWindow> windows;
  final String? rejection;
}

/// Allowlists documented Pro/Max plan windows from one status-line value.
///
/// Checked against the Claude Code status-line contract on 2026-10-22.
/// `five_hour` and `seven_day` are the only plan windows. Gateway
/// `spend_limit` is ignored. Every other `rate_limits` key rejects the payload
/// so a new binding pool cannot be dropped silently. Transcripts, paths, cost,
/// context, model identity, and session identifiers are never read into the
/// result. Epoch milliseconds are not converted into seconds.
ClaudeStatusParseResult parseClaudeStatusPayload(
  Object? decoded, {
  required int now,
}) {
  if (decoded is! Map) {
    return const ClaudeStatusParseResult.reject(claudeStatusRejectionNotObject);
  }
  if (!decoded.containsKey('rate_limits')) {
    return const ClaudeStatusParseResult.leave();
  }
  final limits = decoded['rate_limits'];
  if (limits is! Map) {
    return const ClaudeStatusParseResult.reject(
      claudeStatusRejectionRateLimitsType,
    );
  }
  for (final key in limits.keys) {
    if (key is! String || !_allowedRateLimitKeys.contains(key)) {
      return const ClaudeStatusParseResult.reject(
        claudeStatusRejectionUnknownRateLimit,
      );
    }
  }

  final fiveHour = _parsePlanWindow(
    limits,
    claudeStatusFiveHourId,
    now: now,
    maxFutureSeconds: claudeStatusFiveHourMaxSeconds,
  );
  final sevenDay = _parsePlanWindow(
    limits,
    claudeStatusSevenDayId,
    now: now,
    maxFutureSeconds: claudeStatusSevenDayMaxSeconds,
  );
  if (fiveHour.kind == _PlanWindowKind.malformed ||
      sevenDay.kind == _PlanWindowKind.malformed) {
    return const ClaudeStatusParseResult.reject(
      claudeStatusRejectionMalformedWindow,
    );
  }

  return ClaudeStatusParseResult.apply([
    if (fiveHour.kind == _PlanWindowKind.current)
      ClaudeStatusParsedWindow(
        id: claudeStatusFiveHourId,
        usedPercent: fiveHour.usedPercent,
        resetsAt: fiveHour.resetsAt,
      ),
    if (sevenDay.kind == _PlanWindowKind.current)
      ClaudeStatusParsedWindow(
        id: claudeStatusSevenDayId,
        usedPercent: sevenDay.usedPercent,
        resetsAt: sevenDay.resetsAt,
      ),
  ]);
}

enum _PlanWindowKind { absent, current, expired, malformed }

class _PlanWindowParse {
  const _PlanWindowParse._(this.kind, this.usedPercent, this.resetsAt);

  const _PlanWindowParse.absent() : this._(_PlanWindowKind.absent, 0, 0);

  const _PlanWindowParse.expired() : this._(_PlanWindowKind.expired, 0, 0);

  const _PlanWindowParse.malformed() : this._(_PlanWindowKind.malformed, 0, 0);

  const _PlanWindowParse.current(double usedPercent, int resetsAt)
      : this._(_PlanWindowKind.current, usedPercent, resetsAt);

  final _PlanWindowKind kind;
  final double usedPercent;
  final int resetsAt;
}

_PlanWindowParse _parsePlanWindow(
  Map<dynamic, dynamic> limits,
  String key, {
  required int now,
  required int maxFutureSeconds,
}) {
  if (!limits.containsKey(key)) return const _PlanWindowParse.absent();
  final value = limits[key];
  if (value is! Map) return const _PlanWindowParse.malformed();
  final used = value['used_percentage'];
  final resets = value['resets_at'];
  if (used is! num || resets is! num) return const _PlanWindowParse.malformed();
  final usedPercent = used.toDouble();
  final resetsDouble = resets.toDouble();
  if (!usedPercent.isFinite || usedPercent < 0 || usedPercent > 100) {
    return const _PlanWindowParse.malformed();
  }
  if (!resetsDouble.isFinite ||
      resetsDouble.truncateToDouble() != resetsDouble) {
    return const _PlanWindowParse.malformed();
  }
  final resetsAt = resets.toInt();
  if (resetsAt <= 0 || resetsAt > now + maxFutureSeconds) {
    return const _PlanWindowParse.malformed();
  }
  if (resetsAt <= now) return const _PlanWindowParse.expired();
  return _PlanWindowParse.current(usedPercent, resetsAt);
}
