part of '../../parsing.dart';

// --- Claude -----------------------------------------------------------------

/// One admitted Anthropic OAuth usage response. Shared and model-scoped limits
/// are one observation and must cross the trust boundary together.
typedef ClaudeLiveUsage = ({
  List<QuotaWindow> windows,
  List<ModelQuota> modelQuotas,
});

/// Parses one Anthropic OAuth usage response atomically.
///
/// The shared session and weekly rows are both binding pools. Dropping either
/// one can overstate immediate availability, so an admitted response must prove
/// both. Every recognized canonical `limits` row and every present known legacy
/// block must also be structurally valid, and an unknown quota-shaped row inside
/// the `limits` array still rejects the observation because a new binding pool
/// arrives there. When the authoritative `limits` array is present, additive
/// non-account root blocks alongside it (usage-credit `spend`, `extra_usage`, and
/// per-model or rotating codenamed weekly windows) are tolerated rather than
/// failing the whole read. The strict unknown-root-block guard applies only to
/// the older response shape that has no `limits` array, where an unknown root
/// block carrying quota markers may be a newly introduced binding pool.
ClaudeLiveUsage? claudeLiveUsage(
  Map<String, dynamic>? data, {
  int? observedAt,
}) {
  if (data == null) return null;
  final observation = observedAt ?? nowEpoch();

  var canonical = (
    valid: true,
    windows: const <QuotaWindow>[],
    modelQuotas: const <ModelQuota>[],
  );
  final hasCanonicalLimits = data['limits'] is List;
  if (data.containsKey('limits')) {
    final limits = data['limits'];
    if (limits is! List) return null;
    canonical = _claudeCanonicalLimits(limits, observation);
    if (!canonical.valid) return null;
  }

  // The `limits` array is the authoritative account-window source. Anthropic
  // ships many additive non-account root blocks alongside it (usage credits,
  // spend, per-model and rotating codenamed windows), so the strict
  // unknown-root-block guard only applies to the older response shape that has
  // no `limits` array; failing the whole read on those additive blocks would
  // drop the account's real 5h and weekly windows entirely.
  if (!hasCanonicalLimits && _claudeHasUnknownRootQuotaBlock(data)) return null;

  final legacy = _legacyClaudeUsage(
    data,
    failClosed: !hasCanonicalLimits,
  );
  if (!legacy.valid) return null;

  final windows = _mergeClaudeWindows(canonical.windows, legacy.windows);
  final labels = windows.map((window) => window.label).toSet();
  if (!labels.contains('5h') || !labels.contains('weekly')) return null;

  return (
    windows: windows,
    modelQuotas: _mergeClaudeModelQuotas(
      canonical.modelQuotas,
      legacy.modelQuotas,
    ),
  );
}

/// Display-only Claude usage-tab extras from the same `/usage` metadata.
/// Extra-usage credits and spend are not account windows and never route.
List<String> claudeUsageDetails(Map<String, dynamic>? data) {
  if (data == null) return const [];
  final out = <String>[];
  final extra = data['extra_usage'];
  if (extra is Map) {
    final enabled = extra['is_enabled'] == true;
    final util = finiteOrNull(extra['utilization']);
    if (enabled && util != null) {
      out.add('Extra usage ${_detailPercent(util)}% of credits');
    } else if (enabled) {
      out.add('Extra usage is on (credits, not plan windows)');
    } else if (util != null) {
      out.add('Extra usage ${_detailPercent(util)}% of credits');
    }
  }
  final spend = data['spend'];
  if (spend is Map) {
    final enabled = spend['enabled'] == true;
    final percent = finiteOrNull(spend['percent']);
    if (enabled || (percent != null && percent > 0)) {
      if (percent != null) {
        out.add('Usage credits ${_detailPercent(percent)}%');
      } else {
        out.add('Usage credits are on');
      }
    }
  }
  return out;
}

