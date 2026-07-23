import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/storage_keys.dart';
import 'package:test/test.dart';

import '../bin/collect.dart' as cli;

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_simulation_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    return runCollectCli(args, environment: {'LOCALAPPDATA': temp.path});
  }

  test('doctor does not call temporary transport failures a login problem', () {
    const cases = [
      ('Claude usage read timed out', providerPipeHealthThrottled, null),
      ('HTTP 429', providerPipeHealthThrottled, 429),
      ('HTTP 503', providerPipeHealthDegraded, 503),
    ];

    for (final (error, pipeHealth, httpStatus) in cases) {
      final quota = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'default',
        asOf: 1782046566,
        ok: false,
        error: error,
        pipeHealth: pipeHealth,
        httpStatus: httpStatus,
      );

      expect(cli.doctorRecoveryHint(quota, 'ERROR'), isNull, reason: error);
    }
  });

  test('analytics storage diagnostics stay scoped and identity safe', () {
    final affected = ProviderQuota(
      provider: codexProviderId,
      displayName: 'Codex',
      account: 'secret@example.com',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    final healthy = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'healthy@example.com',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 30)],
    );
    const notice = AnalyticsStorageNotice(
      provider: codexProviderId,
      account: 'secret@example.com',
      tiers: ['history', 'buckets'],
      observedAt: 1782000100,
    );
    final notices = {quotaIdentityKeyFor(affected): notice};

    final fields = cli.statsStorageNoticeFields(affected, notices);
    final encoded = jsonEncode(fields);
    expect(fields['storage_notice'], isA<Map<String, dynamic>>());
    expect(encoded, contains('"state":"diverged"'));
    expect(encoded, contains('"tiers":["history","buckets"]'));
    expect(encoded, isNot(contains('secret@example.com')));
    expect(encoded, isNot(contains(r'C:\Users')));
    expect(cli.statsStorageNoticeFields(healthy, notices), isEmpty);
    expect(
      cli.analyticsStorageWarningForQuota(affected, notices),
      allOf(
        contains('ordered checkpoint proves both deltas'),
        contains('quotabot doctor'),
      ),
    );
    expect(cli.analyticsStorageWarningForQuota(healthy, notices), isNull);
    expect(
      cli.statsHistoryAvailabilityLabel(affected, notices),
      'affected history unavailable',
    );
    expect(
      cli.statsHistoryAvailabilityLabel(healthy, notices),
      'no history yet',
    );

    const hiddenIncident = AnalyticsStorageIncident(
      provider: codexProviderId,
      tiers: ['buckets'],
      recordedAt: 1782000100,
      incidentId: '0123456789abcdef0123456789abcdef',
    );
    const inventory = AnalyticsIncidentInventory(
      incidents: [hiddenIncident],
      state: 'complete',
      scope: 'all_local',
      scannedMarkers: 1,
      unverifiableMarkers: 0,
      invalidMarkers: 0,
      truncated: false,
    );
    final incidentFields = cli.analyticsIncidentSnapshotFields(inventory);
    final incidentJson = jsonEncode(incidentFields);
    expect(incidentJson, contains('"analytics_incident_inventory"'));
    expect(incidentJson, contains('"exact_account_in_snapshot":false'));
    expect(incidentJson, contains('"state":"complete"'));
    expect(
      cli.unavailableAnalyticsIncidentSummary([hiddenIncident]),
      allOf(
        contains('Codex account not currently available'),
        contains('Current quota and routing are unaffected'),
        contains('reconnect'),
      ),
    );
  });

  test('doctor keeps sparse model quota separate from shared limits', () {
    const now = 1782046566;
    final summary = cli.doctorModelSummary(
      claudeProviderId,
      const [
        ModelQuota(
          model: 'Fable',
          usedPercent: 26,
          windowLabel: 'weekly',
        ),
      ],
      now,
    );

    expect(summary, contains('model-specific'));
    expect(summary, contains('Fable 26%'));
    expect(summary, contains('(weekly)'));
    expect(summary, contains('separate from shared account limits'));
    expect(
      cli.doctorModelSummary(
        codexProviderId,
        const [
          ModelQuota(
            model: 'GPT-5.3-Codex-Spark',
            usedPercent: 0,
            windowLabel: 'weekly',
          ),
        ],
        now,
      ),
      allOf(
        contains('model-specific'),
        contains('GPT-5.3-Codex-Spark 0%'),
        contains('(weekly)'),
        contains('separate from shared account limits'),
      ),
    );
    expect(
      cli.doctorModelSummary(
        antigravityProviderId,
        const [ModelQuota(model: 'Gemini', usedPercent: 26)],
        now,
      ),
      isNot(contains('shared account limits')),
    );
  });

  test('doctor labels Fable spend evidence without trusting host plan claims',
      () {
    const now = kClaudeFableIncludedQuotaEffectiveAt + 86400;
    const scoped = [
      ModelQuota(model: 'Fable', usedPercent: 26, windowLabel: 'weekly'),
    ];
    ProviderQuota quota(
      String plan,
      ProviderPlanEvidenceSource source,
    ) =>
        ProviderQuota(
          provider: claudeProviderId,
          displayName: claudeProviderName,
          account: 'opaque',
          plan: plan,
          planEvidenceSource: source,
          planEvidenceAsOf: now,
          asOf: now,
          windows: [
            QuotaWindow(label: 'weekly', usedPercent: 17),
          ],
          modelQuotas: scoped,
        );

    final host = quota('max', ProviderPlanEvidenceSource.hostCredential);
    expect(
      cli.doctorModelSummary(
        claudeProviderId,
        scoped,
        now,
        providerQuota: host,
      ),
      contains('Fable spend: included quota not proven'),
    );

    final included = quota('max', ProviderPlanEvidenceSource.providerMetadata);
    expect(
      cli.doctorModelSummary(
        claudeProviderId,
        scoped,
        now,
        providerQuota: included,
      ),
      contains('Fable spend: included quota'),
    );

    final pro = quota('pro', ProviderPlanEvidenceSource.providerMetadata);
    expect(
      cli.doctorModelSummary(
        claudeProviderId,
        scoped,
        now,
        providerQuota: pro,
      ),
      contains('Fable spend: credit-backed availability'),
    );

    final hostPro = quota('pro', ProviderPlanEvidenceSource.hostCredential);
    expect(
      cli.doctorModelSummary(
        claudeProviderId,
        scoped,
        now,
        providerQuota: hostPro,
      ),
      contains('Fable spend: included quota not proven'),
    );
  });

  test('json snapshot accepts separated simulation flag values', () async {
    final result = await runCli([
      '--json',
      '--mock-provider',
      'claude',
      '--state',
      'exhausted',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.v1');
    expect(json['snapshot_source'], 'simulation');
    final incidentInventory =
        json['analytics_incident_inventory'] as Map<String, dynamic>;
    expect(incidentInventory['state'], 'suppressed');
    expect(incidentInventory['scope'], 'simulation');
    expect(incidentInventory['incidents'], isEmpty);
    final providers = json['providers'] as List;
    expect(providers, hasLength(1));
    final claude = providers.single as Map<String, dynamic>;
    expect(claude['provider'], 'claude');
    expect(claude['account'], 'simulated');
    final windows = claude['windows'] as List;
    expect(
      windows.any(
        (w) =>
            (w as Map<String, dynamic>)['label'] == '5h' &&
            w['used_percent'] == 100,
      ),
      isTrue,
    );
  });

  test('separated provider preference is applied', () async {
    final result = await runCollectCli(
      ['suggest', '--json', '--prefer', 'codex,claude'],
      environment: {
        'LOCALAPPDATA': temp.path,
        'QUOTABOT_DEMO': '1',
      },
    );

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect((json['recommended'] as Map)['provider'], 'codex');
    expect(json['reason'], contains('first by your preference'));
  });

  test('value option without a value is a usage error', () async {
    final result = await runCli([
      'models',
      '--mock-provider=codex',
      '--min-context',
    ]);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('--min-context requires a value'));
    expect(result.stdout as String, isEmpty);
  });

  test('unknown option is a usage error', () async {
    final result = await runCli([
      'models',
      '--mock-provider=codex',
      '--does-not-exist',
    ]);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unknown option'));
    expect(result.stderr as String, contains('--does-not-exist'));
    expect(result.stdout as String, isEmpty);
  });

  test('option terminator keeps later dash-prefixed text positional', () async {
    final result = await runCollectCli(
      ['status', '--', '--json'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unexpected argument "--json"'));
    expect(result.stdout as String, isEmpty);
  });

  test('recognized option on the wrong command is a usage error', () async {
    final result = await runCollectCli(
      ['models', '--used=10'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('--used is not valid for models'));
    expect(result.stdout as String, isEmpty);
  });

  test('extra positional argument is a usage error', () async {
    final result = await runCollectCli(
      ['suggest', 'extra'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unexpected argument "extra"'));
    expect(result.stdout as String, isEmpty);
  });

  test('simulation state requires a mock provider', () async {
    final result = await runCollectCli(
      ['status', '--state=spent'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('--state requires'));
    expect(result.stdout as String, isEmpty);
  });

  test('check rejects unsafe exact account before collection', () async {
    final unsafe = 'work${String.fromCharCode(7)}account';
    final accountResult = await runCli([
      'check',
      'claude',
      '--account=$unsafe',
      '--mock-provider=claude',
      '--state=healthy',
    ]);
    final providerResult = await runCli([
      'check',
      unsafe,
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(accountResult, 64);
    expect(accountResult.stdout as String, isEmpty);
    expect(
      accountResult.stderr as String,
      contains('bounded account identity'),
    );
    expect(
      accountResult.stderr as String,
      isNot(contains(String.fromCharCode(7))),
    );
    expectExitCode(providerResult, 64);
    expect(providerResult.stdout as String, isEmpty);
    expect(providerResult.stderr as String, contains('safe provider name'));
    expect(
      providerResult.stderr as String,
      isNot(contains(String.fromCharCode(7))),
    );
  });

  test('check exits unavailable for an exhausted mock provider', () async {
    final result = await runCli([
      'check',
      'claude',
      '--json',
      '--mock-provider=claude',
      '--state=exhausted',
    ]);

    expectExitCode(result, 69);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.check.v1');
    expect(json['as_of'], isA<int>());
    expect(json['captured_at'], isA<int>());
    expect(json['staleness_seconds'], isA<int>());
    expect(json['snapshot_source'], 'simulation');
    expect(json['provider'], 'claude');
    expect(json['matched_account_count'], 1);
    expect(json['selection_mode'], 'only');
    expect(json['source_class'], 'authoritative_live');
    expect(json['ok'], isTrue);
    expect(json['live_read_succeeded'], isFalse,
        reason: 'simulation must not claim an adapter read');
    expect(json['available'], isFalse);
    expect(json['headroom_percent'], 0);
    final runtimeAccess = json['runtime_access'] as Map<String, dynamic>;
    expect(runtimeAccess['collection_executed'], isFalse);
    expect(runtimeAccess['providers'], isEmpty);
  });

  test('check exits unavailable for a stale cached mock provider', () async {
    final result = await runCli([
      'check',
      'grok',
      '--json',
      '--mock-provider=grok',
      '--state=stale',
    ]);

    expectExitCode(result, 69);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.check.v1');
    expect(json['provider'], 'grok');
    expect(json['source_class'], 'authoritative_live');
    expect(json['available'], isFalse);
    expect(json['stale'], isTrue);
    expect(json['headroom_percent'], 48);
    expect(json['error'], contains('simulated stale cache'));
  });

  test('check human output explains a failed live read behind cached quota',
      () async {
    final result = await runCli([
      'check',
      'grok',
      '--no-color',
      '--mock-provider=grok',
      '--state=stale',
    ]);

    expectExitCode(result, 69);
    final out = result.stdout as String;
    expect(out, contains('live read failed: simulated stale cache'));
    expect(out, contains('showing last-known quota'));
  });

  test('check reports provider drift as unavailable trusted cache', () async {
    final result = await runCli([
      'check',
      'claude',
      '--json',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 69);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['source_class'], 'authoritative_live');
    expect(json['available'], isFalse);
    expect(json['stale'], isTrue);
    expect(json['headroom_percent'], 37);
    expect(json['drift_reason'], contains('usage fell'));
    expect(json['drift_observed_at'], isA<int>());
  });

  test('check human output labels provider drift instead of cached data',
      () async {
    final result = await runCli([
      'check',
      'claude',
      '--no-color',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 69);
    final out = result.stdout as String;
    expect(out, contains('(provider drift)'));
    expect(out, contains('(authoritative)'));
    expect(out, isNot(contains('(cached)')));
    expect(out, isNot(contains('authoritative, authoritative')));
    expect(out, contains('provider drift:'));
  });

  test('suggest uses the mock snapshot without real burn history', () async {
    final result = await runCli([
      'suggest',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest.v1');
    expect((json['recommended'] as Map)['provider'], 'claude');
    expect((json['ranked'] as List), hasLength(1));
  });

  test('stats and doctor suppress ambient simulated-account storage', () async {
    final cache = Directory('${temp.path}/quotabot/cache')
      ..createSync(recursive: true);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prior = HeadroomBucket(start: bucketStart(now) - 3600)..add(90);
    final current = HeadroomBucket(start: bucketStart(now))..add(40);
    File('${cache.path}/buckets_claude.json').writeAsStringSync(
      jsonEncode([prior.toJson(), current.toJson()]),
    );
    File(
      '${cache.path}/analytics_migration_claude_'
      '${accountStorageStem('simulated')}.json',
    ).writeAsStringSync('{invalid marker');

    final stats = await runCli([
      'stats',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ]);
    expectExitCode(stats, 0);
    final report = jsonDecode(stats.stdout as String) as Map<String, dynamic>;
    final claude = report['claude'] as Map<String, dynamic>;
    expect(claude['samples'], 0);
    expect(claude, isNot(contains('storage_notice')));

    final doctor = await runCli([
      'doctor',
      '--no-color',
      '--mock-provider=claude',
      '--state=healthy',
    ]);
    expectExitCode(doctor, 0);
    final output = doctor.stdout as String;
    expect(output, isNot(contains('History incomplete')));
    expect(output, isNot(contains('Inventory incomplete')));
    expect(output, isNot(contains('Local analytics incidents')));
    expect(output, isNot(contains('storage_notice')));
  });

  test('suggest ignores active cross-process leases in simulation', () async {
    final leaseStore = FileRouteLeaseStore(
      dirFactory: () => Directory('${temp.path}/quotabot/leases'),
      idFactory: () => 'cli-lease',
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final reservation = leaseStore.reserve(
      provider: 'claude',
      account: 'simulated',
      now: now,
      leaseSeconds: 300,
      weightPercent: 50,
    );
    expect(reservation.reserved, isTrue);

    final result = await runCli([
      'suggest',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final claude = (json['ranked'] as List).single as Map<String, dynamic>;
    expect(claude.containsKey('lease_discount_percent'), isFalse);
    expect(
      (claude['effective_headroom_percent'] as num).toDouble(),
      (claude['headroom_percent'] as num).toDouble(),
    );
    final receipt = json['receipt'] as Map<String, dynamic>;
    expect((receipt['snapshot'] as Map)['source'], 'simulation');
  });

  test('suggest human output names trust provenance', () async {
    final result = await runCli([
      'suggest',
      '--no-color',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('SIMULATION - synthetic provider evidence'));
    expect(out, contains('quota plan'));
    expect(out, contains('live'));
    expect(out, contains('captured'));
  });

  test('suggest human output marks stale quota as last known unavailable',
      () async {
    final result = await runCli([
      'suggest',
      '--no-color',
      '--mock-provider=grok',
      '--state=stale',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('no provider to route to right now'));
    expect(out, contains('Only cached quota evidence is present'));
    expect(out, contains('48% last known'));
    expect(out, contains('unavailable'));
    expect(out, isNot(contains('-> grok')));
  });

  test('suggest never routes provider-drift evidence', () async {
    final result = await runCli([
      'suggest',
      '--json',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['recommended'], isNull);
    final candidate = (json['ranked'] as List).single as Map<String, dynamic>;
    expect(candidate['available'], isFalse);
    expect(candidate['stale'], isTrue);
  });

  test('suggest human output labels drift and last-trusted headroom', () async {
    final result = await runCli([
      'suggest',
      '--no-color',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('[provider drift, authoritative, quota plan'));
    expect(out, contains('37% last trusted'));
    expect(out, contains('unavailable'));
    expect(out, isNot(contains('37% last known')));
  });

  test('suggest human output avoids calling plan strings account identities',
      () async {
    final result = await runCli([
      'suggest',
      '--no-color',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('[live, authoritative, quota plan, captured'));
    expect(out, isNot(contains('claude (simulated)')));
  });

  test('models human output names trust provenance', () async {
    final result = await runCollectCli(
      ['models', '--no-color'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('[live, authoritative, quota plan'));
    expect(out, contains('you@example.com'));
    expect(out, contains('local runtime, loaded'));
    expect(out, contains('local runtime, cold'));
    expect(out, isNot(contains('this machine')));
    expect(out, contains('captured'));
  });

  test('task-profiled suggest human output names model provenance', () async {
    final result = await runCollectCli(
      ['suggest', '--task=hard', '--no-color'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out,
        contains('on grok [live, authoritative, quota plan, you@example.com'));
    expect(out, contains('captured'));
  });

  test('provider-route suggest keeps provider schema with task context',
      () async {
    final result = await runCollectCli(
      ['suggest', '--provider-route', '--task=simple', '--json'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.suggest.v1');
    expect(json['ranked'], isA<List<Object?>>());
  });

  test('doctor human output names trust provenance', () async {
    final result = await runCli([
      'doctor',
      '--no-color',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('SIMULATION - synthetic provider evidence'));
    expect(out, contains('[live, authoritative, quota plan, captured'));
    expect(out, isNot(contains('Claude (simulated)')));
    expect(
      out,
      isNot(contains('Detected installed agentic dev coding tools')),
    );
  });

  test('doctor shows cached failure before generic login guidance', () async {
    final doctor = await runCli([
      'doctor',
      '--no-color',
      '--mock-provider=claude',
      '--state=stale',
    ]);
    final help = await runCli(['help', '--no-color']);

    expectExitCode(doctor, 0);
    expectExitCode(help, 0);
    expect(doctor.stdout as String, contains('simulated stale cache'));
    expect(doctor.stdout as String, isNot(contains('quotabot login claude')));
    expect(help.stdout as String, contains('adds a refreshable path'));
    expect(help.stdout as String, contains('inspect with doctor'));
    expect(
      help.stdout as String,
      contains('--recover-analytics=P --account=A --tier=history|buckets'),
    );
    expect(
      help.stdout as String,
      contains(
        'recovery: exact current account from unfiltered quotabot --json',
      ),
    );
    expect(
      help.stdout as String,
      contains(
        'machine-readable output where supported (including suggest, models, report, verify)',
      ),
    );
    expect(
      help.stdout as String,
      isNot(
        contains(
          'machine-readable output (status/check/suggest/stats/json)',
        ),
      ),
    );
    expect(
      help.stdout as String,
      contains(
        'Quota and routing reads use metadata only and cost no usage tokens.',
      ),
    );
    expect(
      help.stdout as String,
      contains(
        'Live reads may contact provider endpoints; state commands can write bounded local metadata.',
      ),
    );
    expect(
      help.stdout as String,
      isNot(contains('Every command is a local metadata read')),
    );
    expect(doctor.stdout as String, isNot(contains('keeps it live')));
    expect(help.stdout as String, isNot(contains('keeps it live')));
  });

  for (final provider in ['claude', 'codex', 'grok', 'antigravity']) {
    test('doctor gives $provider an exact signed-out recovery command',
        () async {
      final result = await runCli([
        'doctor',
        '--no-color',
        '--mock-provider=$provider',
        '--state=signed-out',
      ]);

      expectExitCode(result, 0);
      final out = result.stdout as String;
      expect(out, contains('[error, authoritative, quota plan, captured'));
      expect(out, contains('simulated signed-out state'));
      expect(out, contains('-> run: quotabot login $provider'));
    });
  }

  test('doctor human output explains provider drift and recovery', () async {
    final result = await runCli([
      'doctor',
      '--no-color',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('PROVIDER DRIFT'));
    expect(
      out,
      contains(
        '[provider drift, authoritative, quota plan, captured 60m ago]',
      ),
    );
    expect(out, contains('usage fell'));
    expect(out, contains('quotabot verify'));
  });

  test('doctor demo output labels local scope without duplicate badges',
      () async {
    final result = await runCollectCli(
      ['doctor', '--no-color'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(
      out,
      contains('[live, authoritative, quota plan, you@example.com'),
    );
    expect(out, contains('[live, passive local, metered plan, captured'));
    expect(out, contains('[in use, local runtime, loaded, captured'));
    expect(out, contains('[available, local runtime, cold, captured'));
    expect(out, isNot(contains('note: this machine only')));
    expect(out, isNot(contains('local fallback; other devices may differ')));
    expect(out, isNot(contains('local runtime, loaded, this machine')));
  });

  test('top snapshot keeps simulation provenance visible', () async {
    final result = await runCli([
      'top',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    expect(
      result.stdout as String,
      contains('SIMULATION - synthetic provider evidence'),
    );
  });

  test('doctor provenance does not call plan strings account identities', () {
    final planOnly = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'max',
      asOf: 1000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
    );
    final emailIdentity = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'you@example.com',
      asOf: 1000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
    );
    final manualIdentity = ProviderQuota(
      provider: 'custom-ai',
      displayName: 'Custom AI',
      account: 'work',
      source: providerQuotaManualSource,
      asOf: 1000,
      windows: [QuotaWindow(label: 'manual', usedPercent: 10)],
    );

    expect(cli.providerHasDoctorProvenanceIdentity(planOnly), isFalse);
    expect(cli.providerHasDoctorProvenanceIdentity(emailIdentity), isTrue);
    expect(cli.providerHasDoctorProvenanceIdentity(manualIdentity), isTrue);
  });

  test('future capture label does not present clock skew as fresh', () {
    expect(cli.routeCaptureAgeLabel(1050, 1000), cli.routeFutureCaptureLabel);
    expect(cli.routeCaptureAgeLabel(1000, 1000), 'captured just now');
    expect(cli.routeCaptureAgeLabel(999, 1000), 'captured 1s ago');
  });

  test('invalid simulation state is a usage error', () async {
    final result = await runCli([
      '--json',
      '--mock-provider=claude',
      '--state=missing',
    ]);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unknown --state "missing"'));
  });

  test('models rejects invalid capability filter values', () async {
    final cases = {
      '--min-context=1e309': '--min-context',
      '--min-context=-1': '--min-context',
      '--task=banana': '--task',
      '--tier-floor=banana': '--tier-floor',
      '--tier-ceiling=': '--tier-ceiling',
    };
    for (final entry in cases.entries) {
      final result = await runCollectCli(
        ['models', entry.key],
        environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
      );
      expectExitCode(result, 64);
      expect(result.stderr as String, contains(entry.value));
      expect(result.stdout as String, isEmpty);
    }
  });

  test('models rejects an inverted tier range', () async {
    final result = await runCollectCli(
      ['models', '--tier-floor=flagship', '--tier-ceiling=light'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('cannot be higher'));
    expect(result.stdout as String, isEmpty);
  });

  test('suggest rejects invalid risk policy values', () async {
    for (final value in ['banana', 'NaN', '-1', '6']) {
      final result = await runCollectCli(
        ['suggest', '--json', '--risk=$value'],
        environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
      );

      expectExitCode(result, 64);
      expect(result.stderr as String, contains('--risk'));
      expect(result.stdout as String, isEmpty);
    }
  });

  test('invalid simulated command does not emit normal output', () async {
    final result = await runCli([
      'suggest',
      '--mock-provider=claude',
      '--state=healthy',
      '--risk=bogus',
    ]);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('--risk'));
    expect(result.stdout as String, isEmpty);
  });

  test('unknown command fails before producing a snapshot', () async {
    final result = await runCollectCli(
      ['definitely-not-a-command', '--json'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('unknown command'));
    expect(result.stdout as String, isEmpty);
  });

  test('models says filters excluded everything, not "no models detected"',
      () async {
    final result = await runCollectCli(
      ['models', '--min-context=999000000'],
      environment: {'LOCALAPPDATA': temp.path, 'QUOTABOT_DEMO': '1'},
    );

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('no models match these filters'));
    expect(out, isNot(contains('no models detected')));
  });

  test('watch --once confirms an all-clear run instead of printing nothing',
      () async {
    final result = await runCli([
      'watch',
      '--once',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    expect(result.stdout as String, contains('all clear'));
  });

  test('watch human alerts include trust provenance', () async {
    final result = await runCli([
      'watch',
      '--once',
      '--no-color',
      '--mock-provider=claude',
      '--state=exhausted',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('SIMULATION - synthetic provider evidence'));
    expect(out, contains('[red] Claude 5h at 0% free'));
    expect(out, contains('fallback: wait for claude'));
    expect(out, contains('[live, authoritative, quota plan, captured'));
    expect(out, isNot(contains('claude (simulated)')));
  });

  test('watch provenance names cached route evidence without duplicate emails',
      () {
    cli.style = const AnsiStyle(false);
    const now = 2000;
    final alert = QuotaAlert(
      provider: 'codex',
      displayName: 'Codex',
      account: 'work@example.com',
      sourceClass: ProviderSourceClass.authoritativeLive,
      window: 'weekly',
      severity: AlertSeverity.red,
      freePercent: 4,
      asOf: 1940,
      routeTo: 'claude',
      routeDisplayName: 'Claude',
      routeAccount: 'home@example.com',
      routeSourceClass: ProviderSourceClass.authoritativeLive,
      routeFreePercent: 70,
    );
    final provenance = cli.quotaAlertProvenance(
      alert,
      [
        ProviderQuota(
          provider: 'codex',
          displayName: 'Codex',
          account: 'work@example.com',
          asOf: 1940,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 96)],
        ),
        ProviderQuota(
          provider: 'claude',
          displayName: 'Claude',
          account: 'home@example.com',
          asOf: 1400,
          stale: true,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 30)],
        ),
      ],
      now,
    );

    expect(alert.message, contains('work@example.com'));
    expect(alert.message, contains('home@example.com'));
    expect(provenance, contains('live, authoritative, quota plan'));
    expect(provenance, contains('route cached'));
    expect(provenance, contains('route authoritative'));
    expect(provenance, contains('route captured 10m ago'));
    expect(provenance, isNot(contains('work@example.com')));
    expect(provenance, isNot(contains('home@example.com')));
  });

  test('watch --once stays silent in JSON mode when nothing fires', () async {
    final result = await runCli([
      'watch',
      '--once',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    expect((result.stdout as String).trim(), isEmpty);
  });

  test('watch rejects invalid projected-waste thresholds', () async {
    final result = await runCli([
      'watch',
      '--once',
      '--waste-threshold=bad',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 64);
    expect(
      result.stderr as String,
      contains('--waste-threshold must be between 0 and 100'),
    );
  });

  test('watch rejects a malformed fixed interval before collecting', () async {
    final result = await runCli([
      'watch',
      '--once',
      '--interval=nope',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 64);
    expect(
      result.stderr as String,
      contains('--interval must be an integer number of seconds'),
    );
    expect(result.stdout as String, isNot(contains('all clear')));
  });

  test('watch diagnostics never echo a secret-capable webhook URL', () async {
    const webhook =
        'https://hooks.example.invalid/services/SYNTHETIC_SECRET_TOKEN';
    final result = await runCli([
      'watch',
      '--once',
      '--webhook=$webhook',
    ]);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('webhook host is not loopback'));
    expect(result.stderr as String, isNot(contains(webhook)));
    expect(result.stderr as String, isNot(contains('SYNTHETIC_SECRET_TOKEN')));

    final summary = cli.watchWebhookDeliverySummary(webhook);
    expect(summary, contains('webhook delivery enabled'));
    expect(summary, isNot(contains(webhook)));
    expect(summary, isNot(contains('SYNTHETIC_SECRET_TOKEN')));
  });

  test('watch health reports one failure edge and one recovery edge', () {
    final health = cli.WatchLoopHealth();

    expect(
      health.recordSnapshot(anyLive: false),
      'quotabot watch: quota refresh failed; retrying with backoff.',
    );
    expect(health.failStreak, 1);
    expect(health.recordPollFailed(), isNull);
    expect(health.failStreak, 2);

    expect(
      health.recordSnapshot(anyLive: true),
      'quotabot watch: quota refresh recovered.',
    );
    expect(health.failStreak, 0);
    expect(health.recordSnapshot(anyLive: true), isNull);
  });
}
