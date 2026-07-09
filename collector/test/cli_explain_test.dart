import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_explain_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    return runCollectCli(args, environment: {'LOCALAPPDATA': temp.path});
  }

  test('explain --json emits runtime access manifest without collecting',
      () async {
    final result = await runCli(['explain', '--reads', '--network', '--json']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.explain.v1');
    expect(json['mode'], 'runtime_access_manifest');
    expect(json['collection_executed'], isFalse);
    expect((json['privacy_boundary'] as Map)['spends_tokens'], isFalse);
    expect((json['providers'] as List), isNotEmpty);
  });

  test('explain --network omits read paths in JSON', () async {
    final result = await runCli(['explain', '--network', '--json']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final providers = (json['providers'] as List).cast<Map<String, dynamic>>();
    expect(providers.any((p) => p.containsKey('network')), isTrue);
    expect(providers.any((p) => p.containsKey('reads')), isFalse);
  });

  test('explain human output names the privacy boundary', () async {
    final result = await runCli(['explain', '--no-color']);

    expectExitCode(result, 0);
    final out = result.stdout as String;
    expect(out, contains('quotabot explain'));
    expect(out, contains('metadata only'));
    expect(out, contains('provider collection was not run'));
  });
}
