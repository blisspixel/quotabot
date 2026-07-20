import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/adapters/kiro.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_kiro_adapter_');
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

  Map<String, Object?> kiroUsageState(DateTime resetDate) => {
        'kiro.resourceNotifications.usageState': {
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'usageBreakdowns': [
            {
              'currentUsage': 10000,
              'usageLimit': 10000,
              'percentageUsed': 100,
              'resetDate': resetDate.toUtc().toIso8601String(),
              'displayName': 'Credit',
            },
          ],
        },
      };

  test('missing database reports Kiro installed without live quota', () async {
    final q = await KiroAdapter(dbPath: '${temp.path}/missing.vscdb').collect();

    expect(q.ok, isTrue);
    expect(q.account, 'installed');
    expect(q.windows, isEmpty);
    expect(q.error, contains('Kiro installed'));
  });

  test('reports future exhausted credits with reset context', () async {
    final db = writeDb({
      'kiro.kiroAgent': jsonEncode(
        kiroUsageState(DateTime.now().toUtc().add(const Duration(hours: 2))),
      ),
    });

    final q = await KiroAdapter(dbPath: db.path).collect();

    expect(q.windows.single.label, 'credit');
    expect(q.windows.single.usedPercent, 100);
    expect(q.sourceClass.wireName, 'passive_local_evidence');
    expect(q.error, startsWith('out of quota (resets '));
  });

  test('does not report out of quota after reset boundary passes', () async {
    final db = writeDb({
      'kiro.kiroAgent': jsonEncode(
        kiroUsageState(
            DateTime.now().toUtc().subtract(const Duration(minutes: 1))),
      ),
    });

    final q = await KiroAdapter(dbPath: db.path).collect();

    expect(q.windows.single.label, 'credit');
    expect(q.windows.single.usedPercent, 100);
    expect(q.error, isNull);
  });

  test('database modification time cannot make quota evidence routable',
      () async {
    final checkedAt = DateTime.now().toUtc();
    final modifiedAt = checkedAt.subtract(const Duration(hours: 2));
    final state = kiroUsageState(checkedAt.add(const Duration(days: 7)));
    (state['kiro.resourceNotifications.usageState'] as Map<String, Object?>)
        .remove('timestamp');
    final db = writeDb({'kiro.kiroAgent': jsonEncode(state)});
    db.setLastModifiedSync(modifiedAt);

    final q = await KiroAdapter(dbPath: db.path).collect();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    expect(q.asOf, 0);
    expect(q.stale, isTrue);
    expect(q.error, contains('evidence time is unavailable'));
    expect(providerAvailability(q, now).available, isFalse);
  });

  test('usage-state timestamp wins over a freshly touched database', () async {
    final checkedAt = DateTime.now().toUtc();
    final updatedAt = checkedAt.subtract(const Duration(hours: 2));
    final state = kiroUsageState(checkedAt.add(const Duration(days: 7)));
    (state['kiro.resourceNotifications.usageState']
        as Map<String, Object?>)['timestamp'] = updatedAt.toIso8601String();
    final db = writeDb({'kiro.kiroAgent': jsonEncode(state)});

    final q = await KiroAdapter(dbPath: db.path).collect();

    expect(q.asOf, updatedAt.millisecondsSinceEpoch ~/ 1000);
    expect(q.stale, isTrue);
  });

  test('unrelated root content cannot supply quota provenance', () async {
    final checkedAt = DateTime.now().toUtc();
    final state = kiroUsageState(checkedAt.add(const Duration(days: 7)));
    (state['kiro.resourceNotifications.usageState'] as Map<String, Object?>)
        .remove('timestamp');
    state['unrelatedAgentContent'] = {
      'quota': true,
      'updatedAt': checkedAt.toIso8601String(),
      'prompt': 'content-shaped value outside quota state',
    };
    final db = writeDb({'kiro.kiroAgent': jsonEncode(state)});

    final q = await KiroAdapter(dbPath: db.path).collect();

    expect(q.windows, hasLength(1));
    expect(q.asOf, 0);
    expect(q.stale, isTrue);
    expect(q.error, contains('evidence time is unavailable'));
  });
}
