/// Audits the committed cloud model catalog against provider-owned model-list
/// endpoints.
///
/// The audit deliberately diffs only provider-native model ids. Capability
/// fields such as context, tools, vision, reasoning, and tier stay curated in
/// `model_catalog.dart` because most model-list endpoints either omit them or
/// expose account-specific metadata that is not enough for a stable routing
/// contract.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'model_catalog.dart';
import 'models.dart';

typedef ModelFilter = bool Function(String id, Map<String, dynamic>? raw);
typedef HeaderBuilder = Map<String, String> Function(String? secret);

class ModelListSource {
  final String provider;
  final Uri endpoint;
  final List<String> requiredEnv;
  final HeaderBuilder headers;
  final ModelFilter includeModel;
  final int maxPages;

  const ModelListSource({
    required this.provider,
    required this.endpoint,
    this.requiredEnv = const [],
    this.headers = _noHeaders,
    this.includeModel = _includeAllModels,
    this.maxPages = 20,
  });

  String? secretFrom(Map<String, String> environment) {
    for (final key in requiredEnv) {
      final value = environment[key];
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  String get authLabel => requiredEnv.join('|');

  String get safeEndpoint {
    if (!endpoint.hasQuery) return endpoint.toString();
    final redacted = <String, String>{};
    for (final entry in endpoint.queryParameters.entries) {
      final key = entry.key.toLowerCase();
      redacted[entry.key] =
          key.contains('key') || key.contains('token') || key.contains('secret')
              ? '<redacted>'
              : entry.value;
    }
    return endpoint.replace(queryParameters: redacted).toString();
  }
}

Map<String, String> _noHeaders(String? _) => const {};

bool _includeAllModels(String _, Map<String, dynamic>? __) => true;

class ProviderCatalogAudit {
  final String provider;
  final String endpoint;
  final String authEnv;
  final bool ok;
  final bool skipped;
  final String? error;
  final List<String> catalogModelIds;
  final List<String> endpointModelIds;
  final List<String> missingFromCatalog;
  final List<String> catalogOnly;

  const ProviderCatalogAudit({
    required this.provider,
    required this.endpoint,
    required this.authEnv,
    required this.ok,
    required this.skipped,
    required this.error,
    required this.catalogModelIds,
    required this.endpointModelIds,
    required this.missingFromCatalog,
    required this.catalogOnly,
  });

  bool get hasDrift => missingFromCatalog.isNotEmpty || catalogOnly.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'endpoint': endpoint,
        if (authEnv.isNotEmpty) 'auth_env': authEnv,
        'ok': ok,
        'skipped': skipped,
        if (error != null) 'error': error,
        'catalog_models': catalogModelIds,
        'endpoint_models': endpointModelIds,
        'missing_from_catalog': missingFromCatalog,
        'catalog_only': catalogOnly,
      };
}

class CatalogAuditReport {
  final int generatedAt;
  final String catalogUpdated;
  final List<ProviderCatalogAudit> providers;

  const CatalogAuditReport({
    required this.generatedAt,
    required this.catalogUpdated,
    required this.providers,
  });

  bool get hasDrift => providers.any((p) => p.hasDrift);

  bool get hasErrors => providers.any((p) => !p.ok && !p.skipped);

  /// Whole days between the catalog's `kCatalogUpdated` date and when the audit
  /// ran, or null when the date does not parse. A dev/CI freshness signal: the
  /// curated capability fields (context, tier, output caps) age silently between
  /// hand updates, so a large age is a prompt to re-verify - not a user-facing
  /// error.
  int? get catalogAgeDays {
    final parsed = DateTime.tryParse(catalogUpdated);
    if (parsed == null) return null;
    // Rebuild as a UTC calendar date so a bare `YYYY-MM-DD` (parsed as local
    // midnight) is compared against the UTC generation time without a
    // timezone-offset day being lost.
    final updated = DateTime.utc(parsed.year, parsed.month, parsed.day);
    final generated =
        DateTime.fromMillisecondsSinceEpoch(generatedAt * 1000, isUtc: true);
    final days = generated.difference(updated).inDays;
    return days < 0 ? 0 : days;
  }

