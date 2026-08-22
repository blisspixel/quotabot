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

  test(
    'manual set list and remove round-trip through the CLI',
    () async {
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
        _futureReset(),
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
    },
    timeout: Timeout.factor(2),
  );

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
        _futureReset(),
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
  }, timeout: Timeout.factor(2));

  test('check selects a live account after a spent first manual account',
      () async {
    for (final spec in const [
      (account: 'spent', used: '10'),
      (account: 'live', used: '2'),
    ]) {
      final saved = await runCli([
        'manual',
        'set',
        'custom-check',
        '--account',
        spec.account,
        '--used',
        spec.used,
        '--limit',
        '10',
        '--reset',
        _futureReset(),
      ]);
      expectExitCode(saved, 0);
    }

    final checked = await runCli(['check', 'custom-check', '--json']);
    final exact = await runCli([
      'check',
      'custom-check',
      '--json',
      '--account=spent',
    ]);
    final human = await runCli([
      'check',
      'custom-check',
      '--no-color',
    ]);
    final missing = await runCli([
      'check',
      'custom-check',
      '--json',
      '--account=missing',
    ]);

    expectExitCode(checked, 0);
    final json = jsonDecode(checked.stdout as String) as Map<String, dynamic>;
    expect(json['account'], 'live');
    expect(json['matched_account_count'], 2);
    expect(json['selection_mode'], 'best_available');
    expect(json['live_read_succeeded'], isFalse);
    expect(json['available'], isTrue);
    expect(json['headroom_percent'], 80);

    expectExitCode(exact, 69);
    final exactJson =
        jsonDecode(exact.stdout as String) as Map<String, dynamic>;
    expect(exactJson['account'], 'spent');
    expect(exactJson['matched_account_count'], 2);
    expect(exactJson['selection_mode'], 'exact');
    expect(exactJson['available'], isFalse);
    expect(exactJson['headroom_percent'], 0);

    expectExitCode(human, 0);
    expect(human.stdout as String, contains('(live): available'));

    expectExitCode(missing, 64);
    final missingJson =
        jsonDecode(missing.stdout as String) as Map<String, dynamic>;
    expect(missingJson['found'], isFalse);
    expect(missingJson['provider'], 'custom-check');
    expect(missingJson['account'], 'missing');
    expect(missingJson['reason'], 'account_not_found');
  }, timeout: Timeout.factor(2));

  test('check resolves equal manual accounts by stable account key', () async {
    for (final account in const ['zeta', 'alpha']) {
      final saved = await runCli([
        'manual',
        'set',
        'custom-tie',
        '--account',
        account,
        '--used',
        '2',
        '--limit',
        '10',
        '--reset',
        _futureReset(),
      ]);
      expectExitCode(saved, 0);
    }

    final checked = await runCli(['check', 'custom-tie', '--json']);

    expectExitCode(checked, 0);
    final json = jsonDecode(checked.stdout as String) as Map<String, dynamic>;
    expect(json['account'], 'alpha');
    expect(json['available'], isTrue);
    expect(json['headroom_percent'], 80);
  }, timeout: Timeout.factor(2));

  test('check does not treat a custom display name as a built-in provider',
      () async {
    final saved = await runCli([
      'manual',
      'set',
      'custom-ai',
      '--display-name',
      'Claude',
      '--used=1',
      '--limit=10',
      '--reset=${_futureReset()}',
    ]);
    expectExitCode(saved, 0);

    final builtin = await runCli(['check', 'claude', '--json']);
    final builtinJson =
        jsonDecode(builtin.stdout as String) as Map<String, dynamic>;
    expect(builtinJson['provider'], 'claude');
    expect(builtinJson['provider'], isNot('custom-ai'));
    if (builtinJson['found'] == false) {
      expectExitCode(builtin, 69);
      expect(builtinJson['reason'], 'provider_not_returned');
    } else {
      expect(builtinJson.containsKey('available'), isTrue);
    }

    final display = await runCli(['check', 'Claude', '--json']);
    final displayJson =
        jsonDecode(display.stdout as String) as Map<String, dynamic>;
    expect(displayJson['provider'], 'claude');
    expect(displayJson['provider'], isNot('custom-ai'));
    if (displayJson['found'] == false) {
      expectExitCode(display, 69);
      expect(displayJson['reason'], 'provider_not_returned');
    } else {
      expect(displayJson.containsKey('available'), isTrue);
    }

    final custom = await runCli(['check', 'custom-ai', '--json']);
    expectExitCode(custom, 0);
    final customJson =
        jsonDecode(custom.stdout as String) as Map<String, dynamic>;
    expect(customJson['provider'], 'custom-ai');
    expect(customJson['available'], isTrue);
  }, timeout: Timeout.factor(2));

  test('check still resolves a custom provider by its display name', () async {
    final saved = await runCli([
      'manual',
      'set',
      'custom-ai',
      '--display-name',
      'Custom AI',
      '--used=1',
      '--limit=10',
      '--reset=${_futureReset()}',
    ]);
    expectExitCode(saved, 0);

    final checked = await runCli(['check', 'Custom AI', '--json']);
    expectExitCode(checked, 0);
    final json = jsonDecode(checked.stdout as String) as Map<String, dynamic>;
    expect(json['provider'], 'custom-ai');
    expect(json['available'], isTrue);
  }, timeout: Timeout.factor(2));

  test('check identifies a filtered manual provider as hidden', () async {
    final saved = await runCli([
      'manual',
      'set',
      'custom-filter',
      '--used=1',
      '--limit=10',
      '--reset=${_futureReset()}',
    ]);
    expectExitCode(saved, 0);

    final machine = await runCli([
      'check',
      'custom-filter',
      '--json',
      '--exclude=custom-filter',
    ]);
    final human = await runCli([
      'check',
      'custom-filter',
      '--no-color',
      '--exclude=custom-filter',
    ]);

    expectExitCode(machine, 64);
    final json = jsonDecode(machine.stdout as String) as Map<String, dynamic>;
    expect(json['provider'], 'custom-filter');
    expect(json['found'], isFalse);
    expect(json['reason'], 'filtered');

    expectExitCode(human, 64);
    expect(human.stderr as String, contains('hidden by the current'));
    expect(human.stderr as String, isNot(contains('no provider named')));
  }, timeout: Timeout.factor(2));

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
      _futureReset(),
    ]);
    expectExitCode(set, 0);

    final watch = await runCli(['watch', '--once', '--no-color']);

    expectExitCode(watch, 0);
    final out = watch.stdout as String;
    expect(out, contains('[red] Custom AI monthly at 0% free'));
    expect(out, contains('[live, manual, work, captured'));
  });
}

String _futureReset() => (DateTime.now()
            .toUtc()
            .add(const Duration(days: 30))
            .millisecondsSinceEpoch ~/
        1000)
    .toString();

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
