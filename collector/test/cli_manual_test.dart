import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_manual_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    return runCollectCli(args, environment: _isolatedEnv(temp));
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

    expectExitCode(set, 0);
    final saved = jsonDecode(set.stdout as String) as Map<String, dynamic>;
    expect(saved['schema'], 'quotabot.manual.v1');
    expect(saved['entry']['provider'], 'custom-ai');

    final list = await runCli(['manual', 'list', '--json']);
    expectExitCode(list, 0);
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
    expectExitCode(removed, 0);
    expect(
      jsonDecode(removed.stdout as String) as Map<String, dynamic>,
      containsPair('removed', true),
    );

    final empty = await runCli(['manual', 'list', '--json']);
    expectExitCode(empty, 0);
    expect(
      (jsonDecode(empty.stdout as String) as Map<String, dynamic>)['entries'],
      isEmpty,
    );
  });

  test('manual set rejects missing required quota fields', () async {
    final result = await runCli(['manual', 'set', 'custom-ai', '--used', '3']);

    expectExitCode(result, 64);
    expect(result.stderr as String, contains('usage: quotabot manual set'));
  });

  test('doctor disambiguates duplicate manual accounts', () async {
    for (final account in ['work', 'home']) {
      final result = await runCli([
        'manual',
        'set',
        'custom-ai',
        '--display-name',
        'Custom AI',
        '--account',
        account,
        '--used',
        account == 'work' ? '3' : '4',
        '--limit',
        '10',
        '--reset',
        '1893456000',
      ]);
      expectExitCode(result, 0);
    }

    final doctor = await runCli(['doctor', '--no-color']);

    expectExitCode(doctor, 0);
    final out = doctor.stdout as String;
    expect(out, contains('Custom AI (work)'));
    expect(out, contains('Custom AI (home)'));
    expect(out, contains('[live, manual, work, captured'));
    expect(out, contains('[live, manual, home, captured'));
  });

  test('watch preserves safe non-email manual account provenance', () async {
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
      '10',
      '--limit',
      '10',
      '--reset',
      '1893456000',
    ]);
    expectExitCode(set, 0);

    final watch = await runCli(['watch', '--once', '--no-color']);

    expectExitCode(watch, 0);
    final out = watch.stdout as String;
    expect(out, contains('[red] Custom AI monthly at 0% free'));
    expect(out, contains('[live, manual, work, captured'));
  });
}

Map<String, String> _isolatedEnv(Directory temp) => {
      'LOCALAPPDATA': '${temp.path}${Platform.pathSeparator}LocalAppData',
      'APPDATA': '${temp.path}${Platform.pathSeparator}AppData',
      'USERPROFILE': '${temp.path}${Platform.pathSeparator}UserProfile',
      'HOME': '${temp.path}${Platform.pathSeparator}Home',
      'XDG_CONFIG_HOME': '${temp.path}${Platform.pathSeparator}XdgConfig',
      'XDG_DATA_HOME': '${temp.path}${Platform.pathSeparator}XdgData',
      'QUOTABOT_DEMO': '0',
      'NVIDIA_API_KEY': '',
      'nvapi': '',
      'OLLAMA_HOST': 'http://127.0.0.1:9',
      'LMSTUDIO_HOST': 'http://127.0.0.1:9',
      'LEMONADE_HOST': 'http://127.0.0.1:9',
    };
