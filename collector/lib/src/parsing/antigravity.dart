part of '../../parsing.dart';

// --- Antigravity ------------------------------------------------------------

/// The furthest a reset can be and still credibly represent a resettable weekly
/// cadence. Antigravity's live response carries only `{remainingFraction,
/// resetTime}` per model with no field distinguishing a resettable window from a
/// persistent/baseline balance, so a reset beyond a week (plus a day of buffer)
/// is treated as an indeterminate balance rather than inferred to be a "weekly"
/// window with a concrete reset it may not really have. Such balances still
/// surface per-model via [antigravityModelQuotasFromLive]; they are just not
/// asserted as a plan-level window.
const _antigravityMaxWindowHorizon = 8 * 86400;

/// Account-level Antigravity windows from `retrieveUserQuotaSummary`.
///
/// The daily Cloud Code host reports named shared pools (Gemini models, and
/// Claude and GPT models), each with a weekly bucket and a five-hour bucket.
/// Until typed shared pools, the account card shows one `5h` and one `weekly`
/// window: the most-constrained active bucket of each kind. A `disabled`
/// bucket is not that limiter. A spent longer window still binds routing.
/// An older per-model summary has no `window` field; its account card is the
/// tightest in-horizon row, labeled `weekly` the same way the unnamed model
/// table is. [now] is that horizon's observation time. Returns null when the
/// payload is present but unreadable so callers fail closed instead of
/// falling back to the always-full `fetchAvailableModels` table on the
/// non-daily host.
List<QuotaWindow>? antigravityQuotaSummaryWindows(
  Map<String, dynamic>? resp, {
  int? now,
}) {
  final buckets = _antigravityQuotaSummaryBuckets(resp);
  if (buckets == null) return null;
  if (buckets.isEmpty) return const [];

  QuotaWindow? fiveHour;
  QuotaWindow? weekly;
  QuotaWindow? perModel;
  final observedAt = now ?? nowEpoch();
  for (final bucket in buckets) {
    final used = ((1 - bucket.remainingFraction) * 100).toDouble();
    final candidate = QuotaWindow(
      label: bucket.label ?? 'weekly',
      usedPercent: used,
      resetsAt: bucket.resetsAt,
    );
    if (bucket.model != null) {
      final reset = bucket.resetsAt;
      if (reset == null || reset - observedAt > _antigravityMaxWindowHorizon) {
        continue;
      }
      perModel = _tighterAntigravityWindow(perModel, candidate);
      continue;
    }
    if (bucket.label == '5h') {
      fiveHour = _tighterAntigravityWindow(fiveHour, candidate);
    } else {
      weekly = _tighterAntigravityWindow(weekly, candidate);
    }
  }
  if (fiveHour == null && weekly == null) {
    return [if (perModel != null) perModel];
  }
  return [
    if (fiveHour != null) fiveHour,
    if (weekly != null) weekly,
  ];
}

/// Adds one `models` window when a long catalog cluster is tighter than the
/// grouped summary.
///
/// `agy /usage` shows the per-model rows. A grouped five-hour bucket can stay
/// at zero while many of those rows share one real used percent. More than
/// eight current rows never become individual glance bars, so the shared
/// cluster becomes a window and provider headroom follows it. The original
/// summary windows stay in the snapshot. Eight or fewer rows keep the existing
/// pool-split glance instead of gaining this window.
List<QuotaWindow> antigravityWindowsWithModelCluster(
  List<QuotaWindow> windows,
  List<ModelQuota> modelQuotas,
  int now,
) {
  if (windows.isEmpty) return windows;
  var accountUsed = 0.0;
  for (final window in windows) {
    final used = window.percent;
    if (used == null || !used.isFinite || used < 0 || used > 100) {
      return windows;
    }
    if (used > accountUsed) accountUsed = used;
  }

  final rows = <ModelQuota>[
    for (final row in modelQuotas)
      if (row.usedPercent != null &&
          row.usedPercent!.isFinite &&
          row.usedPercent! >= 0 &&
          row.usedPercent! <= 100 &&
          row.model.trim().isNotEmpty &&
          (row.resetsAt == null || row.resetsAt! > now))
        row,
  ];
  if (rows.length <= 8) return windows;

  final groups = <int, List<ModelQuota>>{};
  for (final row in rows) {
    groups.putIfAbsent(row.usedPercent!.round(), () => []).add(row);
  }
  int? tightest;
  List<ModelQuota>? cluster;
  for (final entry in groups.entries) {
    if (tightest == null || entry.key > tightest) {
      tightest = entry.key;
      cluster = entry.value;
    }
  }
  if (tightest == null ||
      cluster == null ||
      cluster.length < 2 ||
      tightest - accountUsed < 1) {
    return windows;
  }
  var used = cluster.first.usedPercent!;
  var reset = cluster.first.resetsAt;
  var sharedReset = true;
  for (final row in cluster.skip(1)) {
    final rowUsed = row.usedPercent!;
    if (rowUsed > used) used = rowUsed;
    if (row.resetsAt != reset) sharedReset = false;
  }
  if (windows.any((window) {
    final percent = window.percent;
    return percent != null && (percent - used).abs() < 0.5;
  })) {
    return windows;
  }
  return [
    ...windows,
    QuotaWindow(
      label: 'models',
      usedPercent: used,
      resetsAt: sharedReset ? reset : null,
    ),
  ];
}

