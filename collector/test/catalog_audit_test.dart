import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/catalog_audit.dart';
import 'package:quotabot_collector/model_catalog.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

int _epochUtc(int y, int m, int d) =>
    DateTime.utc(y, m, d).millisecondsSinceEpoch ~/ 1000;

const _now = 1782000000;

void main() {
  test('diffs endpoint ids against the committed catalog ids', () async {
    final source = ModelListSource(
      provider: 'codex',
      endpoint: Uri.parse('https://example.test/models'),
    );
    final client = MockClient((request) async => http.Response(
          jsonEncode({
            'data': [
              {'id': 'gpt-current'},
              {'id': 'gpt-new'},
            ],
          }),
          200,
        ));

    final report = await auditModelCatalog(
      now: _now,
      catalog: const {
        'codex': [ModelInfo(id: 'gpt-current'), ModelInfo(id: 'gpt-old')],
      },
      sources: [source],
      client: client,
    );

    final audit = report.providers.single;
    expect(audit.ok, isTrue);
    expect(audit.missingFromCatalog, ['gpt-new']);
    expect(audit.catalogOnly, ['gpt-old']);
    expect(report.hasDrift, isTrue);
  });

  test('skips an authenticated source when its key is absent', () async {
    var called = false;
    final source = ModelListSource(
      provider: 'claude',
      endpoint: Uri.parse('https://example.test/models'),
      requiredEnv: const ['ANTHROPIC_API_KEY'],
    );
    final client = MockClient((request) async {
      called = true;
      return http.Response('{}', 200);
    });

    final report = await auditModelCatalog(
      now: _now,
      catalog: const {
        'claude': [ModelInfo(id: 'claude-sonnet')]
      },
      sources: [source],
      client: client,
    );

    final audit = report.providers.single;
    expect(called, isFalse);
    expect(audit.skipped, isTrue);
    expect(audit.error, 'missing ANTHROPIC_API_KEY');
    expect(audit.missingFromCatalog, isEmpty);
  });

  test('uses configured auth headers without exposing secrets in JSON',
      () async {
    final source = ModelListSource(
      provider: 'grok',
      endpoint: Uri.parse('https://example.test/models'),
      requiredEnv: const ['XAI_API_KEY'],
      headers: (secret) => {'Authorization': 'Bearer $secret'},
    );
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer secret-token');
      return http.Response('{"data":[{"id":"grok-4.3"}]}', 200);
    });

    final report = await auditModelCatalog(
      now: _now,
      catalog: const {
        'grok': [ModelInfo(id: 'grok-4.3')]
      },
      sources: [source],
      environment: const {'XAI_API_KEY': 'secret-token'},
      client: client,
    );

    final json = report.toJson();
    expect(report.hasErrors, isFalse);
    expect(json.toString(), isNot(contains('secret-token')));
    expect(json['schema'], 'quotabot.catalog_audit.v1');
  });

  test('summary report redacts drift model ids', () {
    const report = CatalogAuditReport(
      generatedAt: _now,
      catalogUpdated: '2026-07-01',
      providers: [
        ProviderCatalogAudit(
          provider: 'codex',
          endpoint: 'https://api.openai.com/v1/models',
          authEnv: 'OPENAI_API_KEY',
          ok: true,
          skipped: false,
          error: null,
          catalogModelIds: ['gpt-kept', 'gpt-retired-private'],
          endpointModelIds: ['gpt-kept', 'gpt-new-private'],
          missingFromCatalog: ['gpt-new-private'],
          catalogOnly: ['gpt-retired-private'],
        ),
      ],
    );

    final summary = formatCatalogAuditReport(report, includeModelIds: false);
    expect(summary, contains('codex: drift'));
    expect(summary, contains('missing from catalog: 1'));
    expect(summary, contains('catalog only: 1'));
    expect(summary, contains('Model ids redacted.'));
    expect(summary, isNot(contains('gpt-new-private')));
    expect(summary, isNot(contains('gpt-retired-private')));

    final detailed = formatCatalogAuditReport(report);
    expect(detailed, contains('gpt-new-private'));
    expect(detailed, contains('gpt-retired-private'));
  });

  test('reports HTTP, JSON, timeout, thrown, and pagination errors', () async {
    Future<String?> errorFor(
      http.Client client, {
      int maxPages = 20,
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final report = await auditModelCatalog(
        now: _now,
        catalog: const {'codex': []},
        sources: [
          ModelListSource(
            provider: 'codex',
            endpoint: Uri.parse('https://example.test/models'),
            maxPages: maxPages,
          )
        ],
        client: client,
        timeout: timeout,
      );
      return report.providers.single.error;
    }

    expect(
      await errorFor(MockClient((_) async => http.Response('{}', 503))),
      'HTTP 503',
    );
    expect(
      await errorFor(MockClient((_) async => http.Response('nope', 200))),
      'invalid JSON',
    );
    expect(
      await errorFor(
        MockClient((_) => Future<http.Response>.delayed(
              const Duration(seconds: 1),
              () => http.Response('{}', 200),
            )),
        timeout: const Duration(milliseconds: 1),
      ),
      'timeout',
    );
    expect(
      await errorFor(MockClient((_) async => throw StateError('boom'))),
      'StateError',
    );
    expect(
      await errorFor(
        MockClient((_) async => http.Response(
              '{"data":[],"nextPageToken":"again"}',
              200,
            )),
        maxPages: 1,
      ),
      'pagination exceeded 1 pages',
    );
  });

  test('redacts query strings from endpoint labels', () async {
    final source = ModelListSource(
      provider: 'antigravity',
      endpoint:
          Uri.parse('https://example.test/models?key=secret&pageSize=1000'),
    );
    final report = await auditModelCatalog(
      now: _now,
      catalog: const {'antigravity': []},
      sources: [source],
      client: MockClient((_) async => http.Response('{"models":[]}', 200)),
    );

    expect(report.providers.single.endpoint, isNot(contains('secret')));
    expect(report.providers.single.endpoint, contains('pageSize=1000'));
  });

  test('follows provider pagination tokens', () async {
    final requested = <Uri>[];
    final source = ModelListSource(
      provider: 'antigravity',
      endpoint: Uri.parse('https://example.test/models'),
    );
    final client = MockClient((request) async {
      requested.add(request.url);
      if (request.url.queryParameters['pageToken'] == 'next') {
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-second'}
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'models': [
            {'name': 'models/gemini-first'}
          ],
          'nextPageToken': 'next',
        }),
        200,
      );
    });

    final report = await auditModelCatalog(
      now: _now,
      catalog: const {'antigravity': []},
      sources: [source],
      client: client,
    );

    expect(requested, hasLength(2));
    expect(requested.last.queryParameters['pageToken'], 'next');
    expect(report.providers.single.endpointModelIds,
        ['gemini-first', 'gemini-second']);
  });

  test('follows Anthropic-style after_id pagination', () async {
    final requested = <Uri>[];
    final source = ModelListSource(
      provider: 'claude',
      endpoint: Uri.parse('https://example.test/models'),
    );
    final client = MockClient((request) async {
      requested.add(request.url);
      if (request.url.queryParameters['after_id'] == 'claude-a') {
        return http.Response(
          '{"data":[{"id":"claude-b"}],"has_more":false}',
          200,
        );
      }
      return http.Response(
        '{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}',
        200,
      );
    });

    final report = await auditModelCatalog(
      now: _now,
      catalog: const {'claude': []},
      sources: [source],
      client: client,
    );

    expect(requested, hasLength(2));
    expect(requested.last.queryParameters['after_id'], 'claude-a');
    expect(report.providers.single.endpointModelIds, ['claude-a', 'claude-b']);
  });

  test('parses Gemini model names and filters non-generation models', () {
    final ids = parseModelList(
      {
        'models': [
          {
            'name': 'models/gemini-3-pro',
            'supportedGenerationMethods': ['generateContent'],
          },
          {
            'name': 'models/text-embedding-005',
            'supportedGenerationMethods': ['embedContent'],
          },
        ],
      },
      includeModel: defaultModelListSources()
          .firstWhere((s) => s.provider == 'antigravity')
          .includeModel,
    );

    expect(ids, ['gemini-3-pro']);
  });

  test('default OpenAI filter keeps chat and codex models only', () {
    final ids = parseModelList(
      {
        'data': [
          {'id': 'gpt-5.5'},
          {'id': 'o4-mini'},
          {'id': 'gpt-5.1-codex'},
          {'id': 'gpt-image-2'},
          {'id': 'grok-imagine-image'},
          {'id': 'text-embedding-3-large'},
          {'id': 'omni-moderation-latest'},
        ],
      },
      includeModel: defaultModelListSources()
          .firstWhere((s) => s.provider == 'codex')
          .includeModel,
    );

    expect(ids, ['gpt-5.1-codex', 'gpt-5.5', 'o4-mini']);
  });

  test('parses list, data-string, and models-map shapes', () {
    expect(parseModelList(['plain-model']), ['plain-model']);
    expect(
      parseModelList([
        {'model': 'map-model'},
        {'not_id': 'ignored'},
      ]),
      ['map-model'],
    );
    expect(
      parseModelList({
        'data': ['data-string'],
        'models': <Object, Object>{
          'models/map-key': <String, Object?>{},
          4: {},
        },
      }),
      ['data-string', 'map-key'],
    );
  });

  test('default source metadata and filters are bounded to language models',
      () {
    final sources = defaultModelListSources();
    expect(sources.map((s) => s.provider), [
      'codex',
      'claude',
      'grok',
      'antigravity',
    ]);
    expect(sources.first.headers('token')['Authorization'], 'Bearer token');
    expect(
      sources.firstWhere((s) => s.provider == 'claude').headers('token'),
      containsPair('anthropic-version', '2023-06-01'),
    );
    expect(
      sources.firstWhere((s) => s.provider == 'antigravity').headers('token'),
      containsPair('x-goog-api-key', 'token'),
    );
    expect(
      sources.map((source) => source.publishesShutdownDates),
      [true, false, false, false],
    );
    final grok = sources.firstWhere((s) => s.provider == 'grok').includeModel;
    expect(grok('grok-4.3', null), isTrue);
    expect(grok('grok-imagine-image', null), isFalse);
  });

  test('Haiku 5.5 output cap matches the current provider spec', () {
    final haiku =
        kModelCatalog['claude']!.firstWhere((m) => m.id == 'claude-haiku-5-5');
    // Regression guard: Haiku 4.5 was 64k output and 200k context. Haiku 5.5
    // is 128k output and 1M context. Checked 2026-11-02.
    expect(haiku.maxOutputTokens, 128000);
    expect(haiku.contextTokens, 1000000);
    expect(haiku.tier, 'light');
  });

  test('reports catalog age in whole days', () {
    final report = CatalogAuditReport(
      generatedAt: _epochUtc(2026, 1, 11),
      catalogUpdated: '2026-01-01',
      providers: const [],
    );
    expect(report.catalogAgeDays, 10);
    expect(report.toJson()['catalog_age_days'], 10);
    expect(formatCatalogAuditReport(report), contains('10 days ago'));
  });

  test('clamps a future catalog date to zero age', () {
    final report = CatalogAuditReport(
      generatedAt: _epochUtc(2026, 1, 1),
      catalogUpdated: '2026-02-01',
      providers: const [],
    );
    expect(report.catalogAgeDays, 0);
  });

  test('flags an elapsed included-quota fact, not future or unset ones', () {
    final now = _epochUtc(2026, 7, 11);
    final catalog = {
      'claude': [
        ModelInfo(id: 'past', quotaIncludedUntil: _epochUtc(2026, 7, 7)),
        ModelInfo(id: 'future', quotaIncludedUntil: _epochUtc(2026, 12, 1)),
        const ModelInfo(id: 'normal'),
      ],
    };
    final facts = elapsedIncludedQuotaFacts(catalog, now);
    expect(facts.map((e) => e.modelId), ['past']);
    expect(facts.single.provider, 'claude');
  });

  test('surfaces elapsed included-quota facts in json and text', () {
    final report = CatalogAuditReport(
      generatedAt: _epochUtc(2026, 7, 11),
      catalogUpdated: '2026-07-10',
      providers: const [],
      elapsedIncludedQuota: [
        ElapsedIncludedQuota(
          provider: 'claude',
          modelId: 'claude-fable-5',
          includedUntil: _epochUtc(2026, 7, 7),
        ),
      ],
    );
    expect(report.hasElapsedIncludedQuota, isTrue);
    expect(report.toJson()['elapsed_included_quota'], hasLength(1));
    final text = formatCatalogAuditReport(report);
    expect(text, contains('stale included-quota facts'));
    expect(text, contains('claude-fable-5'));
    expect(text, contains('2026-07-07'));
  });

  test('parses shutdown dates and rejects malformed calendar days', () {
    final listed = parseListedModels({
      'data': [
        {'id': 'gpt-dated', 'shutdown_date': '2026-11-20'},
        {'id': 'gpt-null', 'shutdown_date': null},
        {'id': 'gpt-missing'},
        {'id': 'gpt-invalid', 'shutdown_date': '2026-02-31'},
        {'id': 'gpt-text', 'shutdown_date': 'next month'},
        'gpt-string',
      ],
    });

    expect(
      listed.map((model) => (model.id, model.shutdownDate)),
      [
        ('gpt-dated', '2026-11-20'),
        ('gpt-null', null),
        ('gpt-missing', null),
        ('gpt-invalid', null),
        ('gpt-text', null),
        ('gpt-string', null),
      ],
    );
    expect(parseShutdownDate('2024-02-29'), '2024-02-29');
    expect(parseShutdownDate('2026-02-29'), isNull);
  });

  test('conflicting shutdown dates stay unset after a later repeat', () {
    final dates = shutdownDatesById(const [
      ListedModel('gpt-keep', '2026-12-03'),
      ListedModel('gpt-keep', null),
      ListedModel('gpt-fill', null),
      ListedModel('gpt-fill', '2027-01-01'),
      ListedModel('gpt-clash', '2026-10-01'),
      ListedModel('gpt-clash', '2027-01-01'),
      ListedModel('gpt-clash', '2026-10-01'),
    ]);

    expect(dates['gpt-keep'], '2026-12-03');
    expect(dates['gpt-fill'], '2027-01-01');
    expect(dates['gpt-clash'], isNull);
  });

  test('OpenAI shutdown dates fail only inside the notice window', () async {
    final now = _epochUtc(2026, 11, 2);
    final source = ModelListSource(
      provider: 'codex',
      endpoint: Uri.parse('https://example.test/models'),
      publishesShutdownDates: true,
    );
    final client = MockClient((request) async {
      if (request.url.queryParameters['after_id'] == 'page-1') {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'gpt-near', 'shutdown_date': '2026-11-20'},
              {'id': 'gpt-clash', 'shutdown_date': '2027-06-01'},
              {'id': 'gpt-fill', 'shutdown_date': '2027-06-01'},
            ],
            'has_more': false,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'gpt-past', 'shutdown_date': '2026-10-01'},
            {'id': 'gpt-today', 'shutdown_date': '2026-11-02'},
            {'id': 'gpt-boundary', 'shutdown_date': '2026-12-02'},
            {'id': 'gpt-far', 'shutdown_date': '2026-12-03'},
            {'id': 'gpt-invalid', 'shutdown_date': '2026-02-31'},
            {'id': 'gpt-missing'},
            {'id': 'gpt-endpoint-only', 'shutdown_date': '2020-01-01'},
            {'id': 'gpt-clash', 'shutdown_date': '2026-10-01'},
            {'id': 'gpt-fill'},
            {'id': 'gpt-keep', 'shutdown_date': '2027-08-01'},
          ],
          'has_more': true,
          'last_id': 'page-1',
        }),
        200,
      );
    });

    final report = await auditModelCatalog(
      now: now,
      catalog: const {
        'codex': [
          ModelInfo(id: 'gpt-past'),
          ModelInfo(id: 'gpt-today'),
          ModelInfo(id: 'gpt-boundary'),
          ModelInfo(id: 'gpt-near'),
          ModelInfo(id: 'gpt-far'),
          ModelInfo(id: 'gpt-invalid'),
          ModelInfo(id: 'gpt-missing'),
          ModelInfo(id: 'gpt-clash'),
          ModelInfo(id: 'gpt-fill'),
          ModelInfo(id: 'gpt-keep'),
        ],
      },
      sources: [source],
      client: client,
    );

    final audit = report.providers.single;
    expect(audit.ok, isTrue);
    expect(audit.shutdownDatesChecked, isTrue);
    expect(audit.hasDrift, isTrue);
    expect(
      audit.shutdowns.map((shutdown) => shutdown.modelId),
      [
        'gpt-boundary',
        'gpt-far',
        'gpt-fill',
        'gpt-keep',
        'gpt-near',
        'gpt-past',
        'gpt-today'
      ],
    );
    CatalogShutdown finding(String id) =>
        audit.shutdowns.singleWhere((shutdown) => shutdown.modelId == id);
    expect(finding('gpt-past').daysRemaining, -32);
    expect(finding('gpt-past').actionable, isTrue);
    expect(finding('gpt-today').daysRemaining, 0);
    expect(finding('gpt-today').actionable, isTrue);
    expect(finding('gpt-boundary').daysRemaining, 30);
    expect(finding('gpt-boundary').actionable, isTrue);
    expect(finding('gpt-near').daysRemaining, 18);
    expect(finding('gpt-near').actionable, isTrue);
    expect(finding('gpt-far').daysRemaining, 31);
    expect(finding('gpt-far').actionable, isFalse);
    expect(finding('gpt-fill').shutdownDate, '2027-06-01');
    expect(finding('gpt-keep').shutdownDate, '2027-08-01');
    expect(
      audit.shutdowns.map((shutdown) => shutdown.modelId),
      isNot(contains('gpt-endpoint-only')),
    );
    expect(
      audit.shutdowns.map((shutdown) => shutdown.modelId),
      isNot(contains('gpt-clash')),
    );

    final json = audit.toJson();
    expect(json['shutdown_dates_checked'], isTrue);
    final encoded = json['shutdowns'] as List<dynamic>;
    expect(encoded.first, {
      'model': 'gpt-boundary',
      'shutdown_date': '2026-12-02',
      'days_remaining': 30,
      'actionable': true,
    });
    expect(formatCatalogAuditReport(report), contains('codex: drift'));
    expect(
      catalogAuditExitCode(report, failOnDrift: false, failOnError: false),
      1,
    );
  });

  test('a source that does not publish shutdown dates ignores the field',
      () async {
    final source = ModelListSource(
      provider: 'claude',
      endpoint: Uri.parse('https://example.test/models'),
    );
    final report = await auditModelCatalog(
      now: _epochUtc(2026, 11, 2),
      catalog: const {
        'claude': [ModelInfo(id: 'claude-old')]
      },
      sources: [source],
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'data': [
                {'id': 'claude-old', 'shutdown_date': '2020-01-01'},
              ],
            }),
            200,
          )),
    );

    final audit = report.providers.single;
    expect(audit.shutdownDatesChecked, isFalse);
    expect(audit.shutdowns, isEmpty);
    expect(audit.toJson().containsKey('shutdowns'), isFalse);
    expect(audit.toJson()['shutdown_dates_checked'], isFalse);
    expect(
      formatCatalogAuditReport(report),
      contains('shutdown dates: not published by this source'),
    );
    expect(
      catalogAuditExitCode(report, failOnDrift: false, failOnError: false),
      0,
    );
  });

  test('a failed shutdown-capable read does not check dates', () async {
    final report = await auditModelCatalog(
      now: _epochUtc(2026, 11, 2),
      catalog: const {
        'codex': [ModelInfo(id: 'gpt-current')]
      },
      sources: [
        ModelListSource(
          provider: 'codex',
          endpoint: Uri.parse('https://example.test/models'),
          publishesShutdownDates: true,
        ),
      ],
      client: MockClient((_) async => http.Response('{}', 503)),
    );

    final audit = report.providers.single;
    expect(audit.shutdownDatesChecked, isFalse);
    expect(audit.shutdowns, isEmpty);
    expect(formatCatalogAuditReport(report),
        contains('shutdown dates: not checked'));
  });

  test('summary shutdown lines count models and omit their ids', () {
    const soon = CatalogShutdown(
      modelId: 'gpt-secret-soon',
      shutdownDate: '2026-11-10',
      daysRemaining: 8,
      actionable: true,
    );
    const later = CatalogShutdown(
      modelId: 'gpt-secret-later',
      shutdownDate: '2027-06-01',
      daysRemaining: 200,
      actionable: false,
    );
    const report = CatalogAuditReport(
      generatedAt: _now,
      catalogUpdated: '2026-11-02',
      providers: [
        ProviderCatalogAudit(
          provider: 'codex',
          endpoint: 'https://api.openai.com/v1/models',
          authEnv: 'OPENAI_API_KEY',
          ok: true,
          skipped: false,
          error: null,
          catalogModelIds: ['gpt-secret-soon', 'gpt-secret-later'],
          endpointModelIds: ['gpt-secret-soon', 'gpt-secret-later'],
          missingFromCatalog: [],
          catalogOnly: [],
          shutdownDatesChecked: true,
          shutdowns: [soon, later],
        ),
      ],
    );

    final summary = formatCatalogAuditReport(report, includeModelIds: false);
    expect(summary, contains('codex: shutdown'));
    expect(summary, contains('announced shutdowns: 2'));
    expect(summary, contains('actionable shutdowns: 1'));
    expect(summary, isNot(contains('gpt-secret-soon')));
    expect(summary, isNot(contains('gpt-secret-later')));

    final detailed = formatCatalogAuditReport(report);
    expect(detailed, contains('gpt-secret-soon'));
    expect(detailed, contains('shuts down in 8 days'));
    expect(detailed, contains('exits nonzero'));
    expect(
      catalogAuditExitCode(report, failOnDrift: false, failOnError: false),
      1,
    );

    const farOnly = CatalogAuditReport(
      generatedAt: _now,
      catalogUpdated: '2026-11-02',
      providers: [
        ProviderCatalogAudit(
          provider: 'codex',
          endpoint: 'https://api.openai.com/v1/models',
          authEnv: 'OPENAI_API_KEY',
          ok: true,
          skipped: false,
          error: null,
          catalogModelIds: ['gpt-secret-later'],
          endpointModelIds: ['gpt-secret-later'],
          missingFromCatalog: [],
          catalogOnly: [],
          shutdownDatesChecked: true,
          shutdowns: [later],
        ),
      ],
    );
    expect(formatCatalogAuditReport(farOnly), contains('codex: clean'));
    expect(
      catalogAuditExitCode(farOnly, failOnDrift: false, failOnError: false),
      0,
    );
  });
}
