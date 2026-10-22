import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/claude_session_projection.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  const now = 1760000000;
  const transcriptCanary = 'CANARY-transcript-path-9f3a';
  const sessionCanary = 'CANARY-session-id-22b1';
  const workspaceCanary = 'CANARY-workspace-cwd-77c4';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_claude_status_');
    setQuotabotDirOverrideForTesting(temp);
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Map<String, Object?> payload({
    Object? rateLimits,
    bool includeLimits = true,
  }) =>
      {
        'transcript_path': transcriptCanary,
        'session_id': sessionCanary,
        'cwd': workspaceCanary,
        'session_name': 'private session title',
        'prompt_id': 'CANARY-prompt-id',
        'model': {'id': 'claude-opus', 'display_name': 'Opus'},
        'workspace': {'current_dir': workspaceCanary, 'project_dir': '/repo'},
        'cost': {'total_cost_usd': 4.5, 'total_lines_added': 12},
        'context_window': {
          'used_percentage': 80,
          'remaining_percentage': 20,
          'current_usage': {'input_tokens': 10},
        },
        if (includeLimits) 'rate_limits': rateLimits,
      };

  Map<String, Object> window(num used, int resetsAt) => {
        'used_percentage': used,
        'resets_at': resetsAt,
      };

  Map<String, Object?> planLimits({
    Object? fiveHour = const {'used_percentage': 23.5, 'resets_at': now + 3600},
    Object? sevenDay = const {
      'used_percentage': 41,
      'resets_at': now + 3 * 86400,
    },
    bool includeFiveHour = true,
    bool includeSevenDay = true,
    Map<String, Object?> extra = const {},
  }) =>
      {
        if (includeFiveHour) 'five_hour': fiveHour,
        if (includeSevenDay) 'seven_day': sevenDay,
        'spend_limit': {
          'used_percentage': 150,
          'used_usd': 314.12,
          'limit_usd': 500,
          'period': 'monthly',
          'resets_at': now + 20 * 86400,
        },
        ...extra,
      };

  ClaudeStatusIngest ingest(Object? decoded, {int at = now}) =>
      ingestClaudeStatusObject(decoded, now: at);

  String storedText() => claudeStatusProjectionFile().readAsStringSync();

  test('help is for a terminal invocation without --show', () {
    expect(
      claudeStatusShouldShowHelp(show: false, stdinIsTerminal: true),
      isTrue,
    );
    expect(
      claudeStatusShouldShowHelp(show: true, stdinIsTerminal: true),
      isFalse,
    );
    expect(
      claudeStatusShouldShowHelp(show: false, stdinIsTerminal: false),
      isFalse,
    );
  });

  test('stores plan windows and drops every other field', () async {
    final home = Directory('${temp.path}/home/.claude')
      ..createSync(recursive: true);
    final settings = File('${home.path}/settings.json');
    settings.writeAsStringSync('{"statusLine":{"command":"keep-me"}}');
    final before = settings.readAsBytesSync();

    final result = await runClaudeStatusCommand(
      show: false,
      asJson: false,
      stdin: Stream.value(
        utf8.encode(jsonEncode(payload(rateLimits: planLimits()))),
      ),
      now: now,
    );

    expect(result.exitCode, 0);
    expect(result.stderrText, isEmpty);
    expect(result.stdoutText, '5h 23.5% used | 7d 41% used');
    expect(result.stdoutText, isNot(contains(transcriptCanary)));
    expect(result.stdoutText, isNot(contains(sessionCanary)));
    final text = storedText();
    expect(text, isNot(contains(transcriptCanary)));
    expect(text, isNot(contains(sessionCanary)));
    expect(text, isNot(contains(workspaceCanary)));
    expect(text, isNot(contains('spend_limit')));
    expect(text, isNot(contains('314.12')));
    expect(text, isNot(contains('claude-opus')));
    expect(text, contains('"routing": false'));
    expect(text, contains('"account_bound": false'));
    expect(text, contains('"idle_machine_proof": false'));
    expect(text, isNot(contains('authoritative_live')));
    expect(settings.readAsBytesSync(), before);
    expect(home.listSync(), hasLength(1));
    expect(
      claudeStatusProjectionFile().path.replaceAll(r'\', '/'),
      contains('/quotabot/projections/claude_status.json'),
    );

    final doctor = claudeStatusDoctorJson(now);
    expect(doctor, isNotNull);
    expect(doctor!['routing'], isFalse);
    expect(doctor['account_bound'], isFalse);
    expect(doctor['idle_machine_proof'], isFalse);
    expect(doctor['source'], claudeStatusProjectionSource);
    expect(jsonEncode(doctor), isNot(contains(sessionCanary)));
    expect(
      claudeStatusDoctorLines(now).join('\n'),
      allOf(
        contains('Not account-wide'),
        contains('Not a route'),
        contains('5h 23.5% used, resets in 1h, observed 0s ago'),
        contains('7d 41% used, resets in 3d, observed 0s ago'),
        isNot(contains(transcriptCanary)),
      ),
    );
  });

  test('identical windows keep the first observation time', () {
    ingest(payload(rateLimits: planLimits()));
    final later = now + 120;
    final again = ingest(payload(rateLimits: planLimits()), at: later);
    expect(again.kind, ClaudeStatusIngestKind.stored);
    final loaded = loadClaudeStatusProjection(later).projection!;
    expect(loaded.windows.map((window) => window.observedAt), [now, now]);
    expect(
      claudeStatusDoctorLines(later).join('\n'),
      contains('observed 2m ago'),
    );

    ingest(
      payload(rateLimits: planLimits(fiveHour: window(24, now + 3600))),
      at: later,
    );
    final changed = loadClaudeStatusProjection(later).projection!;
    expect(changed.windows[0].observedAt, later);
    expect(changed.windows[1].observedAt, now);
  });

  test('a missing rate_limits object does not erase a stored projection', () {
    ingest(payload(rateLimits: planLimits()));
    final before = storedText();
    final result = ingest(payload(includeLimits: false), at: now + 30);
    expect(result.kind, ClaudeStatusIngestKind.unchanged);
    expect(storedText(), before);
    expect(Directory('${temp.path}/home').existsSync(), isFalse);
  });

  test('present rate limits with no current plan window delete the file', () {
    ingest(payload(rateLimits: planLimits()));
    final cleared = ingest(
      payload(
        rateLimits: planLimits(includeFiveHour: false, includeSevenDay: false),
      ),
    );
    expect(cleared.kind, ClaudeStatusIngestKind.cleared);
    expect(claudeStatusProjectionFile().existsSync(), isFalse);
    expect(claudeStatusDoctorJson(now), isNull);

    ingest(payload(rateLimits: planLimits()));
    final expired = ingest(
      payload(
        rateLimits: planLimits(
          fiveHour: window(10, now),
          sevenDay: window(10, now - 5),
        ),
      ),
    );
    expect(expired.kind, ClaudeStatusIngestKind.cleared);
    expect(claudeStatusProjectionFile().existsSync(), isFalse);
  });

  test('an expired sibling is omitted and the other window stays', () {
    final result = ingest(
      payload(rateLimits: planLimits(fiveHour: window(10, now))),
    );
    expect(result.kind, ClaudeStatusIngestKind.stored);
    final loaded = loadClaudeStatusProjection(now).projection!;
    expect(loaded.windows.map((window) => window.id), [claudeStatusSevenDayId]);
    expect(claudeStatusStatusLine(loaded, now), '7d 41% used');
  });

  test('malformed or unknown windows do not replace stored evidence', () {
    ingest(payload(rateLimits: planLimits()));
    final before = storedText();
    final cases = <Object?>[
      payload(
        rateLimits: planLimits(
          fiveHour: {'used_percentage': '23.5', 'resets_at': now + 10},
        ),
      ),
      payload(rateLimits: planLimits(fiveHour: window(101, now + 10))),
      payload(rateLimits: planLimits(fiveHour: window(-1, now + 10))),
      payload(
        rateLimits: planLimits(
          fiveHour: {
            'used_percentage': 10,
            'resets_at': now + claudeStatusFiveHourMaxSeconds + 1,
          },
        ),
      ),
      payload(
        rateLimits: planLimits(
          sevenDay: {'used_percentage': 10, 'resets_at': (now + 3600) * 1000},
        ),
      ),
      payload(rateLimits: planLimits(extra: {'weekly': window(1, now + 10)})),
      payload(rateLimits: null),
      payload(rateLimits: ['five_hour']),
      ['not', 'an', 'object'],
    ];
    for (final decoded in cases) {
      final result = ingest(decoded);
      expect(result.kind, ClaudeStatusIngestKind.rejected, reason: '$decoded');
      expect(storedText(), before, reason: '$decoded');
      expect(storedText(), isNot(contains(transcriptCanary)));
    }
  });

  test('a reset at the documented slack boundary is accepted', () {
    final result = ingest(
      payload(
        rateLimits: planLimits(
          includeSevenDay: false,
          fiveHour: window(1, now + claudeStatusFiveHourMaxSeconds),
        ),
      ),
    );
    expect(result.kind, ClaudeStatusIngestKind.stored);
    expect(
      loadClaudeStatusProjection(now).projection!.windows.single.resetsAt,
      now + claudeStatusFiveHourMaxSeconds,
    );
  });

  test('oversized, empty, and undecodable stdin do not create a file', () {
    expect(
      ingestClaudeStatusBytes(const [], now: now).rejection,
      claudeStatusRejectionStdinEmpty,
    );
    expect(
      ingestClaudeStatusBytes(
        List<int>.filled(claudeStatusStdinLimitBytes + 1, 0x20),
        now: now,
      ).rejection,
      claudeStatusRejectionStdinTooLarge,
    );
    expect(
      ingestClaudeStatusBytes(const [0xFF], now: now).rejection,
      claudeStatusRejectionInvalidUtf8,
    );
    expect(
      ingestClaudeStatusBytes(utf8.encode('{'), now: now).rejection,
      claudeStatusRejectionInvalidJson,
    );
    expect(Directory('${temp.path}/quotabot').existsSync(), isFalse);
  });

  test('a hand-edited file is unreadable and is not quota evidence', () {
    final file = claudeStatusProjectionFile(create: true);
    file.writeAsStringSync(
      jsonEncode({
        'schema': claudeStatusProjectionSchema,
        'source': claudeStatusProjectionSource,
        'routing': true,
        'account_bound': false,
        'idle_machine_proof': false,
        'session_id': sessionCanary,
        'windows': [
          {
            'id': 'five_hour',
            'used_percent': 1,
            'resets_at': now + 10,
            'observed_at': now,
          },
        ],
      }),
    );
    expect(
      loadClaudeStatusProjection(now).state,
      ClaudeStatusLoadState.unreadable,
    );
    expect(
      claudeStatusDoctorLines(now).join('\n'),
      contains('not quota evidence'),
    );
    final doctor = claudeStatusDoctorJson(now);
    expect(doctor!['readable'], isFalse);
    expect(doctor.containsKey('windows'), isFalse);
    expect(jsonEncode(doctor), isNot(contains(sessionCanary)));
  });

  test(
    'json output names the outcome and show does not echo the payload',
    () async {
      final stored = await runClaudeStatusCommand(
        show: false,
        asJson: true,
        stdin: Stream.value(
          utf8.encode(jsonEncode(payload(rateLimits: planLimits()))),
        ),
        now: now,
      );
      expect(stored.exitCode, 0);
      expect(stored.stdoutText, contains('"outcome": "stored"'));
      expect(stored.stdoutText, contains('"routing": false'));
      expect(stored.stdoutText, isNot(contains(transcriptCanary)));

      final shown = await runClaudeStatusCommand(
        show: true,
        asJson: true,
        stdin: Stream.value(utf8.encode(transcriptCanary)),
        now: now,
      );
      expect(shown.exitCode, 0);
      expect(shown.stdoutText, contains('"readable": true'));
      expect(shown.stdoutText, isNot(contains('"outcome"')));
      expect(shown.stdoutText, isNot(contains(transcriptCanary)));
      expect(storedText(), isNot(contains(transcriptCanary)));
    },
  );
}