/// Group-level Antigravity model quotas from `retrieveUserQuotaSummary`.
///
/// Each named pool becomes one row whose used percent is its tightest active
/// bucket. A per-model summary instead keeps one row per model. Per-model
/// rows from [antigravityModelQuotasFromLive] remain preferred when that
/// table is present and metered.
List<ModelQuota> antigravityQuotaSummaryModelQuotas(
    Map<String, dynamic>? resp) {
  final buckets = _antigravityQuotaSummaryBuckets(resp);
  if (buckets == null || buckets.isEmpty) return const [];
  final byGroup = <String, _AntigravitySummaryBucket>{};
  final perModel = <String, _AntigravitySummaryBucket>{};
  for (final bucket in buckets) {
    if (bucket.model != null) {
      final key = bucket.model!.toLowerCase();
      final current = perModel[key];
      if (current == null ||
          bucket.remainingFraction < current.remainingFraction) {
        perModel[key] = bucket;
      }
      continue;
    }
    final current = byGroup[bucket.group];
    if (current == null ||
        bucket.remainingFraction < current.remainingFraction) {
      byGroup[bucket.group] = bucket;
    }
  }
  return [
    for (final bucket in byGroup.values)
      ModelQuota(
        model: bucket.group,
        usedPercent: ((1 - bucket.remainingFraction) * 100).toDouble(),
        resetsAt: bucket.resetsAt,
        windowLabel: bucket.label,
      ),
    for (final bucket in perModel.values)
      ModelQuota(
        model: bucket.model!,
        usedPercent: ((1 - bucket.remainingFraction) * 100).toDouble(),
        resetsAt: bucket.resetsAt,
      ),
  ];
}

QuotaWindow _tighterAntigravityWindow(QuotaWindow? current, QuotaWindow next) {
  if (current == null) return next;
  final currentUsed = current.usedPercent ?? -1;
  final nextUsed = next.usedPercent ?? -1;
  if (nextUsed > currentUsed) return next;
  if (nextUsed < currentUsed) return current;
  final currentReset = current.resetsAt;
  final nextReset = next.resetsAt;
  if (nextReset != null && (currentReset == null || nextReset < currentReset)) {
    return next;
  }
  return current;
}

typedef _AntigravitySummaryBucket = ({
  String group,
  String? model,
  String? label,
  double remainingFraction,
  int? resetsAt,
});

