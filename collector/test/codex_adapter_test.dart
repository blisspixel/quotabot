import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/adapters/codex.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_codex_adapter_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('reports a missing sessions directory plainly', () async {
    final q = await CodexAdapter(
      sessionsDir: Directory('${temp.path}/missing'),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, 'no ~/.codex/sessions');
  });

  test('reports when recent rollout files contain no rate limits', () async {
    _writeRollout(
      temp,
      'rollout-empty.jsonl',
      [
        {'timestamp': _iso(nowEpoch()), 'event': 'message'},
      ],
    );

    final q = await CodexAdapter(sessionsDir: temp).collect();

    expect(q.ok, isFalse);
    expect(q.error, 'no rate_limits in recent sessions');
  });

  test('keeps the newest snapshot of each Codex limit bucket', () async {
    final now = nowEpoch();
    _writeRollout(
      temp,
      'rollout-standard-old.jsonl',
      [
        {
          'timestamp': _iso(now - 120),
          'rate_limits': _limits('standard', primary: 10, weekly: 95),
        },
      ],
      modifiedAt: now - 120,
    );
    _writeRollout(
      temp,
      'rollout-standard-new.jsonl',
      [
        {
          'timestamp': _iso(now - 30),
          'rate_limits': _limits('standard', primary: 20, weekly: 15),
        },
      ],
      modifiedAt: now - 30,
    );
    _writeRollout(
      temp,
      'rollout-spark.jsonl',
      [
        {
          'timestamp': _iso(now - 10),
          'rate_limits': {
            'limit_id': 'spark',
            'plan_type': 'pro',
            'primary': {
              'used_percent': 70,
              'window_minutes': 300,
              'resets_at': now + 1000,
            },
          },
        },
      ],
      modifiedAt: now - 10,
    );

    final q = await CodexAdapter(sessionsDir: temp).collect();

    expect(q.ok, isTrue);
    expect(q.stale, isFalse);
    expect(q.plan, 'pro');
    expect(q.windows.firstWhere((w) => w.label == '5h').usedPercent, 70);
    expect(q.windows.firstWhere((w) => w.label == 'weekly').usedPercent, 15);
  });

  test('marks old rate-limit snapshots stale even when the file is new',
      () async {
    final now = nowEpoch();
    _writeRollout(
      temp,
      'rollout-stale.jsonl',
      [
        {
          'timestamp': _iso(now - 7200),
          'rate_limits': _limits(
            'standard',
            primary: 42,
            weekly: 10,
            primaryMinutes: 60,
          ),
        },
      ],
      modifiedAt: now,
    );

    final q = await CodexAdapter(sessionsDir: temp).collect();

    expect(q.ok, isTrue);
    expect(q.stale, isTrue);
    expect(q.error, contains('snapshot 2h old'));
    expect(q.windows.firstWhere((w) => w.label == '1h').usedPercent, 42);
  });
}

void _writeRollout(
  Directory dir,
  String name,
  List<Map<String, dynamic>> rows, {
  int? modifiedAt,
}) {
  final file = File('${dir.path}/$name');
  file.writeAsStringSync('${rows.map(jsonEncode).join('\n')}\n');
  if (modifiedAt != null) {
    file.setLastModifiedSync(
      DateTime.fromMillisecondsSinceEpoch(modifiedAt * 1000),
    );
  }
}

Map<String, dynamic> _limits(
  String id, {
  required num primary,
  required num weekly,
  int primaryMinutes = 300,
}) {
  final now = nowEpoch();
  return {
    'limit_id': id,
    'plan_type': 'pro',
    'primary': {
      'used_percent': primary,
      'window_minutes': primaryMinutes,
      'resets_at': now + 1000,
    },
    'secondary': {
      'used_percent': weekly,
      'window_minutes': 10080,
      'resets_at': now + 2000,
    },
  };
}

String _iso(int epoch) =>
    DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true)
        .toIso8601String();
