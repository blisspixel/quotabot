import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_manual_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    final env = Map<String, String>.from(Platform.environment)
      ..['LOCALAPPDATA'] = temp.path
      ..['NO_COLOR'] = '1';
    return Process.run(
      Platform.resolvedExecutable,
      ['bin/collect.dart', ...args],
      workingDirectory: Directory.current.path,
      environment: env,
    );
  }

  test('manual set list and remove round-trip through the CLI', () async {
    final set = await runCli([
      'manual',
      'set',
      'custom-ai',
      '--display-name',
      'Custom AI',
      '--account',
      'work',
      '--window',
      'monthly',
      '--used',
      '3',
      '--limit',
      '10',
      '--reset',
      '1893456000',
      '--json',
    ]);

    expect(set.exitCode, 0);
    final saved = jsonDecode(set.stdout as String) as Map<String, dynamic>;
    expect(saved['schema'], 'quotabot.manual.v1');
    expect(saved['entry']['provider'], 'custom-ai');

    final list = await runCli(['manual', 'list', '--json']);
    expect(list.exitCode, 0);
    final listed = jsonDecode(list.stdout as String) as Map<String, dynamic>;
    expect(listed['entries'], hasLength(1));
    expect(listed['entries'][0]['used'], 3);

    final removed = await runCli([
      'manual',
      'remove',
      'custom-ai',
      '--account',
      'work',
      '--json',
    ]);
    expect(removed.exitCode, 0);
    expect(
      jsonDecode(removed.stdout as String) as Map<String, dynamic>,
      containsPair('removed', true),
    );

    final empty = await runCli(['manual', 'list', '--json']);
    expect(
      (jsonDecode(empty.stdout as String) as Map<String, dynamic>)['entries'],
      isEmpty,
    );
  });

  test('manual set rejects missing required quota fields', () async {
    final result = await runCli(['manual', 'set', 'custom-ai', '--used', '3']);

    expect(result.exitCode, 64);
    expect(result.stderr as String, contains('usage: quotabot manual set'));
  });
}