/// Compatibility projection for callers that need only shared windows. Runtime
/// collection uses [claudeLiveUsage] once so windows and scoped limits cannot be
/// admitted from different parser outcomes.
List<QuotaWindow> claudeWindows(
  Map<String, dynamic> data, {
  int? observedAt,
}) =>
    claudeLiveUsage(data, observedAt: observedAt)?.windows ?? const [];

/// Compatibility projection for callers that need only model-scoped limits.
List<ModelQuota> claudeModelQuotas(
  Map<String, dynamic> data, {
  int? observedAt,
}) =>
    claudeLiveUsage(data, observedAt: observedAt)?.modelQuotas ?? const [];

/// Parses Anthropic's current `limits` array. Recognized rows need a complete
/// kind/group/scope pairing and a bounded numeric percent. Weekly rows also
/// need a positive ISO reset. A session row may omit `resets_at`. `is_active`
/// is advisory: Claude reports enforced weekly rows as inactive while still
/// displaying them in `/usage`. Unknown kinds remain additive only when they
/// do not carry any canonical quota marker.
({
  bool valid,
  List<QuotaWindow> windows,
  List<ModelQuota> modelQuotas,
}) _claudeCanonicalLimits(List<dynamic> limits, int observedAt) {
  final byLabel = <String, QuotaWindow>{};
  final byModel = <String, ModelQuota>{};
  for (final row in limits) {
    if (row is! Map) {
      return (
        valid: false,
        windows: const [],
        modelQuotas: const [],
      );
    }
    final kind = row['kind'];
    if (kind is! String) {
      return (
        valid: false,
        windows: const [],
        modelQuotas: const [],
      );
    }

    if (kind == 'session' || kind == 'weekly_all') {
      final label = _claudeLimitLabel(row);
      final percent = _claudeCanonicalPercent(row);
      final reset = _claudeOptionalReset(row);
      // A current session row can omit resets_at. Dropping the whole account
      // for that would freeze last-known 5h and weekly while the live weekly
      // bar is already spent. Weekly still needs a parseable reset.
      if (label == null ||
          percent == null ||
          reset.malformed ||
          (kind == 'weekly_all' && reset.value == null)) {
        return (
          valid: false,
          windows: const [],
          modelQuotas: const [],
        );
      }
      final candidate = QuotaWindow(
        label: label,
        usedPercent: percent,
        resetsAt: reset.value,
      );
      final current = byLabel[label];
      if (current == null ||
          _preferClaudeWindow(candidate, current, observedAt)) {
        byLabel[label] = candidate;
      }
      continue;
    }

    if (kind == 'weekly_scoped') {
      final model =
          row['group'] == 'weekly' ? _claudeScopedModelName(row) : null;
      final percent = _claudeCanonicalPercent(row);
      final reset = _claudeOptionalReset(row);
      if (model == null ||
          percent == null ||
          reset.malformed ||
          reset.value == null) {
        return (
          valid: false,
          windows: const [],
          modelQuotas: const [],
        );
      }
      final candidate = ModelQuota(
        model: model,
        usedPercent: percent,
        resetsAt: reset.value,
        windowLabel: 'weekly',
      );
      final key = model.toLowerCase();
      final current = byModel[key];
      if (current == null ||
          _preferClaudeModelQuota(candidate, current, observedAt)) {
        byModel[key] = candidate;
      }
      continue;
    }

    if (_claudeUnknownLimitIsQuotaShaped(row)) {
      return (
        valid: false,
        windows: const [],
        modelQuotas: const [],
      );
    }
  }
  return (
    valid: true,
    windows: byLabel.values.toList(growable: false),
    modelQuotas: byModel.values.toList(growable: false),
  );
}

const _claudeCanonicalQuotaMarkers = {
  'percent',
  'utilization',
  'resets_at',
  'group',
  'scope',
  'is_active',
};

