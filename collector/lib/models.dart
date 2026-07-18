/// Normalized quota model shared by every provider adapter and the UI.
library;

import 'provider_source.dart';

export 'provider_source.dart';

/// Conservative defaults for use-it-or-lose-it quota signals. These defaults
/// are shared by provider routing and concrete-model routing so both surfaces
/// agree on what counts as meaningful projected waste.
const double kDefaultExpiringQuotaWasteThreshold = 35.0;
const int kDefaultExpiringQuotaMaxHours = 24;

/// Remaining headroom at or below this percent is treated as spent.
///
/// Provider quota APIs and user-facing surfaces round differently near zero.
/// Keeping a 1.5 percent buffer avoids routing to a sliver that still renders as
/// "1% free" after whole-percent display rounding and may already be rejected.
const double kSpentHeadroomFloor = 1.5;

/// A finite double from a JSON-decoded number, or null. `jsonEncode` throws on
/// NaN and infinities, and the routing and analytics math assume finite input,
/// so a non-finite value read back from a corrupt or hostile cache/history file
/// is dropped here at the boundary rather than propagated into a later crash.
double? finiteOrNull(Object? v) =>
    v is num && v.toDouble().isFinite ? v.toDouble() : null;

/// A single rolling limit window for a provider (e.g. a 5-hour or weekly cap).
class QuotaWindow {
  /// Short human label, e.g. "5h", "weekly", "daily".
  final String label;

  /// Percent of the window consumed, 0..100. Null if the provider exposes
  /// absolute counts but no percent (then [used]/[limit] are set instead).
  final double? usedPercent;

  /// Absolute used count, when the provider reports raw units instead of %.
  final num? used;

  /// Absolute limit, paired with [used].
  final num? limit;

  /// Unix epoch seconds when this window resets. Null if unknown.
  final int? resetsAt;

  QuotaWindow({
    required this.label,
    this.usedPercent,
    this.used,
    this.limit,
    this.resetsAt,
  });

  /// Best-effort percent used, deriving from used/limit when needed.
  ///
  /// Intentionally NOT clamped: the trust boundary
  /// ([unusableQuotaEvidenceDriftReason]) and `quotabot verify` rely on seeing a
  /// raw out-of-range value (a negative percent, or `used > limit` giving
  /// >100%) so they can reject or flag the read as drift rather than route on it.
  /// Clamping here would hide that from those checks. Display-time consumers
  /// clamp separately (see `windowUsedPercent`).
  double? get percent {
    if (usedPercent != null) return usedPercent;
    if (used != null && limit != null && limit! > 0) {
      return (used! / limit!) * 100.0;
    }
    return null;
  }

  /// True when the window is effectively exhausted.
  bool get exhausted => (percent ?? 0) >= 100 - kSpentHeadroomFloor;

  Map<String, dynamic> toJson() => {
        'label': label,
        if (usedPercent != null) 'used_percent': usedPercent,
        if (used != null) 'used': used,
        if (limit != null) 'limit': limit,
        if (resetsAt != null) 'resets_at': resetsAt,
      };

  factory QuotaWindow.fromJson(Map<String, dynamic> j) => QuotaWindow(
        label: j['label'] as String,
        // Percents bound to 0..100; counts kept as-is but finite; a non-finite
        // reset is dropped rather than thrown through `as int`.
        usedPercent: finiteOrNull(j['used_percent'])?.clamp(0, 100).toDouble(),
        used: finiteOrNull(j['used']),
        limit: finiteOrNull(j['limit']),
        resetsAt: finiteOrNull(j['resets_at'])?.toInt(),
      );
}

/// Live per-model quota for a provider that meters each model family from its
/// own pool rather than one shared window (Antigravity: every Gemini/Claude/
/// GPT-OSS family has its own remaining headroom and reset). Captured richly for
/// routing and detail views; the compact window summary stays the headline, so
/// this never bloats the default display.
class ModelQuota {
  /// Model name as the provider labels it, e.g. "Gemini 3.5 Flash". Effort or
  /// mode variants that share a pool are rolled up to this base name.
  final String model;

  /// Percent of this model's pool consumed, 0..100. Null when unknown.
  final double? usedPercent;

  /// Unix epoch seconds when this model's pool resets. Null when unknown.
  final int? resetsAt;

  /// Provider speed/category label, e.g. "Fast". Null when not exposed.
  final String? category;

  /// Short provider badge, e.g. "Limited time". Null when not exposed.
  final String? note;

  const ModelQuota({
    required this.model,
    this.usedPercent,
    this.resetsAt,
    this.category,
    this.note,
  });

  /// Remaining headroom percent (100 - used), 0..100. Null when unknown.
  double? get remainingPercent {
    final u = usedPercent;
    return u == null ? null : (100 - u).clamp(0, 100).toDouble();
  }

  /// True when this model's pool is effectively spent.
  bool get exhausted => (usedPercent ?? 0) >= 100 - kSpentHeadroomFloor;

