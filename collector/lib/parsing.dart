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

/// Parses several legacy sanitized `rate_limits` fixture snapshots. Runtime
/// collection uses [codexUsageWindows] on account-wide metadata and never reads
/// mixed session files. Reset timestamps do not synthesize a fresh balance.
/// [now] remains in the signature for fixture compatibility only.
List<QuotaWindow> codexBindingWindows(
  Iterable<Map<String, dynamic>> snapshots,
  int now,
) {
  final trustedSnapshots = snapshots.where(_codexPercentShapeIsValid).toList();
  final windows = <QuotaWindow>[];
  for (final entry in const [
    ['primary', '5h'],
    ['secondary', 'weekly'],
  ]) {
    QuotaWindow? binding;
    double bindingUsed = -1;
    for (final rl in trustedSnapshots) {
      final w = rl[entry[0]];
      if (w is! Map) continue;
      final used = _boundedPercent(w['used_percent']);
      if (used == null) continue;
      final resetsAt = parseReset(w['resets_at']);
      final candidate = QuotaWindow(
        label: codexLabel(w['window_minutes'], entry[1]),
        usedPercent: used,
        resetsAt: resetsAt,
      );
      if (used > bindingUsed ||
          (used == bindingUsed &&
              binding != null &&
              _saferEqualUseWindow(candidate, binding))) {
        bindingUsed = used;
        binding = candidate;
      }
    }
    if (binding != null) windows.add(binding);
  }
  return windows;
}

bool _codexPercentShapeIsValid(Map<String, dynamic> rateLimits) {
  for (final key in const ['primary', 'secondary']) {
    if (!rateLimits.containsKey(key)) continue;
    final window = rateLimits[key];
    if (window is! Map || _boundedPercent(window['used_percent']) == null) {
      return false;
    }
  }
  return true;
}

String codexLabel(dynamic minutes, String fallback) {
  final bounded = boundedIntFromWire(
    minutes,
    min: 1,
    max: 366 * 24 * 60,
  );
  if (bounded == null) return fallback;
  if (bounded == 300) return '5h';
  if (bounded == 10080) return 'weekly';
  if (bounded % 1440 == 0) return '${bounded ~/ 1440}d';
  if (bounded % 60 == 0) return '${bounded ~/ 60}h';
  return '${bounded}m';
}

/// Windows from the live Codex `/backend-api/wham/usage` response, which is
/// authoritative and cross-device unlike the per-machine session snapshots.
/// `rate_limit.primary_window` and `secondary_window` each carry
/// `used_percent`, `reset_at`, and `limit_window_seconds`. The duration is the
/// source of truth for the label because some plans now expose one weekly
/// primary window and an explicit null secondary window.
typedef CodexLiveUsage = ({
  List<QuotaWindow> windows,
  List<ModelQuota> modelQuotas,
});

/// Parses one live response atomically. Shared and model-scoped rate limits are
/// one provider observation: accepting the shared pool while silently dropping
/// a malformed named sibling could overstate a model's usable budget.
CodexLiveUsage? codexLiveUsage(Map<String, dynamic>? resp) {
  if (resp == null) return null;
  final shared = _codexLiveRateLimitWindows(resp['rate_limit']);
  if (!shared.valid) return null;
  final scoped = _codexAdditionalRateLimits(resp);
  if (!scoped.valid) return null;
  return (windows: shared.windows, modelQuotas: scoped.modelQuotas);
}

List<QuotaWindow> codexUsageWindows(Map<String, dynamic>? resp) =>
    codexLiveUsage(resp)?.windows ?? const [];

({bool valid, List<QuotaWindow> windows}) _codexLiveRateLimitWindows(
  dynamic raw,
) {
  if (raw is! Map) return (valid: false, windows: const []);
  if (_codexHasUnknownQuotaWindow(raw)) {
    return (valid: false, windows: const []);
  }
  final out = <QuotaWindow>[];
  for (final key in const ['primary_window', 'secondary_window']) {
    if (!raw.containsKey(key)) continue;
    final window = raw[key];
    // The live endpoint uses an explicit null for a pool that this plan does
    // not have. That is absence, not a malformed observation. A non-null row
    // still has to be structurally complete and bounded.
    if (window == null) continue;
    if (window is! Map) {
      return (valid: false, windows: const []);
    }
    final pct = _codexLivePercent(window['used_percent']);
    final reset = parseReset(window['reset_at']);
    final seconds = _codexLiveWindowSeconds(window['limit_window_seconds']);
    if (pct == null || reset == null || reset <= 0 || seconds == null) {
      return (valid: false, windows: const []);
    }
    out.add(
      QuotaWindow(
        label: codexLabel(seconds ~/ 60, '${seconds ~/ 60}m'),
        usedPercent: pct,
        resetsAt: reset,
      ),
    );
  }
  if (out.isEmpty || !_codexLiveFlagsAreConsistent(raw, out)) {
    return (valid: false, windows: const []);
  }
  return (valid: true, windows: out);
}

