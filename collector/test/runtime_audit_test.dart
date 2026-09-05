import 'package:quotabot_collector/collector.dart';
import 'package:test/test.dart';

void main() {
  test('Codex manifest follows the requested OS and explicit home', () {
    const environment = {
      'USERPROFILE': r'C:\windows-home',
      'HOME': '/posix-home',
    };
    String authPath(String os, Map<String, String> env) =>
        defaultProviderRuntimeAccess(environment: env, os: os)
            .singleWhere((provider) => provider.provider == 'codex')
            .reads
            .singleWhere((record) => record.target.endsWith('auth.json'))
            .target;
    expect(
        authPath('windows', environment), r'C:\windows-home\.codex\auth.json');
    for (final os in ['linux', 'macos']) {
      expect(authPath(os, environment), '/posix-home/.codex/auth.json');
      expect(authPath(os, {...environment, 'CODEX_HOME': '/configured'}),
          '/configured/auth.json');
    }
    expect(
        authPath('windows', {...environment, 'CODEX_HOME': r'D:\configured'}),
        r'D:\configured\auth.json');
  });

  test('modern metadata manifests include only their declared coordination',
      () {
    final providers = defaultProviderRuntimeAccess(
        environment: const {'HOME': '/synthetic'}, os: 'linux');
    for (final id in ['codex', 'claude', 'grok']) {
      final provider = providers.singleWhere((p) => p.provider == id);
      final gateRecords = provider.reads
          .where((record) => record.target.contains('/provider_read_gates/'));
      expect(gateRecords.map((record) => record.access).toSet(),
          {'read', 'write'});
      expect(gateRecords.every((record) => record.metadataOnly), isTrue);
      final associations = provider.reads.where(
          (record) => record.target.contains('/credential_pools/$id.json'));
      expect(associations, hasLength(id == 'codex' ? 0 : 2));
    }
    final grok = providers.singleWhere((p) => p.provider == 'grok');
    final quotaReads = grok.network
        .where((record) => record.host == 'cli-chat-proxy.grok.com');
    expect(quotaReads.map((record) => record.path).toSet(), {
      '/v1/billing?format=credits',
      '/v1/user?include=subscription',
    });
    expect(quotaReads.every((record) => record.method == 'GET'), isTrue);
    expect(grok.network.any((record) => record.host == 'grok.com'), isFalse);
    expect(
        providers
            .singleWhere((p) => p.provider == 'antigravity')
            .reads
            .any((record) => record.target.contains('/provider_read_gates/')),
        isFalse);
  });

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
    expect(
      claudeReads.any((record) =>
          (record['target'] as String).contains('.claude') &&
          (record['target'] as String).contains('.credentials.json') &&
          record['credential_material'] == true),
      isTrue,
    );
    expect(
      claudeReads.any((record) =>
          (record['target'] as String).contains('auth') &&
          (record['target'] as String).contains('claude') &&
          record['kind'] == 'fileRead'),
      isTrue,
    );
    expect(
      claudeReads.any((record) =>
          (record['target'] as String).contains('auth') &&
          (record['target'] as String).contains('claude') &&
          record['kind'] == 'fileWrite'),
      isTrue,
    );

    final claudeNetwork =
        (claude['network'] as List).cast<Map<String, dynamic>>();
    expect(
      claudeNetwork.any((record) =>
          record['host'] == 'api.anthropic.com' &&
          record['path'] == '/api/oauth/usage' &&
          record['spends_tokens'] == false),
      isTrue,
    );
    expect(
      claudeNetwork.any((record) =>
          record['host'] == 'api.anthropic.com' &&
          record['path'] == '/api/oauth/profile' &&
          record['spends_tokens'] == false &&
          record['data_class'] == 'account_metadata'),
      isTrue,
    );
    expect(
      claudeNetwork.any((record) =>
          record['host'] == 'platform.claude.com' &&
          record['path'] == '/v1/oauth/token' &&
          record['data_class'] == 'credential_exchange' &&
          record['credential_material'] == true),
      isTrue,
    );

    final codex = providers.firstWhere((p) => p['provider'] == 'codex');
    final codexReads = (codex['reads'] as List).cast<Map<String, dynamic>>();
    expect(
      codexReads.any((record) =>
          (record['target'] as String).contains('auth') &&
          (record['target'] as String).contains('codex') &&
          record['kind'] == 'fileRead'),
      isTrue,
    );
    expect(
      codexReads.any((record) =>
          (record['target'] as String).contains('auth') &&
          (record['target'] as String).contains('codex') &&
          record['kind'] == 'fileWrite'),
      isTrue,
    );
    final codexNetwork =
        (codex['network'] as List).cast<Map<String, dynamic>>();
    expect(
      codexNetwork.any((record) =>
          record['host'] == 'auth.openai.com' &&
          record['path'] == '/oauth/token' &&
          record['data_class'] == 'credential_exchange' &&
          record['credential_material'] == true),
      isTrue,
    );

    final shared = (json['shared'] as List).cast<Map<String, dynamic>>();
    final historyRecords = shared.where(
      (record) => (record['target'] as String).contains('history_*.jsonl'),
    );
    expect(historyRecords, hasLength(2));
    expect(
      historyRecords.every(
        (record) => !(record['target'] as String)
            .replaceAll('\\', '/')
            .contains('/cache/history/'),
      ),
      isTrue,
    );
    expect(
      shared.any((r) =>
          r['kind'] == 'fileWrite' &&
          (r['target'] as String).contains('quotabot') &&
          r['access'] == 'write'),
      isTrue,
    );
    expect(
      shared.any((r) =>
          r['kind'] == 'process' &&
          (r['target'] as String).contains('ComputerInfo') &&
          (r['target'] as String).contains('Win32_OperatingSystem') &&
          r['data_class'] == 'hardware_metadata' &&
          r['spends_tokens'] == false),
      isTrue,
    );
    expect(
      shared.any((r) =>
          r['kind'] == 'process' &&
          (r['target'] as String).contains('Win32_VideoController') &&
          r['data_class'] == 'hardware_metadata'),
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
    final antigravityReads =
        (antigravity['reads'] as List).cast<Map<String, dynamic>>();
    expect(
      antigravityReads.any((r) =>
          (r['target'] as String).contains('os-keyring://gemini/antigravity') &&
          r['credential_material'] == true),
      isTrue,
    );
    final antigravityNetwork =
        (antigravity['network'] as List).cast<Map<String, dynamic>>();
    expect(
      antigravityNetwork.any((r) => r['path'] == '/v1internal:onboardUser'),
      isTrue,
    );
    final lemonade = providers.firstWhere((p) => p['provider'] == 'lemonade');
    final lemonadeNetwork =
        (lemonade['network'] as List).cast<Map<String, dynamic>>();
    expect(
      lemonadeNetwork.every(
        (record) =>
            (record['target'] as String).startsWith('http://127.0.0.1:13305/'),
      ),
      isTrue,
    );
    expect(
      lemonadeNetwork.map((record) => record['path']),
      containsAll(['/api/v1/health', '/v1/health']),
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

  test('runtime access paths match production filenames and Linux XDG roots',
      () {
    final report = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: true,
      includeNetwork: false,
      environment: const {
        'HOME': '/home/tester',
        'XDG_CONFIG_HOME': '/config-root',
        'XDG_DATA_HOME': '/data-root',
      },
      os: 'linux',
    );
    String normalized(String value) => value.replaceAll('\\', '/');
    final shared = report.shared.map((record) => normalized(record.target));
    expect(
      shared,
      contains('/config-root/quotabot/manual/quotas.json'),
    );
    expect(
      shared,
      contains('/home/tester/.quotabot/litellm-metrics.jsonl'),
    );
    expect(shared.join('\n'), isNot(contains('manual_quotas.json')));
    expect(shared.join('\n'), isNot(contains('litellm_metrics.jsonl')));

    const appRoots = {
      'antigravity': 'Antigravity',
      'cursor': 'Cursor',
      'kiro': 'Kiro',
      'windsurf': 'Windsurf',
    };
    for (final entry in appRoots.entries) {
      final targets = report.providers
          .firstWhere((provider) => provider.provider == entry.key)
          .reads
          .map((record) => normalized(record.target));
      expect(
        targets.any(
          (target) => target.startsWith('/data-root/${entry.value}'),
        ),
        isTrue,
        reason: entry.key,
      );
      expect(
        targets.any(
          (target) => target.startsWith('/config-root/${entry.value}'),
        ),
        isFalse,
        reason: entry.key,
      );
    }
  });

  test('runtime access paths use the requested OS instead of the host OS', () {
    const environment = {
      'USERPROFILE': r'C:\host-user',
      'LOCALAPPDATA': r'C:\host-local',
      'APPDATA': r'C:\host-roaming',
      'HOME': '/target-home',
      'XDG_CONFIG_HOME': '/target-config',
      'XDG_DATA_HOME': '/target-data',
    };

    final linux = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: true,
      includeNetwork: false,
      environment: environment,
      os: 'linux',
    );
    final linuxTargets = [
      ...linux.shared,
      ...linux.providers.expand((provider) => provider.reads),
    ].map((record) => record.target);
    expect(linuxTargets, everyElement(isNot(contains(r'C:\host'))));
    expect(linuxTargets, everyElement(isNot(contains(r'\'))));
    expect(
      linuxTargets,
      contains('/target-data/Cursor/User/globalStorage/state.vscdb'),
    );

    final windows = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: true,
      includeNetwork: false,
      environment: environment,
      os: 'windows',
    );
    final windowsTargets = [
      ...windows.shared,
      ...windows.providers.expand((provider) => provider.reads),
    ].map((record) => record.target);
    expect(
      windowsTargets,
      contains(r'C:\host-local\quotabot\manual\quotas.json'),
    );
    expect(
      windowsTargets,
      contains(r'C:\host-roaming\Cursor\User\globalStorage\state.vscdb'),
    );

    final macos = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: true,
      includeNetwork: false,
      environment: environment,
      os: 'macos',
    );
    final macosTargets = [
      ...macos.shared,
      ...macos.providers.expand((provider) => provider.reads),
    ].map((record) => record.target);
    expect(macosTargets, everyElement(isNot(contains(r'C:\host'))));
    expect(macosTargets, everyElement(isNot(contains(r'\'))));
    expect(
      macosTargets,
      contains(
        '/target-home/Library/Application Support/Cursor/User/globalStorage/state.vscdb',
      ),
    );
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

  test('local runtime manifest shares HTTPS and Lemonade port resolution', () {
    final report = buildRuntimeAccessReport(
      generatedAt: 1,
      includeReads: false,
      includeNetwork: true,
      environment: const {
        'HOME': '/home/tester',
        'OLLAMA_HOST': 'https://ollama.internal',
        'LMSTUDIO_HOST': 'https://lmstudio.internal',
        'LEMONADE_HOST': 'lemonade.internal',
        'LEMONADE_PORT': '14000',
      },
      os: 'linux',
    );

    List<String> targets(String provider) => report.providers
        .firstWhere((entry) => entry.provider == provider)
        .network
        .map((record) => record.target)
        .toList();

    expect(targets('ollama'),
        everyElement(startsWith('https://ollama.internal/')));
    expect(
      targets('lmstudio'),
      everyElement(startsWith('https://lmstudio.internal/')),
    );
    expect(
      targets('lemonade'),
      everyElement(startsWith('http://lemonade.internal:14000/')),
    );
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

  test('runtime manifest discloses OS-specific passive hardware access', () {
    List<Map<String, dynamic>> sharedFor(String os) =>
        (buildRuntimeAccessReport(
          generatedAt: 1,
          includeReads: true,
          includeNetwork: false,
          environment: const {
            'HOME': '/home/tester',
            'SystemRoot': r'C:\Windows',
          },
          os: os,
        ).toJson()['shared'] as List)
            .cast<Map<String, dynamic>>();

    final linux = sharedFor('linux');
    expect(linux.any((record) => record['target'] == '/proc/meminfo'), isTrue);
    expect(
      linux.any((record) =>
          record['kind'] == 'process' &&
          (record['target'] as String).contains('nvidia-smi')),
      isTrue,
    );

    final mac = sharedFor('macos');
    expect(
      mac.any((record) =>
          (record['target'] as String).contains('sysctl -n hw.memsize')),
      isTrue,
    );
    expect(
      mac.any((record) =>
          (record['target'] as String).contains('/usr/bin/vm_stat')),
      isTrue,
    );
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