  Map<String, dynamic> toJson() => {
        'model': model,
        if (usedPercent != null) 'used_percent': usedPercent,
        if (resetsAt != null) 'resets_at': resetsAt,
        if (category != null) 'category': category,
        if (note != null) 'note': note,
      };

  factory ModelQuota.fromJson(Map<String, dynamic> j) => ModelQuota(
        model: j['model'] as String,
        usedPercent: finiteOrNull(j['used_percent'])?.clamp(0, 100).toDouble(),
        resetsAt: finiteOrNull(j['resets_at'])?.toInt(),
        category: j['category'] as String?,
        note: j['note'] as String?,
      );
}

/// One provider account's quota snapshot.
const providerQuotaSubscriptionKind = 'subscription';
const providerQuotaLocalKind = 'local';
const providerPipeHealthHealthy = 'healthy';
const providerPipeHealthThrottled = 'throttled';
const providerPipeHealthDegraded = 'degraded';
const providerPipeHealthNoData = 'no_data';
const providerPipeThrottlePenaltyPercent = 60.0;
const providerPipeDegradedPenaltyPercent = 30.0;
const providerPipeRetryAfterPenaltyMaxPercent = 20.0;
const providerPipeRoutingPenaltyMaxPercent = 80.0;
const providerPipeHealthValues = [
  providerPipeHealthHealthy,
  providerPipeHealthThrottled,
  providerPipeHealthDegraded,
  providerPipeHealthNoData,
];

String? providerPipeHealthFromWire(Object? value) =>
    value is String && providerPipeHealthValues.contains(value) ? value : null;

String? providerPipeHealthForHttpStatus(int statusCode) {
  if (statusCode == 429) return providerPipeHealthThrottled;
  if (statusCode >= 500 && statusCode <= 599) return providerPipeHealthDegraded;
  return null;
}

double providerPipeRetryAfterPenaltyPercent(int? retryAfterSeconds) =>
    retryAfterSeconds == null
        ? 0.0
        : (retryAfterSeconds / 60.0)
            .clamp(0.0, providerPipeRetryAfterPenaltyMaxPercent)
            .toDouble();

double providerPipeHealthRoutingPenaltyPercent(
  String? pipeHealth, {
  int? retryAfterSeconds,
}) {
  final basePenalty = switch (pipeHealth) {
    providerPipeHealthThrottled => providerPipeThrottlePenaltyPercent,
    providerPipeHealthDegraded => providerPipeDegradedPenaltyPercent,
    _ => 0.0,
  };
  if (basePenalty <= 0) return 0.0;
  return (basePenalty + providerPipeRetryAfterPenaltyPercent(retryAfterSeconds))
      .clamp(0.0, providerPipeRoutingPenaltyMaxPercent)
      .toDouble();
}

int? boundedIntFromWire(Object? value, {required int min, int? max}) {
  final number = finiteOrNull(value);
  if (number == null || number.truncateToDouble() != number) return null;
  final parsed = number.toInt();
  if (parsed < min || (max != null && parsed > max)) return null;
  return parsed;
}

enum ProviderQuotaKind {
  subscription(providerQuotaSubscriptionKind),
  local(providerQuotaLocalKind);

  const ProviderQuotaKind(this.wireName);

  final String wireName;

  bool get isLocal => this == ProviderQuotaKind.local;

  static ProviderQuotaKind fromWire(String? value) => switch (value) {
        null || providerQuotaSubscriptionKind => ProviderQuotaKind.subscription,
        providerQuotaLocalKind => ProviderQuotaKind.local,
        _ => throw FormatException('unknown provider quota kind: $value'),
      };
}

/// Passive memory capacity observed on the machine hosting a local runtime.
///
/// These values come from operating-system memory metadata and, when present,
/// the local NVIDIA driver utility. They are not a benchmark, allocation, model
/// load, or inference request. GPU values describe the largest single observed
/// GPU so fit estimates never assume that memory from separate devices can be
/// combined.
class LocalHardwareInfo {
  /// Unix epoch seconds when the capacity metadata was captured.
  final int asOf;

  /// Total physical system memory in bytes, when available.
  final int? systemMemoryTotalBytes;

  /// Physical system memory currently available in bytes, when available.
  final int? systemMemoryAvailableBytes;

  /// Total memory on the largest observed GPU in bytes, when available.
  final int? gpuMemoryTotalBytes;

  /// Currently free memory on that same GPU in bytes, when available.
  final int? gpuMemoryAvailableBytes;

  /// Number of GPUs represented by the driver metadata.
  final int gpuCount;

  const LocalHardwareInfo({
    required this.asOf,
    this.systemMemoryTotalBytes,
    this.systemMemoryAvailableBytes,
    this.gpuMemoryTotalBytes,
    this.gpuMemoryAvailableBytes,
    this.gpuCount = 0,
  });

  bool get hasMemoryEvidence =>
      systemMemoryTotalBytes != null || gpuMemoryTotalBytes != null;

