import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

void main() {
  // Use a provider id unlikely to collide with a real snapshot.
  const id = '__test_provider__';

  tearDown(() {
    for (final name in [
      '$id.json',
      'history_$id.jsonl',
      'buckets_$id.json',
      '.._escape.json',
      'history_.._escape.jsonl',
      'buckets_.._escape.json',
      'antigravity_test-account.json',
      'grok_test-account.json',
    ]) {
      final f = File('${cacheDir().path}/$name');
      if (f.existsSync()) f.deleteSync();
    }
  });

  test('saveSnapshot then loadSnapshot round-trips', () {
    final q = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      plan: 'pro',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 33, resetsAt: 999)],
    );
    saveSnapshot(q);

    final back = loadSnapshot(id);
    expect(back, isNotNull);
    expect(back!.provider, id);
    expect(back.windows.single.usedPercent, 33);
    expect(back.windows.single.resetsAt, 999);
  });

  test('saveHistory and loadHistory works for recent', () {
    final q1 = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      plan: 'pro',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 10)],
    );
    final q2 = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      plan: 'pro',
      asOf: 1782000100,
      windows: [QuotaWindow(label: '5h', usedPercent: 20)],
    );
    saveSnapshot(q1);
    saveSnapshot(q2); // triggers history
    final hist = loadHistory(id);
    expect(hist.length, greaterThanOrEqualTo(1));
  });

  test('loadSnapshot returns null for an unknown provider', () {
    expect(loadSnapshot('__nope_does_not_exist__'), isNull);
  });

  test('recordHeadroomSample accumulates into one hourly bucket', () {
    final now = 1782000000;
    recordHeadroomSample(id, 80, now);
    recordHeadroomSample(id, 60, now + 30); // same hour
    final buckets = loadBuckets(id);
    expect(buckets.length, 1);
    expect(buckets.single.count, 2);
    expect(buckets.single.mean, closeTo(70, 0.001));
  });

  test('recordHeadroomSample prunes buckets beyond the retention window', () {
    final now = 1782000000;
    recordHeadroomSample(id, 50, now - 100 * 86400); // older than 90 days
    recordHeadroomSample(id, 90, now); // current
    final buckets = loadBuckets(id);
    expect(buckets.length, 1);
    expect(buckets.single.start, bucketStart(now));
  });

  test('loadBuckets returns empty for an unknown provider', () {
    expect(loadBuckets('__nope_does_not_exist__'), isEmpty);
  });

  test('provider cache filenames stay inside the cache directory', () {
    final q = ProviderQuota(
      provider: '../escape',
      displayName: 'Test',
      account: 'acct',
      asOf: 1,
      windows: [QuotaWindow(label: '5h', usedPercent: 10)],
    );
    saveSnapshot(q);
    recordHeadroomSample('../escape', 80, 1782000000);

    expect(loadSnapshot('../escape'), isNotNull);
    expect(loadHistory('../escape'), isNotEmpty);
    expect(loadBuckets('../escape'), isNotEmpty);
    expect(File('${cacheDir().path}/../escape.json').existsSync(), isFalse);
  });

  test('loadAntigravitySnapshot round-trips per account', () {
    final q = ProviderQuota(
      provider: 'antigravity',
      displayName: 'Antigravity',
      account: 'test-account',
      asOf: 1,
      windows: [QuotaWindow(label: '5h', usedPercent: 12)],
    );
    saveSnapshot(q);
    final back = loadAntigravitySnapshot('test-account');
    expect(back, isNotNull);
    expect(back!.account, 'test-account');
    expect(back.windows.single.usedPercent, 12);
    expect(loadAntigravitySnapshot('unknown'), isNull);
    expect(loadAntigravitySnapshot(''), isNull);
    expect(
      loadAllAntigravitySnapshots().any((s) => s.account == 'test-account'),
      isTrue,
    );
  });

  test('loadGrokSnapshot round-trips per account', () {
    final q = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'test-account',
      asOf: 1,
      windows: [QuotaWindow(label: 'monthly', usedPercent: 44)],
    );
    saveSnapshot(q);
    final back = loadGrokSnapshot('test-account');
    expect(back, isNotNull);
    expect(back!.account, 'test-account');
    expect(back.windows.single.usedPercent, 44);
    expect(
        loadAllGrokSnapshots().map((s) => s.account), contains('test-account'));
  });

  group('generic per-account snapshots', () {
    const ap = '__test_acct__';

    ProviderQuota aq(String account, double used) => ProviderQuota(
          provider: ap,
          displayName: 'AcctTest',
          account: account,
          asOf: 1782000000,
          windows: [QuotaWindow(label: '5h', usedPercent: used)],
        );

    void writeAccount(String account, double used) =>
        File('${cacheDir().path}/${ap}_$account.json')
            .writeAsStringSync(jsonEncode(aq(account, used).toJson()));

    tearDown(() {
      for (final n in ['${ap}_work.json', '${ap}_home.json', '$ap.json']) {
        final f = File('${cacheDir().path}/$n');
        if (f.existsSync()) f.deleteSync();
      }
    });

    test('loadAccountSnapshot reads one account, ignores placeholders', () {
      writeAccount('work', 20);
      final q = loadAccountSnapshot(ap, 'work');
      expect(q?.account, 'work');
      expect(loadAccountSnapshot(ap, 'missing'), isNull);
      expect(loadAccountSnapshot(ap, 'unknown'), isNull);
      expect(loadAccountSnapshot(ap, ''), isNull);
    });

    test('loadAccountSnapshots gathers every account for the provider', () {
      writeAccount('work', 20);
      writeAccount('home', 40);
      final all = loadAccountSnapshots(ap);
      expect(all.map((q) => q.account).toSet(), {'work', 'home'});
    });

    test('currentAccountFallbacks hides signed-out account caches', () {
      final fallbacks = currentAccountFallbacks(
        liveResults: [aq('work', 20)],
        cachedSnapshots: [
          aq('work', 25),
          aq('home', 40),
          aq('old', 60),
          ProviderQuota(
            provider: ap,
            displayName: 'AcctTest',
            account: 'empty',
            asOf: 1782000000,
            windows: const [],
          ),
        ],
        currentAccounts: {'work', 'home'},
      );

      expect(fallbacks.map((q) => q.account).toList(), ['home']);
      expect(fallbacks.single.stale, isTrue);
      expect(fallbacks.single.error, 'cached account');
    });
  });
}
