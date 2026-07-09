import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/collector.dart';
import 'package:test/test.dart';

import '../bin/collect.dart' as cli;

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_verify_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    return runCollectCli(args, environment: {'LOCALAPPDATA': temp.path});
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
    expect(json['os'], Platform.operatingSystem);
    final providers = json['providers'] as List;
    expect(providers, hasLength(1));
    final claude = providers.single as Map<String, dynamic>;
    expect(claude['provider'], 'claude');
    expect(claude['state'], 'live');
    expect(claude['passed'], isTrue);
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
    expect(grok['state'], 'error');
    expect(grok['passed'], isTrue);
    final checks = (grok['checks'] as List).cast<Map<String, dynamic>>();
    final readOrReason = checks.firstWhere((c) => c['id'] == 'read_or_reason');
    expect(readOrReason['status'], 'pass');
    expect(readOrReason['detail'], contains('simulated signed-out state'));
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
    expect(out, contains('PASS'));
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
    expect(out, contains('[live, quota plan, captured'));
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
    expect(out, contains('[error, quota plan, captured'));
    expect(out, contains('read_or_reason'));
    expect(out, contains('simulated signed-out state'));
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
    expect(out, contains('[cached, quota plan, captured 60m ago]'));
    expect(out, contains('stale_honesty'));
    expect(out, contains('simulated stale cache'));
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
    for (final out in [cursorOut, quotaPlanOut]) {
      expect(out, contains('[metadata, metadata only, captured'));
      expect(out, contains('read_or_reason'));
      expect(out, contains('simulated metadata-only state'));
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
