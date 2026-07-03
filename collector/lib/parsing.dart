import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';
import 'util.dart';

/// Pure parsing logic shared by the adapters, separated from all network and
/// disk I/O so it can be unit tested directly against fixture inputs.

// --- Codex ------------------------------------------------------------------

/// Builds windows from a single Codex `rate_limits` object.
List<QuotaWindow> codexWindows(Map<String, dynamic> rateLimits) =>
    codexBindingWindows([rateLimits], 0);

/// Builds the binding windows across several Codex `rate_limits` snapshots.
///
/// Codex meters different models against separate limit buckets (for example a
/// standard limit and a newer model's own allocation), and each session's
/// rollout only records the bucket that session used. Reading just the newest
/// session therefore hides usage accrued on another bucket. This takes the
/// latest snapshot of each bucket and, per window slot (5h, weekly), keeps the
/// most-constrained one so the glance reflects real remaining headroom.
///
/// A window whose reset time has passed counts as fresh (0 used) when choosing
/// the binding bucket, so a bucket that has already rolled over does not keep
/// reading as spent. [now] is unix epoch seconds; pass 0 to disable rollover
/// handling (used by the single-snapshot path where it does not apply).
List<QuotaWindow> codexBindingWindows(
  Iterable<Map<String, dynamic>> snapshots,
  int now,
) {
  final windows = <QuotaWindow>[];
  for (final entry in const [
    ['primary', '5h'],
    ['secondary', 'weekly'],
  ]) {
    QuotaWindow? binding;
    double bindingUsed = -1;
    for (final rl in snapshots) {
      final w = rl[entry[0]];
      if (w is! Map) continue;
      final used = _boundedPercent(w['used_percent']);
      if (used == null) continue;
      final resetsAt = parseReset(w['resets_at']);
      final rolledOver = now > 0 && resetsAt != null && resetsAt < now;
      final effectiveUsed = rolledOver ? 0.0 : used;
      if (effectiveUsed > bindingUsed) {
        bindingUsed = effectiveUsed;
        binding = QuotaWindow(
          label: codexLabel(w['window_minutes'], entry[1]),
          usedPercent: used,
          resetsAt: resetsAt,
        );
      }
    }
    if (binding != null) windows.add(binding);
  }
  return windows;
}

String codexLabel(dynamic minutes, String fallback) {
  if (minutes is num) {
    if (minutes == 300) return '5h';
    if (minutes == 10080) return 'weekly';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440}d';
    if (minutes % 60 == 0) return '${minutes ~/ 60}h';
    return '${minutes}m';
  }
  return fallback;
}

/// Windows from the live Codex `/backend-api/wham/usage` response, which is
/// authoritative and cross-device unlike the per-machine session snapshots.
/// `rate_limit.primary_window` is the 5-hour window and `secondary_window` the
/// weekly, each with `used_percent`, `reset_at`, and `limit_window_seconds`.
List<QuotaWindow> codexUsageWindows(Map<String, dynamic>? resp) {
  final rl = resp?['rate_limit'];
  if (rl is! Map) return const [];
  final out = <QuotaWindow>[];
  for (final entry in const [
    ['primary_window', '5h'],
    ['secondary_window', 'weekly'],
  ]) {
    final w = rl[entry[0]];
    if (w is! Map) continue;
    final pct = _boundedPercent(w['used_percent']);
    final reset = parseReset(w['reset_at']);
    final secs = w['limit_window_seconds'];
    final label = secs is num ? codexLabel(secs / 60, entry[1]) : entry[1];
    if (pct != null || reset != null) {
      out.add(QuotaWindow(label: label, usedPercent: pct, resetsAt: reset));
    }
  }
  return out;
}

// --- Claude -----------------------------------------------------------------

/// Builds windows from the Anthropic OAuth usage response.
List<QuotaWindow> claudeWindows(Map<String, dynamic> data) {
  final out = <QuotaWindow>[];
  for (final spec in const [
    ['five_hour', '5h'],
    ['seven_day', 'weekly'],
    ['seven_day_opus', 'opus'],
  ]) {
    final block = data[spec[0]];
    if (block is! Map) continue;
    final util = _boundedPercent(block['utilization']);
    if (util == null) continue;
    out.add(
      QuotaWindow(
        label: spec[1],
        usedPercent: util,
        resetsAt: parseIsoToEpoch(block['resets_at']),
      ),
    );
  }
  return out;
}