const _claudeKnownRootQuotaKeys = {
  'limits',
  'five_hour',
  'seven_day',
  'seven_day_opus',
  'seven_day_sonnet',
  'seven_day_cowork',
  'seven_day_routines',
  'seven_day_claude_routines',
  'claude_routines',
  'routines',
  'routine',
  'cowork',
  // Last-resort app window. It is not a second included weekly pool and must
  // not reject a read that already has the shared 5h and weekly rows.
  'seven_day_oauth_apps',
};

const _claudeRootQuotaMarkers = {
  ..._claudeCanonicalQuotaMarkers,
  'used_percent',
  'reset_at',
};

bool _claudeUnknownLimitIsQuotaShaped(Map<dynamic, dynamic> row) =>
    _hasDirectQuotaMarker(row, _claudeCanonicalQuotaMarkers);

bool _claudeHasUnknownRootQuotaBlock(Map<String, dynamic> data) {
  for (final entry in data.entries) {
    if (_claudeKnownRootQuotaKeys.contains(entry.key)) continue;
    final value = entry.value;
    if (value is Map && _hasDirectQuotaMarker(value, _claudeRootQuotaMarkers)) {
      return true;
    }
  }
  return false;
}

bool _hasDirectQuotaMarker(
  Map<dynamic, dynamic> value,
  Set<String> markers,
) =>
    value.keys.any(
      (key) => key is String && markers.contains(key.toLowerCase()),
    );

/// Combines transitional response shapes without duplicate pools. Canonical
/// rows win by label, while legacy fields can fill a missing primary. The
/// primary routing windows stay in stable short-window, long-window order.
List<QuotaWindow> _mergeClaudeWindows(
  List<QuotaWindow> canonical,
  List<QuotaWindow> legacy,
) {
  final byLabel = <String, QuotaWindow>{};
  for (final window in legacy) {
    byLabel[window.label] = window;
  }
  for (final window in canonical) {
    byLabel[window.label] = window;
  }

  final out = <QuotaWindow>[];
  final emitted = <String>{};
  for (final label in const ['5h', 'weekly']) {
    final window = byLabel[label];
    if (window != null) {
      out.add(window);
      emitted.add(label);
    }
  }
  for (final source in [canonical, legacy]) {
    for (final window in source) {
      if (emitted.add(window.label)) out.add(byLabel[window.label]!);
    }
  }
  return out;
}

List<ModelQuota> _mergeClaudeModelQuotas(
  List<ModelQuota> canonical,
  List<ModelQuota> legacy,
) {
  final byModel = <String, ModelQuota>{};
  for (final quota in legacy) {
    byModel[quota.model.toLowerCase()] = quota;
  }
  for (final quota in canonical) {
    byModel[quota.model.toLowerCase()] = quota;
  }
  return byModel.values.toList(growable: false);
}

bool _preferClaudeWindow(
  QuotaWindow candidate,
  QuotaWindow current,
  int observedAt,
) {
  final candidateExpired = _resetExpired(candidate.resetsAt, observedAt);
  final currentExpired = _resetExpired(current.resetsAt, observedAt);
  if (candidateExpired != currentExpired) return !candidateExpired;
  return _tighterWindow(candidate, current);
}

bool _tighterModelQuota(ModelQuota candidate, ModelQuota current) {
  final candidateUsed = candidate.usedPercent;
  final currentUsed = current.usedPercent;
  if (candidateUsed == null) return false;
  if (currentUsed == null || candidateUsed > currentUsed) return true;
  if (candidateUsed < currentUsed) return false;
  return (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1);
}

bool _preferClaudeModelQuota(
  ModelQuota candidate,
  ModelQuota current,
  int observedAt,
) {
  final candidateExpired = _resetExpired(candidate.resetsAt, observedAt);
  final currentExpired = _resetExpired(current.resetsAt, observedAt);
  if (candidateExpired != currentExpired) return !candidateExpired;
  return _tighterModelQuota(candidate, current);
}

bool _resetExpired(int? reset, int observedAt) =>
    reset != null && reset <= observedAt;