/// Parses the grouped weekly and five-hour buckets. Null means the payload is
/// structurally untrustworthy; an empty list means there is no metered pool.
/// A `disabled` bucket is omitted. An unlabeled consumed bucket fails the
/// summary when any bucket names a window, because that row may be a binding
/// pool. A summary whose buckets are all unlabeled is the older per-model
/// plan: each display name is that model's tighter cap.
List<_AntigravitySummaryBucket>? _antigravityQuotaSummaryBuckets(
  Map<String, dynamic>? resp,
) {
  if (resp == null) return const [];
  if (!resp.containsKey('groups')) return const [];
  final groups = resp['groups'];
  if (groups is! List) return null;
  final labeled = <_AntigravitySummaryBucket>[];
  final unlabeled = <({
    String group,
    Map<Object?, Object?> bucket,
    double remainingFraction,
  })>[];
  for (final group in groups) {
    if (group is! Map) return null;
    final displayName = group['displayName']?.toString().trim();
    final groupName = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : 'Models';
    final buckets = group['buckets'];
    if (buckets == null) continue;
    if (buckets is! List) return null;
    for (final bucket in buckets) {
      if (bucket is! Map) return null;
      final fields = Map<Object?, Object?>.from(bucket);
      final rawFraction = fields['remainingFraction'];
      final remainingFraction = _fraction(rawFraction);
      if (rawFraction != null && remainingFraction == null) return null;
      if (fields.containsKey('disabled') && fields['disabled'] != null) {
        final disabled = fields['disabled'];
        if (disabled is! bool) return null;
        if (disabled) continue;
      }
      if (remainingFraction == null) continue;
      final label = _antigravitySummaryWindowLabel(fields);
      if (label == null) {
        unlabeled.add((
          group: groupName,
          bucket: fields,
          remainingFraction: remainingFraction,
        ));
        continue;
      }
      final resetsAt = parseReset(fields['resetTime']);
      if (resetsAt == null || resetsAt <= 0) {
        if (remainingFraction < 1) return null;
        continue;
      }
      labeled.add((
        group: groupName,
        model: null,
        label: label,
        remainingFraction: remainingFraction,
        resetsAt: resetsAt,
      ));
    }
  }
  if (labeled.isNotEmpty) {
    for (final row in unlabeled) {
      // An unlabeled consumed bucket beside a named window could be the
      // binding pool. A full helper bucket is not.
      if (row.remainingFraction < 1) return null;
    }
    return labeled;
  }
  final perModel = <_AntigravitySummaryBucket>[];
  for (final row in unlabeled) {
    final model = _antigravityPerModelName(row.bucket);
    if (model == null) {
      if (row.remainingFraction < 1) return null;
      continue;
    }
    final resetsAt = parseReset(row.bucket['resetTime']);
    if (resetsAt == null || resetsAt <= 0) {
      if (row.remainingFraction < 1) return null;
      continue;
    }
    perModel.add((
      group: row.group,
      model: model,
      label: null,
      remainingFraction: row.remainingFraction,
      resetsAt: resetsAt,
    ));
  }
  return perModel;
}

String? _antigravityPerModelName(Map<Object?, Object?> bucket) {
  final name = bucket['displayName']?.toString().trim();
  if (name == null || name.isEmpty || name.length > 160) return null;
  if (name.codeUnits.any((code) => code < 32 || code == 127)) return null;
  return name;
}

String? _antigravitySummaryWindowLabel(Map<Object?, Object?> bucket) {
  final window = bucket['window']?.toString().trim().toLowerCase();
  if (window == '5h' ||
      window == 'five_hour' ||
      window == 'five-hour' ||
      window == 'five hour') {
    return '5h';
  }
  if (window == 'weekly') return 'weekly';
  final id = bucket['bucketId']?.toString().trim().toLowerCase() ?? '';
  if (_antigravityFiveHourToken(id)) return '5h';
  if (id.contains('weekly')) return 'weekly';
  final name = bucket['displayName']?.toString().trim().toLowerCase() ?? '';
  if (name.contains('five hour') ||
      name.contains('5-hour') ||
      name.contains('5 hour') ||
      _antigravityFiveHourToken(name)) {
    return '5h';
  }
  if (name.contains('weekly')) return 'weekly';
  return null;
}

/// A five-hour id or name has a `5h` token. `gemini-5h` matches. A model id
/// such as `gemini-2.5h`, or an allowance id such as `15h`, does not.
bool _antigravityFiveHourToken(String value) =>
    RegExp(r'(^|[^0-9.])5h([^a-z0-9]|$)').hasMatch(value);

/// The account's binding Antigravity limit as a single weekly-allowance window.
///
/// `fetchAvailableModels` reports one `quotaInfo` per model: a single
/// `remainingFraction` and `resetTime`, its tightest cap across the plan's
/// weekly allowance and its short-term burst limit, with no field naming which
/// window that is. Live collection prefers [antigravityQuotaSummaryWindows].
/// This parser remains for the per-model table and for injected tests that
/// still supply only the model catalog. A reset beyond
/// [_antigravityMaxWindowHorizon] is treated as an indeterminate balance and not
/// asserted as a window.
List<QuotaWindow> antigravityWindows(Map<String, dynamic>? resp, int now) {
  final models = _antigravityLiveQuotaRows(resp);
  if (models == null || models.isEmpty) return const [];

  double? bindingUsed;
  int? bindingReset;
  for (final model in models) {
    if (model.resetsAt - now > _antigravityMaxWindowHorizon) continue;
    final used = ((1 - model.remainingFraction) * 100).clamp(0, 100).toDouble();
    if (bindingUsed == null || used > bindingUsed) {
      bindingUsed = used;
      bindingReset = model.resetsAt;
    }
  }

  if (bindingUsed == null) return const [];
  return [
    QuotaWindow(
      label: 'weekly',
      usedPercent: bindingUsed,
      resetsAt: bindingReset,
    ),
  ];
}

