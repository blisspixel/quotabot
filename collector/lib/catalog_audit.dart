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

  /// True when this endpoint publishes OpenAI-style `shutdown_date` values.
  /// Other model lists stay presence-only. A missing field is not a date.
  final bool publishesShutdownDates;

  const ModelListSource({
    required this.provider,
    required this.endpoint,
    this.requiredEnv = const [],
    this.headers = _noHeaders,
    this.includeModel = _includeAllModels,
    this.maxPages = 20,
    this.publishesShutdownDates = false,
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

  /// True when this source publishes shutdown dates and the read succeeded.
  final bool shutdownDatesChecked;

  /// Catalog models on this source that announced a shutdown date.
  final List<CatalogShutdown> shutdowns;

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
    this.shutdownDatesChecked = false,
    this.shutdowns = const [],
  });

  bool get hasDrift => missingFromCatalog.isNotEmpty || catalogOnly.isNotEmpty;

  bool get hasActionableShutdown =>
      shutdowns.any((shutdown) => shutdown.actionable);

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
        'shutdown_dates_checked': shutdownDatesChecked,
        if (shutdowns.isNotEmpty)
          'shutdowns': shutdowns.map((shutdown) => shutdown.toJson()).toList(),
      };
}

/// Days from the audit date, including today, that make an announced shutdown
/// fail the audit. Farther dates stay in the report and do not change the exit.
const int kCatalogShutdownNoticeDays = 30;

/// One catalog model with a provider-announced shutdown date.
class CatalogShutdown {
  final String modelId;
  final String shutdownDate;
  final int daysRemaining;
  final bool actionable;

  const CatalogShutdown({
    required this.modelId,
    required this.shutdownDate,
    required this.daysRemaining,
    required this.actionable,
  });

  Map<String, dynamic> toJson() => {
        'model': modelId,
        'shutdown_date': shutdownDate,
        'days_remaining': daysRemaining,
        'actionable': actionable,
      };
}

/// A model id from a list endpoint, with a validated shutdown date when the
/// payload announced one.
class ListedModel {
  final String id;
  final String? shutdownDate;

  const ListedModel(this.id, this.shutdownDate);
}

/// A curated `quotaIncludedUntil` date-fact that has elapsed: the model is past
/// its promised included-quota window, so the catalog entry is a stale claim a
/// maintainer should re-verify. Routing already treats a passed date as expired
/// (the model stops being quota-backed); this is the freshness signal to update
/// the data itself, not a routing bug.
class ElapsedIncludedQuota {
  final String provider;
  final String modelId;
  final int includedUntil;

  const ElapsedIncludedQuota({
    required this.provider,
    required this.modelId,
    required this.includedUntil,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'model': modelId,
        'included_until': includedUntil,
      };
}

class CatalogAuditReport {
  final int generatedAt;
  final String catalogUpdated;
  final List<ProviderCatalogAudit> providers;

  /// Curated included-quota date-facts that have already passed as of
  /// [generatedAt]. A freshness prompt, not an error.
  final List<ElapsedIncludedQuota> elapsedIncludedQuota;

  const CatalogAuditReport({
    required this.generatedAt,
    required this.catalogUpdated,
    required this.providers,
    this.elapsedIncludedQuota = const [],
  });

  bool get hasDrift => providers.any((p) => p.hasDrift);

  bool get hasErrors => providers.any((p) => !p.ok && !p.skipped);

  /// True when at least one curated included-quota window has elapsed. A prompt
  /// to re-verify the catalog, surfaced separately from drift and errors.
  bool get hasElapsedIncludedQuota => elapsedIncludedQuota.isNotEmpty;

  /// True when a catalog model is already shut down or shuts down inside
  /// [kCatalogShutdownNoticeDays].
  bool get hasActionableShutdown =>
      providers.any((provider) => provider.hasActionableShutdown);

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
        if (elapsedIncludedQuota.isNotEmpty)
          'elapsed_included_quota':
              elapsedIncludedQuota.map((e) => e.toJson()).toList(),
        'providers': providers.map((p) => p.toJson()).toList(),
      };
}

