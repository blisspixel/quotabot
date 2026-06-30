/// Response builders and JSON-Schema declarations for the quotabot MCP server
/// (`bin/mcp_server.dart`).
///
/// These are kept out of the bin, free of stdio and clock access, so the
/// response shapes and their output schemas can be unit tested directly and the
/// server itself stays a thin wiring shell (the repo's pure-core / thin-I/O
/// rule). Every builder takes an already-collected snapshot plus the current
/// epoch and returns a JSON-serializable map.
///
/// Each `*OutputSchema` is deliberately fail-soft. It documents the stable
/// fields agents depend on but never rejects a legitimate response: nullable
/// fields are typed `union(T, null)`, only always-present fields are marked
/// required, and additive fields are allowed (additionalProperties stays open).
/// This matters because the MCP server validates a tool's structuredContent
/// against its declared schema and turns any mismatch into a hard error; an
/// over-strict schema would break the fail-soft routing contract.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'alerts.dart';
import 'analysis.dart';
import 'leases.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'profiles.dart';
import 'registry.dart';
import 'schema_contracts.dart';
import 'util.dart';

const quotabotMcpName = 'quotabot';
const quotabotMcpVersion = '0.5.1';
const quotasCurrentResourceUri = 'quotas://current';
const quotasAlertsResourceUri = 'quotas://alerts';

/// A schema that accepts [schema] or an explicit null, for nullable fields.
JsonSchema _nullable(JsonSchema schema) =>
    JsonSchema.union([schema, JsonSchema.nullValue()]);

/// Full normalized quota snapshot. Shared by the `list_quotas` tool and the
/// `quotas://current` resource so both speak the exact same shape.
Map<String, dynamic> quotasSnapshot(
  List<ProviderQuota> providers,
  int now, {
  String? profile,
  String? accountFilter,
  String? error,
}) =>
    {
      'schema': quotabotV1SchemaId,
      if (profile != null) 'profile': profile,
      if (accountFilter != null) 'account_filter': accountFilter,
      if (error != null) 'error': error,
      'generated_at': now,
      'providers': providers.map((p) => p.toJson()).toList(),
    };

/// The connected provider with the most remaining headroom right now, or a
/// `{provider: null, reason: ...}` shape when nothing is usable.
Map<String, dynamic> mostHeadroomResponse(
  List<ProviderQuota> providers,
  int now,
) {
  final best = providerWithMostHeadroom(providers, now);
  if (best == null) {
    return {'provider': null, 'reason': 'no live quota available'};
  }
  final a = providerAvailability(best, now);
  return {
    'provider': best.provider,
    'account': best.account,
    'headroom_percent': a.headroom,
    'resets_at': a.resetsAt,
    'stale': best.stale,
  };
}

/// The full routing recommendation, ranked alternatives, and guaranteed
/// fallback. [burnStatsByProvider] supplies each provider's recent burn and its
/// uncertainty; pass an empty map to rank on raw headroom.
Map<String, dynamic> suggestResponse(
  List<ProviderQuota> providers,
  int now, {
  Map<String, BurnStat> burnStatsByProvider = const {},
  List<RouteLease> activeLeases = const [],
}) {
  final response = suggestRoute(
    providers,
    now,
    burnStatsByProvider: burnStatsByProvider,
    leaseDiscountFor: (provider, account) =>
        leaseDiscountFor(activeLeases, provider, account),
  ).toJson();
  response['active_leases'] = leaseDiscounts(activeLeases)
      .map((discount) => discount.toJson())
      .toList();
  return response;
}

class CachedQuotaSnapshot {
  final List<ProviderQuota> providers;
  final int? asOf;
  final String source;

  const CachedQuotaSnapshot({
    required this.providers,
    required this.asOf,
    required this.source,
  });

  const CachedQuotaSnapshot.empty()
      : providers = const [],
        asOf = null,
        source = 'empty';
}

typedef CachedSnapshotProvider = Future<CachedQuotaSnapshot> Function();

Future<CachedQuotaSnapshot> emptyCachedSnapshot() async =>
    const CachedQuotaSnapshot.empty();

Map<String, dynamic> alertsSnapshot(
  List<QuotaAlert> alerts,
  int now, {
  int? lastAlertAt,
}) =>
    {
      'schema': 'quotabot.alerts.v1',
      'generated_at': now,
      'last_alert_at': lastAlertAt,
      'alerts': alerts.map((alert) => alert.toJson()).toList(),
    };

Map<String, dynamic> decideNowResponse(
  CachedQuotaSnapshot cached,
  int now, {
  int maxAgeSeconds = 300,
  Map<String, BurnStat> burnStatsByProvider = const {},
  List<RouteLease> activeLeases = const [],
}) {
  final age = cached.asOf == null
      ? null
      : (now - cached.asOf!).clamp(0, 1 << 31).toInt();
  final stale = cached.providers.isEmpty ||
      cached.asOf == null ||
      (age != null && age > maxAgeSeconds) ||
      cached.providers.any((provider) => provider.stale);
  final suggestion = suggestRoute(
    cached.providers,
    now,
    burnStatsByProvider: burnStatsByProvider,
    leaseDiscountFor: (provider, account) =>
        leaseDiscountFor(activeLeases, provider, account),
  ).toJson();
  return {
    'schema': 'quotabot.decision.v1',
    'as_of': now,
    'risk_z': suggestion['risk_z'],
    'source': cached.source,
    'snapshot_as_of': cached.asOf,
    'snapshot_age_seconds': age,
    'snapshot_stale': stale,
    'max_age_seconds': maxAgeSeconds,
    'recommended': suggestion['recommended'],
    'reason': suggestion['reason'],
    'using_local_fallback': suggestion['using_local_fallback'],
    'fallback': suggestion['fallback'],
    'ranked': suggestion['ranked'],
    'active_leases': leaseDiscounts(activeLeases)
        .map((discount) => discount.toJson())
        .toList(),
  };
}