  Map<String, dynamic> toJson() => {
        'schema': 'quotabot.catalog_audit.v1',
        'generated_at': generatedAt,
        'catalog_updated': catalogUpdated,
        if (catalogAgeDays != null) 'catalog_age_days': catalogAgeDays,
        'providers': providers.map((p) => p.toJson()).toList(),
      };
}

String formatCatalogAuditReport(
  CatalogAuditReport report, {
  bool includeModelIds = true,
}) {
  final age = report.catalogAgeDays;
  final lines = <String>[
    'quotabot model catalog audit',
    age == null
        ? 'catalog updated ${report.catalogUpdated}'
        : 'catalog updated ${report.catalogUpdated} ($age day'
            '${age == 1 ? '' : 's'} ago)',
    '',
  ];
  for (final provider in report.providers) {
    final status = provider.skipped
        ? 'skipped'
        : provider.ok
            ? (provider.hasDrift ? 'drift' : 'clean')
            : 'error';
    lines.add('${provider.provider}: $status');
    if (provider.error != null) {
      lines.add('  ${provider.error}');
    }
    if (provider.ok) {
      lines.add(
        '  catalog ${provider.catalogModelIds.length}, '
        'endpoint ${provider.endpointModelIds.length}',
      );
      if (provider.missingFromCatalog.isNotEmpty) {
        lines.add(_auditDiffLine(
          label: 'missing from catalog',
          values: provider.missingFromCatalog,
          includeModelIds: includeModelIds,
        ));
      }
      if (provider.catalogOnly.isNotEmpty) {
        lines.add(_auditDiffLine(
          label: 'catalog only',
          values: provider.catalogOnly,
          includeModelIds: includeModelIds,
        ));
      }
    }
  }
  lines.add('');
  if (includeModelIds) {
    lines.add('Use --json for a machine-readable quotabot.catalog_audit.v1 '
        'report.');
  } else {
    lines.add('Model ids redacted. Re-run locally without --summary for '
        'details.');
  }
  lines.add('Use --fail-on-drift or --fail-on-error when wiring this into CI.');
  return lines.join('\n');
}

String _auditDiffLine({
  required String label,
  required List<String> values,
  required bool includeModelIds,
}) {
  if (includeModelIds) return '  $label: ${values.join(', ')}';
  return '  $label: ${values.length}';
}

Future<CatalogAuditReport> auditModelCatalog({
  required int now,
  Map<String, List<ModelInfo>> catalog = kModelCatalog,
  List<ModelListSource>? sources,
  Map<String, String> environment = const {},
  http.Client? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ownedClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    final providerAudits = <ProviderCatalogAudit>[];
    for (final source in sources ?? defaultModelListSources()) {
      providerAudits.add(await _auditProvider(
        source: source,
        catalogIds: _catalogIds(catalog[source.provider] ?? const []),
        environment: environment,
        client: httpClient,
        timeout: timeout,
      ));
    }
    return CatalogAuditReport(
      generatedAt: now,
      catalogUpdated: kCatalogUpdated,
      providers: providerAudits,
    );
  } finally {
    if (ownedClient) httpClient.close();
  }
}

Future<ProviderCatalogAudit> _auditProvider({
  required ModelListSource source,
  required List<String> catalogIds,
  required Map<String, String> environment,
  required http.Client client,
  required Duration timeout,
}) async {
  final secret = source.secretFrom(environment);
  if (source.requiredEnv.isNotEmpty && secret == null) {
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: const [],
      ok: false,
      skipped: true,
      error: 'missing ${source.authLabel}',
    );
  }

  try {
    var uri = source.endpoint;
    final endpointIds = <String>{};
    for (var page = 0; page < source.maxPages; page++) {
      final response = await client
          .get(uri, headers: source.headers(secret))
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _providerAudit(
          source: source,
          catalogIds: catalogIds,
          endpointIds: const [],
          ok: false,
          skipped: false,
          error: 'HTTP ${response.statusCode}',
        );
      }
      final decoded = jsonDecode(response.body);
      endpointIds.addAll(
        parseModelList(decoded, includeModel: source.includeModel),
      );
      final next = _nextPageUri(uri, decoded);
      if (next == null) {
        return _providerAudit(
          source: source,
          catalogIds: catalogIds,
          endpointIds: endpointIds.toList()..sort(),
          ok: true,
          skipped: false,
          error: null,
        );
      }
      uri = next;
    }
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: endpointIds.toList()..sort(),
      ok: false,
      skipped: false,
      error: 'pagination exceeded ${source.maxPages} pages',
    );
  } on TimeoutException {
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: const [],
      ok: false,
      skipped: false,
      error: 'timeout',
    );
  } on FormatException {
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: const [],
      ok: false,
      skipped: false,
      error: 'invalid JSON',
    );
  } on Object catch (error) {
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: const [],
      ok: false,
      skipped: false,
      error: error.runtimeType.toString(),
    );
  }
}

Uri? _nextPageUri(Uri current, Object? decoded) {
  if (decoded is! Map) return null;
  final nextPageToken = decoded['nextPageToken'];
  if (nextPageToken is String && nextPageToken.isNotEmpty) {
    return _replaceQuery(current, 'pageToken', nextPageToken);
  }
  final hasMore = decoded['has_more'];
  final lastId = decoded['last_id'];
  if (hasMore == true && lastId is String && lastId.isNotEmpty) {
    return _replaceQuery(current, 'after_id', lastId);
  }
  return null;
}

Uri _replaceQuery(Uri current, String key, String value) {
  final query = Map<String, String>.from(current.queryParameters);
  query[key] = value;
  return current.replace(queryParameters: query);
}