String? _claudeLimitLabel(Map<dynamic, dynamic> row) {
  final kind = row['kind'];
  final group = row['group'];
  final scope = row['scope'];
  if (kind == 'session' && group == 'session' && scope == null) return '5h';
  if (kind == 'weekly_all' && group == 'weekly' && scope == null) {
    return 'weekly';
  }
  return null;
}

double? _claudeCanonicalPercent(Map<dynamic, dynamic> row) {
  if (row.containsKey('is_active') && row['is_active'] is! bool) return null;
  return _strictBoundedPercent(row['percent']);
}

({bool malformed, int? value}) _claudeOptionalReset(Map<dynamic, dynamic> row) {
  if (!row.containsKey('resets_at') || row['resets_at'] == null) {
    return (malformed: false, value: null);
  }
  final value = _strictClaudeIsoEpoch(row['resets_at']);
  if (value == null) return (malformed: true, value: null);
  return (malformed: false, value: value);
}

String? _claudeScopedModelName(Map<dynamic, dynamic> row) {
  final scope = row['scope'];
  if (scope is! Map) return null;
  // A present model scope is the pool name. Falling through to surface when
  // that model text is unusable would hide a malformed row. Surface is the
  // name only when model is absent.
  if (scope.containsKey('model') && scope['model'] != null) {
    return _claudeScopeDisplay(scope['model']);
  }
  if (scope.containsKey('surface') && scope['surface'] != null) {
    return _claudeScopeDisplay(scope['surface']);
  }
  return null;
}

