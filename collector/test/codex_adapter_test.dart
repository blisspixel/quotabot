import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/codex.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/parsing.dart';
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

  Directory writeAuth(String accessToken) {
    final sessions = Directory('${temp.path}/sessions')..createSync();
    File('${temp.path}/auth.json').writeAsStringSync(jsonEncode({
      'tokens': {'access_token': accessToken, 'account_id': 'acct-1'},
    }));
    return sessions;
  }

  test('uses the host auth.json token for the live read', () async {
    final sessions = writeAuth('host-tok');
    final q = await CodexAdapter(
      sessionsDir: sessions,
      grantToken: () async => null,
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-tok');
        expect(request.headers['chatgpt-account-id'], 'acct-1');
        return http.Response(
            jsonEncode(_wham(primary: 20, secondary: 50)), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.perMachine, isFalse, reason: 'the live read is account-wide');
    expect(q.hasWindows, isTrue);
  });

  test('falls through to the quotabot grant when the host token 401s',
      () async {
    final sessions = writeAuth('stale-host-tok');
    final tried = <String>[];
    final q = await CodexAdapter(
      sessionsDir: sessions,
      grantToken: () async => 'grant-tok',
      client: MockClient((request) async {
        final auth = request.headers['Authorization']!;
        tried.add(auth);
        // The account id still rides along from auth.json even on the grant.
        expect(request.headers['chatgpt-account-id'], 'acct-1');
        if (auth == 'Bearer grant-tok') {
          return http.Response(
              jsonEncode(_wham(primary: 20, secondary: 50)), 200);
        }
        return http.Response('{}', 401);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(tried, ['Bearer stale-host-tok', 'Bearer grant-tok']);
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

  test('prefers the authoritative live usage endpoint over local sessions',
      () async {
    // A local session says barely used; the account was hammered on another
    // machine, so the live read (weekly spent) must win.
    _writeRollout(temp, 'rollout-standard.jsonl', [
      {
        'timestamp': _iso(nowEpoch()),
        'rate_limits': _limits('standard', primary: 5, weekly: 5),
      },
    ]);

    final q = await CodexAdapter(
      sessionsDir: temp,
      usageFetcher: () async => _wham(primary: 0, secondary: 100),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.account, 'blisspixel@example.com');
    expect(q.plan, 'pro');
    expect(q.windows.firstWhere((w) => w.label == '5h').usedPercent, 0);
    expect(q.windows.firstWhere((w) => w.label == 'weekly').usedPercent, 100);
    expect(q.perMachine, isFalse); // authoritative, cross-device
    expect(q.sourceClass.wireName, 'authoritative_live');
  });

  test('falls back to local sessions when the live read is unavailable',
      () async {
    _writeRollout(temp, 'rollout-standard.jsonl', [
      {
        'timestamp': _iso(nowEpoch()),
        'rate_limits': _limits('standard', primary: 20, weekly: 15),
      },
    ]);

    final q = await CodexAdapter(
      sessionsDir: temp,
      usageFetcher: () async => null, // no token, expired, or offline
    ).collect();

    expect(q.ok, isTrue);
    expect(q.windows.firstWhere((w) => w.label == 'weekly').usedPercent, 15);
    expect(q.perMachine, isTrue); // this-machine session fallback
    expect(q.sourceClass.wireName, 'this_machine_fallback');
  });

  test('codexUsageWindows maps the live rate_limit windows', () {
    final w = codexUsageWindows(_wham(primary: 12, secondary: 100));
    expect(w.firstWhere((x) => x.label == '5h').usedPercent, 12);
    expect(w.firstWhere((x) => x.label == 'weekly').usedPercent, 100);
    expect(codexUsageWindows(const {}), isEmpty);
  });

  test('surfaces redeemable reset credits as a structured signal', () async {
    final q = await CodexAdapter(
      sessionsDir: temp,
      usageFetcher: () async =>
          _wham(primary: 95, secondary: 40, resetCredits: 2),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.resetCreditsAvailable, 2);
    // The shared escape-hatch phrasing names the count and the action.
    expect(
      resetAvailableMessage(q),
      allOf(contains('2 resets available in Codex'), contains('redeem')),
    );
  });

  test('reset credits are zero when none are available or the field is absent',
      () async {
    final none = await CodexAdapter(
      sessionsDir: temp,
      usageFetcher: () async =>
          _wham(primary: 95, secondary: 40, resetCredits: 0),
    ).collect();
    expect(none.resetCreditsAvailable, 0);
    expect(resetAvailableMessage(none), isNull);

    final absent = await CodexAdapter(
      sessionsDir: temp,
      usageFetcher: () async => _wham(primary: 95, secondary: 40),
    ).collect();
    expect(absent.resetCreditsAvailable, 0);
    expect(resetAvailableMessage(absent), isNull);
  });

  test('a single redeemable reset reads in the singular', () async {
    final one = await CodexAdapter(
      sessionsDir: temp,
      usageFetcher: () async =>
          _wham(primary: 95, secondary: 40, resetCredits: 1),
    ).collect();
    expect(one.resetCreditsAvailable, 1);
    expect(resetAvailableMessage(one), contains('1 reset available in Codex'));
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

/// The live `/backend-api/wham/usage` response shape (sanitized).
Map<String, dynamic> _wham({
  required num primary,
  required num secondary,
  int? resetCredits,
}) {
  final now = nowEpoch();
  return {
    'email': 'blisspixel@example.com',
    'plan_type': 'pro',
    'rate_limit': {
      'allowed': secondary < 100,
      'limit_reached': secondary >= 100,
      'primary_window': {
        'used_percent': primary,
        'limit_window_seconds': 18000,
        'reset_at': now + 18000,
      },
      'secondary_window': {
        'used_percent': secondary,
        'limit_window_seconds': 604800,
        'reset_at': now + 604800,
      },
    },
    if (resetCredits != null)
      'rate_limit_reset_credits': {'available_count': resetCredits},
  };
}

String _iso(int epoch) =>
    DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true)
        .toIso8601String();