const _codexKnownRateLimitKeys = {
  'allowed',
  'limit_reached',
  'primary_window',
  'secondary_window',
};

const _codexQuotaWindowMarkers = {
  'used_percent',
  'reset_at',
  'limit_window_seconds',
};

/// A newly added binding pool must not be mistaken for harmless metadata. Its
/// schema is unknown, so the only safe result is to reject the atomic provider
/// observation until the pool can be parsed and included in routing.
bool _codexHasUnknownQuotaWindow(Map<dynamic, dynamic> rateLimit) {
  for (final entry in rateLimit.entries) {
    final key = entry.key;
    if (key is String && _codexKnownRateLimitKeys.contains(key)) continue;

    final normalizedKey = key is String ? key.toLowerCase() : '';
    if (normalizedKey.endsWith('_window')) return true;

    final value = entry.value;
    if (value is Map &&
        value.keys.any(
          (candidate) =>
              candidate is String &&
              _codexQuotaWindowMarkers.contains(candidate.toLowerCase()),
        )) {
      return true;
    }
  }
  return false;
}

double? _codexLivePercent(dynamic raw) =>
    raw is num ? _boundedPercent(raw) : null;

int? _codexLiveWindowSeconds(dynamic raw) {
  if (raw is! num || !raw.toDouble().isFinite) return null;
  if (raw.truncateToDouble() != raw.toDouble()) return null;
  final seconds = raw.toInt();
  if (seconds < 60 || seconds > 366 * 86400 || seconds % 60 != 0) {
    return null;
  }
  return seconds;
}

bool _codexLiveFlagsAreConsistent(
  Map<dynamic, dynamic> raw,
  List<QuotaWindow> windows,
) {
  bool? allowed;
  bool? limitReached;
  if (raw.containsKey('allowed')) {
    final value = raw['allowed'];
    if (value is! bool) return false;
    allowed = value;
  }
  if (raw.containsKey('limit_reached')) {
    final value = raw['limit_reached'];
    if (value is! bool) return false;
    limitReached = value;
  }
  if (allowed != null && limitReached != null && allowed == limitReached) {
    return false;
  }
  // Provider status flags describe the provider's hard limit, not quotabot's
  // earlier routing comfort floor. A valid 99% observation can be unavailable
  // for new routing while the provider still truthfully reports that its hard
  // limit has not been reached.
  final observedLimitReached = windows.any((window) {
    final percent = window.percent;
    return percent != null && percent >= 100;
  });
  if (allowed != null && allowed == observedLimitReached) {
    return false;
  }
  if (limitReached != null && limitReached != observedLimitReached) {
    return false;
  }
  return true;
}

/// Model-scoped Codex pools from `additional_rate_limits`. These are sparse
/// overlays on the shared account limit, not an exhaustive model catalog. A
/// valid row is reduced to its tightest reported window. The field is optional,
/// but when present every row is required to be complete. A malformed sibling
/// rejects the entire live provider observation rather than being silently
/// omitted.
List<ModelQuota> codexModelQuotas(Map<String, dynamic>? resp) {
  if (resp == null) return const [];
  final parsed = _codexAdditionalRateLimits(resp);
  return parsed.valid ? parsed.modelQuotas : const [];
}

({bool valid, List<ModelQuota> modelQuotas}) _codexAdditionalRateLimits(
  Map<String, dynamic> resp,
) {
  if (!resp.containsKey('additional_rate_limits') ||
      resp['additional_rate_limits'] == null) {
    return (valid: true, modelQuotas: const []);
  }
  final rawRows = resp['additional_rate_limits'];
  if (rawRows is! List) return (valid: false, modelQuotas: const []);

  final byModel = <String, ModelQuota>{};
  for (final row in rawRows) {
    if (row is! Map) return (valid: false, modelQuotas: const []);
    final model = _codexScopedModelName(row['limit_name']);
    if (model == null) return (valid: false, modelQuotas: const []);

    final parsed = _codexLiveRateLimitWindows(row['rate_limit']);
    if (!parsed.valid) return (valid: false, modelQuotas: const []);
    final candidate = _codexBindingModelQuota(model, parsed.windows);
    final key = model.toLowerCase();
    final current = byModel[key];
    byModel[key] = current == null
        ? candidate
        : _conservativeCodexModelQuota(current, candidate);
  }
  return (
    valid: true,
    modelQuotas: byModel.values.toList(growable: false),
  );
}