  Map<String, dynamic> toJson() => {
        'as_of': asOf,
        if (systemMemoryTotalBytes != null)
          'system_memory_total_bytes': systemMemoryTotalBytes,
        if (systemMemoryAvailableBytes != null)
          'system_memory_available_bytes': systemMemoryAvailableBytes,
        if (gpuMemoryTotalBytes != null)
          'gpu_memory_total_bytes': gpuMemoryTotalBytes,
        if (gpuMemoryAvailableBytes != null)
          'gpu_memory_available_bytes': gpuMemoryAvailableBytes,
        if (gpuCount > 0) 'gpu_count': gpuCount,
      };

  factory LocalHardwareInfo.fromJson(Map<String, dynamic> json) {
    // 16 PiB is deliberately far above current workstation capacity while
    // bounding corrupt or hostile local snapshot values.
    const maxMemoryBytes = 16 * 1024 * 1024 * 1024 * 1024 * 1024;
    final systemTotal = boundedIntFromWire(
      json['system_memory_total_bytes'],
      min: 1,
      max: maxMemoryBytes,
    );
    final systemAvailable = systemTotal == null
        ? null
        : boundedIntFromWire(
            json['system_memory_available_bytes'],
            min: 0,
            max: systemTotal,
          );
    final gpuTotal = boundedIntFromWire(
      json['gpu_memory_total_bytes'],
      min: 1,
      max: maxMemoryBytes,
    );
    final gpuAvailable = gpuTotal == null
        ? null
        : boundedIntFromWire(
            json['gpu_memory_available_bytes'],
            min: 0,
            max: gpuTotal,
          );
    return LocalHardwareInfo(
      asOf: boundedIntFromWire(json['as_of'], min: 0) ?? 0,
      systemMemoryTotalBytes: systemTotal,
      systemMemoryAvailableBytes: systemAvailable,
      gpuMemoryTotalBytes: gpuTotal,
      gpuMemoryAvailableBytes: gpuAvailable,
      gpuCount: gpuTotal == null
          ? 0
          : boundedIntFromWire(json['gpu_count'], min: 0, max: 64) ?? 0,
    );
  }
}

class ProviderQuota {
  /// Stable provider id: "codex", "claude", "grok", "antigravity".
  final String provider;

  /// Human display name, e.g. "Codex", "Claude".
  final String displayName;

  /// Account identifier (email, plan, or "default").
  final String account;

  /// Plan/tier string when known, e.g. "pro", "max".
  final String? plan;

  /// Data source hint. Null means a built-in adapter or local runtime produced
  /// the snapshot; [providerQuotaManualSource] means the user entered the quota
  /// themselves.
  final String? source;

  /// Normalized provenance class describing what this observation proves.
  /// Unlike [source], this is present for every current producer and survives
  /// routing, caching, and verification as a machine-readable trust boundary.
  final ProviderSourceClass sourceClass;

  /// Provider class. [ProviderQuotaKind.subscription] is a metered paid/free
  /// account whose headroom governs routing. [ProviderQuotaKind.local] is an
  /// always-available local runtime used as fallback capacity and never counted
  /// as the "most headroom" winner.
  final ProviderQuotaKind kind;

  /// Short status line for providers that have no quota windows, such as a
  /// local runtime ("qwen3-coder loaded" / "5 models, idle"). Null otherwise.
  final String? status;

  /// True when a local runtime currently has a model loaded in memory (a proxy
  /// for being in use). Always false for metered subscriptions.
  final bool active;

  /// Extra human-readable detail lines for providers without quota windows
  /// (e.g. a local runtime's loaded model size, quantization, and disk usage).
  final List<String> details;

  /// The models this provider exposes, when known. Local runtimes fill this live
  /// from their own model list; cloud providers are populated from the catalog by
  /// the registry. Empty when the model set is unknown.
  final List<ModelInfo> models;

  /// Passive capacity metadata for the machine hosting a local runtime. Null
  /// for subscriptions and when the operating system exposes no usable value.
  final LocalHardwareInfo? localHardware;

  /// Live per-model quota, for providers that meter each model family from its
  /// own pool (Antigravity). Empty for providers with a single shared window;
  /// the [windows] summary stays the headline and this is detail on demand.
  final List<ModelQuota> modelQuotas;

  /// True when data was read successfully.
  final bool ok;

  /// Error detail when [ok] is false.
  final String? error;

  /// Rolling windows for this provider.
  final List<QuotaWindow> windows;

  /// Unix epoch seconds when this snapshot was taken/last known good.
  final int asOf;

  /// True when [asOf] is older data served from cache (e.g. logged-out account).
  final bool stale;

  /// A non-fatal plausibility concern raised by the drift canary when this read
  /// is implausible versus the last one (e.g. a window's reset moved earlier, or
  /// usage fell with no reset for a provider that only consumes). Null when the
  /// read looks consistent. The reading is still shown; this only annotates it,
  /// so a silently drifted provider is flagged rather than trusted blindly.
  final String? suspect;

  /// Why a fresh provider observation was rejected by the drift canary. The
  /// quota windows in this object remain the prior trusted snapshot and are
  /// marked [stale]; the rejected values are never stored here.
  final String? driftReason;

  /// Unix epoch seconds when [driftReason] was observed. This is deliberately
  /// separate from [asOf], which remains the capture time of the trusted quota
  /// windows being shown.
  final int? driftObservedAt;

