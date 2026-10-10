part of '../../parsing.dart';

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
  RequestAdmission requestAdmission,
});

/// Parses one live response atomically. Shared and model-scoped rate limits are
/// one provider observation: accepting the shared pool while silently dropping
/// a malformed named sibling could overstate a model's usable budget.
CodexLiveUsage? codexLiveUsage(Map<String, dynamic>? resp) {
  if (resp == null) return null;
  final shared = _codexLiveRateLimitWindows(resp['rate_limit']);
  if (shared == null) return null;
  final scoped = _codexAdditionalRateLimits(resp);
  if (!scoped.valid) return null;
  final spendReached = _codexSpendControlReached(resp);
  if (spendReached == null) return null;
  final typeDenies = _codexRateLimitReachedTypeDenies(resp);
  if (typeDenies == null) return null;
  // A reached workspace spend cap, or a named rate-limit denial, blocks new
  // requests. Credit amounts and the denial label are not included quota and
  // must not change the measured windows. Scoped rows keep their measured
  // percent and inherit the same denial, so a named pool cannot stay
  // admissible on its own.
  final denyAdmission = spendReached || typeDenies;
  final admission =
      denyAdmission ? RequestAdmission.denied : shared.requestAdmission;
  return (
    windows: shared.windows,
    modelQuotas: denyAdmission
        ? [
            for (final quota in scoped.modelQuotas)
              _codexQuotaWithAdmission(quota, RequestAdmission.denied),
          ]
        : scoped.modelQuotas,
    requestAdmission: admission,
  );
}

ModelQuota _codexQuotaWithAdmission(
  ModelQuota quota,
  RequestAdmission admission,
) =>
    ModelQuota(
      model: quota.model,
      usedPercent: quota.usedPercent,
      resetsAt: quota.resetsAt,
      windowLabel: quota.windowLabel,
      category: quota.category,
      note: quota.note,
      requestAdmission: admission,
    );

/// `true` when `spend_control.reached` blocks the account, `false` when that
/// cap is absent or explicitly open, and null when the flag is unreadable.
bool? _codexSpendControlReached(Map<String, dynamic> resp) {
  if (!resp.containsKey('spend_control') || resp['spend_control'] == null) {
    return false;
  }
  final spend = resp['spend_control'];
  if (spend is! Map) return null;
  if (!spend.containsKey('reached') || spend['reached'] == null) return false;
  final reached = spend['reached'];
  if (reached is! bool) return null;
  return reached;
}

const _codexRateLimitDenialTypes = {
  'rate_limit_reached',
  'workspace_owner_credits_depleted',
  'workspace_member_credits_depleted',
  'workspace_owner_usage_limit_reached',
  'workspace_member_usage_limit_reached',
};

/// `true` when `rate_limit_reached_type.type` names a denial, `false` when
/// that object is absent or its type is `unknown`, and null when the object
/// cannot be read. Open windows do not outvote a named denial. The type is an
/// admission reason, not a usage percent.
bool? _codexRateLimitReachedTypeDenies(Map<String, dynamic> resp) {
  if (!resp.containsKey('rate_limit_reached_type') ||
      resp['rate_limit_reached_type'] == null) {
    return false;
  }
  final raw = resp['rate_limit_reached_type'];
  if (raw is! Map) return null;
  if (!raw.containsKey('type') || raw['type'] == null) return null;
  final type = raw['type'];
  if (type is! String || type != type.trim() || type.isEmpty) return null;
  if (type == 'unknown') return false;
  if (_codexRateLimitDenialTypes.contains(type)) return true;
  return null;
}

List<QuotaWindow> codexUsageWindows(Map<String, dynamic>? resp) =>
    codexLiveUsage(resp)?.windows ?? const [];

({List<QuotaWindow> windows, RequestAdmission requestAdmission})?
    _codexLiveRateLimitWindows(
  dynamic raw,
) {
  if (raw is! Map) return null;
  if (_codexHasUnknownQuotaWindow(raw)) {
    return null;
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
      return null;
    }
    final pct = _codexLivePercent(window['used_percent']);
    final reset = parseReset(window['reset_at']);
    final seconds = _codexLiveWindowSeconds(window['limit_window_seconds']);
    if (pct == null || reset == null || reset <= 0 || seconds == null) {
      return null;
    }
    out.add(
      QuotaWindow(
        label: codexLabel(seconds ~/ 60, '${seconds ~/ 60}m'),
        usedPercent: pct,
        resetsAt: reset,
      ),
    );
  }
  final admission = _codexLiveRequestAdmission(raw);
  if (out.isEmpty || admission == null) {
    return null;
  }
  return (windows: out, requestAdmission: admission);
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

RequestAdmission? _codexLiveRequestAdmission(Map<dynamic, dynamic> raw) {
  bool? allowed;
  bool? limitReached;
  if (raw.containsKey('allowed')) {
    final value = raw['allowed'];
    if (value is! bool) return null;
    allowed = value;
  }
  if (raw.containsKey('limit_reached')) {
    final value = raw['limit_reached'];
    if (value is! bool) return null;
    limitReached = value;
  }
  // Admission flags say whether ChatGPT will take a new request. They are not
  // a second encoding of used_percent. Plus currently reports a rounded 100%
  // weekly window with allowed: true. Preserve a valid negative separately
  // from these measurements; only contradictory or malformed flags reject the
  // atomic observation.
  if (allowed != null && limitReached != null && allowed == limitReached) {
    return null;
  }
  if (allowed == false || limitReached == true) return RequestAdmission.denied;
  if (allowed == true || limitReached == false) return RequestAdmission.allowed;
  return RequestAdmission.notReported;
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
    if (parsed == null) return (valid: false, modelQuotas: const []);
    final candidate =
        _codexBindingModelQuota(model, parsed.windows, parsed.requestAdmission);
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
  RequestAdmission admission,
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
    requestAdmission: admission,
  );
}

ModelQuota _conservativeCodexModelQuota(
  ModelQuota current,
  ModelQuota candidate,
) {
  final currentUsed = current.usedPercent;
  final candidateUsed = candidate.usedPercent;
  final admission =
      current.requestAdmission.combine(candidate.requestAdmission);
  if (currentUsed == null || candidateUsed == null) {
    return ModelQuota(
      model: current.model,
      windowLabel: current.windowLabel == candidate.windowLabel
          ? current.windowLabel
          : null,
      note: 'provider returned conflicting scoped quota rows',
      requestAdmission: admission,
    );
  }
  final binding = candidateUsed > currentUsed ||
          (candidateUsed == currentUsed &&
              (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1))
      ? candidate
      : current;
  return ModelQuota(
    model: binding.model,
    usedPercent: binding.usedPercent,
    resetsAt: binding.resetsAt,
    windowLabel: binding.windowLabel,
    requestAdmission: admission,
  );
}

/// The number of banked resets Codex reports as available to redeem,
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