String? _codexScopedModelName(dynamic raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  if (value.isEmpty || value.length > 160) return null;
  if (value.codeUnits.any((code) => code < 32 || code == 127)) return null;
  return value;
}

ModelQuota _codexBindingModelQuota(
  String model,
  List<QuotaWindow> windows,
) {
  var binding = windows.first;
  for (final candidate in windows.skip(1)) {
    final candidateUsed = candidate.usedPercent!;
    final bindingUsed = binding.usedPercent!;
    if (candidateUsed > bindingUsed ||
        (candidateUsed == bindingUsed &&
            _saferEqualUseWindow(candidate, binding))) {
      binding = candidate;
    }
  }
  return ModelQuota(
    model: model,
    usedPercent: binding.usedPercent,
    resetsAt: binding.resetsAt,
    windowLabel: binding.label,
  );
}

ModelQuota _conservativeCodexModelQuota(
  ModelQuota current,
  ModelQuota candidate,
) {
  final currentUsed = current.usedPercent;
  final candidateUsed = candidate.usedPercent;
  if (currentUsed == null || candidateUsed == null) {
    return ModelQuota(
      model: current.model,
      windowLabel: current.windowLabel == candidate.windowLabel
          ? current.windowLabel
          : null,
      note: 'provider returned conflicting scoped quota rows',
    );
  }
  if (candidateUsed > currentUsed) return candidate;
  if (candidateUsed < currentUsed) return current;
  return (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1)
      ? candidate
      : current;
}