ProviderCatalogAudit _providerAudit({
  required ModelListSource source,
  required List<String> catalogIds,
  required List<String> endpointIds,
  required bool ok,
  required bool skipped,
  required String? error,
}) {
  final catalogSet = catalogIds.toSet();
  final endpointSet = endpointIds.toSet();
  final missing = endpointSet.difference(catalogSet).toList()..sort();
  final catalogOnly = catalogSet.difference(endpointSet).toList()..sort();
  return ProviderCatalogAudit(
    provider: source.provider,
    endpoint: source.safeEndpoint,
    authEnv: source.authLabel,
    ok: ok,
    skipped: skipped,
    error: error,
    catalogModelIds: catalogIds,
    endpointModelIds: endpointIds,
    missingFromCatalog: ok ? missing : const [],
    catalogOnly: ok ? catalogOnly : const [],
  );
}

List<String> _catalogIds(List<ModelInfo> models) =>
    (models.map((m) => m.id).toSet().toList()..sort());

List<String> parseModelList(
  Object? decoded, {
  ModelFilter includeModel = _includeAllModels,
}) {
  final ids = <String>{};

  void add(String? rawId, Map<String, dynamic>? raw) {
    if (rawId == null) return;
    final id = _normalizeModelId(rawId);
    if (id.isEmpty || !includeModel(id, raw)) return;
    ids.add(id);
  }

  if (decoded is Map) {
    final data = decoded['data'];
    if (data is List) {
      for (final item in data) {
        if (item is String) {
          add(item, null);
        } else if (item is Map) {
          final raw = item.cast<String, dynamic>();
          add(_firstString(raw, const ['id', 'name', 'model']), raw);
        }
      }
    }

    final models = decoded['models'];
    if (models is List) {
      for (final item in models) {
        if (item is String) {
          add(item, null);
        } else if (item is Map) {
          final raw = item.cast<String, dynamic>();
          add(_firstString(raw, const ['id', 'name', 'model']), raw);
        }
      }
    } else if (models is Map) {
      for (final key in models.keys) {
        if (key is String) add(key, null);
      }
    }
  } else if (decoded is List) {
    for (final item in decoded) {
      if (item is String) {
        add(item, null);
      } else if (item is Map) {
        final raw = item.cast<String, dynamic>();
        add(_firstString(raw, const ['id', 'name', 'model']), raw);
      }
    }
  }

  return ids.toList()..sort();
}

String? _firstString(Map<String, dynamic> raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

String _normalizeModelId(String id) {
  final trimmed = id.trim();
  return trimmed.startsWith('models/')
      ? trimmed.substring('models/'.length)
      : trimmed;
}

List<ModelListSource> defaultModelListSources() => [
      ModelListSource(
        provider: 'codex',
        endpoint: Uri.parse('https://api.openai.com/v1/models'),
        requiredEnv: const ['OPENAI_API_KEY'],
        headers: (secret) => {'Authorization': 'Bearer $secret'},
        includeModel: _includeOpenAiModel,
      ),
      ModelListSource(
        provider: 'claude',
        endpoint:
            Uri.https('api.anthropic.com', '/v1/models', {'limit': '100'}),
        requiredEnv: const ['ANTHROPIC_API_KEY'],
        headers: (secret) => {
          'x-api-key': secret ?? '',
          'anthropic-version': '2023-06-01',
        },
        includeModel: (id, _) => id.startsWith('claude-'),
      ),
      ModelListSource(
        provider: 'grok',
        endpoint: Uri.parse('https://api.x.ai/v1/models'),
        requiredEnv: const ['XAI_API_KEY'],
        headers: (secret) => {'Authorization': 'Bearer $secret'},
        includeModel: _includeGrokModel,
      ),
      ModelListSource(
        provider: 'antigravity',
        endpoint: Uri.https('generativelanguage.googleapis.com',
            '/v1beta/models', {'pageSize': '1000'}),
        requiredEnv: const ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
        headers: (secret) => {'x-goog-api-key': secret ?? ''},
        includeModel: _includeGeminiModel,
      ),
    ];

bool _includeOpenAiModel(String id, Map<String, dynamic>? _) =>
    !_looksNonLanguageModel(id) &&
    (id.startsWith('gpt-') ||
        id.startsWith('chatgpt-') ||
        id.contains('codex') ||
        RegExp(r'^o\d').hasMatch(id));

bool _includeGrokModel(String id, Map<String, dynamic>? _) =>
    id.startsWith('grok-') && !_looksNonLanguageModel(id);

bool _looksNonLanguageModel(String id) {
  const blocked = [
    'audio',
    'embedding',
    'image',
    'imagine',
    'moderation',
    'realtime',
    'search',
    'transcribe',
    'tts',
    'video',
    'whisper',
  ];
  return blocked.any(id.contains);
}

bool _includeGeminiModel(String id, Map<String, dynamic>? raw) {
  if (!id.startsWith('gemini-')) return false;
  final methods = raw?['supportedGenerationMethods'];
  if (methods is! List) return true;
  return methods.contains('generateContent');
}