int? parseIsoToEpoch(dynamic v) {
  if (v is! String) return null;
  final dt = DateTime.tryParse(v);
  return dt == null ? null : dt.millisecondsSinceEpoch ~/ 1000;
}

// --- Antigravity ------------------------------------------------------------

/// Buckets per-model Cloud Code quota into sprint/daily/weekly windows, keeping
/// the most constrained model per bucket.
List<QuotaWindow> antigravityWindows(Map<String, dynamic>? resp, int now) {
  final models = resp?['models'];
  if (models is! Map) return const [];

  final buckets = <String, (double, int)>{};
  models.forEach((_, m) {
    if (m is! Map) return;
    final qi = m['quotaInfo'];
    if (qi is! Map) return;
    final frac = _fraction(qi['remainingFraction']);
    final reset = parseReset(qi['resetTime']);
    if (frac == null || reset == null) return;
    final used = ((1 - frac) * 100).clamp(0, 100).toDouble();
    final label = resetLabel(reset, now);
    final existing = buckets[label];
    if (existing == null || used > existing.$1) {
      buckets[label] = (used, reset);
    }
  });

  return buckets.entries
      .map(
        (e) => QuotaWindow(
          label: e.key,
          usedPercent: e.value.$1,
          resetsAt: e.value.$2,
        ),
      )
      .toList()
    ..sort((a, b) => (a.resetsAt ?? 0).compareTo(b.resetsAt ?? 0));
}

/// Per-model quota from the live Cloud Code `fetchAvailableModels` response.
/// This is authoritative and cross-machine, unlike the local `userStatus`
/// cache (which only reflects usage on the machine that wrote it), so it is
/// preferred whenever the live read succeeds. Each entry is keyed by the model
/// id and carries `{quotaInfo: {remainingFraction, resetTime}}`.
List<ModelQuota> antigravityModelQuotasFromLive(Map<String, dynamic>? resp) {
  final models = resp?['models'];
  if (models is! Map) return const [];
  final out = <ModelQuota>[];
  models.forEach((key, m) {
    if (m is! Map) return;
    final qi = m['quotaInfo'];
    if (qi is! Map) return;
    final frac = _fraction(qi['remainingFraction']);
    if (frac == null) return;
    out.add(
      ModelQuota(
        model: key.toString(),
        usedPercent: ((1 - frac) * 100).clamp(0, 100).toDouble(),
        resetsAt: parseReset(qi['resetTime']),
      ),
    );
  });
  return out;
}

/// Extracts Antigravity's per-model quota table from the `userStatus` protobuf
/// it caches locally. Each model family draws from its own pool, so this is
/// richer and more robust than the single derived window: it names every model
/// with its own remaining headroom and reset, needs no network call, and the
/// same blob already yields the account email and plan. Variants that share a
/// pool (reasoning effort or a "(Thinking)" mode) roll up to their base model so
/// a detail view stays compact.
///
/// Schema, confirmed against live local state: a model entry is a message with
/// the model name in field 1 and a quota submessage in field 15 of
/// `{remainingFraction: fixed32 (field 1), reset: {epochSeconds: varint (field
/// 1)} (field 2)}`; an optional speed category is field 16 and a badge field 17.
/// The blob nests base64-encoded protobufs inside string fields, so the walk
/// descends those layers exactly as [antigravityUserStatusFromProto] does.
List<ModelQuota> antigravityModelQuotas(List<int> bytes) {
  final found = <_AgModelEntry>[];
  final seen = <String>{};

  void visit(List<int> b, int depth) {
    if (depth > 12) return;
    final fields = <(int, int, List<int>)>[];
    final parsed = _forEachProtoField(b, (field, wire, varint, fb) {
      if (wire == 2 || wire == 5) fields.add((field, wire, fb));
    });
    if (parsed) {
      String? name;
      List<int>? quota;
      String? category;
      String? note;
      for (final (field, wire, fb) in fields) {
        if (field == 1 && wire == 2) {
          name ??= asciiString(fb);
        } else if (field == 15 && wire == 2) {
          quota ??= fb;
        } else if (field == 16 && wire == 2) {
          category ??= asciiString(fb);
        } else if (field == 17 && wire == 2) {
          note ??= asciiString(fb);
        }
      }
      // A model entry is precisely a name plus a parseable quota submessage;
      // mime-type and "Recommended" sub-records have a name but no field 15.
      if (name != null &&
          quota != null &&
          name.length >= 3 &&
          !name.contains('/')) {
        final q = _agModelQuota(quota);
        if (q != null && seen.add(name)) {
          found.add(_AgModelEntry(name, q.$1, q.$2, category, note));
        }
      }
      for (final (_, wire, fb) in fields) {
        if (wire == 2 && fb.length >= 2) visit(fb, depth + 1);
      }
    }
    // Descend base64-text wrapping layers: the userStatus blob stores
    // base64-encoded protobufs inside string fields.
    final text = asciiString(b);
    if (text != null) {
      for (final m in RegExp(r'[A-Za-z0-9+/_\-]{24,}={0,2}').allMatches(text)) {
        final decoded = _tryDecodeBase64(m.group(0)!);
        if (decoded != null && decoded.length >= 4) visit(decoded, depth + 1);
      }
    }
  }

  visit(bytes, 0);
  return _rollupModelQuotas(found);
}