  /// True when this reading reflects only this machine's local usage rather than
  /// the account's usage across every device. Providers read from local IDE
  /// state (Cursor, Windsurf, Kiro) or a per-machine session log can undercount
  /// when the same account is used on a phone or another computer; authoritative
  /// server-side reads (Claude, Grok, Antigravity, Codex live) leave this false.
  final bool perMachine;

  /// Native adapter pipe-health classification when a metadata read reached the
  /// provider but could not return quota. This distinguishes throttling or
  /// provider-side degradation from generic no-data without exposing response
  /// bodies or secrets.
  final String? pipeHealth;

  /// Sanitized HTTP status from the metadata endpoint, when available.
  final int? httpStatus;

  /// Sanitized Retry-After delay in seconds from the metadata endpoint, when
  /// available and parseable.
  final int? retryAfterSeconds;

  /// Count of redeemable off-cycle resets the provider reports as available now
  /// (for example Codex's rate-limit reset credits). Zero when none are offered
  /// or the provider does not expose them. This is a live, fresh-read signal, so
  /// it is deliberately not asserted from stale, drifted, or degraded snapshots.
  final int resetCreditsAvailable;

  ProviderQuota({
    required this.provider,
    required this.displayName,
    required this.account,
    required this.asOf,
    this.plan,
    this.source,
    this.ok = true,
    this.error,
    this.windows = const [],
    this.stale = false,
    this.kind = ProviderQuotaKind.subscription,
    this.status,
    this.active = false,
    this.details = const [],
    this.models = const [],
    this.localHardware,
    this.modelQuotas = const [],
    this.suspect,
    this.driftReason,
    this.driftObservedAt,
    this.perMachine = false,
    this.pipeHealth,
    this.httpStatus,
    this.retryAfterSeconds,
    this.resetCreditsAvailable = 0,
    ProviderSourceClass? sourceClass,
  }) : sourceClass = sourceClass ??
            inferProviderSourceClass(
              provider: provider,
              source: source,
              isLocal: kind.isLocal,
              perMachine: perMachine,
            );

  /// True when this is a local, always-available runtime rather than a metered
  /// remote subscription.
  bool get isLocal => kind.isLocal;

  /// True when this is a self-reported manual quota entry, not measured data.
  bool get isManual => source == providerQuotaManualSource;

  /// A plain reason when provenance contradicts the observation shape.
  ///
  /// This check is independent of the provider registry so routing, cache, and
  /// analytics can fail closed even when they do not load adapter code.
  String? get sourceClassViolation {
    if (localHardware != null && !isLocal) {
      return 'local hardware evidence requires kind=local';
    }
    final classifiedManual = sourceClass == ProviderSourceClass.manual;
    if (isManual != classifiedManual) {
      return classifiedManual
          ? 'manual source class requires source=manual'
          : 'source=manual requires the manual source class';
    }
    final allowed = builtInProviderSourceClasses(provider);
    if (!classifiedManual &&
        allowed != null &&
        !allowed.contains(sourceClass)) {
      return '${sourceClass.label} is not admitted for $provider';
    }
    switch (sourceClass) {
      case ProviderSourceClass.authoritativeLive:
        if (isLocal) return 'authoritative live evidence cannot be local';
        if (perMachine) {
          return 'authoritative live evidence cannot be machine-scoped';
        }
      case ProviderSourceClass.thisMachineFallback:
        if (isLocal) return 'this-machine fallback cannot be a local runtime';
        if (ok && hasWindows && !perMachine) {
          return 'this-machine fallback quota must be machine-scoped';
        }
      case ProviderSourceClass.passiveLocalEvidence:
        if (isLocal) return 'passive local evidence cannot be a local runtime';
        if (ok && hasWindows && !perMachine) {
          return 'passive local quota must be machine-scoped';
        }
      case ProviderSourceClass.localRuntime:
        if (!isLocal) return 'local runtime evidence requires kind=local';
        if (hasWindows) return 'local runtime evidence cannot carry quota';
        if (driftReason != null) {
          return 'local runtime evidence cannot carry provider drift';
        }
      case ProviderSourceClass.statusOnly:
        if (isLocal) return 'status-only evidence cannot be a local runtime';
        if (hasWindows) return 'status-only evidence cannot carry quota';
        if (driftReason != null) {
          return 'status-only evidence cannot carry provider drift';
        }
      case ProviderSourceClass.manual:
        if (isLocal) return 'manual quota cannot be a local runtime';
        if (perMachine) return 'manual quota cannot claim machine scope';
        if (driftReason != null) {
          return 'manual quota cannot carry provider drift';
        }
    }
    return null;
  }

