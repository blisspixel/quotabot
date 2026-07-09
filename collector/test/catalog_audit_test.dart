import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/catalog_audit.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

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
    final grok = sources.firstWhere((s) => s.provider == 'grok').includeModel;
    expect(grok('grok-4.3', null), isTrue);
    expect(grok('grok-imagine-image', null), isFalse);
  });
}