/// Builds a [ModelRequirements] from `list_models` tool arguments: a coarse
/// `task` profile overlaid with explicit capability/tier filters.
ModelRequirements _requirementsFromArgs(Map<String, dynamic> args) {
  final explicit = ModelRequirements(
    minContextTokens: (args['min_context'] as num?)?.toInt(),
    requireTools: args['require_tools'] == true,
    requireVision: args['require_vision'] == true,
    requireReasoning: args['require_reasoning'] == true,
    tierFloor: args['tier_floor'] as String?,
    tierCeiling: args['tier_ceiling'] as String?,
  );
  return taskProfile(args['task'] as String?).merge(explicit);
}

/// Whether a single named provider has quota available now, or an
/// `{error: 'unknown provider'}` shape when it is not connected.
Map<String, dynamic> availabilityResponse(
  List<ProviderQuota> providers,
  int now,
  String? providerId,
  String? accountId,
) {
  final name = providerId?.toLowerCase();
  final account = _accountFilter(accountId);
  final match = providers.where((q) {
    if (q.provider != name) return false;
    if (account == null) return true;
    return q.account == account;
  });
  if (match.isEmpty) {
    return {
      'provider': name,
      if (account != null) 'account': account,
      'error':
          account == null ? 'unknown provider' : 'unknown provider/account',
    };
  }
  final q = match.first;
  final a = providerAvailability(q, now);
  return {
    'provider': q.provider,
    'account': q.account,
    'available': a.available,
    'headroom_percent': a.headroom,
    'resets_at': a.resetsAt,
    'stale': q.stale,
  };
}

/// One rolling window inside a provider entry.
final _windowSchema = JsonSchema.object(
  description: 'A rolling limit window (e.g. 5h or weekly).',
  properties: {
    'label': JsonSchema.string(description: 'Short label, e.g. "5h".'),
    'used_percent':
        JsonSchema.number(description: 'Percent consumed (0..100).'),
    'used':
        JsonSchema.number(description: 'Absolute used count, when reported.'),
    'limit':
        JsonSchema.number(description: 'Absolute limit, paired with used.'),
    'resets_at': JsonSchema.integer(description: 'Reset epoch seconds.'),
  },
  required: ['label'],
);

/// One provider entry inside a snapshot.
final _providerSchema = JsonSchema.object(
  description: 'A provider snapshot. Unlisted fields may be added over time.',
  properties: {
    'provider': JsonSchema.string(description: 'Stable provider id.'),
    'display_name': JsonSchema.string(description: 'Human display name.'),
    'account': JsonSchema.string(),
    'plan': JsonSchema.string(),
    'kind': JsonSchema.string(description: '"subscription" or "local".'),
    'ok': JsonSchema.boolean(description: 'False when the read failed.'),
    'error': JsonSchema.string(description: 'Why a read failed, when it did.'),
    'as_of': JsonSchema.integer(description: 'Capture epoch seconds.'),
    'stale': JsonSchema.boolean(description: 'True when served from cache.'),
    'windows': JsonSchema.array(items: _windowSchema),
  },
  required: ['provider', 'account'],
);

/// Output schema for `list_quotas` and the `quotas://current` resource.
final quotasSnapshotOutputSchema = JsonSchema.object(
  description: 'Normalized quota snapshot across all connected providers.',
  properties: {
    'schema':
        JsonSchema.string(description: 'Schema id, always "quotabot.v1".'),
    'generated_at':
        JsonSchema.integer(description: 'Epoch seconds when produced.'),
    'profile': JsonSchema.string(
      description: 'Named local profile applied to this snapshot, when any.',
    ),
    'error': JsonSchema.string(
      description: 'Set when a requested profile could not be loaded.',
    ),
    'providers': JsonSchema.array(
      description: 'One entry per connected provider.',
      items: _providerSchema,
    ),
  },
  required: ['schema', 'generated_at', 'providers'],
);

/// Output schema for `provider_with_most_headroom`.
final mostHeadroomOutputSchema = JsonSchema.object(
  description: 'The connected provider with the most remaining headroom now.',
  properties: {
    'provider': _nullable(JsonSchema.string(
      description: 'Provider id, or null when none is usable.',
    )),
    'account': JsonSchema.string(),
    'headroom_percent': _nullable(JsonSchema.number(
      description: 'Remaining percent (0..100) of the binding window.',
    )),
    'resets_at': _nullable(JsonSchema.integer(
      description: 'Binding-window reset epoch seconds.',
    )),
    'stale': JsonSchema.boolean(),
    'reason': JsonSchema.string(
      description: 'Why there is no pick (only when provider is null).',
    ),
  },
  required: ['provider'],
);

/// One ranked candidate inside a routing suggestion.
final _candidateSchema = JsonSchema.object(
  properties: {
    'provider': JsonSchema.string(),
    'account': JsonSchema.string(),
    'plan': JsonSchema.string(),
    'local': JsonSchema.boolean(description: 'True for a local runtime.'),
    'headroom_percent': _nullable(JsonSchema.number()),
    'effective_headroom_percent': _nullable(JsonSchema.number(
      description: 'Headroom after discounting recent burn (and risk if set).',
    )),
    'lease_discount_percent': JsonSchema.number(
      description:
          'Temporary active lease discount applied to effective headroom.',
    ),
    'burn_percent_per_hour': JsonSchema.number(),
    'burn_se_percent_per_hour': JsonSchema.number(
      description: 'Standard error of the burn estimate, when estimable.',
    ),
    'strand_probability': JsonSchema.number(
      description: 'Probability (0..1) the window is spent before it resets.',
    ),
    'confidence': JsonSchema.number(
      description:
          'Trust in this candidate (0..1): freshness x sample adequacy.',
    ),
    'resets_at': JsonSchema.integer(),
    'stale': JsonSchema.boolean(),
    'available': JsonSchema.boolean(),
  },
  required: ['provider', 'account', 'local', 'stale', 'available'],
);