/// The number of rate-limit reset credits Codex reports as available to redeem,
/// or null when the field is absent. Codex exposes these under
/// `rate_limit_reset_credits.available_count`; each one lets the account refresh
/// its rate limit early, out of the normal cycle. Returning null (rather than 0)
/// for an absent field keeps "the provider did not report credits" distinct from
/// "the provider reported zero available".
int? codexResetCredits(Map<String, dynamic>? resp) {
  final credits = resp?['rate_limit_reset_credits'];
  if (credits is! Map) return null;
  // Bounded like every other numeric wire field: reject a fractional or absurd
  // count rather than truncating it or rendering "1000000000 resets available".
  // Real counts are single digits; the ceiling only guards against garbage.
  return boundedIntFromWire(credits['available_count'], min: 0, max: 1000);
}

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

  final legacy = _legacyClaudeUsage(data);
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
/// kind/group/scope pairing, bounded numeric percent, and positive ISO reset.
/// `is_active` is advisory: Claude reports enforced weekly rows as inactive
/// while still displaying them in `/usage`. Unknown kinds remain additive only
/// when they do not carry any canonical quota marker.
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
      final reset = _claudeCanonicalReset(row);
      if (label == null || percent == null || reset == null) {
        return (
          valid: false,
          windows: const [],
          modelQuotas: const [],
        );
      }
      final candidate = QuotaWindow(
        label: label,
        usedPercent: percent,
        resetsAt: reset,
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
      final reset = _claudeCanonicalReset(row);
      if (model == null || percent == null || reset == null) {
        return (
          valid: false,
          windows: const [],
          modelQuotas: const [],
        );
      }
      final candidate = ModelQuota(
        model: model,
        usedPercent: percent,
        resetsAt: reset,
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

bool _tighterWindow(QuotaWindow candidate, QuotaWindow current) {
  final candidateUsed = candidate.usedPercent;
  final currentUsed = current.usedPercent;
  if (candidateUsed == null) return false;
  if (currentUsed == null || candidateUsed > currentUsed) return true;
  if (candidateUsed < currentUsed) return false;
  return (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1);
}

/// Resolves an equal-use tie without depending on provider row order. A later
/// reset is the conservative choice because the same amount of spent quota
/// remains binding for longer. A known reset also wins over an unknown one.
bool _saferEqualUseWindow(QuotaWindow candidate, QuotaWindow current) =>
    (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1);

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

int? _claudeCanonicalReset(Map<dynamic, dynamic> row) {
  return _strictClaudeIsoEpoch(row['resets_at']);
}

String? _claudeScopedModelName(Map<dynamic, dynamic> row) {
  final scope = row['scope'];
  if (scope is! Map) return null;
  final model = scope['model'];
  if (model is! Map) return null;
  final displayName = model['display_name'];
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
}) _legacyClaudeUsage(Map<String, dynamic> data) {
  final out = <QuotaWindow>[];
  for (final spec in const [
    ['five_hour', '5h'],
    ['seven_day', 'weekly'],
  ]) {
    if (!data.containsKey(spec[0])) continue;
    final block = data[spec[0]];
    if (block is! Map) {
      return (valid: false, windows: const [], modelQuotas: const []);
    }
    final util = _strictBoundedPercent(block['utilization']);
    final reset = _legacyClaudeReset(block);
    if (util == null || !reset.valid) {
      return (valid: false, windows: const [], modelQuotas: const []);
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
  if (data.containsKey('seven_day_opus') && data['seven_day_opus'] != null) {
    final block = data['seven_day_opus'];
    if (block is! Map) {
      return (valid: false, windows: const [], modelQuotas: const []);
    }
    final util = _strictBoundedPercent(block['utilization']);
    final reset = _legacyClaudeReset(block);
    if (util == null || !reset.valid) {
      return (valid: false, windows: const [], modelQuotas: const []);
    }
    modelQuotas.add(
      ModelQuota(
        model: 'Opus',
        usedPercent: util,
        resetsAt: reset.value,
        windowLabel: 'weekly',
      ),
    );
  }

  return (
    valid: true,
    windows: out,
    modelQuotas: modelQuotas,
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

int? parseIsoToEpoch(dynamic v) {
  if (v is! String) return null;
  final dt = DateTime.tryParse(v);
  return dt == null ? null : dt.millisecondsSinceEpoch ~/ 1000;
}

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

/// The account's binding Antigravity limit as a single weekly-allowance window.
///
/// The Cloud Code endpoint reports one `quotaInfo` per model: a single
/// `remainingFraction` and `resetTime`, its tightest cap across the plan's
/// weekly allowance and its short-term burst limit, with no field naming which
/// window that is. Earlier this was bucketed by reset delta into 5h/daily/weekly
/// labels, which mislabels a weekly whose reset happens to fall within a few
/// hours (the common case near a refresh) as a "5h" window. Instead, surface the
/// most-constrained model's binding limit as the account's weekly allowance -
/// the cap a subscription user tracks - with its true reset time. The separate
/// burst limit and the per-model-group breakdown that Antigravity's own CLI
/// shows are not exposed by this endpoint; per-model detail is carried by
/// [antigravityModelQuotasFromLive]. A reset beyond
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
/// id and carries `{quotaInfo: {remainingFraction, resetTime}}`.
List<ModelQuota> antigravityModelQuotasFromLive(Map<String, dynamic>? resp) {
  final models = _antigravityLiveQuotaRows(resp);
  if (models == null) return const [];
  return models
      .map(
        (model) => ModelQuota(
          model: model.model,
          usedPercent:
              ((1 - model.remainingFraction) * 100).clamp(0, 100).toDouble(),
          resetsAt: model.resetsAt,
        ),
      )
      .toList();
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
    final remainingFraction = _fraction(quotaInfo['remainingFraction']);
    final resetsAt = parseReset(quotaInfo['resetTime']);
    if (resetsAt == null || resetsAt <= 0) {
      // No rolling window. That is a non-metered helper only when it also shows
      // no consumption (a full or absent fraction, like the tab-completion and
      // chat rows). A row that shows real consumption but carries no reset is an
      // incomplete metered pool; skipping it would drop a possibly-binding window
      // and overstate headroom, so fail the whole table closed instead.
      if (remainingFraction == null || remainingFraction >= 1) continue;
      return null;
    }
    if (remainingFraction == null) return null;
    out.add((
      model: entry.key.toString(),
      remainingFraction: remainingFraction,
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
      if (usedP != null || resetsAt != null) {
        windows.add(
          QuotaWindow(label: label, usedPercent: usedP, resetsAt: resetsAt),
        );
      }
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

double? _boundedPercent(dynamic value) {
  final parsed = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.replaceAll(',', '').trim()),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 100) {
    return null;
  }
  return parsed;
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
    if (usedP != null || resetsAt != null) {
      windows.add(
        QuotaWindow(label: label, usedPercent: usedP, resetsAt: resetsAt),
      );
    }
  }
  return windows;
}

/// Magnitude boundaries for present-day unix timestamps in milliseconds,
/// microseconds, and nanoseconds. Provider and IDE state has used all four
/// units over time, so normalize them before trust admission rather than
/// interpreting a microsecond value as a reset tens of thousands of years out.
const int _resetMillisThreshold = 100000000000;
const int _resetMicrosThreshold = 100000000000000;
const int _resetNanosThreshold = 100000000000000000;

int _normalizeEpochSeconds(int value) {
  final magnitude = value.abs();
  if (magnitude >= _resetNanosThreshold) return value ~/ 1000000000;
  if (magnitude >= _resetMicrosThreshold) return value ~/ 1000000;
  if (magnitude >= _resetMillisThreshold) return value ~/ 1000;
  return value;
}

int? parseReset(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    if (!v.toDouble().isFinite) return null;
    if (v.truncateToDouble() != v.toDouble()) return null;
    return _normalizeEpochSeconds(v.toInt());
  }
  final s = v.toString();
  final asInt = int.tryParse(s);
  if (asInt != null) {
    return _normalizeEpochSeconds(asInt);
  }
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

/// Extracts the unary gRPC-web DATA frame payload from a valid response.
///
/// gRPC-web commonly carries `grpc-status` in a body trailer rather than an
/// HTTP header. A nonzero or malformed trailer invalidates the data frame so an
/// authentication failure cannot be mistaken for successful quota evidence.
List<int> grpcMessage(Uint8List resp) {
  List<int>? message;
  var offset = 0;
  while (offset < resp.length) {
    if (resp.length - offset < 5) return const [];
    final flag = resp[offset];
    final len = (resp[offset + 1] << 24) |
        (resp[offset + 2] << 16) |
        (resp[offset + 3] << 8) |
        resp[offset + 4];
    offset += 5;
    if (len < 0 || len > resp.length - offset) return const [];
    final payload = resp.sublist(offset, offset + len);
    offset += len;

    if ((flag & 0x80) != 0) {
      if (flag != 0x80 || message == null || offset != resp.length) {
        return const [];
      }
      final trailer = ascii.decode(payload, allowInvalid: true);
      final status = RegExp(
        r'(?:^|\r?\n)grpc-status:\s*([0-9]+)\s*(?:\r?\n|$)',
        caseSensitive: false,
      ).firstMatch(trailer);
      if (status == null || status.group(1) != '0') return const [];
      continue;
    }

    // Grok's billing RPC is unary and uncompressed. Multiple data frames or a
    // compression flag are response-shape drift, not quota evidence.
    if (flag != 0 || message != null) return const [];
    message = payload;
  }
  return message ?? const [];
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
  final anchored = _grokConfigWindow(message, now);
  if (anchored.recognized) return anchored.window;
  return _grokScanWindow(message, now);
}

/// Schema-anchored read of the Grok credits config message.
({bool recognized, QuotaWindow? window}) _grokConfigWindow(
  List<int> message,
  int now,
) {
  List<int>? config;
  // The top-level walk's verdict is deliberately ignored: trailing garbage
  // after a well-delimited config must not force the less precise scan
  // fallback. The config body itself is still parsed strictly below.
  _forEachProtoField(message, (field, wireType, varint, bytes) {
    if (field == 1 && wireType == 2) config ??= bytes;
  });
  final body = config;
  if (body == null) return (recognized: false, window: null);
  double? used;
  int? windowEnd;
  var invalidPoolPercent = false;
  final ok = _forEachProtoField(body, (field, wireType, varint, bytes) {
    if (field == 1 && wireType == 5) {
      final f = _float32(bytes);
      // This field is the pool total by schema. An impossible total invalidates
      // the anchored response and must not hand parsing to the schema-less scan,
      // which could mistake a valid-looking product breakdown for the total.
      if (!f.isFinite || f < 0 || f > 100) {
        invalidPoolPercent = true;
      } else {
        used ??= _percent2(f);
      }
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
  if (invalidPoolPercent) return (recognized: true, window: null);
  if (!ok) return (recognized: false, window: null);
  if (used == null) return (recognized: false, window: null);
  return (
    recognized: true,
    window: QuotaWindow(
      label: 'weekly',
      usedPercent: used,
      resetsAt:
          windowEnd ?? (ProtoScan()..walk(message)).nearestFutureTimestamp(now),
    ),
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

/// Plausibility bounds for a unix-seconds varint (2020..2100), so field ids,
/// enums, and sub-second counts are never mistaken for timestamps without
/// imposing a 2033 parser expiry on valid long-lived code.
bool _plausibleEpochSeconds(int v) => v > 1600000000 && v < 4102444800;

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