  factory ProviderQuota.error(
    String provider,
    String displayName,
    String error,
    int asOf, {
    String account = 'unknown',
    String? plan,
    String? pipeHealth,
    int? httpStatus,
    int? retryAfterSeconds,
  }) =>
      ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: account,
        plan: plan,
        asOf: asOf,
        ok: false,
        error: error,
        pipeHealth: pipeHealth,
        httpStatus: httpStatus,
        retryAfterSeconds: retryAfterSeconds,
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'display_name': displayName,
        'account': account,
        if (plan != null) 'plan': plan,
        if (source != null) 'source': source,
        'source_class': sourceClass.wireName,
        'kind': kind.wireName,
        if (status != null) 'status': status,
        if (active) 'active': active,
        if (details.isNotEmpty) 'details': details,
        'ok': ok,
        if (error != null) 'error': error,
        'as_of': asOf,
        'stale': stale,
        if (suspect != null) 'suspect': suspect,
        if (driftReason != null) 'drift_reason': driftReason,
        if (driftObservedAt != null) 'drift_observed_at': driftObservedAt,
        if (perMachine) 'per_machine': true,
        if (pipeHealth != null) 'pipe_health': pipeHealth,
        if (httpStatus != null) 'http_status': httpStatus,
        if (retryAfterSeconds != null) 'retry_after_seconds': retryAfterSeconds,
        if (resetCreditsAvailable > 0)
          'reset_credits_available': resetCreditsAvailable,
        'windows': windows.map((w) => w.toJson()).toList(),
        if (models.isNotEmpty) 'models': models.map((m) => m.toJson()).toList(),
        if (localHardware != null) 'local_hardware': localHardware!.toJson(),
        if (modelQuotas.isNotEmpty)
          'model_quotas': modelQuotas.map((m) => m.toJson()).toList(),
      };

  factory ProviderQuota.fromJson(Map<String, dynamic> j) => ProviderQuota(
        provider: j['provider'] as String,
        displayName: j['display_name'] as String,
        account: j['account'] as String,
        plan: j['plan'] as String?,
        source: j['source'] as String?,
        sourceClass: _providerSourceClassFromJson(j),
        ok: j['ok'] as bool? ?? true,
        error: j['error'] as String?,
        asOf: j['as_of'] as int? ?? 0,
        stale: j['stale'] as bool? ?? false,
        kind: ProviderQuotaKind.fromWire(j['kind'] as String?),
        status: j['status'] as String?,
        active: j['active'] as bool? ?? false,
        suspect: j['suspect'] as String?,
        driftReason: j['drift_reason'] as String?,
        driftObservedAt: boundedIntFromWire(j['drift_observed_at'], min: 0),
        perMachine: j['per_machine'] as bool? ?? false,
        pipeHealth: providerPipeHealthFromWire(j['pipe_health']),
        httpStatus: boundedIntFromWire(j['http_status'], min: 100, max: 599),
        retryAfterSeconds: boundedIntFromWire(j['retry_after_seconds'], min: 0),
        resetCreditsAvailable: boundedIntFromWire(j['reset_credits_available'],
                min: 0, max: 1000) ??
            0,
        details: ((j['details'] as List?) ?? const []).cast<String>(),
        windows: ((j['windows'] as List?) ?? const [])
            .map((w) => QuotaWindow.fromJson(w as Map<String, dynamic>))
            .toList(),
        models: ((j['models'] as List?) ?? const [])
            .map((m) => ModelInfo.fromJson(m as Map<String, dynamic>))
            .toList(),
        localHardware: j['local_hardware'] is Map
            ? LocalHardwareInfo.fromJson(
                (j['local_hardware'] as Map).cast<String, dynamic>(),
              )
            : null,
        modelQuotas: ((j['model_quotas'] as List?) ?? const [])
            .map((m) => ModelQuota.fromJson(m as Map<String, dynamic>))
            .toList(),
      );

  /// Returns a copy marked stale, preserving the original capture time.
  /// If [metadataFrom] is supplied, current identity/status labels are used
  /// while the cached quota windows remain intact.
  ProviderQuota asStale(String note, {ProviderQuota? metadataFrom}) =>
      ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: _staleMetadataAccount(metadataFrom, account),
        plan: metadataFrom?.plan ?? plan,
        source: metadataFrom?.source ?? source,
        sourceClass: sourceClass,
        ok: true,
        error: note,
        asOf: asOf,
        stale: true,
        kind: kind,
        status: metadataFrom?.status ?? status,
        active: metadataFrom?.active ?? active,
        details: metadataFrom != null && metadataFrom.details.isNotEmpty
            ? metadataFrom.details
            : details,
        windows: windows,
        models: metadataFrom != null && metadataFrom.models.isNotEmpty
            ? metadataFrom.models
            : models,
        localHardware: metadataFrom?.localHardware ?? localHardware,
        // Per-model budget is quota evidence, not presentation metadata. A
        // failed or windowless fresh read must never graft untrusted pools onto
        // otherwise trusted cached windows.
        modelQuotas: modelQuotas,
        // The concern belongs to these cached windows, so it rides along when
        // they are served stale, regardless of fresh metadata.
        suspect: suspect,
        driftReason: driftReason,
        driftObservedAt: driftObservedAt,
        perMachine: perMachine,
        pipeHealth: metadataFrom?.pipeHealth ?? pipeHealth,
        httpStatus: metadataFrom?.httpStatus ?? httpStatus,
        retryAfterSeconds: metadataFrom?.retryAfterSeconds ?? retryAfterSeconds,
      );

  /// Returns a copy annotated with a drift/plausibility [reason], leaving the
  /// reading itself intact so it is shown, not hidden.
  ProviderQuota withSuspect(String reason) => ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: account,
        asOf: asOf,
        plan: plan,
        source: source,
        sourceClass: sourceClass,
        ok: ok,
        error: error,
        windows: windows,
        stale: stale,
        kind: kind,
        status: status,
        active: active,
        details: details,
        models: models,
        localHardware: localHardware,
        modelQuotas: modelQuotas,
        suspect: reason,
        driftReason: driftReason,
        driftObservedAt: driftObservedAt,
        perMachine: perMachine,
        pipeHealth: pipeHealth,
        httpStatus: httpStatus,
        retryAfterSeconds: retryAfterSeconds,
      );

  /// Returns the trusted quota evidence marked stale after a rejected fresh
  /// observation. [asOf] and all quota windows stay unchanged; only the
  /// additive drift diagnostic and stale explanation are attached.
  ProviderQuota withProviderDrift(String reason, int observedAt) =>
      ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: account,
        asOf: asOf,
        plan: plan,
        source: source,
        sourceClass: sourceClass,
        ok: true,
        error: 'provider drift detected; showing last trusted snapshot',
        windows: windows,
        stale: true,
        kind: kind,
        status: status,
        active: active,
        details: details,
        models: models,
        localHardware: localHardware,
        modelQuotas: modelQuotas,
        driftReason: reason,
        driftObservedAt: observedAt,
        perMachine: perMachine,
        pipeHealth: pipeHealth,
        httpStatus: httpStatus,
        retryAfterSeconds: retryAfterSeconds,
      );

  /// Returns a fail-closed provider-drift result when an upgraded cache contains
  /// only legacy suspect evidence and therefore has no last-known-good windows
  /// that can be shown safely. Identity and current adapter diagnostics remain
  /// visible, but quota/model data is deliberately removed until every retained
  /// reset advances or an evidence-class transition establishes a trustworthy
  /// baseline.
  ProviderQuota asProviderDriftQuarantine(
    String reason,
    int observedAt, {
    ProviderQuota? metadataFrom,
  }) =>
      ProviderQuota(
        provider: provider,
        displayName: metadataFrom?.displayName ?? displayName,
        account: _staleMetadataAccount(metadataFrom, account),
        asOf: metadataFrom != null && metadataFrom.asOf > 0
            ? metadataFrom.asOf
            : asOf,
        plan: metadataFrom?.plan ?? plan,
        source: metadataFrom?.source ?? source,
        sourceClass: sourceClass,
        ok: false,
        error: 'provider drift detected; legacy quota evidence is quarantined '
            'because no trusted snapshot is available',
        stale: true,
        kind: kind,
        status: metadataFrom?.status ?? status,
        localHardware: metadataFrom?.localHardware ?? localHardware,
        driftReason: reason,
        driftObservedAt: observedAt,
        perMachine: perMachine,
        pipeHealth: metadataFrom?.pipeHealth ?? pipeHealth,
        httpStatus: metadataFrom?.httpStatus ?? httpStatus,
        retryAfterSeconds: metadataFrom?.retryAfterSeconds ?? retryAfterSeconds,
      );

  /// Returns a local-runtime copy carrying a fresh passive hardware snapshot.
  /// [detail] is an optional already-formatted display line for human surfaces.
  ProviderQuota withLocalHardware(
    LocalHardwareInfo hardware, {
    String? detail,
  }) =>
      ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: account,
        asOf: asOf,
        plan: plan,
        source: source,
        sourceClass: sourceClass,
        ok: ok,
        error: error,
        windows: windows,
        stale: stale,
        kind: kind,
        status: status,
        active: active,
        details: detail == null ? details : [...details, detail],
        models: models,
        localHardware: hardware,
        modelQuotas: modelQuotas,
        suspect: suspect,
        driftReason: driftReason,
        driftObservedAt: driftObservedAt,
        perMachine: perMachine,
        pipeHealth: pipeHealth,
        httpStatus: httpStatus,
        retryAfterSeconds: retryAfterSeconds,
        resetCreditsAvailable: resetCreditsAvailable,
      );

  /// True when this snapshot carries usable quota windows.
  bool get hasWindows => windows.isNotEmpty;
}