/// Reads `{remainingFraction (fixed32, field 1), reset (varint field 1 of the
/// field-2 submessage)}` from an Antigravity per-model quota submessage.
/// Returns `(usedPercent, resetsAt)`, or null when the fraction is absent or
/// outside the expected 0..1 range (so an unrelated submessage never matches).
(double, int?)? _agModelQuota(List<int> bytes) {
  double? remaining;
  int? reset;
  final ok = _forEachProtoField(bytes, (field, wire, varint, fb) {
    if (field == 1 && wire == 5) {
      final f = _float32(fb);
      if (f.isFinite) remaining ??= f;
    } else if (field == 2 && wire == 2) {
      _forEachProtoField(fb, (sf, sw, sv, _) {
        if (sf == 1 && sw == 0 && sv != null && _plausibleEpochSeconds(sv)) {
          reset ??= sv;
        }
      });
    }
  });
  final r = remaining;
  if (!ok || r == null || r < -0.0001 || r > 1.0001) return null;
  final used = ((1 - r) * 100).clamp(0, 100).toDouble();
  return (_percent2(used), reset);
}

class _AgModelEntry {
  final String name;
  final double usedPercent;
  final int? resetsAt;
  final String? category;
  final String? note;
  _AgModelEntry(
    this.name,
    this.usedPercent,
    this.resetsAt,
    this.category,
    this.note,
  );
}

/// Strips a trailing " (…)" effort/mode qualifier so pool-sharing variants roll
/// up, e.g. "Gemini 3.5 Flash (Medium)" -> "Gemini 3.5 Flash".
String _modelBaseName(String name) {
  final i = name.indexOf(' (');
  return i > 0 ? name.substring(0, i) : name;
}

/// Collapses variants that share a base name and pool into one entry; keeps
/// variants separate when their quota diverges so nothing is hidden.
List<ModelQuota> _rollupModelQuotas(List<_AgModelEntry> entries) {
  final order = <String>[];
  final byBase = <String, List<_AgModelEntry>>{};
  for (final e in entries) {
    final base = _modelBaseName(e.name);
    if (!byBase.containsKey(base)) order.add(base);
    (byBase[base] ??= []).add(e);
  }
  final out = <ModelQuota>[];
  for (final base in order) {
    final group = byBase[base]!;
    final distinct = <String>{
      for (final e in group) '${e.usedPercent}|${e.resetsAt}',
    };
    if (distinct.length == 1) {
      final rep = group.first;
      out.add(
        ModelQuota(
          model: base,
          usedPercent: rep.usedPercent,
          resetsAt: rep.resetsAt,
          category: group
              .map((e) => e.category)
              .firstWhere((c) => c != null, orElse: () => null),
          note: group
              .map((e) => e.note)
              .firstWhere((c) => c != null, orElse: () => null),
        ),
      );
    } else {
      for (final e in group) {
        out.add(
          ModelQuota(
            model: e.name,
            usedPercent: e.usedPercent,
            resetsAt: e.resetsAt,
            category: e.category,
            note: e.note,
          ),
        );
      }
    }
  }
  return out;
}

// --- Cursor -----------------------------------------------------------------

