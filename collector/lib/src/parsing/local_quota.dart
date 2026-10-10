part of '../../parsing.dart';

// --- Cursor -----------------------------------------------------------------

/// Parses Cursor usage data (from state.vscdb JSON blobs).
/// Flexible for credits or request counts. Returns windows if found.
List<QuotaWindow> cursorWindows(dynamic usageData, int now) {
  final usage = _jsonObject(usageData);
  if (usage == null) return const [];
  final windows = <QuotaWindow>[];

  final monthly = _cursorMonthlyPool(usage);
  if (monthly != null) windows.add(monthly);
  if (windows.isNotEmpty) return windows;

  // Try usageBreakdowns like Kiro
  final breakdowns = usage['usageBreakdowns'];
  if (breakdowns is List) {
    for (final b in breakdowns) {
      final block = _jsonObject(b);
      if (block == null) continue;
      final used = _firstNum(block, const ['currentUsage']);
      final limit = _firstNum(block, const ['usageLimit']);
      final pct = _boundedPercent(block['percentageUsed']);
      // See kiroWindows: parseReset tolerates a numeric resetDate; the raw cast
      // threw on one and dropped every window in the breakdown.
      final resetsAt = parseReset(block['resetDate']);
      final label = (block['displayName'] ?? 'usage').toString().toLowerCase();
      final usedP = pct ?? _ratioPercent(used, limit);
      if (usedP == null) continue;
      windows.add(
        QuotaWindow(label: label, usedPercent: usedP, resetsAt: resetsAt),
      );
    }
  }

  return windows;
}

Map<String, dynamic>? _jsonObject(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return value.cast<String, dynamic>();
  }
  return null;
}

QuotaWindow? _cursorMonthlyPool(Map<String, dynamic> usageData) {
  final candidates = <Map<String, dynamic>>[
    usageData,
    for (final key in const [
      'monthlyUsage',
      'usagePool',
      'includedUsage',
      'planUsage',
      'billingUsage',
      'creditPool',
    ])
      if (_jsonObject(usageData[key]) case final nested?) nested,
  ];

  QuotaWindow? binding;
  for (final c in candidates) {
    final used = _firstNum(c, const [
      'usedCents',
      'used_cents',
      'currentUsageCents',
      'current_usage_cents',
      'usageCents',
      'spentCents',
      'used',
      'currentUsage',
      'amountUsed',
      'spent',
    ]);
    final limit = _firstNum(c, const [
      'includedCents',
      'included_cents',
      'includedUsageCents',
      'limitCents',
      'monthlyLimitCents',
      'usageLimitCents',
      'includedUsage',
      'included',
      'limit',
      'usageLimit',
      'hardLimit',
    ]);
    final percent = _ratioPercent(used, limit);
    if (percent == null) continue;
    final candidate = QuotaWindow(
      label: 'monthly',
      usedPercent: percent,
      resetsAt: _cursorReset(c) ?? _cursorReset(usageData),
    );
    if (binding == null || _tighterWindow(candidate, binding)) {
      binding = candidate;
    }
  }
  return binding;
}

double? _firstNum(Map<String, dynamic> data, List<String> keys) {
  for (final key in keys) {
    final value = data[key];
    if (value is num) {
      final parsed = value.toDouble();
      if (parsed.isFinite) return parsed;
      continue;
    }
    if (value is String) {
      final parsed = double.tryParse(value.replaceAll(',', '').trim());
      if (parsed != null && parsed.isFinite) return parsed;
    }
  }
  return null;
}

double? _ratioPercent(double? used, double? limit) {
  if (used == null || limit == null || used < 0 || limit <= 0) return null;
  return (used / limit * 100).clamp(0.0, 100.0).toDouble();
}

int? _cursorReset(Map<String, dynamic> data) {
  for (final key in const [
    'resetAt',
    'resetsAt',
    'resetDate',
    'periodEnd',
    'currentPeriodEnd',
    'billingPeriodEnd',
    'nextResetAt',
  ]) {
    final reset = parseReset(data[key]);
    if (reset != null) return reset;
  }
  return null;
}

// --- Windsurf -----------------------------------------------------------------