ProviderSourceClass _providerSourceClassFromJson(Map<String, dynamic> json) {
  if (json.containsKey('source_class')) {
    return ProviderSourceClass.fromWire(json['source_class'] as String?);
  }
  final provider = json['provider'] as String;
  final source = json['source'] as String?;
  if (source != providerQuotaManualSource &&
      builtInProviderSourceClasses(provider) == null) {
    throw FormatException(
      'legacy provider source class is required for unregistered provider: '
      '$provider',
    );
  }
  final kind = ProviderQuotaKind.fromWire(json['kind'] as String?);
  return inferProviderSourceClass(
    provider: provider,
    source: source,
    isLocal: kind.isLocal,
    perMachine: json['per_machine'] as bool? ?? false,
  );
}

String _staleMetadataAccount(
    ProviderQuota? metadataFrom, String cachedAccount) {
  final fresh = metadataFrom?.account;
  if (fresh == null || fresh == 'unknown') return cachedAccount;
  return fresh;
}

/// Strips terminal control bytes (C0 controls, DEL, and C1 controls) from
/// provider-sourced text, so a malicious provider response or rogue local
/// runtime can never inject escape sequences into an interactive terminal
/// (screen rewrites, hidden text, OSC 52 clipboard writes). Printable text
/// and non-control Unicode pass through unchanged.
String stripTerminalControl(String s) {
  bool isControl(int c) => c <= 0x1F || (c >= 0x7F && c <= 0x9F);
  if (!s.codeUnits.any(isControl)) return s;
  final b = StringBuffer();
  for (final c in s.runes) {
    if (!isControl(c)) b.writeCharCode(c);
  }
  return b.toString();
}

