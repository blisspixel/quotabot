import 'package:quotabot_collector/collector.dart';
import 'package:test/test.dart';

void main() {
  test('runtime access report names metadata-only reads and hosts', () {
    final report = buildRuntimeAccessReport(
      generatedAt: 1782000000,
      includeReads: true,
      includeNetwork: true,
      environment: const {
        'USERPROFILE': r'C:\Users\tester',
        'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
        'APPDATA': r'C:\Users\tester\AppData\Roaming',
      },
      os: 'windows',
    );

    final json = report.toJson();
    expect(json['schema'], quotabotExplainV1SchemaId);
    expect(json['mode'], 'runtime_access_manifest');
    expect(json['evidence'], 'static_manifest');
    expect(json['collection_executed'], isFalse);
    expect((json['privacy_boundary'] as Map)['spends_tokens'], isFalse);
    expect((json['privacy_boundary'] as Map)['sends_prompt_or_code'], isFalse);

    final providers = (json['providers'] as List).cast<Map<String, dynamic>>();
    final claude = providers.firstWhere((p) => p['provider'] == 'claude');
    final claudeReads = (claude['reads'] as List).cast<Map<String, dynamic>>();
    expect(claudeReads.single['target'], contains('.claude'));
    expect(claudeReads.single['target'], contains('.credentials.json'));
    expect(claudeReads.single['credential_material'], isTrue);

    final claudeNetwork =
        (claude['network'] as List).cast<Map<String, dynamic>>();
    expect(claudeNetwork.single['host'], 'api.anthropic.com');
    expect(claudeNetwork.single['path'], '/api/oauth/usage');
    expect(claudeNetwork.single['spends_tokens'], isFalse);

    final shared = (json['shared'] as List).cast<Map<String, dynamic>>();
    expect(
      shared.any((r) =>
          r['kind'] == 'fileWrite' &&
          (r['target'] as String).contains('quotabot') &&
          r['access'] == 'write'),
      isTrue,
    );
    final grok = providers.firstWhere((p) => p['provider'] == 'grok');
    final grokReads = (grok['reads'] as List).cast<Map<String, dynamic>>();
    expect(
      grokReads.any((r) =>
          r['kind'] == 'fileWrite' &&
          (r['target'] as String).contains('quotabot') &&
          r['credential_material'] == true),
      isTrue,
    );
    final antigravity =
        providers.firstWhere((p) => p['provider'] == 'antigravity');
    final antigravityNetwork =
        (antigravity['network'] as List).cast<Map<String, dynamic>>();
    expect(
      antigravityNetwork.any((r) => r['path'] == '/v1internal:onboardUser'),
      isTrue,
    );
  });

  test('runtime access report honors profile and exclusions', () {
    final report = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: false,
      includeNetwork: true,
      profile: const QuotaProfile(name: 'local', providers: {'ollama'}),
      excludedProviders: const {'claude'},
      environment: const {'HOME': '/home/tester'},
      os: 'linux',
    );

    expect(report.providers.map((p) => p.provider), ['ollama']);
    expect(report.providers.single.reads, isEmpty);
    expect(report.providers.single.network, isNotEmpty);
  });

  test('local runtime network records honor host overrides without queries',
      () {
    final report = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: false,
      includeNetwork: true,
      environment: const {
        'HOME': '/home/tester',
        'OLLAMA_HOST': 'https://ollama.internal:9443/ignored?token=secret',
      },
      os: 'linux',
    );
    final ollama = report.providers.firstWhere((p) => p.provider == 'ollama');

    expect(ollama.network.first.scheme, 'https');
    expect(ollama.network.first.host, 'ollama.internal:9443');
    expect(
        ollama.network.first.target, 'https://ollama.internal:9443/api/tags');
    expect(ollama.network.first.target, isNot(contains('token=secret')));
  });

  test('runtime access manifest never lists generation endpoints', () {
    final report = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: true,
      includeNetwork: true,
      environment: const {'HOME': '/home/tester'},
      os: 'linux',
    );
    final targets = [
      for (final provider in report.providers)
        for (final record in provider.network) record.target,
    ].join('\n');

    expect(targets, isNot(contains('/chat/completions')));
    expect(targets, isNot(contains('/v1/messages')));
    expect(targets, isNot(contains('/images')));
    expect(targets, isNot(contains('/responses')));
    expect(targets, isNot(contains(':generateContent')));
  });

  test('runtime access observation records invoked providers explicitly', () {
    final report = buildRuntimeAccessReport(
      generatedAt: 1782000000,
      includeReads: true,
      includeNetwork: true,
      observedProviderIds: const {'claude', 'ollama'},
      collectionExecuted: true,
      environment: const {'HOME': '/home/tester'},
      os: 'linux',
    );

    final json = report.toJson();
    expect(json['mode'], 'runtime_access_observation');
    expect(json['collection_executed'], isTrue);
    expect(json['evidence'], 'provider_adapter_invoked_static_access_map');
    expect((json['notes'] as List).join(' '),
        contains('provider-specific branches may skip'));
    final providers = (json['providers'] as List).cast<Map<String, dynamic>>();
    expect(providers.map((p) => p['provider']), ['claude', 'ollama']);
    expect(providers.every((p) => p['observed'] == true), isTrue);
    expect(
      providers.every(
          (p) => p['evidence'] == 'provider_adapter_invoked_static_access_map'),
      isTrue,
    );
  });
}