/// Parses Cursor usage data (from state.vscdb JSON blobs).
/// Flexible for credits or request counts. Returns windows if found.
List<QuotaWindow> cursorWindows(dynamic usageData, int now) {
  if (usageData is! Map) return const [];
  final windows = <QuotaWindow>[];

  final monthly = _cursorMonthlyPool(usageData);
  if (monthly != null) windows.add(monthly);
  if (windows.isNotEmpty) return windows;

  // Try usageBreakdowns like Kiro
  final breakdowns = usageData['usageBreakdowns'];
  if (breakdowns is List) {
    for (final b in breakdowns) {
      if (b is! Map) continue;
      final used = _firstNum(b, const ['currentUsage']);
      final limit = _firstNum(b, const ['usageLimit']);
      final pct = _boundedPercent(b['percentageUsed']);
      final resetStr = b['resetDate'] as String?;
      int? resetsAt;
      if (resetStr != null) {
        final dt = DateTime.tryParse(resetStr);
        if (dt != null) resetsAt = dt.millisecondsSinceEpoch ~/ 1000;
      }
      final label = (b['displayName'] ?? 'usage').toString().toLowerCase();
      final usedP = pct ??
          (used != null && limit != null && limit > 0
              ? (used / limit * 100).clamp(0, 100)
              : null);
      if (usedP != null || resetsAt != null) {
        windows.add(
          QuotaWindow(label: label, usedPercent: usedP, resetsAt: resetsAt),
        );
      }
    }
  }

  return windows;
}

QuotaWindow? _cursorMonthlyPool(Map usageData) {
  final candidates = <Map>[
    usageData,
    for (final key in const [
      'monthlyUsage',
      'usagePool',
      'includedUsage',
      'planUsage',
      'billingUsage',
      'creditPool',
    ])
      if (usageData[key] is Map) usageData[key] as Map,
  ];

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
    if (used == null || limit == null || limit <= 0) continue;
    return QuotaWindow(
      label: 'monthly',
      usedPercent: (used / limit * 100).clamp(0.0, 100.0),
      resetsAt: _cursorReset(c) ?? _cursorReset(usageData),
    );
  }
  return null;
}

double? _firstNum(Map data, List<String> keys) {
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

double? _boundedPercent(dynamic value) {
  final parsed = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.replaceAll(',', '').trim()),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite) return null;
  return parsed.clamp(0.0, 100.0);
}

double? _fraction(dynamic value) {
  final parsed = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.replaceAll(',', '').trim()),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite) return null;
  return parsed.clamp(0.0, 1.0);
}

int? _cursorReset(Map data) {
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
  if (usageData is! Map) return const [];
  final windows = <QuotaWindow>[];

  final seenLabels = <String>{};

  void addWindow(QuotaWindow? window) {
    if (window == null) return;
    if (!seenLabels.add(window.label)) return;
    windows.add(window);
  }

  addWindow(_windsurfDirectQuotaWindow('daily', usageData));
  addWindow(_windsurfDirectQuotaWindow('weekly', usageData));

  for (final container in _windsurfQuotaContainers(usageData)) {
    for (final label in const ['daily', 'weekly', 'cascade']) {
      final quota = _windsurfNestedQuota(container, label);
      if (quota is Map) {
        addWindow(_windsurfQuotaWindowFromMap(label, quota, usageData));
      }
    }
  }

  // usage counters (newer cache shapes per research; usedMessages/messages etc)
  final usedMsgs = _firstNum(usageData, const ['usedMessages']);
  final totMsgs = _firstNum(usageData, const ['messages', 'messageLimit']);
  if (usedMsgs != null && totMsgs != null && totMsgs > 0) {
    windows.add(
      QuotaWindow(
        label: 'messages',
        usedPercent: (usedMsgs / totMsgs * 100).clamp(0.0, 100.0),
      ),
    );
  }

  final usedFlows = _firstNum(usageData, const ['usedFlowActions']);
  final totFlows =
      _firstNum(usageData, const ['flowActions', 'flowActionLimit']);
  if (usedFlows != null && totFlows != null && totFlows > 0) {
    windows.add(
      QuotaWindow(
        label: 'flow',
        usedPercent: (usedFlows / totFlows * 100).clamp(0.0, 100.0),
      ),
    );
  }

  // Try similar to Kiro/Cursor breakdowns as last resort
  if (windows.isEmpty) {
    final breakdowns = usageData['usageBreakdowns'] ?? usageData['credits'];
    if (breakdowns is List) {
      for (final b in breakdowns) {
        if (b is! Map) continue;
        final used = _firstNum(b, const ['currentUsage']);
        final limit = _firstNum(b, const ['usageLimit']);
        final pct = _boundedPercent(b['percentageUsed']);
        final label = (b['displayName'] ?? 'prompts').toString().toLowerCase();
        final usedP = pct ??
            (used != null && limit != null && limit > 0
                ? (used / limit * 100).clamp(0.0, 100.0)
                : null);
        if (usedP != null) {
          windows.add(QuotaWindow(label: label, usedPercent: usedP));
        }
      }
    }
  }

  return windows;
}