/// Curated included-quota windows in [catalog] whose end date is at or before
/// [now]. Pure and network-free, so it runs even when every provider audit is
/// skipped for lack of an API key.
List<ElapsedIncludedQuota> elapsedIncludedQuotaFacts(
  Map<String, List<ModelInfo>> catalog,
  int now,
) {
  final out = <ElapsedIncludedQuota>[];
  catalog.forEach((provider, models) {
    for (final m in models) {
      final until = m.quotaIncludedUntil;
      if (until != null && now >= until) {
        out.add(ElapsedIncludedQuota(
          provider: provider,
          modelId: m.id,
          includedUntil: until,
        ));
      }
    }
  });
  return out;
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
            ? (provider.hasDrift
                ? 'drift'
                : provider.hasActionableShutdown
                    ? 'shutdown'
                    : 'clean')
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
      lines.add(
        provider.shutdownDatesChecked
            ? '  shutdown dates: checked'
            : '  shutdown dates: not published by this source',
      );
      if (provider.shutdowns.isNotEmpty) {
        if (includeModelIds) {
          for (final shutdown in provider.shutdowns) {
            lines.add(
              '  shutdown ${shutdown.modelId} on ${shutdown.shutdownDate} '
              '(${_shutdownWhen(shutdown.daysRemaining)})',
            );
          }
        } else {
          final actionable = provider.shutdowns
              .where((shutdown) => shutdown.actionable)
              .length;
          lines.add('  announced shutdowns: ${provider.shutdowns.length}');
          lines.add('  actionable shutdowns: $actionable');
        }
      }
    } else {
      lines.add('  shutdown dates: not checked');
    }
  }
  if (report.elapsedIncludedQuota.isNotEmpty) {
    lines.add('');
    lines
        .add('stale included-quota facts (re-verify and refresh the catalog):');
    for (final e in report.elapsedIncludedQuota) {
      lines.add('  ${e.provider} ${e.modelId}: included-quota window ended '
          '${_isoDate(e.includedUntil)}');
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
  lines.add(
    'Shutdown dates are read only from sources that publish them. '
    'A catalog model that is already shut down, or shuts down within '
    '$kCatalogShutdownNoticeDays days, exits nonzero.',
  );
  return lines.join('\n');
}

String _shutdownWhen(int daysRemaining) {
  if (daysRemaining < 0) {
    final days = -daysRemaining;
    return '$days day${days == 1 ? '' : 's'} past shutdown';
  }
  if (daysRemaining == 0) return 'shuts down today';
  return 'shuts down in $daysRemaining day${daysRemaining == 1 ? '' : 's'}';
}

/// Exit code for the catalog audit tool. An actionable shutdown fails on its
/// own. Id drift and transport errors still require their flags.
int catalogAuditExitCode(
  CatalogAuditReport report, {
  required bool failOnDrift,
  required bool failOnError,
}) {
  if (report.hasActionableShutdown) return 1;
  if (failOnDrift && report.hasDrift) return 1;
  if (failOnError && report.hasErrors) return 1;
  return 0;
}

String _auditDiffLine({
  required String label,
  required List<String> values,
  required bool includeModelIds,
}) {
  if (includeModelIds) return '  $label: ${values.join(', ')}';
  return '  $label: ${values.length}';
}

/// UTC calendar date (`YYYY-MM-DD`) for an epoch second, for human-readable
/// stale-fact lines.
String _isoDate(int epochSeconds) =>
    DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true)
        .toIso8601String()
        .split('T')
        .first;

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
        now: now,
      ));
    }
    return CatalogAuditReport(
      generatedAt: now,
      catalogUpdated: kCatalogUpdated,
      providers: providerAudits,
      elapsedIncludedQuota: elapsedIncludedQuotaFacts(catalog, now),
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
  required int now,
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
      now: now,
    );
  }

  try {
    var uri = source.endpoint;
    final endpointIds = <String>{};
    final listed = <ListedModel>[];
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
          now: now,
        );
      }
      final decoded = jsonDecode(response.body);
      final pageModels =
          parseListedModels(decoded, includeModel: source.includeModel);
      listed.addAll(pageModels);
      endpointIds.addAll(pageModels.map((model) => model.id));
      final next = _nextPageUri(uri, decoded);
      if (next == null) {
        return _providerAudit(
          source: source,
          catalogIds: catalogIds,
          endpointIds: endpointIds.toList()..sort(),
          ok: true,
          skipped: false,
          error: null,
          listed: listed,
          now: now,
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
      now: now,
    );
  } on TimeoutException {
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: const [],
      ok: false,
      skipped: false,
      error: 'timeout',
      now: now,
    );
  } on FormatException {
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: const [],
      ok: false,
      skipped: false,
      error: 'invalid JSON',
      now: now,
    );
  } on Object catch (error) {
    return _providerAudit(
      source: source,
      catalogIds: catalogIds,
      endpointIds: const [],
      ok: false,
      skipped: false,
      error: error.runtimeType.toString(),
      now: now,
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
  List<ListedModel> listed = const [],
  required int now,
}) {
  final catalogSet = catalogIds.toSet();
  final endpointSet = endpointIds.toSet();
  final missing = endpointSet.difference(catalogSet).toList()..sort();
  final catalogOnly = catalogSet.difference(endpointSet).toList()..sort();
  final shutdownDatesChecked = source.publishesShutdownDates && ok;
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
    shutdownDatesChecked: shutdownDatesChecked,
    shutdowns: catalogShutdownFindings(
      catalogIds: catalogIds,
      shutdownDates: shutdownDatesById(listed),
      now: now,
      checked: shutdownDatesChecked,
    ),
  );
}