final _leaseDiscountSchema = JsonSchema.object(
  description:
      'Active temporary routing reservations for one provider account.',
  properties: {
    'provider': JsonSchema.string(),
    'account': JsonSchema.string(),
    'discount_percent': JsonSchema.number(),
    'leases': JsonSchema.integer(),
    'expires_at': JsonSchema.integer(),
  },
  required: ['provider', 'account', 'discount_percent', 'leases'],
);

final _routeLeaseSchema = JsonSchema.object(
  description: 'A temporary local routing reservation.',
  properties: {
    'id': JsonSchema.string(),
    'provider': JsonSchema.string(),
    'account': JsonSchema.string(),
    'created_at': JsonSchema.integer(),
    'expires_at': JsonSchema.integer(),
    'weight_percent': JsonSchema.number(),
    'client': JsonSchema.string(),
    'idempotency_key': JsonSchema.string(),
  },
  required: [
    'id',
    'provider',
    'account',
    'created_at',
    'expires_at',
    'weight_percent',
  ],
);

/// The always-present fail-soft fallback inside a routing suggestion.
final _fallbackSchema = JsonSchema.object(
  properties: {
    'kind': JsonSchema.string(
      description: '"local", "soonest_reset", or "passthrough".',
    ),
    'provider': JsonSchema.string(),
    'resets_at': JsonSchema.integer(),
    'reason': JsonSchema.string(),
  },
  required: ['kind', 'reason'],
);

/// Output schema for `suggest_provider`.
final suggestOutputSchema = JsonSchema.object(
  description: 'A routing recommendation with ranked alternatives and a '
      'guaranteed fallback.',
  properties: {
    'schema': JsonSchema.string(),
    'as_of':
        JsonSchema.integer(description: 'Epoch seconds the decision was made.'),
    'risk_z': JsonSchema.number(description: 'Risk aversion used (0 = mean).'),
    'recommended': _nullable(_candidateSchema),
    'reason': JsonSchema.string(),
    'using_local_fallback': JsonSchema.boolean(),
    'fallback': _fallbackSchema,
    'ranked': JsonSchema.array(items: _candidateSchema),
    'active_leases': JsonSchema.array(items: _leaseDiscountSchema),
  },
  required: ['schema', 'reason', 'using_local_fallback', 'fallback', 'ranked'],
);

final decideNowOutputSchema = JsonSchema.object(
  description:
      'A cache-only routing decision that never forces live collection.',
  properties: {
    'schema': JsonSchema.string(),
    'as_of': JsonSchema.integer(),
    'risk_z': JsonSchema.number(),
    'source': JsonSchema.string(
      description: '"memory", "disk", or "empty".',
    ),
    'snapshot_as_of': _nullable(JsonSchema.integer()),
    'snapshot_age_seconds': _nullable(JsonSchema.integer()),
    'snapshot_stale': JsonSchema.boolean(),
    'max_age_seconds': JsonSchema.integer(),
    'recommended': _nullable(_candidateSchema),
    'reason': JsonSchema.string(),
    'using_local_fallback': JsonSchema.boolean(),
    'fallback': _fallbackSchema,
    'ranked': JsonSchema.array(items: _candidateSchema),
    'active_leases': JsonSchema.array(items: _leaseDiscountSchema),
  },
  required: [
    'schema',
    'as_of',
    'source',
    'snapshot_stale',
    'max_age_seconds',
    'reason',
    'using_local_fallback',
    'fallback',
    'ranked',
  ],
);

final reserveProviderOutputSchema = JsonSchema.object(
  description: 'Result of creating a temporary local routing reservation.',
  properties: {
    'schema': JsonSchema.string(),
    'as_of': JsonSchema.integer(),
    'reserved': JsonSchema.boolean(),
    'reused': JsonSchema.boolean(),
    'reason': JsonSchema.string(),
    'lease': _nullable(_routeLeaseSchema),
    'active_leases': JsonSchema.array(items: _leaseDiscountSchema),
  },
  required: [
    'schema',
    'as_of',
    'reserved',
    'reused',
    'reason',
    'active_leases'
  ],
);

final releaseProviderOutputSchema = JsonSchema.object(
  description: 'Result of releasing a temporary local routing reservation.',
  properties: {
    'schema': JsonSchema.string(),
    'as_of': JsonSchema.integer(),
    'released': JsonSchema.boolean(),
    'reason': JsonSchema.string(),
    'lease_id': JsonSchema.string(),
    'lease': _nullable(_routeLeaseSchema),
    'active_leases': JsonSchema.array(items: _leaseDiscountSchema),
  },
  required: [
    'schema',
    'as_of',
    'released',
    'reason',
    'lease_id',
    'active_leases'
  ],
);

/// One model entry in the registry: the model's capability fields plus the live
/// budget of its gating provider. Permissive (additive fields allowed).
final _modelEntrySchema = JsonSchema.object(
  description: 'A routable model plus the gating provider budget.',
  properties: {
    'id': JsonSchema.string(description: 'Provider-native model id.'),
    'display_name': JsonSchema.string(),
    'provider': JsonSchema.string(),
    'account': JsonSchema.string(),
    'local': JsonSchema.boolean(),
    'available': JsonSchema.boolean(),
    'stale': JsonSchema.boolean(),
    'context_tokens': JsonSchema.integer(),
    'max_output_tokens': JsonSchema.integer(),
    'tools': JsonSchema.boolean(),
    'vision': JsonSchema.boolean(),
    'reasoning': JsonSchema.string(),
    'tier': JsonSchema.string(
      description: "The provider's own tier: light, standard, or flagship.",
    ),
    'headroom_percent': _nullable(JsonSchema.number()),
    'resets_at': JsonSchema.integer(),
    'gating_window': JsonSchema.string(),
  },
  required: ['id', 'provider', 'local', 'available'],
);

