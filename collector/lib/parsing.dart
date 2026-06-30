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
      final used = (w['used_percent'] as num?)?.toDouble();
      if (used == null) continue;
      final resetsAt = (w['resets_at'] as num?)?.toInt();
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
    final util = (block['utilization'] as num?)?.toDouble();
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
    final frac = (qi['remainingFraction'] as num?)?.toDouble();
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
      final used = (b['currentUsage'] as num?)?.toDouble();
      final limit = (b['usageLimit'] as num?)?.toDouble();
      final pct = (b['percentageUsed'] as num?)?.toDouble();
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
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value.replaceAll(',', '').trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
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

  // Direct remaining percent style (from some caches / API mirrors). A blob may
  // carry both snake_case and camelCase spellings of the same field, so the
  // first spelling seen for a label wins and later duplicates are skipped.
  final seenLabels = <String>{};
  for (final spec in const [
    ['daily_quota_remaining_percent', 'daily'],
    ['dailyQuotaRemainingPercent', 'daily'],
    ['weekly_quota_remaining_percent', 'weekly'],
    ['weeklyQuotaRemainingPercent', 'weekly'],
  ]) {
    if (seenLabels.contains(spec[1])) continue;
    final rem = (usageData[spec[0]] as num?)?.toDouble();
    if (rem != null) {
      final used = (100 - rem).clamp(0.0, 100.0);
      windows.add(QuotaWindow(label: spec[1], usedPercent: used));
      seenLabels.add(spec[1]);
    }
  }

  // usage counters (newer cache shapes per research; usedMessages/messages etc)
  final usedMsgs = (usageData['usedMessages'] as num?)?.toDouble();
  final totMsgs = (usageData['messages'] as num?)?.toDouble() ??
      (usageData['messageLimit'] as num?)?.toDouble();
  if (usedMsgs != null && totMsgs != null && totMsgs > 0) {
    windows.add(
      QuotaWindow(
        label: 'messages',
        usedPercent: (usedMsgs / totMsgs * 100).clamp(0.0, 100.0),
      ),
    );
  }

  final usedFlows = (usageData['usedFlowActions'] as num?)?.toDouble();
  final totFlows = (usageData['flowActions'] as num?)?.toDouble() ??
      (usageData['flowActionLimit'] as num?)?.toDouble();
  if (usedFlows != null && totFlows != null && totFlows > 0) {
    windows.add(
      QuotaWindow(
        label: 'flow',
        usedPercent: (usedFlows / totFlows * 100).clamp(0.0, 100.0),
      ),
    );
  }

  // quotaUsage nested or direct
  dynamic qu = usageData['quotaUsage'];
  if (qu is Map) {
    // try common subfields
    for (final k in ['daily', 'weekly', 'cascade']) {
      final v = qu[k];
      if (v is Map) {
        final used = (v['used'] as num?)?.toDouble();
        final lim = (v['limit'] as num?)?.toDouble();
        if (used != null && lim != null && lim > 0) {
          windows.add(
            QuotaWindow(
              label: k,
              usedPercent: (used / lim * 100).clamp(0.0, 100.0),
            ),
          );
        }
      }
    }
  }

  // Try similar to Kiro/Cursor breakdowns as last resort
  if (windows.isEmpty) {
    final breakdowns = usageData['usageBreakdowns'] ?? usageData['credits'];
    if (breakdowns is List) {
      for (final b in breakdowns) {
        if (b is! Map) continue;
        final used = (b['currentUsage'] as num?)?.toDouble();
        final limit = (b['usageLimit'] as num?)?.toDouble();
        final pct = (b['percentageUsed'] as num?)?.toDouble();
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

  // raw fallback placeholder (will show as 0 until better data)
  if (windows.isEmpty && usageData.containsKey('raw')) {
    windows.add(QuotaWindow(label: 'quota', usedPercent: 0));
  }

  return windows;
}

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
    final used = (b['currentUsage'] as num?)?.toDouble();
    final limit = (b['usageLimit'] as num?)?.toDouble();
    final pct = (b['percentageUsed'] as num?)?.toDouble();
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
  if (v is num) return v.toInt();
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

// --- Grok -------------------------------------------------------------------

/// Extracts the first gRPC-web DATA frame payload (flag 0x00) from a response.
List<int> grpcMessage(Uint8List resp) {
  if (resp.length < 5) return const [];
  if ((resp[0] & 0x80) != 0) return const []; // first frame is a trailer
  final len = (resp[1] << 24) | (resp[2] << 16) | (resp[3] << 8) | resp[4];
  if (5 + len > resp.length) return const [];
  return resp.sublist(5, 5 + len);
}

/// Parses the Grok billing protobuf into a single monthly usage window.
QuotaWindow? grokWindow(List<int> message, int now) {
  if (message.isEmpty) return null;
  final scan = ProtoScan()..walk(message);
  final percent = scan.firstPercent;
  if (percent == null) return null;
  return QuotaWindow(
    label: 'monthly',
    usedPercent: percent,
    resetsAt: scan.nearestFutureTimestamp(now),
  );
}

/// Walks a protobuf collecting 32-bit floats and timestamp-like varints without
/// the schema. Used for the Grok billing response.
class ProtoScan {
  final List<double> floats = [];
  final List<int> timestamps = [];

  double? get firstPercent {
    for (final f in floats) {
      if (f >= 0 && f <= 100) return double.parse(f.toStringAsFixed(2));
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
    var i = 0;
    while (i < b.length) {
      final (tag, ni) = readVarint(b, i);
      if (tag == null) break;
      i = ni;
      final wt = tag & 7;
      switch (wt) {
        case 0:
          final (v, n2) = readVarint(b, i);
          if (v == null) return;
          i = n2;
          if (v > 1600000000 && v < 2000000000) timestamps.add(v);
          break;
        case 5:
          if (i + 4 > b.length) return;
          final view = ByteData.sublistView(
            Uint8List.fromList(b.sublist(i, i + 4)),
          );
          floats.add(view.getFloat32(0, Endian.little));
          i += 4;
          break;
        case 1:
          i += 8;
          break;
        case 2:
          final (len, n2) = readVarint(b, i);
          if (len == null || n2 + len > b.length) return;
          i = n2;
          walk(b.sublist(i, i + len), depth + 1);
          i += len;
          break;
        default:
          return;
      }
    }
  }
}
