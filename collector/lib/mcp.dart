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

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'analysis.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'registry.dart';
import 'util.dart';

/// A schema that accepts [schema] or an explicit null, for nullable fields.
JsonSchema _nullable(JsonSchema schema) =>
    JsonSchema.union([schema, JsonSchema.nullValue()]);

/// Full normalized quota snapshot. Shared by the `list_quotas` tool and the
/// `quotas://current` resource so both speak the exact same shape.
Map<String, dynamic> quotasSnapshot(List<ProviderQuota> providers, int now) => {
      'schema': 'quotabot.v1',
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
}) =>
    suggestRoute(providers, now, burnStatsByProvider: burnStatsByProvider)
        .toJson();

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
) {
  final name = providerId?.toLowerCase();
  final match = providers.where((q) => q.provider == name);
  if (match.isEmpty) {
    return {'provider': name, 'error': 'unknown provider'};
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
  },
  required: ['schema', 'reason', 'using_local_fallback', 'fallback', 'ranked'],
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

/// Returns recent burn and its uncertainty per provider id. Kept out of the pure
/// layer because the real implementation reads history from disk.
typedef BurnProvider = Map<String, BurnStat> Function(
  Iterable<String> providers,
  int now,
);

/// Shared read-only annotations for every quotabot tool: each reads provider
/// metadata, modifies nothing, is safe to repeat, and reaches external services.
const _readOnly = ToolAnnotations(
  readOnlyHint: true,
  idempotentHint: true,
  destructiveHint: false,
  openWorldHint: true,
);

/// Registers quotabot's tools and the `quotas://current` resource on [server].
///
/// This is the single wiring point shared by `bin/mcp_server.dart` (which feeds
/// live data) and the tests (which feed fixtures), so there is exactly one
/// definition of each tool's schema, annotations, and behavior. [snapshot] and
/// [burnByProvider] are injected; [now] defaults to the wall clock and is
/// overridden in tests for determinism.
void registerQuotabotTools(
  McpServer server, {
  required SnapshotProvider snapshot,
  required BurnProvider burnByProvider,
  int Function() now = nowEpoch,
  Map<String, List<ModelInfo>> catalog = kModelCatalog,
}) {
  server.registerTool(
    'list_quotas',
    title: 'List quotas',
    description:
        'Return the current usage quota for every connected AI subscription '
        '(Codex, Claude, Grok, Antigravity, Kiro, Cursor, Windsurf) and local '
        'runtime as JSON. Per provider: account, plan, ok/stale, and rolling '
        'windows (label, used_percent or used/limit, resets_at). Longer windows '
        'that are spent are the binding constraint.',
    inputSchema: JsonSchema.object(properties: {}),
    outputSchema: quotasSnapshotOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async => CallToolResult.fromStructuredContent(
      quotasSnapshot(await snapshot(), now()),
    ),
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
    inputSchema: JsonSchema.object(properties: {}),
    outputSchema: mostHeadroomOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async => CallToolResult.fromStructuredContent(
      mostHeadroomResponse(await snapshot(), now()),
    ),
  );

  server.registerTool(
    'suggest_provider',
    title: 'Suggest provider',
    description:
        'Recommend which provider to route the next request to. Prefers the '
        'metered subscription with the most remaining headroom (above a comfort '
        'threshold, after discounting recent burn), and falls back to a local '
        'runtime (e.g. Ollama) when every subscription is low. Returns the '
        'recommended provider, a human reason, a using_local_fallback flag, a '
        'guaranteed fallback, and the full ranked candidate list. Local runtimes '
        'never win on headroom; they are fallbacks only.',
    inputSchema: JsonSchema.object(properties: {}),
    outputSchema: suggestOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async {
      final results = await snapshot();
      final n = now();
      return CallToolResult.fromStructuredContent(
        suggestResponse(
          results,
          n,
          burnStatsByProvider:
              burnByProvider(results.map((q) => q.provider), n),
        ),
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
    inputSchema: JsonSchema.object(
      description: 'Optional capability filter. quotabot never reads the task; '
          'the caller supplies the requirements it needs.',
      properties: {
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
      },
    ),
    outputSchema: listModelsOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async => CallToolResult.fromStructuredContent(
      modelRegistryJson(
        await snapshot(),
        now(),
        catalog: catalog,
        requirements: _requirementsFromArgs(args),
      ),
    ),
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
      },
      required: ['provider'],
    ),
    outputSchema: availabilityOutputSchema,
    annotations: _readOnly,
    callback: (args, extra) async => CallToolResult.fromStructuredContent(
      availabilityResponse(
        await snapshot(),
        now(),
        args['provider'] as String?,
      ),
    ),
  );

  server.registerResource(
    'quotas',
    'quotas://current',
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
}