/// Shared capability filter for `list_models` and `suggest_model`. quotabot never
/// reads the task; the caller supplies the requirements it needs.
final _modelFilterInputSchema = JsonSchema.object(
  description: 'Optional capability filter; all fields optional.',
  properties: {
    'profile': JsonSchema.string(
      description: 'Optional local named profile to filter providers/accounts.',
    ),
    'account': JsonSchema.string(
      description:
          'Optional exact account label to route within after profile filtering.',
    ),
    'task': JsonSchema.string(
      description: 'Coarse profile: "simple", "standard", or "hard".',
    ),
    'min_context': JsonSchema.integer(
      description: 'Require a context window of at least this many tokens.',
    ),
    'require_tools': JsonSchema.boolean(),
    'require_vision': JsonSchema.boolean(),
    'require_reasoning': JsonSchema.boolean(),
    'tier_floor': JsonSchema.string(
      description: 'Minimum provider tier: light, standard, or flagship.',
    ),
    'tier_ceiling': JsonSchema.string(
      description: 'Maximum provider tier: light, standard, or flagship.',
    ),
    'exclude': JsonSchema.array(
      items: JsonSchema.string(),
      description:
          'Optional provider ids to ignore for this one request, after profile filtering.',
    ),
  },
);

final _profileAndAccountInputSchema = JsonSchema.object(
  properties: {
    'profile': JsonSchema.string(
      description: 'Optional local named profile to filter providers/accounts.',
    ),
    'account': JsonSchema.string(
      description:
          'Optional exact account label to route within after profile filtering.',
    ),
    'exclude': JsonSchema.array(
      items: JsonSchema.string(),
      description:
          'Optional provider ids to ignore for this one request, after profile filtering.',
    ),
  },
);

/// Output schema for `suggest_model`.
final suggestModelOutputSchema = JsonSchema.object(
  description: 'One concrete model recommended for a task profile.',
  properties: {
    'schema': JsonSchema.string(),
    'generated_at': JsonSchema.integer(),
    'recommended': _nullable(_modelEntrySchema),
    'reason': JsonSchema.string(),
    'ranked': JsonSchema.array(items: _modelEntrySchema),
  },
  required: ['schema', 'reason', 'ranked'],
);

/// Output schema for `list_models`.
final listModelsOutputSchema = JsonSchema.object(
  description: 'Every model the user can route to now, with per-model budget.',
  properties: {
    'schema': JsonSchema.string(),
    'generated_at': JsonSchema.integer(),
    'catalog_updated': JsonSchema.string(
      description: 'Date the cloud capability catalog was last refreshed.',
    ),
    'models': JsonSchema.array(items: _modelEntrySchema),
  },
  required: ['schema', 'generated_at', 'models'],
);

/// Output schema for `check_provider_availability`.
final availabilityOutputSchema = JsonSchema.object(
  description: 'Whether one named provider has quota available now.',
  properties: {
    'provider': _nullable(JsonSchema.string()),
    'account': JsonSchema.string(),
    'available': JsonSchema.boolean(),
    'headroom_percent': _nullable(JsonSchema.number()),
    'resets_at': _nullable(JsonSchema.integer()),
    'stale': JsonSchema.boolean(),
    'error':
        JsonSchema.string(description: 'Set when the provider is unknown.'),
  },
  required: ['provider'],
);

/// Returns the current quota snapshot. Injected so the server and its tests
/// share one wiring path while feeding real or fixture data respectively.
typedef SnapshotProvider = Future<List<ProviderQuota>> Function();

typedef ProfileLoader = QuotaProfile? Function(String name);

/// Returns recent burn and its uncertainty per provider id. Kept out of the pure
/// layer because the real implementation reads history from disk.
typedef BurnProvider = Map<String, BurnStat> Function(
  Iterable<String> providers,
  int now,
);

McpServer buildQuotabotMcpServer({
  required SnapshotProvider snapshot,
  required BurnProvider burnByProvider,
  CachedSnapshotProvider cachedSnapshot = emptyCachedSnapshot,
  RouteLeaseStore leaseStore = const NoopRouteLeaseStore(),
  bool enableSubscriptionTimers = true,
  int Function() now = nowEpoch,
  Map<String, List<ModelInfo>> catalog = kModelCatalog,
  ProfileLoader profileLoader = loadProfile,
}) {
  final server = McpServer(
    const Implementation(name: quotabotMcpName, version: quotabotMcpVersion),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
        resources: ServerCapabilitiesResources(),
      ),
    ),
  );

  registerQuotabotTools(
    server,
    snapshot: snapshot,
    burnByProvider: burnByProvider,
    cachedSnapshot: cachedSnapshot,
    leaseStore: leaseStore,
    enableSubscriptionTimers: enableSubscriptionTimers,
    now: now,
    catalog: catalog,
    profileLoader: profileLoader,
  );

  return server;
}

/// Shared read-only annotations for every quotabot tool: each reads provider
/// metadata, modifies nothing, is safe to repeat, and reaches external services.
const _readOnly = ToolAnnotations(
  readOnlyHint: true,
  idempotentHint: true,
  destructiveHint: false,
  openWorldHint: true,
);

const _localWrite = ToolAnnotations(
  readOnlyHint: false,
  idempotentHint: false,
  destructiveHint: false,
  openWorldHint: false,
);

const _localRelease = ToolAnnotations(
  readOnlyHint: false,
  idempotentHint: true,
  destructiveHint: false,
  openWorldHint: false,
);

class _ProfiledSnapshot {
  final List<ProviderQuota> providers;
  final String? profile;
  final String? accountFilter;
  final String? error;

  const _ProfiledSnapshot({
    required this.providers,
    this.profile,
    this.accountFilter,
    this.error,
  });
}

String? _accountFilter(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= 240 ? trimmed : trimmed.substring(0, 240);
}

List<ProviderQuota> _filterAccount(
  List<ProviderQuota> providers,
  String? account,
) {
  if (account == null) return providers;
  return providers.where((provider) => provider.account == account).toList();
}

