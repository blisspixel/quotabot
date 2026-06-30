import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/profiles.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_profile_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    final env = Map<String, String>.from(Platform.environment)
      ..['LOCALAPPDATA'] = temp.path
      ..['QUOTABOT_DEMO'] = '1'
      ..['NO_COLOR'] = '1';
    return Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/collect.dart', ...args],
      workingDirectory: Directory.current.path,
      environment: env,
    );
  }

  test('json snapshot applies a named local-only profile', () async {
    saveProfile(
      const QuotaProfile(
        name: 'local',
        routingPolicy: ProfileRoutingPolicy.localOnly,
      ),
      dir: Directory('${temp.path}/quotabot/profiles'),
    );

    final result = await runCli(['--json', '--profile=local']);

    expect(result.exitCode, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.v1');
    expect(json['profile'], 'local');
    final providers = json['providers'] as List;
    expect(providers, isNotEmpty);
    expect(providers.every((p) => p['kind'] == 'local'), isTrue);
    expect(providers.map((p) => p['provider']), isNot(contains('claude')));
  });

  test('missing profile is a usage error', () async {
    final result = await runCli(['--json', '--profile=missing']);

    expect(result.exitCode, 64);
    expect(result.stderr as String, contains('no profile named "missing"'));
  });
}