/// Returns a copy of [q] with every provider-sourced text field cleared of
/// terminal control bytes. Applied once where snapshots are collected, so no
/// adapter, cache, or runtime string can smuggle escape sequences to any
/// display surface.
ProviderQuota sanitizeProviderQuota(ProviderQuota q) {
  final t = stripTerminalControl;
  return ProviderQuota(
    provider: t(q.provider),
    displayName: t(q.displayName),
    account: t(q.account),
    plan: q.plan == null ? null : t(q.plan!),
    source: q.source == null ? null : t(q.source!),
    sourceClass: q.sourceClass,
    ok: q.ok,
    error: q.error == null ? null : t(q.error!),
    asOf: q.asOf,
    stale: q.stale,
    kind: q.kind,
    status: q.status == null ? null : t(q.status!),
    active: q.active,
    details: [for (final d in q.details) t(d)],
    windows: [
      for (final w in q.windows)
        QuotaWindow(
          label: t(w.label),
          usedPercent: w.usedPercent,
          used: w.used,
          limit: w.limit,
          resetsAt: w.resetsAt,
        ),
    ],
    models: [
      for (final m in q.models)
        ModelInfo(
          id: t(m.id),
          displayName: m.displayName == null ? null : t(m.displayName!),
          contextTokens: m.contextTokens,
          maxOutputTokens: m.maxOutputTokens,
          tools: m.tools,
          vision: m.vision,
          reasoning: m.reasoning == null ? null : t(m.reasoning!),
          tier: m.tier == null ? null : t(m.tier!),
          quotaIncludedUntil: m.quotaIncludedUntil,
          local: m.local,
          loaded: m.loaded,
          sizeBytes: m.sizeBytes,
          vramBytes: m.vramBytes,
          quant: m.quant == null ? null : t(m.quant!),
          // Must be carried: sanitize runs on every collected snapshot, and
          // dropping this would reset a cloud-offloaded model to on-device,
          // letting a billable `-cloud` model satisfy --budget=local and free.
          cloudOffloaded: m.cloudOffloaded,
        ),
    ],
    localHardware: q.localHardware,
    modelQuotas: [
      for (final m in q.modelQuotas)
        ModelQuota(
          model: t(m.model),
          usedPercent: m.usedPercent,
          resetsAt: m.resetsAt,
          category: m.category == null ? null : t(m.category!),
          note: m.note == null ? null : t(m.note!),
        ),
    ],
    suspect: q.suspect == null ? null : t(q.suspect!),
    driftReason: q.driftReason == null ? null : t(q.driftReason!),
    driftObservedAt: q.driftObservedAt,
    perMachine: q.perMachine,
    pipeHealth: q.pipeHealth == null ? null : t(q.pipeHealth!),
    httpStatus: q.httpStatus,
    retryAfterSeconds: q.retryAfterSeconds,
    resetCreditsAvailable: q.resetCreditsAvailable,
  );
}

/// A short escape-hatch message when [q] reports redeemable off-cycle resets, or
/// null when none are. Shared by every surface for consistent wording. Never
/// asserted from stale or drifted evidence, since [resetCreditsAvailable] is a
/// fresh-read signal.
String? resetAvailableMessage(ProviderQuota q) {
  final n = q.resetCreditsAvailable;
  // Never assert a redeemable reset from any degraded snapshot: stale, drifted,
  // or plausibility-flagged (suspect). This does not rely on the reconstruction
  // paths happening to zero the field.
  if (n <= 0 || q.stale || q.driftReason != null || q.suspect != null) {
    return null;
  }
  final unit = n == 1 ? 'reset' : 'resets';
  return '$n $unit available in ${q.displayName} - redeem now';
}

/// True when an account string names a specific identity rather than a generic
/// placeholder used by providers that do not expose account metadata.
bool hasSpecificQuotaAccount(String account) =>
    account.isNotEmpty && account != 'unknown' && account != 'default';

/// Internal key used when local analytics need account-specific history. Public
/// JSON keeps provider and account as separate fields; this is only for maps.
String quotaIdentityKey(String provider, String account) =>
    hasSpecificQuotaAccount(account) ? '$provider\u0000$account' : provider;

