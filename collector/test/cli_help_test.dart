import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/cli_command_help.dart';
import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_help_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) => runCollectCli(
        args,
        environment: {'LOCALAPPDATA': temp.path},
      );

  test('fresh is accepted for quota reads and rejected for unrelated commands',
      () async {
    final result = await runCli([
      'suggest',
      '--fresh',
      '--mock-provider=claude',
      '--state=healthy',
      '--json'
    ]);
    expectExitCode(result, 0);
    expect(result.stdout, contains('quotabot.suggest.v1'));
    final rejected = await runCli(['update', '--fresh']);
    expectExitCode(rejected, 64);
  });

  test('suggest help is focused, equivalent, and side-effect free', () async {
    final optionForm = await runCli(['suggest', '--help']);
    final commandForm = await runCli(['help', 'suggest']);

    expectExitCode(optionForm, 0);
    expectExitCode(commandForm, 0);
    expect(optionForm.stderr, isEmpty);
    expect(commandForm.stderr, isEmpty);
    expect(commandForm.stdout, optionForm.stdout);

    final output = optionForm.stdout as String;
    expect(output, contains('quotabot suggest [provider options]'));
    expect(output, contains('quotabot.suggest.v1'));
    expect(output, contains('quotabot.suggest_model.v1'));
    expect(output, contains('--provider-route'));
    expect(output, contains('model suggestions default to quota'));
    expect(output, contains('--local-first and --quota-stretch cannot'));
    expect(output, isNot(contains('--webhook')));
    expect(output, isNot(contains('--recover-drift')));
    expect(temp.listSync(), isEmpty);
  });

  test('models help states inspection defaults without routing options',
      () async {
    final optionForm = await runCli(['models', '--help']);
    final commandForm = await runCli(['help', 'models']);

    expectExitCode(optionForm, 0);
    expectExitCode(commandForm, 0);
    expect(commandForm.stdout, optionForm.stdout);

    final output = optionForm.stdout as String;
    expect(output, contains('quotabot models [model filters]'));
    expect(output, contains('quotabot.models.v1'));
    expect(output, contains('defaults to any for inspection'));
    expect(output, contains('--budget=any|quota|local'));
    expect(output, isNot(contains('--provider-route')));
    expect(output, isNot(contains('--local-first')));
    expect(temp.listSync(), isEmpty);
  });

  test('update help documents channels, verification, and exact targets',
      () async {
    final optionForm = await runCli(['update', '--help']);
    final commandForm = await runCli(['help', 'update']);

    expectExitCode(optionForm, 0);
    expectExitCode(commandForm, 0);
    expect(optionForm.stderr, isEmpty);
    expect(commandForm.stderr, isEmpty);
    expect(commandForm.stdout, optionForm.stdout);

    final output = optionForm.stdout as String;
    expect(output, contains('quotabot update [--check]'));
    expect(
      output,
      contains(
        '[--check] --target=vMAJOR.MINOR.PATCH[-rc.N] [--force]',
      ),
    );
    expect(output, contains('Release candidates follow the preview channel'));
    expect(output, contains('verifies its SHA-256 sidecar'));
    expect(output, contains('left in place'));
    expect(output, contains('quotabot.update.v1'));
    expect(temp.listSync(), isEmpty);
  });

  test('update rejects ambiguous controls before any network request',
      () async {
    for (final testCase in [
      (
        ['update', '--stable', '--preview'],
        '--stable and --preview are mutually exclusive',
      ),
      (
        ['update', '--target=v0.9.9', '--preview'],
        '--target cannot be combined with --stable or --preview',
      ),
      (
        ['update', '--check', '--force'],
        '--check and --force are mutually exclusive',
      ),
      (
        ['update', '--target=0.9.9'],
        '--target must be vMAJOR.MINOR.PATCH',
      ),
      (
        ['update', '--target=v${'9' * 100}.0.0'],
        '--target must be vMAJOR.MINOR.PATCH',
      ),
    ]) {
      final result = await runCli(testCase.$1);
      expectExitCode(result, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr as String, contains(testCase.$2));
    }
    expect(temp.listSync(), isEmpty);
  });

  test('global help remains available', () async {
    final result = await runCli(['--help']);

    expectExitCode(result, 0);
    expect(result.stderr, isEmpty);
    expect(result.stdout as String, contains('SEE QUOTA'));
    expect(result.stdout as String, contains('quotabot <command> [options]'));
  });

  test('unknown help targets fail as usage errors', () async {
    for (final args in [
      ['unknown-command', '--help'],
      ['help', 'unknown-command'],
    ]) {
      final result = await runCli(args);
      expectExitCode(result, 64);
      expect(result.stdout, isEmpty);
      expect(
        result.stderr as String,
        contains('unknown help topic "unknown-command"'),
      );
    }
  });

  test('top, doctor, and status help are focused and side-effect free',
      () async {
    for (final command in ['top', 'doctor', 'status']) {
      final optionForm = await runCli([command, '--help']);
      final commandForm = await runCli(['help', command]);
      expectExitCode(optionForm, 0);
      expectExitCode(commandForm, 0);
      expect(optionForm.stderr, isEmpty);
      expect(commandForm.stdout, optionForm.stdout);
      final output = optionForm.stdout as String;
      expect(output, isNot(contains('SEE QUOTA')));
      expect(output, contains('quotabot $command'));
    }

    final top = (await runCli(['top', '--help'])).stdout as String;
    expect(top, contains('--interval'));
    expect(top, contains('--sort'));
    expect(top, contains('--theme'));
    expect(top, contains('--truecolor'));
    expect(top, contains('gruvbox'));
    expect(top, contains('q or Ctrl-C'));
    expect(top, contains('m             inspect models'));
    expect(top, isNot(contains('--json')));

    final doctor = (await runCli(['doctor', '--help'])).stdout as String;
    expect(doctor, contains('read_state'));
    expect(doctor, contains('session projection'));

    final status = (await runCli(['status', '--help'])).stdout as String;
    expect(status, contains('windows'));
    expect(status, isNot(contains('read_state')));
    expect(temp.listSync(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('commands that take a required argument document it', () async {
    final check = (await runCli(['check', '--help'])).stdout as String;
    expect(check, contains('quotabot check <provider>'));
    expect(check, contains('--account'));
    expect(check, isNot(contains('SEE QUOTA')));

    final verify = (await runCli(['verify', '--help'])).stdout as String;
    expect(verify, contains('--require-live'));
    expect(verify, contains('--recover-drift'));
    expect(verify, isNot(contains('SEE QUOTA')));

    final login = (await runCli(['help', 'login'])).stdout as String;
    expect(login, contains('quotabot login <grok|antigravity|claude|codex>'));
    expect(login, isNot(contains('SEE QUOTA')));

    final logout = (await runCli(['logout', '--help'])).stdout as String;
    expect(logout, contains('quotabot logout <grok|antigravity|claude|codex>'));
    expect(temp.listSync(), isEmpty);
  });

  test('every known command has focused help or is on the global allowlist',
      () async {
    expect(
      commandsWithGlobalHelp,
      isNot(contains('top')),
      reason: 'top must not fall through to the global index',
    );
    for (final command in knownCliCommands.difference(commandsWithGlobalHelp)) {
      final result = await runCli([command, '--help']);
      expectExitCode(result, 0);
      expect(result.stderr, isEmpty, reason: command);
      expect(
        result.stdout as String,
        isNot(contains('SEE QUOTA')),
        reason: command,
      );
    }
    for (final command in commandsWithGlobalHelp) {
      final result = await runCli([command, '--help']);
      expectExitCode(result, 0);
      expect(result.stdout as String, contains('SEE QUOTA'), reason: command);
    }
    expect(temp.listSync(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('a closed stdout ends read-only commands without a stack trace',
      () async {
    final cases = [
      ['--help'],
      ['status', '--mock-provider=claude', '--state=healthy'],
      ['doctor', '--mock-provider=claude', '--state=healthy'],
      ['suggest', '--mock-provider=claude', '--state=healthy'],
      ['models', '--mock-provider=claude', '--state=healthy'],
    ];
    for (final args in cases) {
      final proc = await startCollectCli(
        args,
        environment: {'LOCALAPPDATA': temp.path},
      );
      final stderrText = StringBuffer();
      final stderrDone = proc.stderr
          .transform(utf8.decoder)
          .listen(stderrText.write)
          .asFuture<void>();
      await proc.stdout.listen((_) {}).cancel();
      final code = await proc.exitCode.timeout(const Duration(seconds: 30));
      await stderrDone.timeout(const Duration(seconds: 5));
      final errorText = stderrText.toString();
      expect(code, 0, reason: '${args.join(' ')}\n$errorText');
      expect(errorText, isNot(contains('Unhandled exception')),
          reason: args.join(' '));
      expect(errorText, isNot(contains('FileSystemException')),
          reason: args.join(' '));
      expect(errorText, isNot(contains('StdoutException')),
          reason: args.join(' '));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('concrete model suggestions reject provider-only policy flags',
      () async {
    for (final flag in [
      '--local-first',
      '--risk=1',
      '--tuned-burn',
      '--prefer=codex,claude',
    ]) {
      final result = await runCli([
        'suggest',
        '--task=hard',
        flag,
        '--mock-provider=claude',
        '--state=healthy',
      ]);
      expectExitCode(result, 64);
      expect(result.stdout, isEmpty);
      expect(
        result.stderr as String,
        contains('apply to provider suggestions only'),
        reason: flag,
      );
      expect(result.stderr as String, contains('--provider-route'));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
