import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_report_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ProcessResult> runCli(List<String> args) {
    return runCollectCli(
      args,
      environment: {
        'LOCALAPPDATA': temp.path,
        'QUOTABOT_DEMO': '1',
      },
    );
  }

  test('report prints markdown by default', () async {
    final result = await runCli(['report']);

    expectExitCode(result, 0);
    final output = result.stdout as String;
    expect(output, startsWith('# quotabot weekly quota health'));
    expect(output, contains('Recommendation:'));
    expect(output, contains('| Provider | Account | State | Headroom |'));
    expect(output, contains('| Streak | Pace |'));
  });

  test('report --json prints the structured report', () async {
    final result = await runCli(['report', '--json']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['schema'], 'quotabot.report.v1');
    expect(json['providers'], isNotEmpty);
    final providers = json['providers'] as List;
    expect(
      providers.any(
        (provider) => (provider as Map<String, dynamic>)
            .containsKey('weekly_usable_day_streak'),
      ),
      isTrue,
    );
    expect(
      providers.any(
        (provider) => (provider as Map<String, dynamic>)
            .containsKey('weekly_contribution_calendar'),
      ),
      isTrue,
    );
    expect(
      providers.any(
        (provider) => (provider as Map<String, dynamic>)
            .containsKey('weekly_best_time_windows'),
      ),
      isTrue,
    );
  });

  test('stats prints sampled-day streaks', () async {
    final cache = Directory('${temp.path}/quotabot/cache')
      ..createSync(recursive: true);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final today = now - (now % Duration.secondsPerDay);
    File('${cache.path}/buckets_codex.json').writeAsStringSync(jsonEncode([
      _bucket(today - 2 * Duration.secondsPerDay, 80),
      _bucket(today - Duration.secondsPerDay, 75),
      _bucket(today, 70),
    ]));

    final result = await runCli(['stats']);

    expectExitCode(result, 0);
    final output = result.stdout as String;
    expect(output, contains('sampled days'));
    expect(output, contains('usable streak'));
    expect(output, contains('calendar .++'));
    expect(output, contains('best '));
    expect(output, contains('raw '));
    expect(output, contains('support='));
  });

  test('stats json includes a reset-aware schedule hint when supported',
      () async {
    final cache = Directory('${temp.path}/quotabot/cache')
      ..createSync(recursive: true);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nextHour =
        now - (now % Duration.secondsPerHour) + Duration.secondsPerHour;
    File('${cache.path}/buckets_codex.json').writeAsStringSync(jsonEncode([
      _bucketSamples(nextHour - Duration.secondsPerDay * 7, 92, 2),
    ]));

    final result = await runCli(['stats', '--json']);

    expectExitCode(result, 0);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final codex = json['codex'] as Map<String, dynamic>;
    final hint = codex['schedule_hint'] as Map<String, dynamic>;
    expect(hint['summary'], contains('before reset'));
    expect(hint['window'], isA<Map<String, dynamic>>());
  });
}

Map<String, dynamic> _bucket(int start, double headroom) => {
      's': start - (start % Duration.secondsPerHour),
      'n': 1,
      'sum': headroom,
      'sq': headroom * headroom,
      'min': headroom,
      'max': headroom,
      'x': 0,
      'h': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
    };

Map<String, dynamic> _bucketSamples(int start, double headroom, int samples) =>
    {
      's': start - (start % Duration.secondsPerHour),
      'n': samples,
      'sum': headroom * samples,
      'sq': headroom * headroom * samples,
      'min': headroom,
      'max': headroom,
      'x': 0,
      'h': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, samples, 0, 0, 0, 0, 0],
    };