QuotaWindow? _windsurfDirectQuotaWindow(String label, Map data) {
  final cap = _cap(label);
  final remaining = _firstNum(data, [
    '${label}_quota_remaining_percent',
    '${label}QuotaRemainingPercent',
    '${label}_remaining_percent',
    '${label}RemainingPercent',
  ]);
  if (remaining != null) {
    return QuotaWindow(
      label: label,
      usedPercent: (100 - remaining).clamp(0.0, 100.0),
      resetsAt: _windsurfReset(label, data, data),
    );
  }

  final usedPercent = _firstNum(data, [
    '${label}_quota_used_percent',
    '${label}QuotaUsedPercent',
    '${label}_used_percent',
    '${label}UsedPercent',
  ]);
  if (usedPercent != null) {
    return QuotaWindow(
      label: label,
      usedPercent: usedPercent.clamp(0.0, 100.0),
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
  if (used == null || limit == null || limit <= 0) return null;
  return QuotaWindow(
    label: label,
    usedPercent: (used / limit * 100).clamp(0.0, 100.0),
    resetsAt: _windsurfReset(label, data, data),
  );
}

Iterable<Map> _windsurfQuotaContainers(Map data) sync* {
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
    final value = data[key];
    if (value is Map) yield value;
  }
}

dynamic _windsurfNestedQuota(Map container, String label) {
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
    final value = container[key];
    if (value is Map) return value;
  }
  return null;
}

