import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/adapters/windsurf.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_windsurf_adapter_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File writeDb(Map<String, Object> rows) {
    final file = File('${temp.path}/state.vscdb');
    final db = sqlite3.open(file.path);
    try {
      db.execute('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)');
      for (final entry in rows.entries) {
        db.execute(
          'INSERT INTO ItemTable (key, value) VALUES (?, ?)',
          [entry.key, entry.value],
        );
      }
    } finally {
      db.close();
    }
    return file;
  }

  String updatedNow() => DateTime.now().toUtc().toIso8601String();

  test('missing database reports installed without live quota', () async {
    final q = await WindsurfAdapter(
      dbPath: '${temp.path}/missing.vscdb',
      hasDevinCli: false,
    ).collect();

    expect(q.ok, isTrue);
    expect(q.account, 'installed');
    expect(q.windows, isEmpty);
    expect(q.error, contains('Windsurf installed'));
  });

  test('CLI-only install reports org context from Devin config', () async {
    final cfg = File('${temp.path}/config.json')
      ..writeAsStringSync(jsonEncode({
        'devin': {'org_id': 'organization-1234567890'},
      }));

    final q = await WindsurfAdapter(
      dbPath: '${temp.path}/missing.vscdb',
      hasDevinCli: true,
      devinConfigPath: cfg.path,
    ).collect();

    expect(q.ok, isTrue);
    expect(q.account, 'organization...');
    expect(q.windows, isEmpty);
    expect(q.error, contains('Devin'));
  });

  test('reads daily and weekly quotas, account, and plan from state DB',
      () async {
    final db = writeDb({
      'windsurf.settings.cachedPlanInfo': utf8.encode(jsonEncode({
        'updatedAt': updatedNow(),
        'user': {'email': 'work@example.com'},
        'planName': 'Teams',
        'quotaUsage': {
          'daily': {
            'used': 8,
            'limit': 10,
            'resetAt': '2026-07-01T00:00:00.000Z',
          },
          'weekly': {
            'remainingPercent': 25,
            'resetAt': '2026-07-07T00:00:00.000Z',
          },
        },
      })),
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.account, 'work@example.com');
    expect(q.plan, 'Teams');
    expect(q.windows.map((w) => w.label), containsAll(['daily', 'weekly']));
    expect(q.windows.firstWhere((w) => w.label == 'daily').usedPercent, 80);
    expect(q.windows.firstWhere((w) => w.label == 'weekly').usedPercent, 75);
    expect(q.windows.every((w) => w.resetsAt != null), isTrue);
    expect(q.sourceClass.wireName, 'passive_local_evidence');
  });

  test('reads direct quota percent strings and separate account rows',
      () async {
    final db = writeDb({
      'devin.account': jsonEncode({
        'teamName': 'Platform Team',
        'currentPlan': 'Pro',
      }),
      'devin.usage': jsonEncode({
        'updatedAt': updatedNow(),
        'dailyQuotaRemainingPercent': '12.5',
        'weekly_quota_remaining_percent': 40,
        'dailyResetAt': '2026-07-01T00:00:00.000Z',
      }),
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.account, 'Platform Team');
    expect(q.plan, 'Pro');
    expect(q.windows.firstWhere((w) => w.label == 'daily').usedPercent, 87.5);
    expect(q.windows.firstWhere((w) => w.label == 'daily').resetsAt, isNotNull);
    expect(q.windows.firstWhere((w) => w.label == 'weekly').usedPercent, 60);
  });

  test('reads exact related Codeium quota and account metadata rows', () async {
    final db = writeDb({
      'codeium.account': jsonEncode({
        'email': 'codeium@example.com',
        'planName': 'Teams',
      }),
      'codeium.quota': jsonEncode({
        'updatedAt': updatedNow(),
        'daily': {'usedPercent': 25},
      }),
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.account, 'codeium@example.com');
    expect(q.plan, 'Teams');
    expect(q.windows.single.label, 'daily');
    expect(q.windows.single.usedPercent, 25);
  });

  test('reports an exhausted daily quota with reset context', () async {
    final db = writeDb({
      'windsurf.settings.cachedPlanInfo': jsonEncode({
        'updatedAt': updatedNow(),
        'daily': {
          'usedPercent': 100,
          'resetAt': DateTime.fromMillisecondsSinceEpoch(
            (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200) * 1000,
            isUtc: true,
          ).toIso8601String(),
        },
      }),
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.windows.single.label, 'daily');
    expect(q.error, startsWith('out of quota (resets '));
  });

  test('an expired passive reset does not claim current exhaustion', () async {
    final db = writeDb({
      'windsurf.settings.cachedPlanInfo': jsonEncode({
        'updatedAt': updatedNow(),
        'daily': {
          'usedPercent': 100,
          'resetAt': DateTime.now()
              .subtract(const Duration(minutes: 1))
              .toUtc()
              .toIso8601String(),
        },
      }),
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.windows.single.usedPercent, 100);
    expect(q.error, isNull);
  });

  test('multiple usage rows keep the tightest same-label observation',
      () async {
    final db = writeDb({
      'windsurf.settings.cachedPlanInfo': jsonEncode({
        'updatedAt': updatedNow(),
        'daily': {'usedPercent': 15},
      }),
      'windsurf.usage': jsonEncode({
        'updatedAt': updatedNow(),
        'daily': {'usedPercent': 85},
      }),
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.windows.single.label, 'daily');
    expect(q.windows.single.usedPercent, 85);
  });

  test('ignores prompt rows and prompt subtrees with quota-like fields',
      () async {
    final db = writeDb({
      'windsurf.settings.cachedPlanInfo': jsonEncode({
        'conversation': {
          'prompt': 'quota account plan used limit',
          'teamName': 'Prompt Team',
          'plan': 'Prompt Plan',
          'daily': {'usedPercent': 99},
        },
        'user': {'teamName': 'Trusted Team'},
        'subscription': {'currentPlan': 'Pro'},
        'updatedAt': updatedNow(),
        'daily': {'usedPercent': 20},
      }),
      'windsurf.usage': jsonEncode({
        'codeContext': {
          'teamName': 'Code Team',
          'plan': 'Code Plan',
          'daily': {'usedPercent': 98},
        },
      }),
      'workbench.panel.chat.devin.usage.account': jsonEncode({
        'prompt': 'unrelated conversation content',
        'teamName': 'Row Decoy',
        'currentPlan': 'Row Plan',
        'updatedAt': updatedNow(),
        'daily': {'usedPercent': 100},
      }),
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.account, 'Trusted Team');
    expect(q.plan, 'Pro');
    expect(q.windows.single.label, 'daily');
    expect(q.windows.single.usedPercent, 20);
  });

  test('generic quota-looking conversation row is not a state source',
      () async {
    final db = writeDb({
      'chat.user.plan.quota': jsonEncode({
        'prompt': 'daily quota is spent',
        'teamName': 'Prompt Team',
        'currentPlan': 'Prompt Plan',
        'updatedAt': updatedNow(),
        'daily': {'usedPercent': 100},
      }),
    });

    final q = await WindsurfAdapter(
      dbPath: db.path,
      hasDevinCli: false,
    ).collect();

    expect(q.account, 'default');
    expect(q.plan, isNull);
    expect(q.windows, isEmpty);
  });

  test('database modification time cannot make quota evidence routable',
      () async {
    final checkedAt = DateTime.now().toUtc();
    final modifiedAt = checkedAt.subtract(const Duration(hours: 2));
    final db = writeDb({
      'windsurf.settings.cachedPlanInfo': jsonEncode({
        'daily': {
          'usedPercent': 20,
          'resetAt': checkedAt.add(const Duration(days: 1)).toIso8601String(),
        },
      }),
    });
    db.setLastModifiedSync(modifiedAt);

    final q = await WindsurfAdapter(dbPath: db.path).collect();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    expect(q.asOf, 0);
    expect(q.stale, isTrue);
    expect(q.error, contains('evidence time is unavailable'));
    expect(providerAvailability(q, now).available, isFalse);
  });

  test('malformed and non-usage rows fail soft with account context', () async {
    final db = writeDb({
      'windsurf.user': jsonEncode({'email': 'known@example.com'}),
      'windsurf.plan': jsonEncode({'planTier': 'Free'}),
      'windsurf.settings.cachedPlanInfo': '{not-json',
    });

    final q = await WindsurfAdapter(dbPath: db.path).collect();

    expect(q.account, 'known@example.com');
    expect(q.plan, 'Free');
    expect(q.windows, isEmpty);
    expect(q.error, 'no quota data found in local state');
  });

  test('corrupt SQLite file fails soft as no local quota state', () async {
    final file = File('${temp.path}/corrupt.vscdb')..writeAsStringSync('nope');

    final q = await WindsurfAdapter(dbPath: file.path).collect();

    expect(q.ok, isTrue);
    expect(q.windows, isEmpty);
    expect(q.error, 'no quota data found in local state');
  });
}
