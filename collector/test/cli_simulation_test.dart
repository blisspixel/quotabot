import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/collector.dart';
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
    expect(json['provider'], 'claude');
    expect(json['source_class'], 'authoritative_live');
    expect(json['available'], isFalse);
    expect(json['headroom_percent'], 0);
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

  test('suggest human output names trust provenance', () async {
    final result = await runCli([
      'suggest',
      '--no-color',
      '--mock-provider=claude',
      '--state=healthy',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
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
    expect(out, contains('[live, authoritative, quota plan, captured'));
    expect(out, isNot(contains('Claude (simulated)')));
  });

  test('doctor human output labels failed quota-plan provenance', () async {
    final result = await runCli([
      'doctor',
      '--no-color',
      '--mock-provider=grok',
      '--state=signed-out',
    ]);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('[error, authoritative, quota plan, captured'));
    expect(out, contains('simulated signed-out state'));
  });

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
    expect(cli.routeCaptureAgeLabel(1000, 1000), 'captured 0s ago');
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
    expect(out, contains('[red] Claude 5h at 0% free'));
    expect(out, contains('fallback: wait for claude'));
    expect(out, contains('[live, authoritative, quota plan, captured'));
    expect(out, isNot(contains('simulated')));
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
}
