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
}