({Set<String> providers, String? error}) _excludeFilter(Object? value) {
  if (value == null) return (providers: const {}, error: null);
  final Iterable<Object?> raw;
  if (value is String) {
    raw = value.split(',');
  } else if (value is List) {
    raw = value;
  } else {
    return (
      providers: const {},
      error: 'exclude must be a string or list of provider ids',
    );
  }
  final providers = <String>{};
  for (final item in raw) {
    if (item is! String || item.trim().isEmpty) continue;
    final provider = normalizeProviderId(item);
    if (provider == null) {
      return (
        providers: const {},
        error: 'invalid exclude provider: $item',
      );
    }
    providers.add(provider);
  }
  return (providers: providers, error: null);
}

List<ProviderQuota> _filterExcluded(
  List<ProviderQuota> providers,
  Set<String> excluded,
) {
  if (excluded.isEmpty) return providers;
  return [
    for (final provider in providers)
      if (!excluded.contains(
        normalizeProviderId(provider.provider) ?? provider.provider,
      ))
        provider,
  ];
}

Future<_ProfiledSnapshot> _profiledSnapshot(
  Map<String, dynamic> args,
  SnapshotProvider snapshot,
  ProfileLoader profileLoader,
) async {
  final account = _accountFilter(args['account']);
  final exclude = _excludeFilter(args['exclude']);
  final rawProfile = args['profile'];
  final requested = rawProfile is String ? rawProfile.trim() : null;
  if (exclude.error != null) {
    return _ProfiledSnapshot(
      providers: const [],
      profile: requested == null || requested.isEmpty ? null : requested,
      accountFilter: account,
      error: exclude.error,
    );
  }
  if (requested == null || requested.isEmpty) {
    return _ProfiledSnapshot(
      providers: _filterExcluded(
        _filterAccount(await snapshot(), account),
        exclude.providers,
      ),
      accountFilter: account,
    );
  }
  final profile = profileLoader(requested);
  if (profile == null) {
    return _ProfiledSnapshot(
      providers: const [],
      profile: requested,
      accountFilter: account,
      error: 'unknown profile: $requested',
    );
  }
  final providers = _filterExcluded(
    _filterAccount(applyProfile(await snapshot(), profile), account),
    exclude.providers,
  );
  return _ProfiledSnapshot(
    providers: providers,
    profile: profile.name,
    accountFilter: account,
  );
}

Map<String, dynamic> _withProfileMeta(
  Map<String, dynamic> response,
  _ProfiledSnapshot snapshot,
) {
  if (snapshot.profile != null) response['profile'] = snapshot.profile;
  if (snapshot.accountFilter != null) {
    response['account_filter'] = snapshot.accountFilter;
  }
  if (snapshot.error != null) response['error'] = snapshot.error;
  return response;
}

List<Map<String, dynamic>> _leaseDiscountJson(List<RouteLease> activeLeases) =>
    leaseDiscounts(activeLeases)
        .map((discount) => discount.toJson())
        .toList(growable: false);

Map<String, dynamic> _reserveJson(
  RouteLeaseReservation reservation,
  int now,
) =>
    {
      'schema': 'quotabot.reserve.v1',
      'as_of': now,
      'reserved': reservation.reserved,
      'reused': reservation.reused,
      'reason': reservation.reason,
      'lease': reservation.lease?.toJson(),
      'active_leases': _leaseDiscountJson(reservation.activeLeases),
    };

Map<String, dynamic> _releaseJson(
  RouteLeaseRelease release,
  String leaseId,
  int now,
) =>
    {
      'schema': 'quotabot.release.v1',
      'as_of': now,
      'released': release.released,
      'reason': release.reason,
      'lease_id': leaseId,
      'lease': release.lease?.toJson(),
      'active_leases': _leaseDiscountJson(release.activeLeases),
    };

class QuotaResourceSubscriptionHub {
  final SnapshotProvider snapshot;
  final BurnProvider burnByProvider;
  final int Function() now;
  final Future<void> Function(String uri) notifyUpdated;
  final bool autoStart;

  final Set<String> _subscribed = {};
  var _armed = <String>{};
  var _lastAlerts = <QuotaAlert>[];
  int? _lastAlertAt;
  var _lastSnapshot = <ProviderQuota>[];
  var _failStreak = 0;
  Timer? _timer;
  var _polling = false;
  var _disposed = false;

  QuotaResourceSubscriptionHub({
    required this.snapshot,
    required this.burnByProvider,
    required this.now,
    required this.notifyUpdated,
    this.autoStart = true,
  });

  Map<String, dynamic> alertsResource() => alertsSnapshot(
        _lastAlerts,
        now(),
        lastAlertAt: _lastAlertAt,
      );

  Future<void> subscribe(String uri) async {
    _assertSubscribable(uri);
    _subscribed.add(uri);
    if (autoStart) _schedule(Duration.zero);
  }

  Future<void> unsubscribe(String uri) async {
    _assertSubscribable(uri);
    _subscribed.remove(uri);
    if (_subscribed.isEmpty) _timer?.cancel();
  }