List<String> _catalogIds(List<ModelInfo> models) =>
    (models.map((m) => m.id).toSet().toList()..sort());

List<String> parseModelList(
  Object? decoded, {
  ModelFilter includeModel = _includeAllModels,
}) {
  final ids = <String>{};
  for (final model in parseListedModels(decoded, includeModel: includeModel)) {
    ids.add(model.id);
  }
  return ids.toList()..sort();
}

/// Every accepted model in [decoded], including repeats so a later page can
/// confirm or contradict a shutdown date.
List<ListedModel> parseListedModels(
  Object? decoded, {
  ModelFilter includeModel = _includeAllModels,
}) {
  final listed = <ListedModel>[];

  void add(String? rawId, Map<String, dynamic>? raw) {
    if (rawId == null) return;
    final id = _normalizeModelId(rawId);
    if (id.isEmpty || !includeModel(id, raw)) return;
    listed.add(ListedModel(
      id,
      raw == null ? null : parseShutdownDate(raw['shutdown_date']),
    ));
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

  return listed;
}

final _shutdownDatePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// A provider `shutdown_date`, or null when the value is absent, null, or
/// not a real UTC calendar date. `2026-02-31` is rejected rather than rolled
/// into March.
String? parseShutdownDate(Object? value) {
  if (value is! String) return null;
  final match = _shutdownDatePattern.firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return value;
}

/// One date per id. The first real date sticks. A later null does not erase
/// it, and a null followed by a date adopts that date. Two different dates
/// drop the finding, and a later page cannot put a date back.
Map<String, String?> shutdownDatesById(Iterable<ListedModel> models) {
  final dates = <String, String?>{};
  final conflicts = <String>{};
  for (final model in models) {
    if (conflicts.contains(model.id)) {
      dates[model.id] = null;
      continue;
    }
    final next = model.shutdownDate;
    if (!dates.containsKey(model.id)) {
      dates[model.id] = next;
      continue;
    }
    final current = dates[model.id];
    if (current == null) {
      if (next != null) dates[model.id] = next;
      continue;
    }
    if (next == null || next == current) continue;
    conflicts.add(model.id);
    dates[model.id] = null;
  }
  return dates;
}

/// Shutdown findings for catalog ids only. Endpoint-only ids, missing dates,
/// and an unchecked source contribute nothing.
List<CatalogShutdown> catalogShutdownFindings({
  required Iterable<String> catalogIds,
  required Map<String, String?> shutdownDates,
  required int now,
  required bool checked,
}) {
  if (!checked) return const [];
  final instant = DateTime.fromMillisecondsSinceEpoch(now * 1000, isUtc: true);
  final today = DateTime.utc(instant.year, instant.month, instant.day);
  final findings = <CatalogShutdown>[];
  for (final id in catalogIds) {
    final date = shutdownDates[id];
    if (date == null) continue;
    final parts = date.split('-');
    if (parts.length != 3) continue;
    final shutdown = DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final days = shutdown.difference(today).inDays;
    findings.add(CatalogShutdown(
      modelId: id,
      shutdownDate: date,
      daysRemaining: days,
      actionable: days <= kCatalogShutdownNoticeDays,
    ));
  }
  findings.sort((a, b) => a.modelId.compareTo(b.modelId));
  return findings;
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
        publishesShutdownDates: true,
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
