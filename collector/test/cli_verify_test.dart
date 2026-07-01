import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

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
    expect(out, contains('quotabot verify --json'));
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
