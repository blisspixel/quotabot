import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_theme_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) => runCollectCli(
        args,
        environment: {'LOCALAPPDATA': temp.path},
      );

  test('theme list and rejected installs stay inside the temp config',
      () async {
    final listed = await runCli(['theme', 'list']);
    expectExitCode(listed, 0);
    expect(listed.stdout, contains('No user themes.'));
    expect(Directory('${temp.path}/quotabot/themes').existsSync(), isFalse);

    final help = await runCli(['theme', '--help']);
    expectExitCode(help, 0);
    expect(help.stdout, contains('quotabot theme install <git-url>'));
    expect(help.stdout, contains('hooks'));

    final blocked = await runCli(['theme', 'install', 'file:///tmp/theme']);
    expectExitCode(blocked, 1);
    expect(blocked.stderr, contains('git url is not allowed'));

    final usage = await runCli(['theme', 'remove', '../dark']);
    expectExitCode(usage, 64);
    expect(usage.stderr, contains('slug is invalid'));

    final missing = await runCli(['theme', 'remove', 'lagoon']);
    expectExitCode(missing, 1);
    expect(missing.stderr, contains('not removed'));
    expect(temp.listSync(), isEmpty);
  });
}
