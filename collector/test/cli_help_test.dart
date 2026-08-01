import 'dart:io';

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
  });
}