/// Parses Windsurf (Codeium) cachedPlanInfo / usage from local state.vscdb.
/// Supports post-2026 daily/weekly quota shapes (Cascade/messages/flowActions)
/// or older credit breakdowns. Pure, no I/O.
List<QuotaWindow> windsurfWindows(dynamic usageData, int now) {
  final usage = _jsonObject(usageData);
  if (usage == null) return const [];
  final byLabel = <String, QuotaWindow>{};

  void addWindow(QuotaWindow? window) {
    if (window == null) return;
    final current = byLabel[window.label];
    if (current == null || _tighterWindow(window, current)) {
      byLabel[window.label] = window;
    }
  }

  addWindow(_windsurfDirectQuotaWindow('daily', usage));
  addWindow(_windsurfDirectQuotaWindow('weekly', usage));

  for (final container in _windsurfQuotaContainers(usage)) {
    for (final label in const ['daily', 'weekly', 'cascade']) {
      final quota = _windsurfNestedQuota(container, label);
      if (quota != null) {
        addWindow(_windsurfQuotaWindowFromMap(label, quota, usage));
      }
    }
  }

  // usage counters (newer cache shapes per research; usedMessages/messages etc)
  final usedMsgs = _firstNum(usage, const ['usedMessages']);
  final totMsgs = _firstNum(usage, const ['messages', 'messageLimit']);
  final messagePercent = _ratioPercent(usedMsgs, totMsgs);
  if (messagePercent != null) {
    addWindow(
      QuotaWindow(
        label: 'messages',
        usedPercent: messagePercent,
      ),
    );
  }

  final usedFlows = _firstNum(usage, const ['usedFlowActions']);
  final totFlows = _firstNum(usage, const ['flowActions', 'flowActionLimit']);
  final flowPercent = _ratioPercent(usedFlows, totFlows);
  if (flowPercent != null) {
    addWindow(
      QuotaWindow(
        label: 'flow',
        usedPercent: flowPercent,
      ),
    );
  }

  // Try similar to Kiro/Cursor breakdowns as last resort
  if (byLabel.isEmpty) {
    final breakdowns = usage['usageBreakdowns'] ?? usage['credits'];
    if (breakdowns is List) {
      for (final b in breakdowns) {
        final block = _jsonObject(b);
        if (block == null) continue;
        final used = _firstNum(block, const ['currentUsage']);
        final limit = _firstNum(block, const ['usageLimit']);
        final pct = _boundedPercent(block['percentageUsed']);
        final label =
            (block['displayName'] ?? 'prompts').toString().toLowerCase();
        final usedP = pct ?? _ratioPercent(used, limit);
        if (usedP != null) {
          addWindow(QuotaWindow(label: label, usedPercent: usedP));
        }
      }
    }
  }

  return byLabel.values.toList();
}

QuotaWindow? _windsurfDirectQuotaWindow(
    String label, Map<String, dynamic> data) {
  final cap = _cap(label);
  final remaining = _firstNum(data, [
    '${label}_quota_remaining_percent',
    '${label}QuotaRemainingPercent',
    '${label}_remaining_percent',
    '${label}RemainingPercent',
  ]);
  final boundedRemaining = _boundedPercent(remaining);
  if (boundedRemaining != null) {
    return QuotaWindow(
      label: label,
      usedPercent: 100 - boundedRemaining,
      resetsAt: _windsurfReset(label, data, data),
    );
  }

  final usedPercent = _firstNum(data, [
    '${label}_quota_used_percent',
    '${label}QuotaUsedPercent',
    '${label}_used_percent',
    '${label}UsedPercent',
  ]);
  final boundedUsed = _boundedPercent(usedPercent);
  if (boundedUsed != null) {
    return QuotaWindow(
      label: label,
      usedPercent: boundedUsed,
      resetsAt: _windsurfReset(label, data, data),
    );
  }

  final used = _firstNum(data, [
    '${label}_used',
    '${label}Used',
    '${label}_usage',
    '${label}Usage',
    'used$cap',
    'used${cap}Quota',
  ]);
  final limit = _firstNum(data, [
    '${label}_limit',
    '${label}Limit',
    '${label}_quota',
    '${label}Quota',
    '${label}_quota_limit',
    '${label}QuotaLimit',
  ]);
  final ratio = _ratioPercent(used, limit);
  if (ratio == null) return null;
  return QuotaWindow(
    label: label,
    usedPercent: ratio,
    resetsAt: _windsurfReset(label, data, data),
  );
}

Iterable<Map<String, dynamic>> _windsurfQuotaContainers(
  Map<String, dynamic> data,
) sync* {
  yield data;
  for (final key in const [
    'quotaUsage',
    'usageQuotas',
    'quota',
    'quotas',
    'usage',
    'planInfo',
    'cachedPlanInfo',
  ]) {
    final value = _jsonObject(data[key]);
    if (value != null) yield value;
  }
}