  Future<void> pollOnce() async {
    if (_disposed || _subscribed.isEmpty || _polling) return;
    _polling = true;
    try {
      final data = await snapshot();
      _lastSnapshot = data;
      final n = now();
      final anyLive = data.any((q) => q.ok && q.hasWindows && !q.stale);
      _failStreak = anyLive ? 0 : _failStreak + 1;
      if (_subscribed.contains(quotasCurrentResourceUri)) {
        await notifyUpdated(quotasCurrentResourceUri);
      }
      final burnStats = burnByProvider(data.map((q) => q.provider), n);
      final suggestion = suggestRoute(data, n, burnStatsByProvider: burnStats);
      final alerts = computeAlerts(
        snapshot: data,
        suggestion: suggestion,
        now: n,
        armed: _armed,
        alertOn: const {AlertSeverity.amber, AlertSeverity.red},
      );
      _armed = alerts.armed;
      if (alerts.fired.isNotEmpty) {
        _lastAlerts = alerts.fired;
        _lastAlertAt = n;
        if (_subscribed.contains(quotasAlertsResourceUri)) {
          await notifyUpdated(quotasAlertsResourceUri);
        }
      }
    } catch (_) {
      _failStreak++;
    } finally {
      _polling = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _subscribed.clear();
  }

  void _schedule(Duration delay) {
    if (_disposed || _subscribed.isEmpty) return;
    _timer?.cancel();
    _timer = Timer(delay, () async {
      await pollOnce();
      if (_disposed || _subscribed.isEmpty) return;
      final seconds = _lastSnapshot.isEmpty
          ? 60
          : nextRefreshSeconds(
              _lastSnapshot,
              now(),
              failStreak: _failStreak,
            );
      _schedule(Duration(seconds: seconds));
    });
  }

  void _assertSubscribable(String uri) {
    if (uri == quotasCurrentResourceUri || uri == quotasAlertsResourceUri) {
      return;
    }
    throw McpError(
      ErrorCode.invalidParams.value,
      'resource is not subscribable: $uri',
    );
  }
}

void _registerQuotaResourceSubscriptions(
  McpServer server,
  QuotaResourceSubscriptionHub hub,
) {
  server.server.registerCapabilities(
    const ServerCapabilities(
      resources: ServerCapabilitiesResources(subscribe: true),
    ),
  );
  server.server.assertCanSetRequestHandler(Method.resourcesSubscribe);
  server.server.setRequestHandler<JsonRpcSubscribeRequest>(
    Method.resourcesSubscribe,
    (request, extra) async {
      await hub.subscribe(request.subParams.uri);
      return const EmptyResult();
    },
    (id, params, meta) => JsonRpcSubscribeRequest.fromJson({
      'id': id,
      'params': params,
      if (meta != null) '_meta': meta,
    }),
  );
  server.server.assertCanSetRequestHandler(Method.resourcesUnsubscribe);
  server.server.setRequestHandler<JsonRpcUnsubscribeRequest>(
    Method.resourcesUnsubscribe,
    (request, extra) async {
      await hub.unsubscribe(request.unsubParams.uri);
      return const EmptyResult();
    },
    (id, params, meta) => JsonRpcUnsubscribeRequest.fromJson({
      'id': id,
      'params': params,
      if (meta != null) '_meta': meta,
    }),
  );
  server.server.onclose = hub.dispose;
}

RouteCandidate? _explicitReserveTarget(
  List<ProviderQuota> providers,
  int now,
  Map<String, dynamic> args,
  List<RouteLease> activeLeases,
  Map<String, BurnStat> burnStatsByProvider,
) {
  final requestedProvider = normalizeLeaseText(args['provider'])?.toLowerCase();
  if (requestedProvider == null) return null;
  final requestedAccount = normalizeLeaseText(args['account']);
  final matches = providers.where((provider) {
    if (provider.provider != requestedProvider) return false;
    if (requestedAccount == null) return true;
    return provider.account == requestedAccount;
  }).toList();
  if (matches.isEmpty) return null;
  final ranked = suggestRoute(
    matches,
    now,
    burnStatsByProvider: burnStatsByProvider,
    leaseDiscountFor: (provider, account) =>
        leaseDiscountFor(activeLeases, provider, account),
  ).ranked;
  return ranked.isEmpty ? null : ranked.first;
}

Map<String, dynamic> _reserveUnavailable(
  String reason,
  int now,
  List<RouteLease> activeLeases,
) =>
    {
      'schema': 'quotabot.reserve.v1',
      'as_of': now,
      'reserved': false,
      'reused': false,
      'reason': reason,
      'lease': null,
      'active_leases': _leaseDiscountJson(activeLeases),
    };

/// Registers quotabot's tools and quota resources on [server].
///
/// This is the single wiring point shared by `bin/mcp_server.dart` (which feeds
/// live data) and the tests (which feed fixtures), so there is exactly one
/// definition of each tool's schema, annotations, and behavior. [snapshot] and
/// [burnByProvider] are injected; [now] defaults to the wall clock and is
/// overridden in tests for determinism.
QuotaResourceSubscriptionHub registerQuotabotTools(
  McpServer server, {
  required SnapshotProvider snapshot,
  required BurnProvider burnByProvider,
  CachedSnapshotProvider cachedSnapshot = emptyCachedSnapshot,
  RouteLeaseStore leaseStore = const NoopRouteLeaseStore(),
  bool enableSubscriptionTimers = true,
  int Function() now = nowEpoch,
  Map<String, List<ModelInfo>> catalog = kModelCatalog,
  ProfileLoader profileLoader = loadProfile,
}) {
  late final QuotaResourceSubscriptionHub subscriptionHub;
  subscriptionHub = QuotaResourceSubscriptionHub(
    snapshot: snapshot,
    burnByProvider: burnByProvider,
    now: now,
    autoStart: enableSubscriptionTimers,
    notifyUpdated: (uri) async {
      if (!server.isConnected) return;
      try {
        await server.server.notification(
          JsonRpcResourceUpdatedNotification(
            updatedParams: ResourceUpdatedNotification(uri: uri),
          ),
        );
      } catch (_) {}
    },
  );

  server.registerTool(
    'list_quotas',
    title: 'List quotas',
    description:
        'Return the current usage quota for every connected AI subscription '
        '(Codex, Claude, Grok, Antigravity, Kiro, Cursor, Windsurf) and local '
        'runtime as JSON. Per provider: account, plan, ok/stale, and rolling '
        'windows (label, used_percent or used/limit, resets_at). Longer windows '
        'that are spent are the binding constraint.',
    inputSchema: _profileAndAccountInputSchema,
    outputSchema: quotasSnapshotOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      return CallToolResult.fromStructuredContent(
        quotasSnapshot(
          profiled.providers,
          now(),
          profile: profiled.profile,
          accountFilter: profiled.accountFilter,
          error: profiled.error,
        ),
      );
    },
  );

