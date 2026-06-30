import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  Future<ProcessResult> runCli(List<String> args) {
    final env = Map<String, String>.from(Platform.environment)
      ..['QUOTABOT_DEMO'] = '1'
      ..['NO_COLOR'] = '1';
    return Process.run(
      Platform.resolvedExecutable,
      ['bin/collect.dart', ...args],
      workingDirectory: Directory.current.path,
      environment: env,
    );
  }

  test('report prints markdown by default', () async {
    final result = await runCli(['report']);

    expect(result.exitCode, 0);
    final output = result.stdout as String;
    expect(output, startsWith('# quotabot weekly quota health'));
    expect(output, contains('Recommendation:'));
    expect(output, contains('| Provider | Account | State | Headroom |'));
  });

  test('report --json prints the structured report', () async {
    final result = await runCli(['report', '--json']);

    expect(result.exitCode, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.report.v1');
    expect(json['providers'], isNotEmpty);
  });
}
