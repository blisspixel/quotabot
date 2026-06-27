/// Normalized quota model shared by every provider adapter and the UI.
library;

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
  double? get percent {
    if (usedPercent != null) return usedPercent;
    if (used != null && limit != null && limit! > 0) {
      return (used! / limit!) * 100.0;
    }
    return null;
  }

  /// True when the window is effectively exhausted.
  bool get exhausted => (percent ?? 0) >= 99.5;

  Map<String, dynamic> toJson() => {
        'label': label,
        if (usedPercent != null) 'used_percent': usedPercent,
        if (used != null) 'used': used,
        if (limit != null) 'limit': limit,
        if (resetsAt != null) 'resets_at': resetsAt,
      };

  factory QuotaWindow.fromJson(Map<String, dynamic> j) => QuotaWindow(
        label: j['label'] as String,
        usedPercent: (j['used_percent'] as num?)?.toDouble(),
        used: j['used'] as num?,
        limit: j['limit'] as num?,
        resetsAt: j['resets_at'] as int?,
      );
}

/// One provider account's quota snapshot.
class ProviderQuota {
  /// Stable provider id: "codex", "claude", "grok", "antigravity".
  final String provider;

  /// Human display name, e.g. "Codex", "Claude".
  final String displayName;

  /// Account identifier (email, plan, or "default").
  final String account;

  /// Plan/tier string when known, e.g. "pro", "max".
  final String? plan;

  /// Provider class. "subscription" (default) is a metered paid/free account
  /// whose headroom governs routing. "local" is an always-available local
  /// runtime (e.g. Ollama, LM Studio) used as a fallback and never counted as
  /// the "most headroom" winner; it is effectively unlimited and free.
  final String kind;

  /// Short status line for providers that have no quota windows, such as a
  /// local runtime ("qwen3-coder loaded" / "5 models, idle"). Null otherwise.
  final String? status;

  /// True when a local runtime currently has a model loaded in memory (a proxy
  /// for being in use). Always false for metered subscriptions.
  final bool active;

  /// Extra human-readable detail lines for providers without quota windows
  /// (e.g. a local runtime's loaded model size, quantization, and disk usage).
  final List<String> details;

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

  ProviderQuota({
    required this.provider,
    required this.displayName,
    required this.account,
    required this.asOf,
    this.plan,
    this.ok = true,
    this.error,
    this.windows = const [],
    this.stale = false,
    this.kind = 'subscription',
    this.status,
    this.active = false,
    this.details = const [],
  });

  /// True when this is a local, always-available runtime rather than a metered
  /// remote subscription.
  bool get isLocal => kind == 'local';

  factory ProviderQuota.error(
    String provider,
    String displayName,
    String error,
    int asOf,
  ) =>
      ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: 'unknown',
        asOf: asOf,
        ok: false,
        error: error,
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'display_name': displayName,
        'account': account,
        if (plan != null) 'plan': plan,
        'kind': kind,
        if (status != null) 'status': status,
        if (active) 'active': active,
        if (details.isNotEmpty) 'details': details,
        'ok': ok,
        if (error != null) 'error': error,
        'as_of': asOf,
        'stale': stale,
        'windows': windows.map((w) => w.toJson()).toList(),
      };

  factory ProviderQuota.fromJson(Map<String, dynamic> j) => ProviderQuota(
        provider: j['provider'] as String,
        displayName: j['display_name'] as String,
        account: j['account'] as String,
        plan: j['plan'] as String?,
        ok: j['ok'] as bool? ?? true,
        error: j['error'] as String?,
        asOf: j['as_of'] as int? ?? 0,
        stale: j['stale'] as bool? ?? false,
        kind: j['kind'] as String? ?? 'subscription',
        status: j['status'] as String?,
        active: j['active'] as bool? ?? false,
        details: ((j['details'] as List?) ?? const []).cast<String>(),
        windows: ((j['windows'] as List?) ?? const [])
            .map((w) => QuotaWindow.fromJson(w as Map<String, dynamic>))
            .toList(),
      );

  /// Returns a copy marked stale, preserving the original capture time.
  ProviderQuota asStale(String note) => ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: account,
        plan: plan,
        ok: true,
        error: note,
        asOf: asOf,
        stale: true,
        kind: kind,
        status: status,
        active: active,
        details: details,
        windows: windows,
      );

  /// True when this snapshot carries usable quota windows.
  bool get hasWindows => windows.isNotEmpty;
}