  server.registerTool(
    'provider_with_most_headroom',
    title: 'Provider with most headroom',
    description:
        'Return the connected provider that currently has the most remaining '
        'quota headroom, for choosing where to route work. The binding '
        '(most constrained) window governs availability. Returns provider, '
        'account, headroom_percent, resets_at of the binding window, and a stale '
        'flag, or {provider: null, reason} when nothing is usable. A longer '
        'window that is spent blocks use even if shorter windows show headroom.',
    inputSchema: _profileAndAccountInputSchema,
    outputSchema: mostHeadroomOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          mostHeadroomResponse(profiled.providers, now()),
          profiled,
        ),
      );
    },
  );

  server.registerTool(
    'suggest_provider',
    title: 'Suggest provider',
    description:
        'Recommend which provider to route the next request to. Prefers the '
        'metered subscription with the most remaining headroom (above a comfort '
        'threshold, after discounting recent burn and active local leases), and '
        'falls back to a local runtime (e.g. Ollama) when every subscription is '
        'low. Returns the '
        'recommended provider, a human reason, a using_local_fallback flag, a '
        'guaranteed fallback, and the full ranked candidate list. Local runtimes '
        'never win on headroom; they are fallbacks only.',
    inputSchema: _profileAndAccountInputSchema,
    outputSchema: suggestOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      final results = profiled.providers;
      final n = now();
      final activeLeases = leaseStore.active(n);
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          suggestResponse(
            results,
            n,
            burnStatsByProvider:
                burnByProvider(results.map((q) => q.provider), n),
            activeLeases: activeLeases,
          ),
          profiled,
        ),
      );
    },
  );

  server.registerTool(
    'decide_now',
    title: 'Decide now from cache',
    description:
        'Return a routing decision from the latest cached quota snapshot without '
        'forcing a live provider collection. The response always states the '
        'cache source, snapshot_as_of, snapshot_age_seconds, and snapshot_stale '
        'so a router can decide whether the answer is fresh enough for a '
        'per-request path. Active temporary leases are applied to effective '
        'headroom.',
    inputSchema: JsonSchema.object(
      properties: {
        'profile': JsonSchema.string(
          description:
              'Optional local named profile to filter providers/accounts.',
        ),
        'account': JsonSchema.string(
          description:
              'Optional exact account label to route within after profile filtering.',
        ),
        'exclude': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'Optional provider ids to ignore for this one request, after profile filtering.',
        ),
        'max_age_seconds': JsonSchema.integer(
          description:
              'Age above which snapshot_stale becomes true. Defaults to 300.',
        ),
      },
    ),
    outputSchema: decideNowOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final cached = await cachedSnapshot();
      final profiled = await _profiledSnapshot(
        args,
        () async => cached.providers,
        profileLoader,
      );
      final n = now();
      final activeLeases = leaseStore.active(n);
      final maxAge = (args['max_age_seconds'] as num?)?.toInt() ?? 300;
      final boundedMaxAge = maxAge.clamp(0, 86400).toInt();
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          decideNowResponse(
            CachedQuotaSnapshot(
              providers: profiled.providers,
              asOf: cached.asOf,
              source: cached.source,
            ),
            n,
            maxAgeSeconds: boundedMaxAge,
            burnStatsByProvider:
                burnByProvider(profiled.providers.map((q) => q.provider), n),
            activeLeases: activeLeases,
          ),
          profiled,
        ),
      );
    },
  );

  server.registerTool(
    'reserve_provider',
    title: 'Reserve provider',
    description:
        'Create a short local routing lease for the current best subscription, '
        'or for an explicit provider/account. The lease reduces that account '
        'effective headroom for later suggestions so parallel agents do not all '
        'choose the same provider at once. This writes only local metadata and '
        'expires automatically.',
    inputSchema: JsonSchema.object(
      properties: {
        'provider': JsonSchema.string(
          description:
              'Optional provider id to reserve. If omitted, quotabot reserves '
              'the current best subscription.',
        ),
        'account': JsonSchema.string(
          description: 'Optional account disambiguator for provider.',
        ),
        'profile': JsonSchema.string(
          description:
              'Optional local named profile to filter providers/accounts.',
        ),
        'exclude': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'Optional provider ids to ignore for this one request, after profile filtering.',
        ),
        'lease_seconds': JsonSchema.integer(
          description: 'Lease TTL, clamped to 15..3600 seconds.',
        ),
        'weight_percent': JsonSchema.number(
          description: 'Effective-headroom discount, clamped to 1..50.',
        ),
        'client': JsonSchema.string(
          description: 'Optional caller label stored with the local lease.',
        ),
        'idempotency_key': JsonSchema.string(
          description: 'Optional retry key; a matching active lease is reused.',
        ),
      },
    ),
    outputSchema: reserveProviderOutputSchema,
    annotations: _localWrite,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      final n = now();
      var activeLeases = leaseStore.active(n);
      if (profiled.error != null) {
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(
            _reserveUnavailable(profiled.error!, n, activeLeases),
            profiled,
          ),
        );
      }

      final results = profiled.providers;
      final burnStats = burnByProvider(results.map((q) => q.provider), n);
      final explicit = normalizeLeaseText(args['provider']) != null;
      final target = _explicitReserveTarget(
            results,
            n,
            args,
            activeLeases,
            burnStats,
          ) ??
          (explicit
              ? null
              : suggestRoute(
                  results,
                  n,
                  burnStatsByProvider: burnStats,
                  leaseDiscountFor: (provider, account) =>
                      leaseDiscountFor(activeLeases, provider, account),
                ).recommended);
      if (target == null) {
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(
            _reserveUnavailable(
              explicit
                  ? 'requested provider/account unavailable'
                  : 'no reservable provider available',
              n,
              activeLeases,
            ),
            profiled,
          ),
        );
      }
      if (target.isLocal) {
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(
            _reserveUnavailable(
              'local runtimes do not need quota leases',
              n,
              activeLeases,
            ),
            profiled,
          ),
        );
      }
      if (!target.available || (target.effectiveHeadroom ?? 0) <= 0) {
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(
            _reserveUnavailable(
              '${target.provider} has no effective headroom available',
              n,
              activeLeases,
            ),
            profiled,
          ),
        );
      }

      final reservation = leaseStore.reserve(
        provider: target.provider,
        account: target.account,
        now: n,
        leaseSeconds: normalizeLeaseSeconds(args['lease_seconds']),
        weightPercent: normalizeLeaseWeight(args['weight_percent']),
        client: normalizeLeaseText(args['client']),
        idempotencyKey: normalizeLeaseText(args['idempotency_key']),
      );
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(_reserveJson(reservation, n), profiled),
      );
    },
  );

  server.registerTool(
    'release_provider',
    title: 'Release provider reservation',
    description:
        'Release a local routing lease before its expiry. The operation is '
        'idempotent: releasing an unknown or expired lease returns released '
        'false with the current active lease summary.',
    inputSchema: JsonSchema.object(
      properties: {
        'lease_id': JsonSchema.string(
            description: 'Lease id returned by reserve_provider.'),
      },
      required: ['lease_id'],
    ),
    outputSchema: releaseProviderOutputSchema,
    annotations: _localRelease,
    callback: (args, extra) async {
      final n = now();
      final leaseId = normalizeLeaseText(args['lease_id'], maxLength: 96);
      if (leaseId == null) {
        return CallToolResult.fromStructuredContent(
          _releaseJson(
            RouteLeaseRelease(
              released: false,
              reason: 'lease_id is required',
              lease: null,
              activeLeases: leaseStore.active(n),
            ),
            '',
            n,
          ),
        );
      }
      final release = leaseStore.release(leaseId: leaseId, now: n);
      return CallToolResult.fromStructuredContent(
        _releaseJson(release, leaseId, n),
      );
    },
  );

  server.registerTool(
    'list_models',
    title: 'List models',
    description:
        'Return every model the user can route to right now, across all cloud '
        'providers and local runtimes, each tagged with the live budget that '
        'gates it (headroom percent, binding window, reset) and capability hints '
        '(context length, tools, vision) where known. Local-runtime models are '
        'read live; cloud models come from a refreshable capability catalog. Use '
        'this to pick a concrete model with budget, not just a provider.',
    inputSchema: _modelFilterInputSchema,
    outputSchema: listModelsOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          modelRegistryJson(
            profiled.providers,
            now(),
            catalog: catalog,
            requirements: _requirementsFromArgs(args),
          ),
          profiled,
        ),
      );
    },
  );

  server.registerTool(
    'suggest_model',
    title: 'Suggest model',
    description:
        'Recommend one concrete model for a task: the cheapest model that meets '
        'the given requirements and has budget, local-first, escalating to a '
        'heavier or paid tier only when the requirements force it. Takes the same '
        'filter as list_models. quotabot never reads the task; the caller supplies '
        'the profile, and tiers are the providers own, not a quality ranking.',
    inputSchema: _modelFilterInputSchema,
    outputSchema: suggestModelOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      final n = now();
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          suggestModel(profiled.providers, n,
                  catalog: catalog, requirements: _requirementsFromArgs(args))
              .toJson(n),
          profiled,
        ),
      );
    },
  );

  server.registerTool(
    'check_provider_availability',
    title: 'Check provider availability',
    description:
        'Check whether a specific provider has quota available right now. '
        'Returns whether it is usable, its remaining headroom percent, and when '
        'the binding window resets. A longer window spent means unavailable.',
    inputSchema: JsonSchema.object(
      properties: {
        'provider': JsonSchema.string(
          description: 'Provider id: codex, claude, grok, antigravity, kiro, '
              'cursor, windsurf, or a local runtime.',
        ),
        'account': JsonSchema.string(
          description:
              'Optional exact account label for providers with multiple accounts.',
        ),
        'profile': JsonSchema.string(
          description:
              'Optional local named profile to filter providers/accounts.',
        ),
      },
      required: ['provider'],
    ),
    outputSchema: availabilityOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          availabilityResponse(
            profiled.providers,
            now(),
            args['provider'] as String?,
            args['account'] as String?,
          ),
          profiled,
        ),
      );
    },
  );

  server.registerResource(
    'quotas',
    quotasCurrentResourceUri,
    (
      description: 'Full live normalized quota snapshot across all providers. '
          'JSON object with schema, generated_at, and a providers list. Each '
          'provider has account, plan, ok, stale, and windows (label, '
          'used_percent, resets_at). Binding longer windows override shorter '
          'ones for availability.',
      mimeType: 'application/json',
    ),
    (uri, extra) async => ReadResourceResult(
      contents: [
        TextResourceContents(
          uri: uri.toString(),
          mimeType: 'application/json',
          text: const JsonEncoder.withIndent('  ')
              .convert(quotasSnapshot(await snapshot(), now())),
        ),
      ],
    ),
  );
  server.registerResource(
    'quota_alerts',
    quotasAlertsResourceUri,
    (
      description: 'Last MCP quota alerts fired by the subscription loop. '
          'JSON object with schema quotabot.alerts.v1 and alert metadata only.',
      mimeType: 'application/json',
    ),
    (uri, extra) async => ReadResourceResult(
      contents: [
        TextResourceContents(
          uri: uri.toString(),
          mimeType: 'application/json',
          text: const JsonEncoder.withIndent('  ')
              .convert(subscriptionHub.alertsResource()),
        ),
      ],
    ),
  );
  _registerQuotaResourceSubscriptions(server, subscriptionHub);
  return subscriptionHub;
}
