import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/storage_keys.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

import '../bin/collect.dart' as cli;

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_verify_');
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    return runCollectCli(args, environment: {'LOCALAPPDATA': temp.path});
  }

  void seedAnalyticsHistoryConflict() {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    setQuotabotDirOverrideForTesting(temp);
    try {
      saveSnapshot(quota);
      File('${cacheDir().path}/history_${provider}_$account.jsonl')
          .writeAsStringSync(
        '${jsonEncode(ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          asOf: now + 60,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 35)],
        ).toJson())}\n',
      );
      expect(
        analyticsStorageNotice(provider, account: account)?.tiers,
        ['history'],
      );
    } finally {
      setQuotabotDirOverrideForTesting(null);
    }
  }

  test('verify --json passes a healthy simulated snapshot', () async {
    final result = await runCli([
      'verify',
      '--json',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.verify.v1');
    expect(json['passed'], isTrue);
    expect(json['honesty_passed'], isTrue);
    expect(json['require_live'], isFalse);
    expect(json['all_live_reads_succeeded'], isFalse,
        reason: 'simulation must never claim that a live adapter ran');
    expect(json['os'], Platform.operatingSystem);
    final providers = json['providers'] as List;
    expect(providers, hasLength(1));
    final claude = providers.single as Map<String, dynamic>;
    expect(claude['provider'], 'claude');
    expect(claude['source_class'], 'authoritative_live');
    expect(claude['state'], 'live');
    expect(claude['passed'], isTrue);
    expect(claude['live_read_succeeded'], isFalse);
    final providerChecks =
        (claude['checks'] as List).cast<Map<String, dynamic>>();
    expect(
      providerChecks.any(
        (check) => check['id'] == 'source_class' && check['status'] == 'pass',
      ),
      isTrue,
    );
    final fleet = (json['fleet_checks'] as List).cast<Map<String, dynamic>>();
    expect(
      fleet.any((c) => c['id'] == 'schema_contract' && c['status'] == 'pass'),
      isTrue,
    );
    expect(
      fleet.any((c) => c['id'] == 'claimed_coverage' && c['status'] == 'info'),
      isTrue,
      reason: 'simulation narrows the read, so coverage must report itself '
          'skipped instead of failing on absent providers',
    );
    final runtimeAccess = json['runtime_access'] as Map<String, dynamic>;
    expect(runtimeAccess['schema'], 'quotabot.explain.v1');
    expect(runtimeAccess['mode'], 'runtime_access_manifest');
    expect(runtimeAccess['collection_executed'], isFalse);
    expect(runtimeAccess['providers'], isEmpty);
    expect(
      fleet.any(
          (c) => c['id'] == 'runtime_access_boundary' && c['status'] == 'info'),
      isTrue,
    );
  });

  test('verify passes a truthfully signed-out simulated snapshot', () async {
    final result = await runCli([
      'verify',
      '--json',
      '--mock-provider=grok',
      '--state=signed-out',
    ]);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['passed'], isTrue);
    final grok = (json['providers'] as List).single as Map<String, dynamic>;
    expect(grok['source_class'], 'authoritative_live');
    expect(grok['state'], 'error');
    expect(grok['passed'], isTrue);
    expect(grok['live_read_succeeded'], isFalse);
    final checks = (grok['checks'] as List).cast<Map<String, dynamic>>();
    final readOrReason = checks.firstWhere((c) => c['id'] == 'read_or_reason');
    expect(readOrReason['status'], 'pass');
    expect(readOrReason['detail'], contains('simulated signed-out state'));
  });

  test('verify fails a provider-drift simulation with additive evidence',
      () async {
    final result = await runCli([
      'verify',
      '--json',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 65);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['passed'], isFalse);
    final provider = (json['providers'] as List).single as Map<String, dynamic>;
    expect(provider['state'], 'cached');
    expect(provider['stale'], isTrue);
    expect(provider['drift_reason'], contains('usage fell'));
    expect(provider['drift_observed_at'], isA<int>());
    final checks = (provider['checks'] as List).cast<Map<String, dynamic>>();
    final drift = checks.firstWhere((check) => check['id'] == 'provider_drift');
    expect(drift['status'], 'fail');
    expect(drift['detail'], contains('not routable'));
  });

  test('drift recovery requires an explicit noninteractive confirmation',
      () async {
    const unsafeAccount = 'work@example.com;Write-Output injected';
    final result = await runCli([
      'verify',
      '--recover-drift=codex',
      '--account=$unsafeAccount',
      '--json',
    ]);

    expectExitCode(result, 64);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('changes one local quota baseline'));
    expect(result.stderr, contains('rerunning the same command with --yes'));
    expect(result.stderr, isNot(contains(unsafeAccount)));
    expect(result.stderr, isNot(contains('--recover-drift=codex')));
  });

  test('drift recovery rejects filters and simulation before any live read',
      () async {
    final result = await runCli([
      'verify',
      '--recover-drift=claude',
      '--account=credential:test-account',
      '--yes',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 64);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('cannot be combined'));
    expect(result.stderr, contains('--mock-provider'));
    expect(result.stderr, contains('--state'));
  });

  test('drift recovery reports an exact missing baseline without collecting',
      () async {
    final result = await runCli([
      'verify',
      '--recover-drift=codex',
      '--account=credential:missing-account',
      '--yes',
      '--json',
    ]);

    expectExitCode(result, 65);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.drift-recovery.v1');
    expect(json['provider'], 'codex');
    expect(json['account'], 'credential:missing-account');
    expect(json['recovered'], isFalse);
    expect(json['status'], 'baseline_not_found');
    expect(json, isNot(contains('runtime_access')));
  });

  test('drift recovery rejects incomplete and unsupported targets', () async {
    final missingAccount = await runCli([
      'verify',
      '--recover-drift=codex',
      '--yes',
    ]);
    final unsupported = await runCli([
      'verify',
      '--recover-drift=not-a-provider',
      '--account=exact',
      '--yes',
      '--json',
    ]);

    expectExitCode(missingAccount, 64);
    expect(missingAccount.stderr, contains('--account=EXACT_ACCOUNT'));
    expectExitCode(unsupported, 64);
    final json =
        jsonDecode(unsupported.stdout as String) as Map<String, dynamic>;
    expect(json['status'], 'unsupported_target');
    expect(json['recovered'], isFalse);
  });

  test('drift recovery rejects conflicting repeated exact targets', () async {
    final result = await runCli([
      'verify',
      '--recover-drift=codex',
      '--recover-drift=claude',
      '--account=first',
      '--account=second',
      '--yes',
    ]);

    expectExitCode(result, 64);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('one exact provider and account'));
  });

  test('analytics recovery inspection is read-only and machine-readable',
      () async {
    seedAnalyticsHistoryConflict();
    final cache = Directory('${temp.path}/quotabot/cache');
    final before = {
      for (final file in cache.listSync().whereType<File>())
        file.uri.pathSegments.last: file.readAsBytesSync(),
    };
    final recoveryRoot = Directory('${temp.path}/quotabot/analytics-recovery');
    expect(recoveryRoot.existsSync(), isFalse);

    final result = await runCli([
      'verify',
      '--recover-analytics=codex',
      '--account=acct',
      '--tier=history',
      '--json',
    ]);

    expectExitCode(result, 0);
    expect(result.stderr, isEmpty);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.analytics-recovery.v1');
    expect(json['mode'], 'inspect');
    expect(json['ready'], isTrue);
    expect(json['recovered'], isFalse);
    expect(json['status'], 'ready');
    expect(json['active_tiers'], ['history']);
    expect(json, isNot(contains('runtime_access')));
    final impact = json['impact'] as Map<String, dynamic>;
    expect(impact['selected_tier'], 'would be archived, then restarted empty');
    expect(impact['exact_merge_performed'], isFalse);
    expect(recoveryRoot.existsSync(), isFalse);
    final human = await runCli([
      'verify',
      '--recover-analytics=codex',
      '--account=acct',
      '--tier=history',
      '--no-color',
    ]);
    expectExitCode(human, 0);
    expect(human.stdout, contains('READY'));
    expect(human.stdout, contains('Rerun this exact command with --yes'));
    expect(human.stdout, contains('Exact merge is unavailable'));
    expect(human.stdout, contains('unselected analytics remain unchanged'));
    expect(
      {
        for (final file in cache.listSync().whereType<File>())
          file.uri.pathSegments.last: file.readAsBytesSync(),
      },
      before,
    );
  });

  test('analytics recovery confirmation archives only the selected tier',
      () async {
    seedAnalyticsHistoryConflict();

    final result = await runCli([
      'verify',
      '--recover-analytics=codex',
      '--account=acct',
      '--tier=history',
      '--yes',
      '--json',
    ]);

    expectExitCode(result, 0);
    expect(result.stderr, isEmpty);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.analytics-recovery.v1');
    expect(json['mode'], 'recover');
    expect(json['recovered'], isTrue);
    expect(json['status'], 'recovered');
    expect(json['active_tiers'], isEmpty);
    expect(json['archived_roles'], contains('legacy-history'));
    final impact = json['impact'] as Map<String, dynamic>;
    expect(impact['exact_merge_performed'], isFalse);
    expect(impact['selected_tier'], 'archived, then restarted empty');
    final bundle = Directory(json['evidence_bundle'] as String);
    expect(bundle.existsSync(), isTrue);
    expect(File('${bundle.path}/manifest.json').existsSync(), isTrue);
    expect(
      File('${temp.path}/quotabot/cache/codex_account_${accountIdentityDigest('acct')}.json')
          .existsSync(),
      isTrue,
    );
    final retry = await runCli([
      'verify',
      '--recover-analytics=codex',
      '--account=acct',
      '--tier=history',
      '--yes',
      '--json',
    ]);
    expectExitCode(retry, 0);
    final retryJson =
        jsonDecode(retry.stdout as String) as Map<String, dynamic>;
    expect(retryJson['status'], 'already_recovered');
    expect(retryJson['recovered'], isTrue);
    expect(retryJson['evidence_bundle'], json['evidence_bundle']);
  });

  test('analytics recovery rejects mixed recovery modes before storage access',
      () async {
    final result = await runCli([
      'verify',
      '--recover-analytics=codex',
      '--recover-drift=codex',
      '--account=acct',
      '--tier=history',
      '--yes',
    ]);

    expectExitCode(result, 64);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('cannot be combined'));
    expect(result.stderr, contains('--recover-drift'));
    expect(
      Directory('${temp.path}/quotabot/analytics-recovery').existsSync(),
      isFalse,
    );
  });

  test('analytics recovery maps target and storage failures to stable exits',
      () async {
    final unsupported = await runCli([
      'verify',
      '--recover-analytics=not-a-provider',
      '--account=acct',
      '--tier=history',
      '--json',
    ]);
    final healthy = await runCli([
      'verify',
      '--recover-analytics=codex',
      '--account=acct',
      '--tier=history',
      '--json',
    ]);
    seedAnalyticsHistoryConflict();
    File('${temp.path}/quotabot/analytics-recovery')
        .writeAsStringSync('not a directory');
    final archiveFailure = await runCli([
      'verify',
      '--recover-analytics=codex',
      '--account=acct',
      '--tier=history',
      '--yes',
      '--json',
    ]);

    expectExitCode(unsupported, 64);
    expect(
      (jsonDecode(unsupported.stdout as String)
          as Map<String, dynamic>)['status'],
      'unsupported_target',
    );
    expectExitCode(healthy, 65);
    expect(
      (jsonDecode(healthy.stdout as String) as Map<String, dynamic>)['status'],
      'no_active_conflict',
    );
    expectExitCode(archiveFailure, 65);
    expect(
      (jsonDecode(archiveFailure.stdout as String)
          as Map<String, dynamic>)['status'],
      'archive_failed',
    );
  });

  test('verify prints a human summary with cross-check pointers', () async {
    final result = await runCli([
      'verify',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('quotabot verify'));
    expect(out, contains('honesty checks over one snapshot'));
    expect(out, isNot(contains('honesty checks over one live read')));
    expect(out, contains('HONEST'));
    expect(out, contains('/usage'));
    expect(out, contains('runtime access manifest only'));
    expect(out, contains('quotabot verify --json'));
  });

  test('verify human output names trust provenance', () async {
    final result = await runCli([
      'verify',
      '--no-color',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('[live, authoritative, quota plan, captured'));
  });

  test('verify human output labels truthful read failures', () async {
    final result = await runCli([
      'verify',
      '--no-color',
      '--mock-provider=grok',
      '--state=signed-out',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('[error, authoritative, quota plan, captured'));
    expect(out, contains('read_or_reason'));
    expect(out, contains('simulated signed-out state'));
    expect(out, contains('HONEST'));
  });

  test('verify human output explains cached snapshots', () async {
    final result = await runCli([
      'verify',
      '--no-color',
      '--mock-provider=claude',
      '--state=stale',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(
      out,
      contains('[cached, authoritative, quota plan, captured 60m ago]'),
    );
    expect(out, contains('stale_honesty'));
    expect(out, contains('simulated stale cache'));
    expect(out, contains('HONEST'));
  });

  test('verify --require-live turns an honest simulation into a strict failure',
      () async {
    final result = await runCli([
      'verify',
      '--json',
      '--require-live',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 65);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['require_live'], isTrue);
    expect(json['honesty_passed'], isTrue);
    expect(json['all_live_reads_succeeded'], isFalse);
    expect(json['passed'], isFalse);
  });

  test('verify --require-live fails closed when filters select no adapters',
      () async {
    final excludeAll = kProviderAdapterRegistry
        .map((registration) => registration.id)
        .join(',');
    final machine = await runCli([
      'verify',
      '--json',
      '--require-live',
      '--exclude=$excludeAll',
    ]);
    final human = await runCli([
      'verify',
      '--no-color',
      '--require-live',
      '--exclude=$excludeAll',
    ]);

    expectExitCode(machine, 65);
    final json = jsonDecode(machine.stdout as String) as Map<String, dynamic>;
    expect(json['honesty_passed'], isTrue);
    expect(json['selected_adapter_count'], 0);
    expect(json['live_read_scope_valid'], isFalse);
    expect(json['all_live_reads_succeeded'], isFalse);
    expect(json['passed'], isFalse);
    expect(json['providers'], isEmpty);
    final runtimeAccess = json['runtime_access'] as Map<String, dynamic>;
    expect(runtimeAccess['collection_executed'], isTrue);
    expect(runtimeAccess['providers'], isEmpty);

    expectExitCode(human, 65);
    expect(
      human.stdout as String,
      contains('strict live verification selected no provider adapters'),
    );
  });

  test('verify human output names provider drift and trusted provenance',
      () async {
    final result = await runCli([
      'verify',
      '--no-color',
      '--mock-provider=claude',
      '--state=provider-drift',
    ]);

    expectExitCode(result, 65);
    final out = result.stdout as String;
    expect(out, contains('PROVIDER DRIFT'));
    expect(out, contains('FAIL'));
    expect(out, contains('provider_drift'));
    expect(out, contains('usage fell'));
    expect(
      out,
      contains(
        '[provider drift, authoritative, quota plan, captured 60m ago]',
      ),
    );
  });

  test('verify human output explains metadata-only snapshots', () async {
    final cursorResult = await runCli([
      'verify',
      '--no-color',
      '--mock-provider=cursor',
      '--state=metadata',
    ]);
    final quotaPlanResult = await runCli([
      'verify',
      '--no-color',
      '--mock-provider=claude',
      '--state=metadata',
    ]);

    expectExitCode(cursorResult, 0);
    expectExitCode(quotaPlanResult, 0);
    final cursorOut = cursorResult.stdout as String;
    final quotaPlanOut = quotaPlanResult.stdout as String;
    expect(cursorOut, contains('[metadata, passive local, captured'));
    expect(quotaPlanOut, contains('[metadata, authoritative, captured'));
    for (final out in [cursorOut, quotaPlanOut]) {
      expect(out, contains('read_or_reason'));
      expect(out, contains('simulated metadata-only state'));
      expect(out, isNot(contains('metadata only')));
    }
  });

  test('verify provenance matching uses row order for duplicate accounts', () {
    const now = 2000;
    final olderManual = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'same',
      source: providerQuotaManualSource,
      asOf: 1000,
      windows: [QuotaWindow(label: 'manual', usedPercent: 20)],
    );
    final newerPlan = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'same',
      asOf: 2000,
      windows: [QuotaWindow(label: '5h', usedPercent: 40)],
    );
    final report = buildVerificationReport(
      [olderManual, newerPlan],
      now,
      os: Platform.operatingSystem,
      filtered: true,
    );

    expect(
      cli.quotaForVerificationProvenance(
        [olderManual, newerPlan],
        report.providers[1],
        1,
      ),
      same(newerPlan),
    );
  });

  test('verify rejects an unknown simulation state as a usage error', () async {
    final result = await runCli([
      'verify',
      '--mock-provider=claude',
      '--state=nonsense',
    ]);

    expectExitCode(result, 64);
  });
}
