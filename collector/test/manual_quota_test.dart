import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/manual_quota.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_manual_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('builds and stores a self-reported quota entry', () {
    final entry = buildManualQuotaEntry(
      provider: 'Custom-AI',
      displayName: 'Custom AI',
      account: 'work',
      plan: 'team',
      window: 'monthly',
      used: '25',
      limit: '100',
      reset: '1893456000',
      now: 123,
    );

    expect(entry, isNotNull);
    setManualQuotaEntry(entry!, dir: temp);

    final loaded = loadManualQuotaEntries(dir: temp);
    expect(loaded, hasLength(1));
    expect(loaded.single.provider, 'custom-ai');
    expect(loaded.single.account, 'work');
    expect(loaded.single.used, 25);

    final quota = loaded.single.toQuota();
    expect(quota.source, manualQuotaSource);
    expect(quota.windows.single.percent, 25);
    expect(quota.details, contains('Self-reported manual quota'));
  });

  test('set replaces the same provider account and remove deletes it', () {
    ManualQuotaEntry entry(String used) => buildManualQuotaEntry(
          provider: 'custom',
          displayName: null,
          account: null,
          plan: null,
          window: null,
          used: used,
          limit: '10',
          reset: '1893456000',
          now: int.parse(used),
        )!;

    setManualQuotaEntry(entry('2'), dir: temp);
    setManualQuotaEntry(entry('3'), dir: temp);

    expect(loadManualQuotaEntries(dir: temp).map((e) => e.used), [3]);
    expect(removeManualQuotaEntry('custom', dir: temp), isTrue);
    expect(loadManualQuotaEntries(dir: temp), isEmpty);
    expect(removeManualQuotaEntry('custom', dir: temp), isFalse);
  });

  test('rejects unsafe or incomplete input and fails soft on corrupt files',
      () {
    expect(
      buildManualQuotaEntry(
        provider: '../bad',
        displayName: 'Bad',
        account: null,
        plan: null,
        window: null,
        used: '1',
        limit: '10',
        reset: '1893456000',
        now: 123,
      ),
      isNull,
    );
    expect(
      buildManualQuotaEntry(
        provider: 'custom',
        displayName: 'Bad${String.fromCharCode(7)}',
        account: null,
        plan: null,
        window: null,
        used: '1',
        limit: '10',
        reset: '1893456000',
        now: 123,
      ),
      isNull,
    );
    expect(parseManualReset('2027-01-01T00:00:00Z'), 1798761600);

    manualQuotaFile(dir: temp).writeAsStringSync('{bad json');
    expect(loadManualQuotaEntries(dir: temp), isEmpty);
  });

  test('ignores malformed entries in an otherwise readable file', () {
    manualQuotaFile(dir: temp).writeAsStringSync(jsonEncode({
      'schema': manualQuotaSchema,
      'entries': [
        {
          'provider': 'ok',
          'display_name': 'OK',
          'account': 'default',
          'window': 'weekly',
          'used': 1,
          'limit': 4,
          'resets_at': 1893456000,
          'updated_at': 123,
        },
        {
          'provider': '../bad',
          'used': 1,
          'limit': 4,
          'resets_at': 1893456000,
        },
      ],
    }));

    expect(loadManualQuotaEntries(dir: temp).map((e) => e.provider), ['ok']);
  });

  test('restricts the temp file before writing manual quota JSON', () {
    final entry = buildManualQuotaEntry(
      provider: 'custom',
      displayName: 'Custom',
      account: 'work@example.com',
      plan: null,
      window: 'weekly',
      used: '1',
      limit: '10',
      reset: '1893456000',
      now: 123,
    )!;
    final calls = <String>[];
    addTearDown(() => setManualQuotaFileRestrictorForTesting(null));

    setManualQuotaFileRestrictorForTesting((file) {
      calls.add(file.path);
      if (calls.length == 1) {
        expect(file.path, endsWith('.tmp'));
        expect(file.existsSync(), isTrue);
        expect(file.lengthSync(), 0,
            reason: 'tmp must be restricted before sensitive JSON is written');
      } else {
        expect(file.path, manualQuotaFile(dir: temp).path);
        expect(file.readAsStringSync(), contains('work@example.com'));
      }
    });

    saveManualQuotaEntries([entry], dir: temp);

    expect(calls, hasLength(2));
    expect(calls.first, contains('quotas.json.'));
    expect(calls.last, manualQuotaFile(dir: temp).path);
  });

  test('saved manual quota file and directory are owner-only on POSIX', () {
    // Manual quota JSON can carry account labels. On POSIX it must not be
    // group- or world-readable. The sequencing test above runs on every
    // platform and proves the temp file is restricted before content lands.
    if (Platform.isWindows) return;
    final entry = buildManualQuotaEntry(
      provider: 'custom',
      displayName: 'Custom',
      account: 'work@example.com',
      plan: null,
      window: 'weekly',
      used: '1',
      limit: '10',
      reset: '1893456000',
      now: 123,
    )!;

    saveManualQuotaEntries([entry], dir: temp);

    final file = manualQuotaFile(dir: temp);
    expect(file.statSync().mode & 0x3f, 0, reason: 'no group/other bits');
    expect(temp.statSync().mode & 0x3f, 0, reason: 'directory owner-only');
  });
}