/// Per-model quota from the live Cloud Code `fetchAvailableModels` response.
/// This is authoritative and cross-machine, unlike the local `userStatus`
/// cache (which only reflects usage on the machine that wrote it), so it is
/// preferred whenever the live read succeeds. Each entry is keyed by the model
/// id and carries `{quotaInfo: {remainingFraction, resetTime}}`. When [windows]
/// from the quota summary are present, a matching reset stamps [ModelQuota.windowLabel].
List<ModelQuota> antigravityModelQuotasFromLive(
  Map<String, dynamic>? resp, {
  List<QuotaWindow> windows = const [],
}) {
  final models = _antigravityLiveQuotaRows(resp);
  if (models == null) return const [];
  return models
      .map(
        (model) => ModelQuota(
          model: model.model,
          usedPercent:
              ((1 - model.remainingFraction) * 100).clamp(0, 100).toDouble(),
          resetsAt: model.resetsAt,
          windowLabel: _antigravityWindowLabelForReset(model.resetsAt, windows),
        ),
      )
      .toList();
}

String? _antigravityWindowLabelForReset(
  int resetsAt,
  List<QuotaWindow> windows,
) {
  String? label;
  for (final window in windows) {
    final windowReset = window.resetsAt;
    if (windowReset == null) continue;
    if ((windowReset - resetsAt).abs() > 2) continue;
    if (label != null && label != window.label) return null;
    label = window.label;
  }
  return label;
}

typedef _AntigravityLiveQuotaRow = ({
  String model,
  double remainingFraction,
  int resetsAt,
});

/// Parses the live model table into one quota snapshot. The endpoint lists two
/// kinds of models side by side: metered ones that carry a rolling window
/// (`quotaInfo` with a `resetTime`) and non-metered helpers (tab-completion and
/// chat models) that have no reset time and a full remaining fraction. A row
/// with no reset window is skipped only when it also shows no consumption (a full
/// or absent fraction), rather than rejecting the whole table - otherwise a
/// single helper hides every real window. A metered row whose remaining fraction
/// is unparseable, and a consumed row (fraction below full) that carries no
/// reset, both stay fatal: dropping a possibly-binding variant there could
/// overstate headroom.
List<_AntigravityLiveQuotaRow>? _antigravityLiveQuotaRows(
  Map<String, dynamic>? resp,
) {
  final models = resp?['models'];
  if (models is! Map) return null;
  final out = <_AntigravityLiveQuotaRow>[];
  for (final entry in models.entries) {
    final model = entry.value;
    if (model is! Map) return null;
    final quotaInfo = model['quotaInfo'];
    // A model with no quota block at all is missing data, not a recognizable
    // helper: the non-metered helpers the endpoint lists (tab-completion, chat)
    // still carry a quota block with a full remaining fraction and no reset. A
    // fully absent block could hide a constrained variant, so fail closed.
    if (quotaInfo is! Map) return null;
    final rawFraction = quotaInfo['remainingFraction'];
    final remainingFraction = _fraction(rawFraction);
    final resetsAt = parseReset(quotaInfo['resetTime']);
    final exhausted = quotaInfo['isExhausted'];
    if (exhausted != null && exhausted is! bool) return null;
    if (resetsAt == null || resetsAt <= 0) {
      // A fraction that is present but unparseable is the same malformed
      // evidence that is fatal when a reset exists, so it fails closed here
      // too. Only a genuinely absent fraction identifies the non-metered
      // helper rows below. Without this split, `_fraction` returning null for
      // absent and malformed alike let an out-of-range value skip the row and
      // overstate the account's headroom.
      if (rawFraction != null && remainingFraction == null) return null;
      // No rolling window. That is a non-metered helper only when it also shows
      // no consumption (a full or absent fraction, like the tab-completion and
      // chat rows). A row that shows real consumption but carries no reset is an
      // incomplete metered pool; skipping it would drop a possibly-binding window
      // and overstate headroom, so fail the whole table closed instead.
      // `isExhausted: true` without a reset is the same incomplete metered case.
      if (exhausted == true) return null;
      if (remainingFraction == null || remainingFraction >= 1) continue;
      return null;
    }
    if (remainingFraction == null) return null;
    out.add((
      model: entry.key.toString(),
      remainingFraction: exhausted == true ? 0 : remainingFraction,
      resetsAt: resetsAt,
    ));
  }
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
  if (!ok || r == null || r < 0 || r > 1) return null;
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

double? _fraction(dynamic value) {
  final parsed = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.replaceAll(',', '').trim()),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 1) {
    return null;
  }
  return parsed;
}
