import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/adapters/cursor.dart';
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

  test('reports an exhausted monthly pool with reset context', () async {
    final db = writeDb({
      'cursor.planUsage': jsonEncode({
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
