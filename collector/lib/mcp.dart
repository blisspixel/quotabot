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
import 'litellm_metrics.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'profiles.dart';
import 'provider_filters.dart';
import 'registry.dart';
import 'schema_contracts.dart';
import 'util.dart';

const quotabotMcpName = 'quotabot';
const quotabotMcpVersion = '0.5.13';
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
    return {
      'schema': quotabotHeadroomV1SchemaId,
      'as_of': now,
      'provider': null,
      'reason': 'no live quota available',
    };
  }
  final a = providerAvailability(best, now);
  return {
    'schema': quotabotHeadroomV1SchemaId,
    'as_of': now,
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
  bool preferLocal = false,
  Map<String, double> costPenaltyByProvider = const {},
  double costWeight = kDefaultRoutingCostWeight,
  Map<String, double> pipePenaltyByProvider = const {},
}) {
  final response = suggestRoute(
    providers,
    now,
    burnStatsByProvider: burnStatsByProvider,
    leaseDiscountFor: (provider, account) =>
        leaseDiscountFor(activeLeases, provider, account),
    preferLocal: preferLocal,
    costPenaltyByProvider: costPenaltyByProvider,
    costWeight: costWeight,
    pipePenaltyByProvider: pipePenaltyByProvider,
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
  bool preferLocal = false,
  Map<String, double> costPenaltyByProvider = const {},
  double costWeight = kDefaultRoutingCostWeight,
  Map<String, double> pipePenaltyByProvider = const {},
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
    preferLocal: preferLocal,
    costPenaltyByProvider: costPenaltyByProvider,
    costWeight: costWeight,
    pipePenaltyByProvider: pipePenaltyByProvider,
  ).toJson();
  return {
    'schema': 'quotabot.decision.v1',
    'as_of': now,
    'risk_z': suggestion['risk_z'],
    'routing_policy': suggestion['routing_policy'],
    'waste_weight': suggestion['waste_weight'],
    'waste_threshold_percent': suggestion['waste_threshold_percent'],
    'waste_max_hours': suggestion['waste_max_hours'],
    'cost_weight': suggestion['cost_weight'],
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
/// `task` profile overlaid with explicit capability/tier/budget filters.
({ModelRequirements requirements, String? error}) _requirementsFromArgs(
  Map<String, dynamic> args,
) {
  final rawBudget = args['budget'];
  final budget = rawBudget is String || rawBudget == null
      ? modelBudgetPolicyFromName(rawBudget as String?)
      : null;
  if (budget == null) {
    final label = rawBudget == null ? 'null' : jsonEncode(rawBudget);
    return (
      requirements: const ModelRequirements(),
      error: 'unknown budget policy: $label',
    );
  }
  final explicit = ModelRequirements(
    minContextTokens: (args['min_context'] as num?)?.toInt(),
    requireTools: args['require_tools'] == true,
    requireVision: args['require_vision'] == true,
    requireReasoning: args['require_reasoning'] == true,
    tierFloor: args['tier_floor'] as String?,
    tierCeiling: args['tier_ceiling'] as String?,
    budgetPolicy: budget,
  );
  return (
    requirements: taskProfile(args['task'] as String?).merge(explicit),
    error: null,
  );
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
      'schema': quotabotCheckV1SchemaId,
      'as_of': now,
      'provider': name,
      if (account != null) 'account': account,
      'error':
          account == null ? 'unknown provider' : 'unknown provider/account',
    };
  }
  final q = match.first;
  final a = providerAvailability(q, now);
  return {
    'schema': quotabotCheckV1SchemaId,
    'as_of': now,
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

/// One per-model quota entry, for providers that meter each model family from
/// its own pool (Antigravity). The `windows` summary stays the headline.
final _modelQuotaSchema = JsonSchema.object(
  description: 'Per-model quota, when a provider meters models separately.',
  properties: {
    'model': JsonSchema.string(description: 'Provider model name.'),
    'used_percent': JsonSchema.number(
        description: 'Percent of the pool consumed (0..100).'),
    'resets_at': JsonSchema.integer(description: 'Reset epoch seconds.'),
    'category':
        JsonSchema.string(description: 'Provider speed label, e.g. "Fast".'),
    'note':
        JsonSchema.string(description: 'Provider badge, e.g. "Limited time".'),
  },
  required: ['model'],
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
    'suspect': JsonSchema.string(
      description: 'Set when this read is implausible versus the last one '
          '(drift canary); the number is still shown, only flagged.',
    ),
    'per_machine': JsonSchema.boolean(
      description: 'True when the read reflects only this machine, not the '
          'account across all devices (a local-only source that can undercount).',
    ),
    'windows': JsonSchema.array(items: _windowSchema),
    'model_quotas': JsonSchema.array(items: _modelQuotaSchema),
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
    'account_filter': JsonSchema.string(
      description: 'Exact account filter applied to this snapshot, when any.',
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
/// Fields `_withProfileMeta` injects into every profile-aware tool response,
/// declared once so each output schema lists them instead of relying on
/// additive permissiveness.
final Map<String, JsonSchema> _profileMetaProperties = {
  'profile': JsonSchema.string(
    description: 'Named local profile applied to this response, when any.',
  ),
  'account_filter': JsonSchema.string(
    description: 'Exact account filter applied to this response, when any.',
  ),
  'error': JsonSchema.string(
    description: 'Profile, filter, or argument error note, when any.',
  ),
};

final mostHeadroomOutputSchema = JsonSchema.object(
  description: 'The connected provider with the most remaining headroom now.',
  properties: {
    ..._profileMetaProperties,
    'schema': JsonSchema.string(
      description: 'Schema id, always "quotabot.headroom.v1".',
    ),
    'as_of': JsonSchema.integer(description: 'Epoch seconds when produced.'),
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
  required: ['schema', 'as_of', 'provider'],
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
    'pipe_discount_percent': JsonSchema.number(
      description:
          'Recent local LiteLLM pipe-health discount applied to effective headroom.',
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
    'routing_score': JsonSchema.number(
      description:
          'Confidence-weighted risk-adjusted runway score used to rank metered subscriptions.',
    ),
    'runway_hours': JsonSchema.number(
      description: 'Risk-adjusted runway hours before confidence is applied.',
    ),
    'projected_waste_percent': JsonSchema.number(
      description:
          'Included quota percent projected to expire unused at reset.',
    ),
    'waste_boost': JsonSchema.number(
      description: 'Use-it-or-lose-it multiplier applied to routing_score.',
    ),
    'cost_penalty': JsonSchema.number(
      description: 'Caller-supplied relative cost penalty for this provider.',
    ),
    'cost_discount': JsonSchema.number(
      description:
          'Multiplier applied to routing_score for explicit cost penalties.',
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
    ..._profileMetaProperties,
    'schema': JsonSchema.string(),
    'as_of':
        JsonSchema.integer(description: 'Epoch seconds the decision was made.'),
    'risk_z': JsonSchema.number(description: 'Risk aversion used (0 = mean).'),
    'routing_policy': JsonSchema.string(
      description: '"balanced" or "local_first".',
    ),
    'waste_weight': JsonSchema.number(
      description: 'Projected-waste multiplier weight used for ranking.',
    ),
    'waste_threshold_percent': JsonSchema.number(
      description: 'Projected-waste floor required before a route is boosted.',
    ),
    'waste_max_hours': JsonSchema.integer(
      description: 'Maximum reset horizon for projected-waste boosting.',
    ),
    'cost_weight': JsonSchema.number(
      description: 'Explicit cost-penalty weight used for ranking.',
    ),
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
    ..._profileMetaProperties,
    'schema': JsonSchema.string(),
    'as_of': JsonSchema.integer(),
    'risk_z': JsonSchema.number(),
    'routing_policy': JsonSchema.string(),
    'waste_weight': JsonSchema.number(),
    'waste_threshold_percent': JsonSchema.number(),
    'waste_max_hours': JsonSchema.integer(),
    'cost_weight': JsonSchema.number(),
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
    ..._profileMetaProperties,
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
    'quota_backed': JsonSchema.boolean(),
    'local_readiness': JsonSchema.string(
      description: 'For local-runtime models: loaded or cold.',
    ),
    'context_tokens': JsonSchema.integer(),
    'max_output_tokens': JsonSchema.integer(),
    'tools': JsonSchema.boolean(),
    'vision': JsonSchema.boolean(),
    'reasoning': JsonSchema.string(),
    'tier': JsonSchema.string(
      description: "The provider's own tier: light, standard, or flagship.",
    ),
    'quota_included_until': JsonSchema.integer(
      description:
          'Epoch second when a temporary included-quota model stops being quota-backed.',
    ),
    'size_bytes': JsonSchema.integer(
      description: 'For local-runtime models: installed model size in bytes.',
    ),
    'vram_bytes': JsonSchema.integer(
      description: 'For loaded local-runtime models: VRAM bytes when known.',
    ),
    'quant': JsonSchema.string(
      description: 'For local-runtime models: quantization label when known.',
    ),
    'loaded': JsonSchema.boolean(
      description: 'For local-runtime models: currently loaded in memory.',
    ),
    'source': JsonSchema.string(
      description: 'Data source of the gating provider, e.g. "manual" for '
          'self-reported entries. Absent for built-in adapters.',
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
    'budget': JsonSchema.string(
      description:
          'Budget envelope: any, quota, or local. quota allows measured built-in quota plans plus local runtimes, but not self-reported manual quota.',
    ),
    'use_expiring_quota': JsonSchema.boolean(
      description:
          'Prefer a qualifying measured quota plan when local burn analytics project that included quota would expire unused soon.',
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

final _routingInputSchema = JsonSchema.object(
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
    'local_first': JsonSchema.boolean(
      description:
          'Prefer a local runtime before spending subscription quota when one is available.',
    ),
    'cost_penalties': JsonSchema.object(
      description:
          'Optional provider-id to relative cost-penalty map. Values are explicit caller policy, not inferred prices.',
    ),
    'cost_weight': JsonSchema.number(
      description:
          'Optional cost penalty weight, 0..10. Defaults to 1 when cost_penalties is provided.',
    ),
  },
);

/// Output schema for `suggest_model`.
final suggestModelOutputSchema = JsonSchema.object(
  description: 'One concrete model recommended for a task profile.',
  properties: {
    ..._profileMetaProperties,
    'schema': JsonSchema.string(),
    'generated_at': JsonSchema.integer(),
    'budget_policy': JsonSchema.string(),
    'recommended': _nullable(_modelEntrySchema),
    'reason': JsonSchema.string(),
    'use_expiring_quota': JsonSchema.boolean(),
    'expiring_quota_threshold_percent': JsonSchema.number(),
    'expiring_quota_max_hours': JsonSchema.integer(),
    'expiring_quota': JsonSchema.object(
      properties: {
        'provider': JsonSchema.string(),
        'account': JsonSchema.string(),
        'projected_waste_percent': JsonSchema.number(),
        'resets_at': JsonSchema.integer(),
        'burn_percent_per_hour': JsonSchema.number(),
      },
      required: ['provider', 'account', 'projected_waste_percent', 'resets_at'],
    ),
    'ranked': JsonSchema.array(items: _modelEntrySchema),
  },
  required: ['schema', 'reason', 'ranked'],
);

/// Output schema for `list_models`.
final listModelsOutputSchema = JsonSchema.object(
  description: 'Every model the user can route to now, with per-model budget.',
  properties: {
    ..._profileMetaProperties,
    'schema': JsonSchema.string(),
    'generated_at': JsonSchema.integer(),
    'catalog_updated': JsonSchema.string(
      description: 'Date the cloud capability catalog was last refreshed.',
    ),
    'budget_policy': JsonSchema.string(),
    'models': JsonSchema.array(items: _modelEntrySchema),
  },
  required: ['schema', 'generated_at', 'models'],
);

/// Output schema for `check_provider_availability`.
final availabilityOutputSchema = JsonSchema.object(
  description: 'Whether one named provider has quota available now.',
  properties: {
    ..._profileMetaProperties,
    'schema': JsonSchema.string(
      description: 'Schema id, always "quotabot.check.v1".',
    ),
    'as_of': JsonSchema.integer(description: 'Epoch seconds when produced.'),
    'provider': _nullable(JsonSchema.string()),
    'account': JsonSchema.string(),
    'available': JsonSchema.boolean(),
    'headroom_percent': _nullable(JsonSchema.number()),
    'resets_at': _nullable(JsonSchema.integer()),
    'stale': JsonSchema.boolean(),
  },
  required: ['schema', 'as_of', 'provider'],
);

/// Returns the current quota snapshot. Injected so the server and its tests
/// share one wiring path while feeding real or fixture data respectively.
typedef SnapshotProvider = Future<List<ProviderQuota>> Function();

typedef ProfileLoader = QuotaProfile? Function(String name);

/// Returns recent burn and its uncertainty per provider id. Kept out of the pure
/// layer because the real implementation reads history from disk.
typedef BurnProvider = Map<String, BurnStat> Function(
  Iterable<ProviderQuota> providers,
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

({Map<String, double> penalties, double weight, String? error})
    _routingCostPolicy(Map<String, dynamic> args) {
  final parsed = parseProviderCostPenalties(args['cost_penalties']);
  if (!parsed.ok) {
    return (penalties: const {}, weight: 0.0, error: parsed.error);
  }
  final rawWeight = args['cost_weight'];
  var weight = parsed.penalties.isEmpty ? 0.0 : 1.0;
  if (rawWeight != null) {
    final parsedWeight = rawWeight is num ? rawWeight.toDouble() : null;
    if (parsedWeight == null ||
        !parsedWeight.isFinite ||
        parsedWeight < 0 ||
        parsedWeight > kMaxRoutingCostWeight) {
      return (
        penalties: const {},
        weight: 0.0,
        error: 'cost_weight must be between 0 and 10',
      );
    }
    weight = parsedWeight;
  }
  return (penalties: parsed.penalties, weight: weight, error: null);
}

List<ProviderQuota> _filterAccount(
  List<ProviderQuota> providers,
  String? account,
) {
  if (account == null) return providers;
  return providers.where((provider) => provider.account == account).toList();
}

Future<_ProfiledSnapshot> _profiledSnapshot(
  Map<String, dynamic> args,
  SnapshotProvider snapshot,
  ProfileLoader profileLoader,
) async {
  final account = _accountFilter(args['account']);
  final exclude = parseProviderExclusions(args['exclude']);
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
      providers: filterExcludedProviders(
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
  final providers = filterExcludedProviders(
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
      final burnStats = burnByProvider(data, n);
      final suggestion = suggestRoute(
        data,
        n,
        burnStatsByProvider: burnStats,
        pipePenaltyByProvider:
            loadRoutedRequestSummary().pipePenaltyByProvider(now: n),
      );
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
  Map<String, double> pipePenaltyByProvider,
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
    pipePenaltyByProvider: pipePenaltyByProvider,
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

Map<String, dynamic> _modelRegistryError(int now, String error) => {
      'schema': 'quotabot.models.v1',
      'generated_at': now,
      'catalog_updated': kCatalogUpdated,
      'budget_policy': ModelBudgetPolicy.any.wireName,
      'models': const <Object?>[],
      'error': error,
    };

Map<String, dynamic> _modelSuggestionError(int now, String error) => {
      'schema': 'quotabot.suggest_model.v1',
      'generated_at': now,
      'budget_policy': ModelBudgetPolicy.any.wireName,
      'recommended': null,
      'reason': error,
      'ranked': const <Object?>[],
      'error': error,
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
        'low. Pass local_first=true to choose a local runtime before spending '
        'subscription quota when one is available. Pass cost_penalties only '
        'when the caller has an explicit relative cost policy; quotabot never '
        'infers prices from provider names. Returns the recommended provider, '
        'a human reason, a using_local_fallback flag, a guaranteed fallback, '
        'and the full ranked candidate list. Local runtimes never win on '
        'headroom unless local_first is explicitly set.',
    inputSchema: _routingInputSchema,
    outputSchema: suggestOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      final results = profiled.providers;
      final n = now();
      final activeLeases = leaseStore.active(n);
      final costPolicy = _routingCostPolicy(args);
      if (costPolicy.error != null) {
        final response = suggestRoute(const [], n).toJson();
        response['error'] = costPolicy.error;
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(response, profiled),
        );
      }
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          suggestResponse(
            results,
            n,
            burnStatsByProvider: burnByProvider(results, n),
            activeLeases: activeLeases,
            preferLocal: args['local_first'] == true,
            costPenaltyByProvider: costPolicy.penalties,
            costWeight: costPolicy.weight,
            pipePenaltyByProvider:
                loadRoutedRequestSummary().pipePenaltyByProvider(now: n),
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
        'headroom. Accepts the same local_first and explicit cost_penalties '
        'routing policy as suggest_provider.',
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
        'local_first': JsonSchema.boolean(
          description:
              'Prefer a local runtime before spending subscription quota when one is available.',
        ),
        'cost_penalties': JsonSchema.object(
          description:
              'Optional provider-id to relative cost-penalty map. Values are explicit caller policy, not inferred prices.',
        ),
        'cost_weight': JsonSchema.number(
          description:
              'Optional cost penalty weight, 0..10. Defaults to 1 when cost_penalties is provided.',
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
      final costPolicy = _routingCostPolicy(args);
      if (costPolicy.error != null) {
        final response = decideNowResponse(
          const CachedQuotaSnapshot.empty(),
          n,
          maxAgeSeconds: boundedMaxAge,
        );
        response['error'] = costPolicy.error;
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(response, profiled),
        );
      }
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
            burnStatsByProvider: burnByProvider(profiled.providers, n),
            activeLeases: activeLeases,
            preferLocal: args['local_first'] == true,
            costPenaltyByProvider: costPolicy.penalties,
            costWeight: costPolicy.weight,
            pipePenaltyByProvider:
                loadRoutedRequestSummary().pipePenaltyByProvider(now: n),
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
        'or for an explicit provider/account. The lease reduces that account'
        "'s effective headroom for later suggestions so parallel agents do not all "
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
      final burnStats = burnByProvider(results, n);
      final pipePenalties =
          loadRoutedRequestSummary().pipePenaltyByProvider(now: n);
      final explicit = normalizeLeaseText(args['provider']) != null;
      final idempotencyKey = normalizeLeaseText(args['idempotency_key']);
      // An idempotent retry with an auto-selected target must reuse the
      // existing lease. The first lease's discount can flip the ranking, so
      // re-selecting would reserve a second provider under the same key and
      // double-count the discount. Explicit-provider retries are already
      // matched provider+account+key by the store, so this only covers the
      // auto-select path.
      if (!explicit && idempotencyKey != null) {
        for (final lease in activeLeases) {
          if (lease.idempotencyKey == idempotencyKey) {
            return CallToolResult.fromStructuredContent(
              _withProfileMeta(
                _reserveJson(
                  RouteLeaseReservation(
                    reserved: true,
                    reused: true,
                    reason: 'reused the active lease for this idempotency key',
                    lease: lease,
                    activeLeases: activeLeases,
                  ),
                  n,
                ),
                profiled,
              ),
            );
          }
        }
      }
      final target = _explicitReserveTarget(
            results,
            n,
            args,
            activeLeases,
            burnStats,
            pipePenalties,
          ) ??
          (explicit
              ? null
              : suggestRoute(
                  results,
                  n,
                  burnStatsByProvider: burnStats,
                  leaseDiscountFor: (provider, account) =>
                      leaseDiscountFor(activeLeases, provider, account),
                  pipePenaltyByProvider: pipePenalties,
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
        'this to pick a concrete model with budget, not just a provider. Add '
        'budget=local for a hard local-only cap or budget=quota for measured '
        'quota plans plus local runtimes.',
    inputSchema: _modelFilterInputSchema,
    outputSchema: listModelsOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      final requirements = _requirementsFromArgs(args);
      final n = now();
      if (requirements.error != null) {
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(
            _modelRegistryError(n, requirements.error!),
            profiled,
          ),
        );
      }
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          modelRegistryJson(
            profiled.providers,
            n,
            catalog: catalog,
            requirements: requirements.requirements,
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
        'filter as list_models, including budget=local or budget=quota. quotabot '
        'never reads the task; the caller supplies the profile, and tiers are the '
        "provider's own, not a quality ranking. Pass use_expiring_quota=true to "
        'let soon-resetting measured included quota outrank local capacity when '
        'projected waste is high.',
    inputSchema: _modelFilterInputSchema,
    outputSchema: suggestModelOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final profiled = await _profiledSnapshot(args, snapshot, profileLoader);
      final n = now();
      final requirements = _requirementsFromArgs(args);
      if (requirements.error != null) {
        return CallToolResult.fromStructuredContent(
          _withProfileMeta(
            _modelSuggestionError(n, requirements.error!),
            profiled,
          ),
        );
      }
      final burnStats = burnByProvider(profiled.providers, n);
      final useExpiringQuota = args['use_expiring_quota'] == true;
      return CallToolResult.fromStructuredContent(
        _withProfileMeta(
          suggestModel(
            profiled.providers,
            n,
            catalog: catalog,
            requirements: requirements.requirements,
            useExpiringQuota: useExpiringQuota,
            expiringQuotaByProvider: useExpiringQuota
                ? expiringQuotaSignals(
                    profiled.providers,
                    n,
                    burnStatsByProvider: burnStats,
                  )
                : const <String, ExpiringQuotaSignal>{},
          ).toJson(n),
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