QuotaWindow? _windsurfQuotaWindowFromMap(String label, Map data, Map root) {
  final remaining = _firstNum(data, const [
    'remainingPercent',
    'remaining_percent',
    'quotaRemainingPercent',
    'quota_remaining_percent',
    'freePercent',
    'free_percent',
  ]);
  if (remaining != null) {
    return QuotaWindow(
      label: label,
      usedPercent: (100 - remaining).clamp(0.0, 100.0),
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
  if (usedPercent != null) {
    return QuotaWindow(
      label: label,
      usedPercent: usedPercent.clamp(0.0, 100.0),
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
  if (used == null || limit == null || limit <= 0) return null;
  return QuotaWindow(
    label: label,
    usedPercent: (used / limit * 100).clamp(0.0, 100.0),
    resetsAt: _windsurfReset(label, data, root),
  );
}

int? _windsurfReset(String label, Map data, Map root) {
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
  if (usageState is! Map) return const [];
  final breakdowns = usageState['usageBreakdowns'];
  if (breakdowns is! List || breakdowns.isEmpty) return const [];

  final windows = <QuotaWindow>[];
  for (final b in breakdowns) {
    if (b is! Map) continue;
    final used = _firstNum(b, const ['currentUsage']);
    final limit = _firstNum(b, const ['usageLimit']);
    final pct = _boundedPercent(b['percentageUsed']);
    final resetStr = b['resetDate'] as String?;
    int? resetsAt;
    if (resetStr != null) {
      final dt = DateTime.tryParse(resetStr);
      if (dt != null) resetsAt = dt.millisecondsSinceEpoch ~/ 1000;
    }
    final label = (b['displayName'] ?? 'Credits').toString().toLowerCase();
    final usedP = pct ??
        (used != null && limit != null && limit > 0
            ? (used / limit * 100).clamp(0, 100)
            : null);
    if (usedP != null || resetsAt != null) {
      windows.add(
        QuotaWindow(label: label, usedPercent: usedP, resetsAt: resetsAt),
      );
    }
  }
  return windows;
}

int? parseReset(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    final parsed = v.toDouble();
    return parsed.isFinite ? v.toInt() : null;
  }
  final s = v.toString();
  final asInt = int.tryParse(s);
  if (asInt != null) return asInt;
  final dt = DateTime.tryParse(s);
  return dt == null ? null : dt.millisecondsSinceEpoch ~/ 1000;
}

String resetLabel(int reset, int now) {
  final dt = reset - now;
  if (dt <= 6 * 3600) return '5h';
  if (dt <= 36 * 3600) return 'daily';
  return 'weekly';
}

/// Recovers a token matching [patternSource] from nested base64/protobuf layers
/// (the stored blob is base64 wrapping protobufs that embed base64-encoded
/// tokens).
String? findEmbeddedToken(String storedB64, String patternSource) {
  final pattern = RegExp(patternSource);
  final seen = <String>{};
  String? result;

  void scan(List<int> bytes, int depth) {
    if (result != null || depth > 6) return;
    final txt = String.fromCharCodes(bytes);
    final m = pattern.firstMatch(txt);
    if (m != null) {
      result = m.group(0);
      return;
    }
    for (final chunk in RegExp(
      r'[A-Za-z0-9+/_\-]{24,}={0,2}',
    ).allMatches(txt)) {
      final c = chunk.group(0)!;
      if (!seen.add(c)) continue;
      for (final variant in [c, c.replaceAll('-', '+').replaceAll('_', '/')]) {
        try {
          final pad = variant + '=' * ((4 - variant.length % 4) % 4);
          final dec = base64Decode(pad);
          if (dec.length > 4) scan(dec, depth + 1);
        } catch (_) {}
        if (result != null) return;
      }
    }
  }

  try {
    final pad = storedB64 + '=' * ((4 - storedB64.length % 4) % 4);
    scan(base64Decode(pad), 0);
  } catch (_) {}
  return result;
}

/// Finds the plan tier display string inside the Antigravity userStatus
/// protobuf.
String? planFromProto(List<int> bytes) {
  const known = {'Free', 'Pro', 'Ultra', 'AI Pro', 'AI Ultra', 'Enterprise'};
  for (final s in protoStrings(bytes)) {
    if (known.contains(s)) return s;
  }
  return null;
}

({String? email, String? plan, String? model, String? note})?
    antigravityUserStatusFromProto(List<int> bytes) {
  String? email;
  String? plan;
  String? model;
  String? note;
  final seenChunks = <String>{};

  late void Function(List<int> value, int depth) scanBytes;
  late void Function(String s, int depth) scanText;

  scanBytes = (List<int> value, int depth) {
    if (depth > 5) return;
    final direct = asciiString(value);
    if (direct != null) scanText(direct, depth);
    for (final s in protoStrings(value)) {
      scanText(s, depth);
    }
  };

  scanText = (String s, int depth) {
    email ??= _firstEmail(s);
    final candidatePlan = _firstKnownPlan(s);
    if (_preferPlan(candidatePlan, plan)) plan = candidatePlan;
    final candidateModel = _bestModelName(s);
    if (_preferModel(candidateModel, model)) model = candidateModel;
    if (note == null && s.contains('higher rate limits')) {
      note = 'Local Antigravity status reports higher rate limits';
    }
    if (depth >= 5) return;
    for (final chunk in RegExp(
      r'[A-Za-z0-9+/_\-]{24,}={0,2}',
    ).allMatches(s)) {
      final raw = chunk.group(0)!;
      if (!seenChunks.add(raw)) continue;
      final decoded = _tryDecodeBase64(raw);
      if (decoded == null || decoded.length < 4) continue;
      scanBytes(decoded, depth + 1);
    }
  };

  scanBytes(bytes, 0);
  if (email == null && plan == null && model == null && note == null) {
    return null;
  }
  return (email: email, plan: plan, model: model, note: note);
}

String? _firstEmail(String s) {
  final m =
      RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false)
          .firstMatch(s);
  return m?.group(0);
}

List<int>? _tryDecodeBase64(String raw) {
  final compact = raw.trim().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return null;
  for (final candidate in [
    compact,
    compact.replaceAll('-', '+').replaceAll('_', '/'),
    if (compact.length % 4 == 1) compact.substring(1),
    if (compact.length % 4 == 1) compact.substring(0, compact.length - 1),
  ]) {
    try {
      final padded = candidate + '=' * ((4 - candidate.length % 4) % 4);
      return base64Decode(padded);
    } catch (_) {}
  }
  return null;
}

String? _firstKnownPlan(String s) {
  final trimmed = s.trim();
  if (const {'Enterprise', 'Ultra', 'Pro', 'Free'}.contains(trimmed)) {
    return trimmed;
  }
  String? best;
  int? bestIndex;
  for (final plan in const [
    'Google AI Ultra',
    'Google AI Pro',
    'AI Ultra',
    'AI Pro',
    'Enterprise',
  ]) {
    final index = s.indexOf(plan);
    if (index < 0) continue;
    if (bestIndex == null || index < bestIndex) {
      best = plan;
      bestIndex = index;
    }
  }
  return best;
}

bool _preferPlan(String? candidate, String? current) {
  if (candidate == null) return false;
  if (current == null) return true;
  return _planSpecificity(candidate) > _planSpecificity(current);
}

int _planSpecificity(String plan) {
  if (plan.startsWith('Google AI ') || plan.startsWith('AI ')) return 3;
  if (plan == 'Enterprise') return 3;
  return 1;
}

String? _bestModelName(String s) {
  String? best;
  for (final pattern in _modelPatterns) {
    for (final m in pattern.allMatches(s)) {
      final candidate = m.group(0)?.trim();
      if (_preferModel(candidate, best)) best = candidate;
    }
  }
  return best;
}

final _modelPatterns = [
  RegExp(
    r'Gemini\s+[0-9]+(?:\.[0-9]+)?(?:\s+[A-Za-z0-9]+)*(?:\s+\([^)]+\))?',
  ),
  RegExp(
    r'Claude\s+[0-9]+(?:\.[0-9]+)?(?:\s+[A-Za-z0-9]+)*(?:\s+\([^)]+\))?',
  ),
  RegExp(
    r'GPT-OSS\s+[0-9]+(?:\.[0-9]+)?(?:\s+[A-Za-z0-9]+)*(?:\s+\([^)]+\))?',
  ),
];

bool _preferModel(String? candidate, String? current) {
  if (candidate == null) return false;
  if (current == null) return true;
  return _modelScore(candidate) > _modelScore(current);
}

int _modelScore(String model) {
  var score = 0;
  if (model.contains('(High)')) score += 100;
  if (model.contains('(Medium)')) score += 50;
  if (model.contains('(Low)')) score += 10;
  if (model.contains(' Pro')) score += 40;
  if (model.contains(' Flash')) score += 20;
  return score;
}

// --- Grok -------------------------------------------------------------------

/// Extracts the first gRPC-web DATA frame payload (flag 0x00) from a response.
List<int> grpcMessage(Uint8List resp) {
  if (resp.length < 5) return const [];
  if ((resp[0] & 0x80) != 0) return const []; // first frame is a trailer
  final len = (resp[1] << 24) | (resp[2] << 16) | (resp[3] << 8) | resp[4];
  if (5 + len > resp.length) return const [];
  return resp.sublist(5, 5 + len);
}

/// Parses the Grok billing protobuf into a single shared weekly usage window.
///
/// GetGrokCreditsConfig wraps one config message in field 1. Inside it, field
/// 1 is the shared pool's used percent (fixed32 float), fields 4 and 5 are the
/// window start and end timestamps, and repeated field 7 carries per-product
/// breakdown percents that sum to the total. Reading the percent by field
/// number keeps a breakdown value from ever posing as the pool total, and the
/// reset comes from the window end, never the start. The schema-less scan
/// remains as a fallback for shape drift. Note that xAI can revise the pool
/// percent downward mid-window (observed live: 100 to 73 under an unchanged
/// reset), so Grok usage is not monotonic between resets.
QuotaWindow? grokWindow(List<int> message, int now) {
  if (message.isEmpty) return null;
  return _grokConfigWindow(message, now) ?? _grokScanWindow(message, now);
}

/// Schema-anchored read of the Grok credits config message.
QuotaWindow? _grokConfigWindow(List<int> message, int now) {
  List<int>? config;
  // The top-level walk's verdict is deliberately ignored: trailing garbage
  // after a well-delimited config must not force the less precise scan
  // fallback. The config body itself is still parsed strictly below.
  _forEachProtoField(message, (field, wireType, varint, bytes) {
    if (field == 1 && wireType == 2) config ??= bytes;
  });
  final body = config;
  if (body == null) return null;
  double? used;
  int? windowEnd;
  final ok = _forEachProtoField(body, (field, wireType, varint, bytes) {
    if (field == 1 && wireType == 5) {
      final f = _float32(bytes);
      // This field is the pool total by schema, so a finite value outside
      // 0..100 is clamped rather than discarded; discarding would hand the
      // read back to the scan, which can pick a breakdown percent.
      if (f.isFinite) used ??= _percent2(f.clamp(0.0, 100.0));
    } else if (field == 5 && wireType == 2) {
      _forEachProtoField(bytes, (subField, subWire, subVarint, _) {
        if (subField == 1 &&
            subWire == 0 &&
            subVarint != null &&
            _plausibleEpochSeconds(subVarint)) {
          windowEnd ??= subVarint;
        }
      });
    }
  });
  if (!ok || used == null) return null;
  return QuotaWindow(
    label: 'weekly',
    usedPercent: used,
    resetsAt:
        windowEnd ?? (ProtoScan()..walk(message)).nearestFutureTimestamp(now),
  );
}

/// Schema-less fallback: first plausible percent, nearest future timestamp.
QuotaWindow? _grokScanWindow(List<int> message, int now) {
  final scan = ProtoScan()..walk(message);
  final percent = scan.firstPercent;
  if (percent == null) return null;
  return QuotaWindow(
    label: 'weekly',
    usedPercent: percent,
    resetsAt: scan.nearestFutureTimestamp(now),
  );
}

/// Plausibility bounds for a unix-seconds varint (2020..2033), so field ids,
/// enums, and nano counts are never mistaken for timestamps.
bool _plausibleEpochSeconds(int v) => v > 1600000000 && v < 2000000000;

double _percent2(double f) => double.parse(f.toStringAsFixed(2));

double _float32(List<int> bytes) =>
    ByteData.sublistView(Uint8List.fromList(bytes))
        .getFloat32(0, Endian.little);

/// Calls [visit] for each top-level field of protobuf [b]. Varint fields pass
/// their value; fixed-width and length-delimited fields pass their raw bytes.
/// Returns false as soon as the buffer stops parsing as valid protobuf.
bool _forEachProtoField(
  List<int> b,
  void Function(int field, int wireType, int? varint, List<int> bytes) visit,
) {
  var i = 0;
  while (i < b.length) {
    final (tag, ni) = readVarint(b, i);
    if (tag == null) return false;
    i = ni;
    final field = tag >> 3;
    final wireType = tag & 7;
    switch (wireType) {
      case 0:
        final (v, n2) = readVarint(b, i);
        if (v == null) return false;
        i = n2;
        visit(field, wireType, v, const []);
      case 5:
        if (i + 4 > b.length) return false;
        visit(field, wireType, null, b.sublist(i, i + 4));
        i += 4;
      case 1:
        if (i + 8 > b.length) return false;
        visit(field, wireType, null, b.sublist(i, i + 8));
        i += 8;
      case 2:
        // Subtraction-form bounds check: a hostile 9-byte length varint
        // decodes near 2^62, where `n2 + len` wraps negative and would pass
        // an addition-form check straight into a throwing sublist.
        final (len, n2) = readVarint(b, i);
        if (len == null || len < 0 || len > b.length - n2) return false;
        visit(field, wireType, null, b.sublist(n2, n2 + len));
        i = n2 + len;
      default:
        return false;
    }
  }
  return true;
}

/// Walks a protobuf collecting 32-bit floats and timestamp-like varints without
/// the schema. Used for the Grok billing response.
class ProtoScan {
  final List<double> floats = [];
  final List<int> timestamps = [];

  double? get firstPercent {
    for (final f in floats) {
      if (f >= 0 && f <= 100) return _percent2(f);
    }
    return null;
  }

  int? nearestFutureTimestamp(int now) {
    final future = timestamps.where((t) => t > now).toList()..sort();
    if (future.isNotEmpty) return future.first;
    if (timestamps.isEmpty) return null;
    return timestamps.reduce((a, b) => a > b ? a : b);
  }

  void walk(List<int> b, [int depth = 0]) {
    if (depth > 8) return;
    _forEachProtoField(b, (field, wireType, varint, bytes) {
      switch (wireType) {
        case 0:
          if (_plausibleEpochSeconds(varint!)) timestamps.add(varint);
        case 5:
          floats.add(_float32(bytes));
        case 2:
          walk(bytes, depth + 1);
      }
    });
  }
}
