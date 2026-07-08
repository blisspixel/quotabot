/// Normalized quota model shared by every provider adapter and the UI.
library;

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
const providerQuotaManualSource = 'manual';

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

  /// True when this reading reflects only this machine's local usage rather than
  /// the account's usage across every device. Providers read from local IDE
  /// state (Cursor, Windsurf, Kiro) or a per-machine session log can undercount
  /// when the same account is used on a phone or another computer; authoritative
  /// server-side reads (Claude, Grok, Antigravity, Codex live) leave this false.
  final bool perMachine;

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
    this.modelQuotas = const [],
    this.suspect,
    this.perMachine = false,
  });

  /// True when this is a local, always-available runtime rather than a metered
  /// remote subscription.
  bool get isLocal => kind.isLocal;

  /// True when this is a self-reported manual quota entry, not measured data.
  bool get isManual => source == providerQuotaManualSource;

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
        if (source != null) 'source': source,
        'kind': kind.wireName,
        if (status != null) 'status': status,
        if (active) 'active': active,
        if (details.isNotEmpty) 'details': details,
        'ok': ok,
        if (error != null) 'error': error,
        'as_of': asOf,
        'stale': stale,
        if (suspect != null) 'suspect': suspect,
        if (perMachine) 'per_machine': true,
        'windows': windows.map((w) => w.toJson()).toList(),
        if (models.isNotEmpty) 'models': models.map((m) => m.toJson()).toList(),
        if (modelQuotas.isNotEmpty)
          'model_quotas': modelQuotas.map((m) => m.toJson()).toList(),
      };

  factory ProviderQuota.fromJson(Map<String, dynamic> j) => ProviderQuota(
        provider: j['provider'] as String,
        displayName: j['display_name'] as String,
        account: j['account'] as String,
        plan: j['plan'] as String?,
        source: j['source'] as String?,
        ok: j['ok'] as bool? ?? true,
        error: j['error'] as String?,
        asOf: j['as_of'] as int? ?? 0,
        stale: j['stale'] as bool? ?? false,
        kind: ProviderQuotaKind.fromWire(j['kind'] as String?),
        status: j['status'] as String?,
        active: j['active'] as bool? ?? false,
        suspect: j['suspect'] as String?,
        perMachine: j['per_machine'] as bool? ?? false,
        details: ((j['details'] as List?) ?? const []).cast<String>(),
        windows: ((j['windows'] as List?) ?? const [])
            .map((w) => QuotaWindow.fromJson(w as Map<String, dynamic>))
            .toList(),
        models: ((j['models'] as List?) ?? const [])
            .map((m) => ModelInfo.fromJson(m as Map<String, dynamic>))
            .toList(),
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
        account: metadataFrom?.account ?? account,
        plan: metadataFrom?.plan ?? plan,
        source: metadataFrom?.source ?? source,
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
        modelQuotas: metadataFrom != null && metadataFrom.modelQuotas.isNotEmpty
            ? metadataFrom.modelQuotas
            : modelQuotas,
        // The concern belongs to these cached windows, so it rides along when
        // they are served stale, regardless of fresh metadata.
        suspect: suspect,
        perMachine: perMachine,
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
        ok: ok,
        error: error,
        windows: windows,
        stale: stale,
        kind: kind,
        status: status,
        active: active,
        details: details,
        models: models,
        modelQuotas: modelQuotas,
        suspect: reason,
        perMachine: perMachine,
      );

  /// True when this snapshot carries usable quota windows.
  bool get hasWindows => windows.isNotEmpty;
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
        ),
    ],
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
    perMachine: q.perMachine,
  );
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

/// One model the user can route to, normalized across cloud providers and local
/// runtimes. Capability fields are hints, null when unknown; local-only fields
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
        loaded: j['loaded'] as bool? ?? false,
        sizeBytes: (j['size_bytes'] as num?)?.toInt(),
        vramBytes: (j['vram_bytes'] as num?)?.toInt(),
        quant: j['quant'] as String?,
      );
}
