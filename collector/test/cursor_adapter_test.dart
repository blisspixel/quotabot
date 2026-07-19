import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/adapters/cursor.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/vscode_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_cursor_adapter_');
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

  test('missing database reports Cursor installed without live quota',
      () async {
    final q =
        await CursorAdapter(dbPath: '${temp.path}/missing.vscdb').collect();

    expect(q.ok, isTrue);
    expect(q.account, 'installed');
    expect(q.windows, isEmpty);
    expect(q.error, contains('Cursor installed'));
  });

  test('reads monthly included-usage pool, account, and plan from SQLite',
      () async {
    final db = writeDb({
      'cursor.planUsage': utf8.encode(jsonEncode({
        'updatedAt': updatedNow(),
        'profile': {
          'email': 'work@example.com',
          'planName': 'Pro',
        },
        'monthlyUsage': {
          'usedCents': 1250,
          'includedCents': 2000,
          'currentPeriodEnd': '2026-07-01T00:00:00.000Z',
        },
      })),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.account, 'work@example.com');
    expect(q.plan, 'Pro');
    expect(q.windows.single.label, 'monthly');
    expect(q.windows.single.usedPercent, closeTo(62.5, 0.1));
    expect(q.windows.single.resetsAt, isNotNull);
    expect(q.sourceClass.wireName, 'passive_local_evidence');
  });

  test('reads account and plan from separate string rows', () async {
    final db = writeDb({
      'cursor.account': jsonEncode({
        'user': {'userEmail': 'team@example.com'},
        'subscriptionPlan': 'Team',
      }),
      'cursor.usage': jsonEncode({
        'updatedAt': updatedNow(),
        'planUsage': {'used': 40, 'limit': 50},
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.account, 'team@example.com');
    expect(q.plan, 'Team');
    expect(q.windows.single.label, 'monthly');
    expect(q.windows.single.usedPercent, closeTo(80, 0.1));
  });

  test('reads top-level string monthly pool values', () async {
    final db = writeDb({
      'cursor.creditPool': jsonEncode({
        'updatedAt': updatedNow(),
        'email': 'solo@example.com',
        'tier': 'Pro',
        'usedCents': '1,500',
        'includedCents': '3000',
        'resetAt': '2026-07-01T00:00:00.000Z',
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.account, 'solo@example.com');
    expect(q.plan, 'Pro');
    expect(q.windows.single.label, 'monthly');
    expect(q.windows.single.usedPercent, closeTo(50, 0.1));
    expect(q.windows.single.resetsAt, isNotNull);
  });

  test('reads an exact related monthly-usage metadata row', () async {
    final db = writeDb({
      'cursor.monthlyUsage': jsonEncode({
        'updatedAt': updatedNow(),
        'usedCents': 300,
        'includedCents': 1200,
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.windows.single.label, 'monthly');
    expect(q.windows.single.usedPercent, 25);
  });

  test('reports an exhausted monthly pool with reset context', () async {
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'updatedAt': updatedNow(),
        'used': 100,
        'limit': 100,
        'resetAt': DateTime.fromMillisecondsSinceEpoch(
          (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200) * 1000,
          isUtc: true,
        ).toIso8601String(),
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.windows.single.usedPercent, 100);
    expect(q.error, startsWith('out of quota (resets '));
  });

  test('an expired passive reset does not claim current exhaustion', () async {
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'updatedAt': updatedNow(),
        'used': 100,
        'limit': 100,
        'resetAt': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.windows.single.usedPercent, 100);
    expect(q.error, isNull);
  });

  test('multiple usage rows keep the tightest same-label observation',
      () async {
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'updatedAt': updatedNow(),
        'planUsage': {'used': 10, 'limit': 100},
      }),
      'cursor.usage': jsonEncode({
        'updatedAt': updatedNow(),
        'planUsage': {'used': 90, 'limit': 100},
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.windows.single.label, 'monthly');
    expect(q.windows.single.usedPercent, 90);
  });

  test('database modification time cannot make quota evidence routable',
      () async {
    final checkedAt = DateTime.now().toUtc();
    final modifiedAt = checkedAt.subtract(const Duration(hours: 2));
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'used': 20,
        'limit': 100,
        'resetAt': checkedAt.add(const Duration(days: 7)).toIso8601String(),
      }),
    });
    db.setLastModifiedSync(modifiedAt);

    final q = await CursorAdapter(dbPath: db.path).collect();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    expect(q.asOf, 0);
    expect(q.stale, isTrue);
    expect(q.error, contains('evidence time is unavailable'));
    expect(providerAvailability(q, now).available, isFalse);
  });

  test('embedded usage update time wins over a freshly touched database',
      () async {
    final checkedAt = DateTime.now().toUtc();
    final updatedAt = checkedAt.subtract(const Duration(hours: 2));
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'updatedAt': updatedAt.toIso8601String(),
        'used': 20,
        'limit': 100,
        'resetAt': checkedAt.add(const Duration(days: 7)).toIso8601String(),
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.asOf, updatedAt.millisecondsSinceEpoch ~/ 1000);
    expect(q.stale, isTrue);
  });

  test('invalid embedded time cannot fall back to fresh database metadata',
      () async {
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'updatedAt': 'not-a-time',
        'used': 20,
        'limit': 100,
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.windows.single.usedPercent, 20);
    expect(q.stale, isTrue);
    expect(q.error, contains('evidence time is unavailable'));
  });

  test('selected duplicate window uses its newest embedded observation',
      () async {
    final checkedAt = DateTime.now().toUtc();
    final oldUpdate = checkedAt.subtract(const Duration(hours: 2));
    final recentUpdate = checkedAt.subtract(const Duration(minutes: 5));
    final resetAt = checkedAt.add(const Duration(days: 7)).toIso8601String();
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'updatedAt': oldUpdate.toIso8601String(),
        'used': 10,
        'limit': 100,
        'resetAt': resetAt,
      }),
      'cursor.usage': jsonEncode({
        'updatedAt': oldUpdate.toIso8601String(),
        'used': 80,
        'limit': 100,
        'resetAt': resetAt,
      }),
      'cursor.creditPool': jsonEncode({
        'updatedAt': recentUpdate.toIso8601String(),
        'used': 80,
        'limit': 100,
        'resetAt': resetAt,
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.windows.single.usedPercent, 80);
    expect(q.asOf, recentUpdate.millisecondsSinceEpoch ~/ 1000);
    expect(q.stale, isFalse);
  });

  test('ignores prompt rows and prompt subtrees with quota-like fields',
      () async {
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'conversation': {
          'prompt': 'quota account plan used limit',
          'email': 'prompt@example.com',
          'plan': 'Prompt Plan',
          'planUsage': {'used': 99, 'limit': 100},
        },
        'profile': {
          'email': 'trusted@example.com',
          'planName': 'Pro',
        },
        'updatedAt': updatedNow(),
        'used': 25,
        'limit': 100,
      }),
      'cursor.usage': jsonEncode({
        'codeContext': {
          'email': 'code@example.com',
          'plan': 'Code Plan',
          'used': 98,
          'limit': 100,
        },
      }),
      'workbench.panel.chat.accountUsage': jsonEncode({
        'prompt': 'unrelated conversation content',
        'email': 'row-decoy@example.com',
        'planName': 'Row Decoy',
        'updatedAt': updatedNow(),
        'planUsage': {'used': 100, 'limit': 100},
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.account, 'trusted@example.com');
    expect(q.plan, 'Pro');
    expect(q.windows.single.usedPercent, 25);
  });

  test('generic quota-looking conversation row is not a state source',
      () async {
    final db = writeDb({
      'chat.user.plan.usage': jsonEncode({
        'prompt': 'used 100 of 100 credits',
        'email': 'prompt@example.com',
        'planName': 'Prompt Plan',
        'updatedAt': updatedNow(),
        'used': 100,
        'limit': 100,
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.account, 'default');
    expect(q.plan, isNull);
    expect(q.windows, isEmpty);
  });

  test('unrelated account update time cannot date quota evidence', () async {
    final checkedAt = DateTime.now().toUtc();
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
        'profile': {
          'email': 'work@example.com',
          'updatedAt':
              checkedAt.subtract(const Duration(days: 30)).toIso8601String(),
        },
        'monthlyUsage': {
          'used': 20,
          'limit': 100,
          'resetAt': checkedAt.add(const Duration(days: 7)).toIso8601String(),
        },
      }),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.stale, isTrue);
    expect(q.error, contains('evidence time is unavailable'));
  });

  test('WAL modification time cannot establish quota provenance', () {
    final checkedAt = DateTime.now().toUtc();
    final oldDbTime = checkedAt.subtract(const Duration(hours: 2));
    final walTime = checkedAt.subtract(const Duration(minutes: 5));
    final db = writeDb({
      'cursor.account': jsonEncode({'plan': 'Pro'})
    });
    db.setLastModifiedSync(oldDbTime);
    final wal = File('${db.path}-wal')..writeAsBytesSync([1]);
    wal.setLastModifiedSync(walTime);
    final payload = <String, dynamic>{'used': 20, 'limit': 100};
    final window = QuotaWindow(label: 'monthly', usedPercent: 20);

    final asOf = passiveStateEvidenceAsOf(
      checkedAt: checkedAt.millisecondsSinceEpoch ~/ 1000,
      observations: [
        PassiveStateQuotaObservation(payload: payload, windows: [window]),
      ],
      selectedWindows: [window],
    );

    expect(asOf, 0);
  });

  test('malformed and non-usage rows fail soft with account context', () async {
    final db = writeDb({
      'cursor.user': jsonEncode({'email': 'known@example.com'}),
      'cursor.plan': '{not-json',
      'cursor.account': jsonEncode({'planName': 'Free'}),
    });

    final q = await CursorAdapter(dbPath: db.path).collect();

    expect(q.account, 'known@example.com');
    expect(q.plan, 'Free');
    expect(q.windows, isEmpty);
    expect(q.error, 'no quota data found in local state');
  });

  test('corrupt SQLite file fails soft as no local quota state', () async {
    final file = File('${temp.path}/corrupt.vscdb')..writeAsStringSync('nope');

    final q = await CursorAdapter(dbPath: file.path).collect();

    expect(q.ok, isTrue);
    expect(q.windows, isEmpty);
    expect(q.error, 'no quota data found in local state');
  });
}