String? _claudeScopeDisplay(dynamic raw) {
  final Object? displayName;
  if (raw is String) {
    displayName = raw;
  } else if (raw is Map) {
    displayName = raw['display_name'] ?? raw['displayName'] ?? raw['name'];
  } else {
    displayName = null;
  }
  if (displayName is! String) return null;
  final trimmed = displayName.trim();
  if (trimmed.isEmpty || trimmed.length > 160) return null;
  if (trimmed.codeUnits.any((code) => code < 32 || code == 127)) return null;
  final label = _claudeScopedLabel(trimmed);
  if (label == null) return null;
  return label
      .split('-')
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

/// Produces a short, deterministic model-family label for a scoped weekly cap.
/// Known Claude families stay stable across display-name version changes. An
/// unknown future family is reduced to a bounded lowercase slug rather than
/// copying arbitrary provider text into terminal or desktop output.
String? _claudeScopedLabel(String displayName) {
  final words = displayName
      .trim()
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return null;
  for (final family in const ['fable', 'opus', 'sonnet', 'haiku']) {
    if (words.contains(family)) return family;
  }
  final slug = words.take(3).join('-');
  if (slug == '5h' || slug == 'weekly') return null;
  return slug.length <= 32 ? slug : slug.substring(0, 32);
}

double? _strictBoundedPercent(dynamic value) {
  if (value is! num) return null;
  final parsed = value.toDouble();
  if (!parsed.isFinite || parsed < 0 || parsed > 100) return null;
  return parsed;
}

({
  bool valid,
  List<QuotaWindow> windows,
  List<ModelQuota> modelQuotas,
}) _legacyClaudeUsage(
  Map<String, dynamic> data, {
  bool failClosed = true,
}) {
  final out = <QuotaWindow>[];
  for (final spec in const [
    ['five_hour', '5h'],
    ['seven_day', 'weekly'],
  ]) {
    if (!data.containsKey(spec[0])) continue;
    final block = data[spec[0]];
    if (block is! Map) {
      if (failClosed) {
        return (valid: false, windows: const [], modelQuotas: const []);
      }
      continue;
    }
    final util = _strictBoundedPercent(block['utilization']);
    final reset = _legacyClaudeReset(block);
    if (util == null || !reset.valid) {
      if (failClosed) {
        return (valid: false, windows: const [], modelQuotas: const []);
      }
      continue;
    }
    out.add(
      QuotaWindow(
        label: spec[1],
        usedPercent: util,
        resetsAt: reset.value,
      ),
    );
  }

  final modelQuotas = <ModelQuota>[];
  for (final entry in const [
    ['seven_day_opus', 'Opus'],
    ['seven_day_sonnet', 'Sonnet'],
  ]) {
    final parsed = _legacyClaudeNamedQuota(data, entry[0], entry[1]);
    if (parsed.malformed) {
      if (failClosed) {
        return (valid: false, windows: const [], modelQuotas: const []);
      }
      continue;
    }
    final quota = parsed.quota;
    if (quota != null) modelQuotas.add(quota);
  }
  // CodexBar charts these aliases as one Daily Routines window. The first
  // well-formed block is not special: the tighter percent is the one that
  // cannot overstate that lane. It stays a model quota, not the shared weekly
  // bar. Generic names count only when they carry utilization, so an unrelated
  // object under the same name does not reject the 5h and weekly rows.
  final routines = _legacyClaudeRoutinesQuota(data);
  if (routines.malformed && failClosed) {
    return (valid: false, windows: const [], modelQuotas: const []);
  }
  final routinesQuota = routines.quota;
  if (routinesQuota != null) modelQuotas.add(routinesQuota);

  return (
    valid: true,
    windows: out,
    modelQuotas: modelQuotas,
  );
}

({bool malformed, ModelQuota? quota}) _legacyClaudeNamedQuota(
  Map<String, dynamic> data,
  String key,
  String model,
) {
  if (!data.containsKey(key) || data[key] == null) {
    return (malformed: false, quota: null);
  }
  final block = data[key];
  if (block is! Map) return (malformed: true, quota: null);
  return _legacyClaudeUtilizationQuota(block, model);
}

const _claudeRoutinesKeys = [
  'seven_day_routines',
  'seven_day_claude_routines',
  'claude_routines',
  'routines',
  'routine',
  'seven_day_cowork',
  'cowork',
];

const _claudeGenericRoutinesKeys = {'routines', 'routine', 'cowork'};

({bool malformed, ModelQuota? quota}) _legacyClaudeRoutinesQuota(
  Map<String, dynamic> data,
) {
  ModelQuota? tightest;
  var malformed = false;
  for (final key in _claudeRoutinesKeys) {
    if (!data.containsKey(key) || data[key] == null) continue;
    final block = data[key];
    final generic = _claudeGenericRoutinesKeys.contains(key);
    if (block is! Map) {
      if (!generic) malformed = true;
      continue;
    }
    if (generic && !block.containsKey('utilization')) continue;
    final parsed = _legacyClaudeUtilizationQuota(block, 'Routines');
    if (parsed.malformed) {
      malformed = true;
      continue;
    }
    final candidate = parsed.quota;
    if (candidate == null) continue;
    if (tightest == null || _tighterModelQuota(candidate, tightest)) {
      tightest = candidate;
    }
  }
  return (malformed: malformed, quota: tightest);
}

({bool malformed, ModelQuota? quota}) _legacyClaudeUtilizationQuota(
  Map<dynamic, dynamic> block,
  String model,
) {
  final util = _strictBoundedPercent(block['utilization']);
  final reset = _legacyClaudeReset(block);
  if (util == null || !reset.valid) {
    return (malformed: true, quota: null);
  }
  return (
    malformed: false,
    quota: ModelQuota(
      model: model,
      usedPercent: util,
      resetsAt: reset.value,
      windowLabel: 'weekly',
    ),
  );
}

({bool valid, int? value}) _legacyClaudeReset(Map<dynamic, dynamic> block) {
  if (!block.containsKey('resets_at') || block['resets_at'] == null) {
    return (valid: true, value: null);
  }
  final parsed = _strictClaudeIsoEpoch(block['resets_at']);
  return parsed != null && parsed > 0
      ? (valid: true, value: parsed)
      : (valid: false, value: null);
}

int? _strictClaudeIsoEpoch(dynamic raw) {
  if (raw is! String) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !parsed.isUtc) return null;
  final epoch = parsed.millisecondsSinceEpoch ~/ 1000;
  return epoch > 0 ? epoch : null;
}