Map<String, dynamic>? _windsurfNestedQuota(
  Map<String, dynamic> container,
  String label,
) {
  final cap = _cap(label);
  for (final key in [
    label,
    '${label}Quota',
    '${label}Usage',
    '${label}UsageQuota',
    '${label}Allowance',
    '${label}_quota',
    '${label}_usage',
    '${label}_usage_quota',
    '${label}_allowance',
    'quota$cap',
    'usage$cap',
  ]) {
    final value = _jsonObject(container[key]);
    if (value != null) return value;
  }
  return null;
}

QuotaWindow? _windsurfQuotaWindowFromMap(
  String label,
  Map<String, dynamic> data,
  Map<String, dynamic> root,
) {
  final remaining = _firstNum(data, const [
    'remainingPercent',
    'remaining_percent',
    'quotaRemainingPercent',
    'quota_remaining_percent',
    'freePercent',
    'free_percent',
  ]);
  final boundedRemaining = _boundedPercent(remaining);
  if (boundedRemaining != null) {
    return QuotaWindow(
      label: label,
      usedPercent: 100 - boundedRemaining,
      resetsAt: _windsurfReset(label, data, root),
    );
  }

  final usedPercent = _firstNum(data, const [
    'usedPercent',
    'used_percent',
    'usagePercent',
    'usage_percent',
    'percentageUsed',
    'percentUsed',
    'quotaUsedPercent',
    'quota_used_percent',
  ]);
  final boundedUsed = _boundedPercent(usedPercent);
  if (boundedUsed != null) {
    return QuotaWindow(
      label: label,
      usedPercent: boundedUsed,
      resetsAt: _windsurfReset(label, data, root),
    );
  }

  final used = _firstNum(data, const [
    'used',
    'currentUsage',
    'usage',
    'consumed',
    'count',
  ]);
  final limit = _firstNum(data, const [
    'limit',
    'usageLimit',
    'quota',
    'quotaLimit',
    'allowance',
    'total',
  ]);
  final ratio = _ratioPercent(used, limit);
  if (ratio == null) return null;
  return QuotaWindow(
    label: label,
    usedPercent: ratio,
    resetsAt: _windsurfReset(label, data, root),
  );
}

int? _windsurfReset(
  String label,
  Map<String, dynamic> data,
  Map<String, dynamic> root,
) {
  final cap = _cap(label);
  for (final source in [data, root]) {
    for (final key in [
      'resetsAt',
      'resetAt',
      'resetDate',
      'periodEnd',
      '${label}ResetAt',
      '${label}QuotaResetAt',
      'next${cap}ResetAt',
      '${label}_reset_at',
      '${label}_quota_reset_at',
    ]) {
      final reset = parseReset(source[key]);
      if (reset != null) return reset;
    }
  }
  return null;
}

String _cap(String label) => '${label[0].toUpperCase()}${label.substring(1)}';

// --- Kiro -------------------------------------------------------------------

/// Parses Kiro credit usage from the kiro.resourceNotifications.usageState blob.
/// Returns a single "credits" window with percentage used and reset date.
List<QuotaWindow> kiroWindows(dynamic usageState, int now) {
  final usage = _jsonObject(usageState);
  if (usage == null) return const [];
  final breakdowns = usage['usageBreakdowns'];
  if (breakdowns is! List || breakdowns.isEmpty) return const [];

  final windows = <QuotaWindow>[];
  for (final b in breakdowns) {
    final block = _jsonObject(b);
    if (block == null) continue;
    final used = _firstNum(block, const ['currentUsage']);
    final limit = _firstNum(block, const ['usageLimit']);
    final pct = _boundedPercent(block['percentageUsed']);
    // parseReset tolerates an ISO string, an epoch-seconds number, or millis; a
    // raw `as String?` cast here threw on a numeric resetDate and aborted the
    // whole loop, discarding every otherwise-parseable window.
    final resetsAt = parseReset(block['resetDate']);
    final label = (block['displayName'] ?? 'Credits').toString().toLowerCase();
    final usedP = pct ?? _ratioPercent(used, limit);
    if (usedP == null) continue;
    windows.add(
      QuotaWindow(label: label, usedPercent: usedP, resetsAt: resetsAt),
    );
  }
  return windows;
}