String quotaIdentityKeyFor(ProviderQuota quota) =>
    quotaIdentityKey(quota.provider, quota.account);

BurnStat? burnStatForQuota(Map<String, BurnStat> stats, ProviderQuota quota) =>
    stats[quotaIdentityKeyFor(quota)] ?? stats[quota.provider];

/// A recent burn-rate estimate with its uncertainty, the input routing uses to
/// forecast headroom. [perHour] is percent of quota consumed per hour (negative
/// when headroom is easing), [sePerHour] the standard error of that estimate
/// (null when too few points to estimate it), and [samples] the number of points
/// it was fit from. Produced by `burnRateWithError`; consumed by `suggestRoute`.
class BurnStat {
  final double? perHour;
  final double? sePerHour;
  final int samples;
  const BurnStat({this.perHour, this.sePerHour, this.samples = 0});
}

/// One normalized model candidate represented by the current provider snapshot
/// and catalog. Capability fields are hints, null when unknown; local-only fields
/// ([loaded], [sizeBytes], [vramBytes], [quant]) are null/false for cloud models.
class ModelInfo {
  /// Provider-native model id, e.g. "claude-opus-4-8" or "llama3.1:8b".
  final String id;

  /// Human display name when it differs usefully from [id].
  final String? displayName;

  /// Context window in tokens, when known.
  final int? contextTokens;

  /// Maximum output tokens, when known.
  final int? maxOutputTokens;

  /// Whether the model supports tool/function calling, when known.
  final bool? tools;

  /// Whether the model accepts image input, when known.
  final bool? vision;

  /// Reasoning-tier hint (e.g. "reasoning"), when known.
  final String? reasoning;

  /// The provider's own product tier: "light", "standard", or "flagship" (e.g.
  /// Haiku/Flash, Sonnet/Pro, Opus/Heavy). A neutral, sourced fact for ordering
  /// cheap-to-capable, never a quotabot quality judgement. Null when unknown.
  final String? tier;

  /// Last epoch second when this model is known to be included in the
  /// provider's subscription quota. Null means it follows the provider's normal
  /// quota semantics.
  final int? quotaIncludedUntil;

  /// True for a local-runtime model (Ollama/LM Studio/Lemonade).
  final bool local;

  /// True when a model reached through a local runtime actually executes in the
  /// provider's cloud rather than on this machine (e.g. an Ollama `-cloud`
  /// model). It is still [local] in the sense of being reached via the local
  /// daemon, but it is not on-device and not free, so budget policies that
  /// promise local-only or free execution must exclude it.
  final bool cloudOffloaded;

  /// Local only: currently loaded into memory.
  final bool loaded;

  /// Local only: on-disk size in bytes.
  final int? sizeBytes;

  /// Local only: VRAM in bytes when loaded.
  final int? vramBytes;

  /// Local only: quantization label, e.g. "Q4_K_M".
  final String? quant;

  const ModelInfo({
    required this.id,
    this.displayName,
    this.contextTokens,
    this.maxOutputTokens,
    this.tools,
    this.vision,
    this.reasoning,
    this.tier,
    this.quotaIncludedUntil,
    this.local = false,
    this.cloudOffloaded = false,
    this.loaded = false,
    this.sizeBytes,
    this.vramBytes,
    this.quant,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        if (displayName != null) 'display_name': displayName,
        if (contextTokens != null) 'context_tokens': contextTokens,
        if (maxOutputTokens != null) 'max_output_tokens': maxOutputTokens,
        if (tools != null) 'tools': tools,
        if (vision != null) 'vision': vision,
        if (reasoning != null) 'reasoning': reasoning,
        if (tier != null) 'tier': tier,
        if (quotaIncludedUntil != null)
          'quota_included_until': quotaIncludedUntil,
        if (local) 'local': local,
        if (cloudOffloaded) 'cloud_offloaded': cloudOffloaded,
        if (loaded) 'loaded': loaded,
        if (sizeBytes != null) 'size_bytes': sizeBytes,
        if (vramBytes != null) 'vram_bytes': vramBytes,
        if (quant != null) 'quant': quant,
      };

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        id: j['id'] as String,
        displayName: j['display_name'] as String?,
        contextTokens: (j['context_tokens'] as num?)?.toInt(),
        maxOutputTokens: (j['max_output_tokens'] as num?)?.toInt(),
        tools: j['tools'] as bool?,
        vision: j['vision'] as bool?,
        reasoning: j['reasoning'] as String?,
        tier: j['tier'] as String?,
        quotaIncludedUntil: (j['quota_included_until'] as num?)?.toInt(),
        local: j['local'] as bool? ?? false,
        cloudOffloaded: j['cloud_offloaded'] as bool? ?? false,
        loaded: j['loaded'] as bool? ?? false,
        sizeBytes: (j['size_bytes'] as num?)?.toInt(),
        vramBytes: (j['vram_bytes'] as num?)?.toInt(),
        quant: j['quant'] as String?,
      );
}
