@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/provider_id_migration.dart';
import 'package:quotabot_collector/storage_keys.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

const _oldProvider = 'oldcodex';
const _newProvider = codexProviderId;
const _aliases = {_oldProvider: _newProvider};

void main() {
  late Directory tempConfig;
  late Directory root;
  const accountA = 'credential:account-a';
  const accountB = 'credential:account-b';

  setUp(() {
    tempConfig =
        Directory.systemTemp.createTempSync('quotabot_provider_id_migration_');
    setQuotabotDirOverrideForTesting(tempConfig);
    root = cacheDir();
  });

  tearDown(() {
    setProviderIdAliasesForTesting(null);
    setProviderIdMigrationObserverForTesting(null);
    setEvidenceGuardObserverForTesting(null);
    setQuotabotDirOverrideForTesting(null);
    if (tempConfig.existsSync()) tempConfig.deleteSync(recursive: true);
  });

  Map<String, dynamic> snapshot(
    String account,
    int asOf,
    double usedPercent,
  ) {
    final value = ProviderQuota(
      provider: _newProvider,
      displayName: 'Codex',
      account: account,
      plan: 'Pro',
      asOf: asOf,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: usedPercent,
          resetsAt: asOf + 3600,
        ),
      ],
    ).toJson();
    value['provider'] = _oldProvider;
    value['cache_observed_at_micros'] = asOf * 1000000;
    return value;
  }

  File roleFile(String name) => File('${root.path}/$name');

  String digestOf(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  test('empty alias map is a no-touch constant-time result', () async {
    final missing = Directory('${tempConfig.path}/missing');

    final report = await coordinateProviderIdCacheMigration(
      aliases: const {},
      root: missing,
    );

    expect(report.state, 'complete');
    expect(report.processedRecords, 0);
    expect(missing.existsSync(), isFalse);
  });

  test('concurrent production calls share one coordinator flight', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    roleFile('$_oldProvider.json')
        .writeAsStringSync(jsonEncode(snapshot('default', now, 10)));
    setProviderIdAliasesForTesting(_aliases);
    var starts = 0;
    setProviderIdMigrationObserverForTesting((phase) {
      if (phase == 'start') starts++;
    });

    final reports = await Future.wait([
      coordinateProviderIdCacheMigration(),
      coordinateProviderIdCacheMigration(),
      coordinateProviderIdCacheMigration(),
    ]);

    expect(starts, 1);
    expect(reports.every((report) => report.state == 'complete'), isTrue);
    expect(roleFile('$_newProvider.json').existsSync(), isTrue);
  });

  test('live collection waits for one migration flight before adapters',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    roleFile('$_oldProvider.json')
        .writeAsStringSync(jsonEncode(snapshot('default', now, 10)));
    setProviderIdAliasesForTesting(_aliases);
    var starts = 0;
    var adapterCalls = 0;
    setProviderIdMigrationObserverForTesting((phase) {
      if (phase == 'start') starts++;
    });
    final registration = ProviderAdapterRegistration(
      id: _newProvider,
      displayName: 'Codex',
      adapterClass: ProviderAdapterClass.subscription,
      sourceClasses: const {ProviderSourceClass.authoritativeLive},
      collect: () async {
        adapterCalls++;
        expect(roleFile('$_newProvider.json').existsSync(), isTrue);
        return const [];
      },
      cached: false,
      fixtureKind: ProviderFixtureKind.codexUsage,
      fixtureFile: 'codex.json',
    );

    await Future.wait([
      collectAllWithRuntimeAccess(registry: [registration]),
      collectAllWithRuntimeAccess(registry: [registration]),
    ]);

    expect(starts, 1);
    expect(adapterCalls, 2);
  });

  test('copies every opaque storage role byte-for-byte with bounded receipt',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final accountDigest = accountIdentityDigest(accountA);
    final historyLine = jsonEncode(snapshot(accountA, now, 40));
    final bucket = HeadroomBucket(start: bucketStart(now))..add(60);
    final bucketJson = jsonEncode([bucket.toJson()]);
    final historyCheckpoint = {
      'digest': digestOf(digestOf(historyLine)),
      'count': 1,
      'row_digests': [digestOf(historyLine)],
    };
    final bucketCheckpoint = {
      'digest': digestOf(bucketJson),
      'count': 1,
      'buckets': [bucket.toJson()],
    };
    final sources = <String, String>{
      '${_oldProvider}_account_$accountDigest.json':
          jsonEncode(snapshot(accountA, now, 40)),
      'drift_${_oldProvider}_account_$accountDigest.json': jsonEncode({
        'schema': 'quotabot.provider-drift.v1',
        'provider': _oldProvider,
        'account': accountA,
        'observed_at': now,
        'observed_at_micros': now * 1000000,
        'reason': 'fixture drift',
      }),
      'history_${_oldProvider}_account_$accountDigest.jsonl': '$historyLine\n',
      'buckets_${_oldProvider}_account_$accountDigest.json': bucketJson,
      'analytics_migration_${_oldProvider}_account_$accountDigest.json':
          jsonEncode({
        'schema': 'quotabot.analytics-migration.v1',
        'provider': _oldProvider,
        'account_digest': accountDigest,
        'observed_at': now,
        'history': historyCheckpoint,
        'buckets': bucketCheckpoint,
      }),
      'legacy_bucket_owner_${_oldProvider}_account_$accountDigest.json':
          jsonEncode({
        'schema': 'quotabot.legacy-bucket-owner.v1',
        'provider': _oldProvider,
        'account_digest': accountDigest,
      }),
    };
    for (final entry in sources.entries) {
      roleFile(entry.key).writeAsStringSync(entry.value);
    }

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'complete');
    expect(report.processedRecords, sources.length);
    expect(report.carriedRecords, sources.length);
    for (final entry in sources.entries) {
      final targetName = entry.key.replaceFirst(_oldProvider, _newProvider);
      expect(roleFile(targetName).readAsStringSync(), entry.value);
      expect(roleFile(entry.key).readAsStringSync(), entry.value);
    }

    final receipt = jsonDecode(roleFile(
      'provider_id_migration_${_oldProvider}_to_$_newProvider.json',
    ).readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['schema'], providerIdMigrationReceiptSchema);
    expect(receipt['state'], 'complete');
    expect((receipt['records'] as List), hasLength(sources.length));
    final encoded = jsonEncode(receipt);
    expect(encoded, isNot(contains(accountA)));
    expect(encoded, isNot(contains(root.path)));

    final migratedMarker = jsonDecode(roleFile(
      'analytics_migration_${_newProvider}_account_$accountDigest.json',
    ).readAsStringSync()) as Map<String, dynamic>;
    expect(migratedMarker['history'], historyCheckpoint);
    expect(migratedMarker['buckets'], bucketCheckpoint);
  });

  test('cache readers canonicalize migrated bytes only in memory', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final accountDigest = accountIdentityDigest(accountA);
    final rawSnapshot = jsonEncode(snapshot(accountA, now, 25));
    final historyLine = jsonEncode(snapshot(accountA, now - 60, 30));
    final bucket = HeadroomBucket(start: bucketStart(now))..add(70);
    roleFile('${_oldProvider}_account_$accountDigest.json')
        .writeAsStringSync(rawSnapshot);
    roleFile('history_${_oldProvider}_account_$accountDigest.jsonl')
        .writeAsStringSync('$historyLine\n');
    roleFile('buckets_${_oldProvider}_account_$accountDigest.json')
        .writeAsStringSync(jsonEncode([bucket.toJson()]));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    setProviderIdAliasesForTesting(_aliases);

    final loaded = loadAccountSnapshot(_newProvider, accountA);
    final history = loadHistory(_newProvider, account: accountA);
    final buckets = loadBuckets(_newProvider, account: accountA);

    expect(loaded, isNotNull);
    expect(loaded!.provider, _newProvider);
    expect(history.single.provider, _newProvider);
    expect(buckets.single.count, 1);
    expect(
      roleFile('${_newProvider}_account_$accountDigest.json')
          .readAsStringSync(),
      rawSnapshot,
    );
    expect(
      roleFile('history_${_newProvider}_account_$accountDigest.jsonl')
          .readAsStringSync(),
      '$historyLine\n',
    );
  });

  test('legacy account stems migrate only with exact bucket ownership',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const legacyAccount = 'legacy/account@example.com';
    final legacyStem =
        legacyAccount.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final accountDigest = accountIdentityDigest(legacyAccount);
    final ownerStem = accountStorageStem(legacyStem);
    final historyLine = jsonEncode(snapshot(legacyAccount, now, 15));
    final bucket = HeadroomBucket(start: bucketStart(now))..add(85);
    final sources = <String, String>{
      '${_oldProvider}_$legacyStem.json':
          jsonEncode(snapshot(legacyAccount, now, 15)),
      'drift_${_oldProvider}_$legacyStem.json': jsonEncode({
        'schema': 'quotabot.provider-drift.v1',
        'provider': _oldProvider,
        'account': legacyAccount,
        'observed_at': now,
        'reason': 'fixture drift',
      }),
      'history_${_oldProvider}_$legacyStem.jsonl': '$historyLine\n',
      'buckets_${_oldProvider}_$legacyStem.json': jsonEncode([bucket.toJson()]),
      'legacy_bucket_owner_${_oldProvider}_$ownerStem.json': jsonEncode({
        'schema': 'quotabot.legacy-bucket-owner.v1',
        'provider': _oldProvider,
        'account_digest': accountDigest,
      }),
    };
    for (final entry in sources.entries) {
      roleFile(entry.key).writeAsStringSync(entry.value);
    }

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    setProviderIdAliasesForTesting(_aliases);

    expect(report.state, 'complete');
    expect(loadAccountSnapshot(_newProvider, legacyAccount), isNotNull);
    expect(loadHistory(_newProvider, account: legacyAccount), hasLength(1));
    expect(loadBuckets(_newProvider, account: legacyAccount), hasLength(1));
    final receipt = jsonDecode(roleFile(
      'provider_id_migration_${_oldProvider}_to_$_newProvider.json',
    ).readAsStringSync()) as Map<String, dynamic>;
    final records = (receipt['records'] as List)
        .map((record) => (record as Map).cast<String, dynamic>())
        .toList();
    expect(
      records.where((record) => record['scope'] == 'account'),
      hasLength(sources.length),
    );
    expect(
      records.every((record) => record['account_digest'] == accountDigest),
      isTrue,
    );
    final encoded = jsonEncode(receipt);
    expect(encoded, isNot(contains(legacyAccount)));
    expect(encoded, isNot(contains(legacyStem)));
  });

  test('unowned legacy buckets are retained without affecting exact accounts',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bucket = HeadroomBucket(start: bucketStart(now))..add(50);
    roleFile('buckets_${_oldProvider}_unresolved.json')
        .writeAsStringSync(jsonEncode([bucket.toJson()]));

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'partial');
    expect(report.invalidRecords, 1);
    expect(roleFile('buckets_${_newProvider}_unresolved.json').existsSync(),
        isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'buckets',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
    setProviderIdAliasesForTesting(_aliases);
    expect(
      () => recordHeadroomSample(
        _newProvider,
        75,
        now,
        account: accountA,
      ),
      returnsNormally,
    );
    expect(loadBuckets(_newProvider, account: accountA), hasLength(1));
  });

  test('identical target without a receipt resumes idempotently', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final content = jsonEncode(snapshot('default', now, 20));
    roleFile('$_oldProvider.json').writeAsStringSync(content);
    roleFile('$_newProvider.json').writeAsStringSync(content);

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'complete');
    expect(report.carriedRecords, 1);
    expect(roleFile('$_oldProvider.json').readAsStringSync(), content);
    expect(roleFile('$_newProvider.json').readAsStringSync(), content);
  });

  test('canonical deletion is durable and a later legacy write quarantines',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final oldFile = roleFile('$_oldProvider.json');
    final newFile = roleFile('$_newProvider.json');
    oldFile.writeAsStringSync(jsonEncode(snapshot('default', now, 20)));
    await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    newFile.deleteSync();

    final deleted = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(deleted.state, 'complete');
    expect(newFile.existsSync(), isFalse);

    oldFile.writeAsStringSync(jsonEncode(snapshot('default', now + 1, 30)));
    final late = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(late.state, 'partial');
    expect(late.quarantinedRecords, 1);
    expect(newFile.existsSync(), isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        'default',
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('canonical then legacy advances from one baseline quarantine', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final accountDigest = accountIdentityDigest(accountA);
    final oldFile = roleFile('${_oldProvider}_account_$accountDigest.json');
    final newFile = roleFile('${_newProvider}_account_$accountDigest.json');
    oldFile.writeAsStringSync(jsonEncode(snapshot(accountA, now, 10)));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);

    final canonical = snapshot(accountA, now + 1, 30)
      ..['provider'] = _newProvider;
    final canonicalContent = jsonEncode(canonical);
    newFile.writeAsStringSync(canonicalContent);
    final canonicalOnly = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(canonicalOnly.state, 'complete');
    expect(newFile.readAsStringSync(), canonicalContent);

    oldFile.writeAsStringSync(jsonEncode(snapshot(accountA, now + 2, 40)));
    final conflict = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(conflict.state, 'partial');
    expect(conflict.quarantinedRecords, 1);
    expect(newFile.readAsStringSync(), canonicalContent);
  });

  test('one-sided late writer advances, two-sided advance quarantines',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final accountDigest = accountIdentityDigest(accountA);
    final oldFile = roleFile('${_oldProvider}_account_$accountDigest.json');
    final newFile = roleFile('${_newProvider}_account_$accountDigest.json');
    oldFile.writeAsStringSync(jsonEncode(snapshot(accountA, now, 10)));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);

    final lateLegacy = jsonEncode(snapshot(accountA, now + 1, 20));
    oldFile.writeAsStringSync(lateLegacy);
    setProviderIdAliasesForTesting(_aliases);
    expect(loadCachedSnapshots(), isEmpty);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
    final advanced = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(advanced.state, 'complete');
    expect(newFile.readAsStringSync(), lateLegacy);

    oldFile.writeAsStringSync(jsonEncode(snapshot(accountA, now + 2, 30)));
    final canonical = snapshot(accountA, now + 2, 35)
      ..['provider'] = _newProvider;
    newFile.writeAsStringSync(jsonEncode(canonical));
    final conflict = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(conflict.state, 'partial');
    expect(conflict.quarantinedRecords, 1);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
    setProviderIdAliasesForTesting(_aliases);
    expect(loadAccountSnapshot(_newProvider, accountA), isNull);
  });

  test('new retired history does not quarantine quota for the same identity',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final baseline = jsonEncode(snapshot(accountA, now, 10));
    roleFile('${_oldProvider}_account_$digest.json')
        .writeAsStringSync(baseline);
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    setProviderIdAliasesForTesting(_aliases);

    roleFile('history_${_oldProvider}_account_$digest.jsonl')
        .writeAsStringSync('$baseline\n');

    expect(loadAccountSnapshot(_newProvider, accountA), isNotNull);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'history',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('provider compatibility fallback stops after a retired late write',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final historyLine = jsonEncode(snapshot(accountA, now, 10));
    final bucket = HeadroomBucket(start: bucketStart(now))..add(90);
    final oldHistory = roleFile('history_$_oldProvider.jsonl');
    final oldBuckets = roleFile('buckets_$_oldProvider.json');
    oldHistory.writeAsStringSync('$historyLine\n');
    oldBuckets.writeAsStringSync(jsonEncode([bucket.toJson()]));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    setProviderIdAliasesForTesting(_aliases);

    expect(loadHistory(_newProvider, account: accountA), hasLength(1));
    expect(loadBuckets(_newProvider, account: accountA), hasLength(1));

    oldHistory.writeAsStringSync(
      '$historyLine\n${jsonEncode(snapshot(accountA, now + 1, 20))}\n',
    );
    final advancedBucket = HeadroomBucket(start: bucketStart(now))..add(80);
    oldBuckets.writeAsStringSync(jsonEncode([advancedBucket.toJson()]));

    expect(loadHistory(_newProvider, account: accountA), isEmpty);
    expect(loadBuckets(_newProvider, account: accountA), isEmpty);
  });

  test('lossy legacy collision quarantines only the receipt owner', () async {
    const collidingA = 'credential:a/b';
    const collidingB = 'credential:a?b';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final legacy = roleFile('${_oldProvider}_credential_a_b.json');
    legacy.writeAsStringSync(jsonEncode(snapshot(collidingB, now, 10)));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);

    legacy.writeAsStringSync(jsonEncode(snapshot(collidingB, now + 1, 20)));
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        collidingA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        collidingB,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('current mutation stops when a retired writer advanced after startup',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final oldFile = roleFile('${_oldProvider}_account_$digest.json');
    final newFile = roleFile('${_newProvider}_account_$digest.json');
    final baseline = jsonEncode(snapshot(accountA, now, 10));
    oldFile.writeAsStringSync(baseline);
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    setProviderIdAliasesForTesting(_aliases);

    final lateLegacy = jsonEncode(snapshot(accountA, now + 1, 20));
    oldFile.writeAsStringSync(lateLegacy);
    final current = ProviderQuota.fromJson(
      snapshot(accountA, now + 2, 30)..['provider'] = _newProvider,
    );
    saveSnapshot(
      current,
      observedAtMicros: DateTime.now().microsecondsSinceEpoch,
    );
    expect(newFile.readAsStringSync(), baseline);

    final reconciled = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(reconciled.state, 'complete');
    expect(newFile.readAsStringSync(), lateLegacy);
  });

  test('history conflict quarantines only one identity and tier', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digestA = accountIdentityDigest(accountA);
    final digestB = accountIdentityDigest(accountB);
    final lineA = jsonEncode(snapshot(accountA, now, 10));
    final conflictingA = jsonEncode(snapshot(accountA, now, 11));
    final lineB = jsonEncode(snapshot(accountB, now, 20));
    roleFile('${_oldProvider}_account_$digestA.json')
        .writeAsStringSync(jsonEncode(snapshot(accountA, now, 10)));
    roleFile('${_oldProvider}_account_$digestB.json')
        .writeAsStringSync(jsonEncode(snapshot(accountB, now, 20)));
    roleFile('history_${_oldProvider}_account_$digestA.jsonl')
        .writeAsStringSync('$lineA\n');
    roleFile('history_${_newProvider}_account_$digestA.jsonl')
        .writeAsStringSync('$conflictingA\n');
    roleFile('history_${_oldProvider}_account_$digestB.jsonl')
        .writeAsStringSync('$lineB\n');
    final bucket = HeadroomBucket(start: bucketStart(now))..add(50);
    roleFile('buckets_${_oldProvider}_account_$digestA.json')
        .writeAsStringSync(jsonEncode([bucket.toJson()]));

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    setProviderIdAliasesForTesting(_aliases);

    expect(report.state, 'partial');
    expect(loadAccountSnapshot(_newProvider, accountA), isNotNull);
    expect(loadHistory(_newProvider, account: accountA), isEmpty);
    expect(loadBuckets(_newProvider, account: accountA), isNotEmpty);
    expect(loadHistory(_newProvider, account: accountB), hasLength(1));
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountB,
        'history',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
  });

  test('malformed root and malformed record fail closed without throwing',
      () async {
    final malformedRoot = Directory('${tempConfig.path}/malformed-root');
    File(malformedRoot.path).writeAsStringSync('not a directory');
    final rootReport = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: malformedRoot,
    );
    expect(rootReport.state, 'partial');
    expect(rootReport.invalidRecords, 1);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: malformedRoot,
      ),
      isTrue,
    );

    final digest = accountIdentityDigest(accountA);
    roleFile('${_oldProvider}_account_$digest.json')
        .writeAsStringSync('{"provider":"wrong"}');
    final recordReport = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(recordReport.state, 'partial');
    expect(recordReport.invalidRecords, 1);
    expect(
        roleFile('${_newProvider}_account_$digest.json').existsSync(), isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('missing migration receipt blocks every quota cache read and admission',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    roleFile('${_oldProvider}_account_$digest.json')
        .writeAsStringSync(jsonEncode(snapshot(accountA, now, 10)));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    setProviderIdAliasesForTesting(_aliases);
    roleFile('provider_id_migration_${_oldProvider}_to_$_newProvider.json')
        .deleteSync();

    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
      ),
      isTrue,
    );
    expect(loadCachedSnapshots(), isEmpty);
    expect(loadAccountSnapshots(_newProvider), isEmpty);

    final liveJson = snapshot(accountA, now + 1, 20)
      ..['provider'] = _newProvider;
    final live = ProviderQuota.fromJson(liveJson);
    expect(attachProviderDriftObservation(live, now: now + 1).driftReason,
        isNotNull);
    expect(
      admitAndCacheQuotaEvidence(
        live,
        observedAt: now + 1,
        observedAtMicros: (now + 1) * 1000000,
      ).driftReason,
      isNotNull,
    );
  });

  test('semantically corrupt receipts fail closed and never forge a baseline',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final sourceFile = roleFile('${_oldProvider}_account_$digest.json');
    final targetFile = roleFile('${_newProvider}_account_$digest.json');
    final receiptFile = roleFile(
      'provider_id_migration_${_oldProvider}_to_$_newProvider.json',
    );
    final baseline = jsonEncode(snapshot(accountA, now, 10));
    sourceFile.writeAsStringSync(baseline);
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);

    var receipt =
        jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
    final duplicated = Map<String, dynamic>.from(receipt)
      ..['records'] = [
        ...(receipt['records'] as List),
        (receipt['records'] as List).first,
      ];
    receiptFile.writeAsStringSync(jsonEncode(duplicated));
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
    final repaired = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(repaired.state, 'complete');

    final advanced = jsonEncode(snapshot(accountA, now + 1, 20));
    sourceFile.writeAsStringSync(advanced);
    receipt =
        jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
    final forgedRecord = Map<String, dynamic>.from(
      (receipt['records'] as List).single as Map,
    )
      ..['state'] = 'invalid'
      ..['baseline_sha256'] = digestOf(baseline);
    receiptFile.writeAsStringSync(jsonEncode({
      ...receipt,
      'records': [forgedRecord],
    }));

    final conflict = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(conflict.state, 'partial');
    expect(conflict.quarantinedRecords, 1);
    expect(targetFile.readAsStringSync(), baseline);

    receipt =
        jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
    final forgedQuarantine = Map<String, dynamic>.from(
      (receipt['records'] as List).single as Map,
    )..['baseline_sha256'] = digestOf(baseline);
    receiptFile.writeAsStringSync(jsonEncode({
      ...receipt,
      'records': [forgedQuarantine],
    }));
    final stillConflicted = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(stillConflicted.state, 'partial');
    expect(stillConflicted.quarantinedRecords, 1);
    expect(targetFile.readAsStringSync(), baseline);
  });

  test('receipt identity and top-level contradictions fail closed', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    roleFile('${_oldProvider}_account_$digest.json')
        .writeAsStringSync(jsonEncode(snapshot(accountA, now, 10)));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    final receiptFile = roleFile(
      'provider_id_migration_${_oldProvider}_to_$_newProvider.json',
    );
    final original =
        jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;

    final mutations = <Map<String, dynamic> Function()>[
      () {
        final record = Map<String, dynamic>.from(
          (original['records'] as List).single as Map,
        )..['account_digest'] = accountIdentityDigest(accountB);
        return {
          ...original,
          'records': [record]
        };
      },
      () {
        final record = Map<String, dynamic>.from(
          (original['records'] as List).single as Map,
        )
          ..['scope'] = 'provider'
          ..remove('account_digest');
        return {
          ...original,
          'records': [record]
        };
      },
      () {
        final record = Map<String, dynamic>.from(
          (original['records'] as List).single as Map,
        )
          ..['role'] = 'buckets'
          ..['tier'] = 'buckets';
        return {
          ...original,
          'records': [record]
        };
      },
      () => {...original, 'global_uncertainty': true},
      () => {
            ...original,
            'state': 'partial',
            'truncated': true,
            'global_uncertainty': false,
          },
      () => {...original, 'state': 'partial'},
    ];

    for (final mutation in mutations) {
      receiptFile.writeAsStringSync(jsonEncode(mutation()));
      expect(
        providerIdMigrationTierQuarantined(
          _newProvider,
          accountA,
          'quota',
          aliases: _aliases,
          root: root,
        ),
        isTrue,
      );
    }
  });

  test('lossy raw receipt identity is revalidated from source content',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rawAccount = List.filled(170, 'a').join();
    roleFile('${_oldProvider}_$rawAccount.json')
        .writeAsStringSync(jsonEncode(snapshot(rawAccount, now, 10)));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    final receiptFile = roleFile(
      'provider_id_migration_${_oldProvider}_to_$_newProvider.json',
    );
    final receipt =
        jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
    final record = Map<String, dynamic>.from(
      (receipt['records'] as List).single as Map,
    )..['account_digest'] = accountIdentityDigest(accountB);
    receiptFile.writeAsStringSync(jsonEncode({
      ...receipt,
      'records': [record],
    }));

    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        rawAccount,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('preexisting new-provider raw branch conflict is preserved', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rawAccount = List.filled(170, 'a').join();
    final retired = jsonEncode(snapshot(rawAccount, now, 10));
    final compatibility = jsonEncode(
      snapshot(rawAccount, now + 1, 20)..['provider'] = _newProvider,
    );
    final retiredFile = roleFile('${_oldProvider}_$rawAccount.json');
    final compatibilityFile = roleFile('${_newProvider}_$rawAccount.json');
    final opaqueFile = roleFile(
      '${_newProvider}_account_${accountIdentityDigest(rawAccount)}.json',
    );
    retiredFile.writeAsStringSync(retired);
    compatibilityFile.writeAsStringSync(compatibility);

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(report.state, 'partial');
    expect(report.quarantinedRecords, 1);
    expect(retiredFile.readAsStringSync(), retired);
    expect(compatibilityFile.readAsStringSync(), compatibility);
    expect(opaqueFile.existsSync(), isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        rawAccount,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('equal new-provider raw compatibility coalesces into opaque storage',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rawAccount = List.filled(170, 'a').join();
    final baseline = jsonEncode(snapshot(rawAccount, now, 10));
    roleFile('${_oldProvider}_$rawAccount.json').writeAsStringSync(baseline);
    roleFile('${_newProvider}_$rawAccount.json').writeAsStringSync(baseline);
    final opaqueFile = roleFile(
      '${_newProvider}_account_${accountIdentityDigest(rawAccount)}.json',
    );

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(report.state, 'complete');
    expect(opaqueFile.readAsStringSync(), baseline);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        rawAccount,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
  });

  test('late new-provider raw branch conflicts with the opaque target',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rawAccount = List.filled(175, 'a').join();
    final retired = jsonEncode(snapshot(rawAccount, now, 10));
    final compatibility = jsonEncode(
      snapshot(rawAccount, now + 1, 20)..['provider'] = _newProvider,
    );
    final retiredFile = roleFile('${_oldProvider}_$rawAccount.json');
    final compatibilityFile = roleFile('${_newProvider}_$rawAccount.json');
    final opaqueFile = roleFile(
      '${_newProvider}_account_${accountIdentityDigest(rawAccount)}.json',
    );
    retiredFile.writeAsStringSync(retired);
    expect(
      (await coordinateProviderIdCacheMigration(
        aliases: _aliases,
        root: root,
      ))
          .state,
      'complete',
    );
    final opaqueBaseline = opaqueFile.readAsStringSync();
    compatibilityFile.writeAsStringSync(compatibility);
    setProviderIdAliasesForTesting(_aliases);

    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        rawAccount,
        'quota',
      ),
      isTrue,
    );
    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(report.state, 'partial');
    expect(report.quarantinedRecords, 1);
    expect(retiredFile.readAsStringSync(), retired);
    expect(compatibilityFile.readAsStringSync(), compatibility);
    expect(opaqueFile.readAsStringSync(), opaqueBaseline);
  });

  test('canonical tombstone blocks a late raw compatibility fallback',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rawAccount = List.filled(180, 'a').join();
    final retired = jsonEncode(snapshot(rawAccount, now, 10));
    final retiredFile = roleFile('${_oldProvider}_$rawAccount.json');
    final compatibilityFile = roleFile('${_newProvider}_$rawAccount.json');
    final opaqueFile = roleFile(
      '${_newProvider}_account_${accountIdentityDigest(rawAccount)}.json',
    );
    retiredFile.writeAsStringSync(retired);
    expect(
      (await coordinateProviderIdCacheMigration(
        aliases: _aliases,
        root: root,
      ))
          .state,
      'complete',
    );
    opaqueFile.deleteSync();
    expect(
      (await coordinateProviderIdCacheMigration(
        aliases: _aliases,
        root: root,
      ))
          .state,
      'complete',
    );
    compatibilityFile.writeAsStringSync(retired);
    setProviderIdAliasesForTesting(_aliases);

    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        rawAccount,
        'quota',
      ),
      isTrue,
    );
    expect(loadAccountSnapshot(_newProvider, rawAccount), isNull);
    final conflict = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(conflict.state, 'partial');
    expect(conflict.quarantinedRecords, 1);
    expect(opaqueFile.existsSync(), isFalse);
    expect(compatibilityFile.readAsStringSync(), retired);
  });

  test('invalid history buckets and checkpoints quarantine exact tiers',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final newer = jsonEncode(snapshot(accountA, now, 10));
    final older = jsonEncode(snapshot(accountA, now - 60, 20));
    roleFile('history_${_oldProvider}_account_$digest.jsonl')
        .writeAsStringSync('$newer\n$older\n');
    roleFile('buckets_${_oldProvider}_account_$digest.json')
        .writeAsStringSync(jsonEncode([
      {
        's': bucketStart(now),
        'n': 2,
        'sum': 100,
        'sq': 5000,
        'min': 50,
        'max': 50,
        'x': 0,
        'h': List<int>.filled(kHistBins, 0),
      },
    ]));
    roleFile('analytics_migration_${_oldProvider}_account_$digest.json')
        .writeAsStringSync(jsonEncode({
      'schema': 'quotabot.analytics-migration.v1',
      'provider': _oldProvider,
      'account_digest': digest,
      'observed_at': now,
      'history': {
        'digest': List.filled(64, '0').join(),
        'count': 1,
        'row_digests': [digestOf(newer)],
      },
    }));

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'partial');
    expect(report.invalidRecords, 3);
    expect(
        roleFile('history_${_newProvider}_account_$digest.jsonl').existsSync(),
        isFalse);
    expect(
        roleFile('buckets_${_newProvider}_account_$digest.json').existsSync(),
        isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'history',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'buckets',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('invalid analytics checkpoint quarantines only its affected tier',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final bucket = HeadroomBucket(start: bucketStart(now))..add(60);
    final bucketJson = jsonEncode([bucket.toJson()]);
    roleFile('analytics_migration_${_oldProvider}_account_$digest.json')
        .writeAsStringSync(jsonEncode({
      'schema': 'quotabot.analytics-migration.v1',
      'provider': _oldProvider,
      'account_digest': digest,
      'observed_at': now,
      'history': {
        'digest': List.filled(64, '0').join(),
        'count': 1,
        'row_digests': [digestOf('history row')],
      },
      'buckets': {
        'digest': digestOf(bucketJson),
        'count': 1,
        'buckets': [bucket.toJson()],
      },
    }));

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'partial');
    expect(report.invalidRecords, 1);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'history',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'buckets',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
  });

  test('malformed canonical target is quarantined without replacement',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final source = jsonEncode(snapshot(accountA, now, 10));
    const malformedTarget = '{"provider":"codex"';
    roleFile('${_oldProvider}_account_$digest.json').writeAsStringSync(source);
    roleFile('${_newProvider}_account_$digest.json')
        .writeAsStringSync(malformedTarget);

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'partial');
    expect(report.quarantinedRecords, 1);
    expect(roleFile('${_newProvider}_account_$digest.json').readAsStringSync(),
        malformedTarget);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('canonical target change fails direct bucket reads before a new receipt',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bucket = HeadroomBucket(start: bucketStart(now))..add(90);
    final oldBuckets = roleFile('buckets_$_oldProvider.json');
    final newBuckets = roleFile('buckets_$_newProvider.json');
    oldBuckets.writeAsStringSync(jsonEncode([bucket.toJson()]));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    setProviderIdAliasesForTesting(_aliases);
    expect(loadBuckets(_newProvider), hasLength(1));

    newBuckets.writeAsStringSync(jsonEncode([
      {
        's': bucketStart(now),
        'n': 2,
        'sum': 200,
        'sq': 1,
        'min': 100,
        'max': 100,
        'x': 0,
        'h': [2, ...List<int>.filled(kHistBins - 1, 0)],
      },
    ]));

    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        'default',
        'buckets',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
    expect(loadBuckets(_newProvider), isEmpty);
  });

  test('normal canonical writers remain readable without a coordinator rerun',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bucket = HeadroomBucket(start: bucketStart(now))..add(90);
    for (final account in const [accountA, accountB]) {
      final digest = accountIdentityDigest(account);
      final baseline = jsonEncode(snapshot(account, now, 10));
      roleFile('${_oldProvider}_account_$digest.json')
          .writeAsStringSync(baseline);
      roleFile('history_${_oldProvider}_account_$digest.jsonl')
          .writeAsStringSync('$baseline\n');
      roleFile('buckets_${_oldProvider}_account_$digest.json')
          .writeAsStringSync(jsonEncode([bucket.toJson()]));
    }
    expect(
      (await coordinateProviderIdCacheMigration(
        aliases: _aliases,
        root: root,
      ))
          .state,
      'complete',
    );
    setProviderIdAliasesForTesting(_aliases);

    final savedMap = snapshot(accountA, now + 1, 20)
      ..['provider'] = _newProvider;
    final saved = ProviderQuota.fromJson(savedMap);
    saveSnapshot(saved, observedAtMicros: (now + 1) * 1000000);
    expect(loadAccountSnapshot(_newProvider, accountA)?.asOf, now + 1);
    expect(loadHistory(_newProvider, account: accountA).last.asOf, now + 1);

    recordHeadroomSample(
      _newProvider,
      80,
      now + 1,
      account: accountA,
    );
    expect(loadBuckets(_newProvider, account: accountA), hasLength(1));
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'buckets',
      ),
      isFalse,
    );

    final admittedMap = snapshot(accountB, now + 2, 30)
      ..['provider'] = _newProvider;
    final admittedFresh = ProviderQuota.fromJson(admittedMap);
    final admitted = admitAndCacheQuotaEvidence(
      admittedFresh,
      observedAt: now + 2,
      observedAtMicros: (now + 2) * 1000000,
    );
    expect(admitted.ok, isTrue);
    expect(admitted.stale, isFalse);
    expect(loadAccountSnapshot(_newProvider, accountB)?.asOf, now + 2);
  });

  test('history conflict does not suppress safe live quota admission',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final retired = jsonEncode(snapshot(accountA, now, 10));
    final canonical = jsonEncode(
      snapshot(accountA, now + 1, 20)..['provider'] = _newProvider,
    );
    roleFile('history_${_oldProvider}_account_$digest.jsonl')
        .writeAsStringSync('$retired\n');
    roleFile('history_${_newProvider}_account_$digest.jsonl')
        .writeAsStringSync('$canonical\n');
    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(report.state, 'partial');
    expect(report.quarantinedRecords, 1);
    setProviderIdAliasesForTesting(_aliases);

    final freshMap = snapshot(accountA, now + 2, 30)
      ..['provider'] = _newProvider;
    final fresh = ProviderQuota.fromJson(freshMap);
    final admitted = admitAndCacheQuotaEvidence(
      fresh,
      observedAt: now + 2,
      observedAtMicros: (now + 2) * 1000000,
    );
    expect(admitted.ok, isTrue);
    expect(admitted.stale, isFalse);
    expect(loadAccountSnapshot(_newProvider, accountA)?.asOf, now + 2);
    expect(loadHistory(_newProvider, account: accountA), isEmpty);
  });

  test('nonregular exact source quarantines only its identity', () async {
    final digest = accountIdentityDigest(accountA);
    Directory(roleFile('${_oldProvider}_account_$digest.json').path)
        .createSync();

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    final receipt = jsonDecode(
      roleFile('provider_id_migration_${_oldProvider}_to_$_newProvider.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;

    expect(report.state, 'partial');
    expect(report.invalidRecords, 1);
    expect(receipt['global_uncertainty'], isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountA,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountB,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
  });

  test('unusable drift record is rejected before canonical creation', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    roleFile('drift_${_oldProvider}_account_$digest.json')
        .writeAsStringSync(jsonEncode({
      'schema': 'quotabot.provider-drift.v1',
      'provider': _oldProvider,
      'account': accountA,
      'observed_at': now + kQuotaEvidenceClockSkewSeconds + 60,
      'observed_at_micros':
          (now + kQuotaEvidenceClockSkewSeconds + 60) * 1000000,
      'reason': '',
    }));

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'partial');
    expect(report.invalidRecords, 1);
    expect(
      roleFile('drift_${_newProvider}_account_$digest.json').existsSync(),
      isFalse,
    );
  });

  test('future source snapshot is rejected before canonical creation',
      () async {
    final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 +
        kQuotaEvidenceClockSkewSeconds +
        60;
    final digest = accountIdentityDigest(accountA);
    roleFile('${_oldProvider}_account_$digest.json')
        .writeAsStringSync(jsonEncode(snapshot(accountA, future, 10)));

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );

    expect(report.state, 'partial');
    expect(report.invalidRecords, 1);
    expect(
        roleFile('${_newProvider}_account_$digest.json').existsSync(), isFalse);
  });

  test('record bound persists truthful partial progress and resumes', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    roleFile('$_oldProvider.json')
        .writeAsStringSync(jsonEncode(snapshot('default', now, 10)));
    final accountDigest = accountIdentityDigest(accountA);
    roleFile('${_oldProvider}_account_$accountDigest.json')
        .writeAsStringSync(jsonEncode(snapshot(accountA, now, 20)));

    final partial = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
      limits: const ProviderIdMigrationLimits(maxRecords: 1),
    );
    expect(partial.state, 'partial');
    expect(partial.truncated, isTrue);
    expect(partial.processedRecords, 1);
    final receiptFile = roleFile(
      'provider_id_migration_${_oldProvider}_to_$_newProvider.json',
    );
    final partialReceipt =
        jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
    expect(partialReceipt['state'], 'partial');
    expect(partialReceipt['truncated'], isTrue);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountB,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );

    final resumed = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(resumed.state, 'complete');
    expect(roleFile('$_newProvider.json').existsSync(), isTrue);
    expect(roleFile('${_newProvider}_account_$accountDigest.json').existsSync(),
        isTrue);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        accountB,
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isFalse,
    );
  });

  test('alias record total-byte and duration limits fail closed', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tooManyAliases = await coordinateProviderIdCacheMigration(
      aliases: const {
        _oldProvider: _newProvider,
        'oldclaude': claudeProviderId,
      },
      root: root,
      limits: const ProviderIdMigrationLimits(maxAliases: 1),
    );
    expect(tooManyAliases.state, 'partial');
    expect(tooManyAliases.truncated, isTrue);
    expect(tooManyAliases.processedRecords, 0);

    final recordRoot = Directory('${tempConfig.path}/record_bound')
      ..createSync();
    File('${recordRoot.path}/$_oldProvider.json')
        .writeAsStringSync(jsonEncode(snapshot('default', now, 10)));
    final recordBound = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: recordRoot,
      limits: const ProviderIdMigrationLimits(maxRecordBytes: 32),
    );
    expect(recordBound.state, 'partial');
    expect(recordBound.invalidRecords, 1);
    expect(File('${recordRoot.path}/$_newProvider.json').existsSync(), isFalse);

    final totalRoot = Directory('${tempConfig.path}/total_bound')..createSync();
    File('${totalRoot.path}/$_oldProvider.json')
        .writeAsStringSync(jsonEncode(snapshot('default', now, 10)));
    final totalBound = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: totalRoot,
      limits: const ProviderIdMigrationLimits(maxTotalBytes: 32),
    );
    expect(totalBound.state, 'partial');
    expect(totalBound.invalidRecords, 1);
    expect(File('${totalRoot.path}/$_newProvider.json').existsSync(), isFalse);

    final durationRoot = Directory('${tempConfig.path}/duration_bound')
      ..createSync();
    File('${durationRoot.path}/$_oldProvider.json')
        .writeAsStringSync(jsonEncode(snapshot('default', now, 10)));
    setProviderIdMigrationObserverForTesting((phase) {
      if (phase == 'coordinator_locked') {
        sleep(const Duration(milliseconds: 10));
      }
    });
    final durationBound = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: durationRoot,
      limits: const ProviderIdMigrationLimits(
        maxDuration: Duration(milliseconds: 1),
      ),
    );
    setProviderIdMigrationObserverForTesting(null);
    expect(durationBound.state, 'partial');
    expect(durationBound.truncated, isTrue);
    expect(durationBound.processedRecords, 0);
    expect(
        File('${durationRoot.path}/$_newProvider.json').existsSync(), isFalse);
  });

  test('configured limits cannot exceed production reader ceilings', () async {
    final oversizedLimits = [
      const ProviderIdMigrationLimits(maxAliases: 33),
      const ProviderIdMigrationLimits(maxRootEntries: 4097),
      const ProviderIdMigrationLimits(maxRecords: 513),
      const ProviderIdMigrationLimits(maxTotalBytes: 32 * 1024 * 1024 + 1),
      const ProviderIdMigrationLimits(maxRecordBytes: 5 * 1024 * 1024 + 1),
      const ProviderIdMigrationLimits(maxDuration: Duration(seconds: 61)),
      const ProviderIdMigrationLimits(lockTimeout: Duration(seconds: 31)),
    ];

    for (final limits in oversizedLimits) {
      final report = await coordinateProviderIdCacheMigration(
        aliases: _aliases,
        root: root,
        limits: limits,
      );
      expect(report.state, 'partial');
      expect(report.truncated, isTrue);
      expect(report.processedRecords, 0);
    }
    expect(root.listSync(), isEmpty);
  });

  test('byte budget is shared across aliases', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final codexSource = jsonEncode(snapshot('default', now, 10));
    final claudeMap = snapshot('default', now, 20)..['provider'] = 'oldclaude';
    final claudeSource = jsonEncode(claudeMap);
    roleFile('$_oldProvider.json').writeAsStringSync(codexSource);
    roleFile('oldclaude.json').writeAsStringSync(claudeSource);

    final report = await coordinateProviderIdCacheMigration(
      aliases: const {
        _oldProvider: _newProvider,
        'oldclaude': claudeProviderId,
      },
      root: root,
      limits: ProviderIdMigrationLimits(
        maxTotalBytes: codexSource.length,
      ),
    );

    expect(report.state, 'partial');
    expect(report.truncated, isTrue);
    expect(report.processedRecords, 1);
    expect(roleFile('$_newProvider.json').existsSync(), isTrue);
    expect(roleFile('$claudeProviderId.json').existsSync(), isFalse);
  });

  test('oversized legacy names are explicit uncertainty', () async {
    final oversizedStem = List.filled(221, 'a').join();
    final ignoredBefore = roleFile('${_oldProvider}_$oversizedStem.json');
    ignoredBefore.writeAsStringSync('{}');

    final oversized = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(oversized.state, 'partial');
    expect(oversized.invalidRecords, 1);
    expect(oversized.truncated, isFalse);
  });

  test('root truncation preserves an unseen common baseline for safe resume',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = accountIdentityDigest(accountA);
    final oldFile = roleFile('${_oldProvider}_account_$digest.json');
    final newFile = roleFile('${_newProvider}_account_$digest.json');
    oldFile.writeAsStringSync(jsonEncode(snapshot(accountA, now, 10)));
    await coordinateProviderIdCacheMigration(aliases: _aliases, root: root);
    oldFile.deleteSync();
    for (var index = 0; index < 4; index++) {
      roleFile('unrelated_$index.txt').writeAsStringSync('bounded');
    }

    final partial = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
      limits: const ProviderIdMigrationLimits(maxRootEntries: 1),
    );
    expect(partial.state, 'partial');
    final receipt = jsonDecode(
      roleFile('provider_id_migration_${_oldProvider}_to_$_newProvider.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final records = receipt['records'] as List;
    expect(records, hasLength(1));
    expect((records.single as Map)['baseline_sha256'], isNotNull);

    final canonical = snapshot(accountA, now + 1, 20)
      ..['provider'] = _newProvider;
    final canonicalContent = jsonEncode(canonical);
    newFile.writeAsStringSync(canonicalContent);
    oldFile.writeAsStringSync(jsonEncode(snapshot(accountA, now + 2, 30)));
    final resumed = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(resumed.state, 'partial');
    expect(resumed.quarantinedRecords, 1);
    expect(newFile.readAsStringSync(), canonicalContent);
  });

  test('process crashes resume from every durable migration boundary',
      () async {
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final fixture =
        File('test/fixtures/provider_id_migration_crash.dart').absolute.path;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const phases = [
      'coordinator_locked',
      'prepared_receipt_temp_written',
      'target_temp_written',
      'target_renamed',
      'committed_receipt_temp_written',
    ];
    for (final phase in phases) {
      final caseRoot = Directory('${tempConfig.path}/crash_$phase')
        ..createSync();
      final source = File('${caseRoot.path}/$_oldProvider.json');
      final target = File('${caseRoot.path}/$_newProvider.json');
      final content = jsonEncode(snapshot('default', now, 10));
      source.writeAsStringSync(content);
      final crashed = await Process.run(
        Platform.resolvedExecutable,
        [
          '--enable-asserts',
          '--packages=$packageConfig',
          fixture,
          caseRoot.path,
          _oldProvider,
          _newProvider,
          phase,
        ],
        workingDirectory: Directory.current.path,
      ).timeout(const Duration(seconds: 30));
      expect(crashed.exitCode, 86, reason: '$phase: ${crashed.stderr}');

      final resumed = await coordinateProviderIdCacheMigration(
        aliases: _aliases,
        root: caseRoot,
        limits: const ProviderIdMigrationLimits(
          maxDuration: Duration(seconds: 30),
          lockTimeout: Duration(seconds: 10),
        ),
      );
      final ambiguousPreparedTarget = phase == 'target_temp_written';
      expect(
        resumed.state,
        ambiguousPreparedTarget ? 'partial' : 'complete',
        reason: phase,
      );
      if (ambiguousPreparedTarget) {
        expect(target.existsSync(), isFalse, reason: phase);
        expect(resumed.quarantinedRecords, 1, reason: phase);
      } else {
        expect(target.readAsStringSync(), content, reason: phase);
      }
      final receipt = jsonDecode(
        File('${caseRoot.path}/provider_id_migration_'
                '${_oldProvider}_to_$_newProvider.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(
        receipt['state'],
        ambiguousPreparedTarget ? 'partial' : 'complete',
        reason: phase,
      );
      expect(
        (receipt['records'] as List)
            .every((record) => (record as Map)['state'] != 'prepared'),
        isTrue,
        reason: phase,
      );
    }
  });

  test('prepared installed target accepts a later legacy-only advance',
      () async {
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final fixture =
        File('test/fixtures/provider_id_migration_crash.dart').absolute.path;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = roleFile('$_oldProvider.json');
    final target = roleFile('$_newProvider.json');
    final baseline = jsonEncode(snapshot('default', now, 10));
    source.writeAsStringSync(baseline);
    target.writeAsStringSync(baseline);
    expect(
      (await coordinateProviderIdCacheMigration(
        aliases: _aliases,
        root: root,
      ))
          .state,
      'complete',
    );

    final intended = jsonEncode(snapshot('default', now + 1, 20));
    source.writeAsStringSync(intended);
    final crashed = await Process.run(
      Platform.resolvedExecutable,
      [
        '--enable-asserts',
        '--packages=$packageConfig',
        fixture,
        root.path,
        _oldProvider,
        _newProvider,
        'target_renamed',
      ],
      workingDirectory: Directory.current.path,
    ).timeout(const Duration(seconds: 30));
    expect(crashed.exitCode, 86, reason: '${crashed.stderr}');
    expect(target.readAsStringSync(), intended);

    final advanced = jsonEncode(snapshot('default', now + 2, 30));
    source.writeAsStringSync(advanced);
    final resumed = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(resumed.state, 'complete');
    expect(target.readAsStringSync(), advanced);
  });

  test('prepared initial target deletion never resurrects retired evidence',
      () async {
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final fixture =
        File('test/fixtures/provider_id_migration_crash.dart').absolute.path;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = roleFile('$_oldProvider.json');
    final target = roleFile('$_newProvider.json');
    final content = jsonEncode(snapshot('default', now, 10));
    source.writeAsStringSync(content);

    final crashed = await Process.run(
      Platform.resolvedExecutable,
      [
        '--enable-asserts',
        '--packages=$packageConfig',
        fixture,
        root.path,
        _oldProvider,
        _newProvider,
        'target_renamed',
      ],
      workingDirectory: Directory.current.path,
    ).timeout(const Duration(seconds: 30));
    expect(crashed.exitCode, 86, reason: '${crashed.stderr}');
    expect(target.existsSync(), isTrue);
    target.deleteSync();

    final resumed = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(resumed.state, 'partial');
    expect(resumed.quarantinedRecords, 1);
    expect(target.existsSync(), isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        '',
        'quota',
        aliases: _aliases,
        root: root,
      ),
      isTrue,
    );
  });

  test('lock-time receipt changes block quota and bucket writers', () async {
    await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    final receiptFile = roleFile(
      'provider_id_migration_${_oldProvider}_to_$_newProvider.json',
    );
    final cleanReceipt = receiptFile.readAsStringSync();
    final accountDigest = accountIdentityDigest(accountA);
    Map<String, dynamic> blockedReceipt(String tier) {
      final name = tier == 'quota'
          ? '${_oldProvider}_account_$accountDigest.json'
          : 'buckets_${_oldProvider}_account_$accountDigest.json';
      return {
        'schema': providerIdMigrationReceiptSchema,
        'old_provider': _oldProvider,
        'new_provider': _newProvider,
        'state': 'partial',
        'observed_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'scanned_entries': 1,
        'truncated': false,
        'global_uncertainty': false,
        'records': [
          {
            'record_id': digestOf(name),
            'role': tier == 'quota' ? 'snapshot' : 'buckets',
            'tier': tier,
            'scope': 'account',
            'account_digest': accountDigest,
            'state': 'quarantined',
            'reason': 'both_branches_advanced',
            'bytes': 1,
            'source_sha256': digestOf('source'),
            'target_absent': true,
          },
        ],
      };
    }

    setProviderIdAliasesForTesting(_aliases);
    var changed = false;
    setEvidenceGuardObserverForTesting((phase, _) {
      if (phase == 'after_acquire' && !changed) {
        changed = true;
        receiptFile.writeAsStringSync(jsonEncode(blockedReceipt('quota')));
      }
    });
    final freshMap = snapshot(
      accountA,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      15,
    )..['provider'] = _newProvider;
    final fresh = ProviderQuota.fromJson(freshMap);
    final admitted = admitAndCacheQuotaEvidence(
      fresh,
      observedAt: fresh.asOf,
      observedAtMicros: fresh.asOf * 1000000,
    );
    expect(admitted.ok, isFalse);
    expect(
      roleFile('${_newProvider}_account_$accountDigest.json').existsSync(),
      isFalse,
    );

    receiptFile.writeAsStringSync(cleanReceipt);
    changed = false;
    setEvidenceGuardObserverForTesting((phase, _) {
      if (phase == 'after_acquire' && !changed) {
        changed = true;
        receiptFile.writeAsStringSync(jsonEncode(blockedReceipt('buckets')));
      }
    });
    recordHeadroomSample(
      _newProvider,
      80,
      fresh.asOf,
      account: accountA,
    );
    expect(
      roleFile('buckets_${_newProvider}_account_$accountDigest.json')
          .existsSync(),
      isFalse,
    );
    expect(
      providerIdMigrationIdentityChanged(
        _newProvider,
        accountA,
        tiers: const {'quota'},
      ),
      isFalse,
    );
    expect(
      providerIdMigrationIdentityChanged(
        _newProvider,
        accountA,
        tiers: const {'buckets'},
      ),
      isTrue,
    );
    setEvidenceGuardObserverForTesting(null);
    saveSnapshot(fresh);
    expect(
      roleFile('${_newProvider}_account_$accountDigest.json').existsSync(),
      isTrue,
    );
  });

  test('long account identities stay bounded and routable', () async {
    await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    setProviderIdAliasesForTesting(_aliases);
    final longAccount = List.filled(1000, 'account').join();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final freshMap = snapshot(longAccount, now, 15)
      ..['provider'] = _newProvider;
    final fresh = ProviderQuota.fromJson(freshMap);

    expect(() => saveSnapshot(fresh), returnsNormally);
    expect(loadAccountSnapshot(_newProvider, longAccount)?.ok, isTrue);
    expect(loadHistory(_newProvider, account: longAccount), isNotEmpty);
    expect(
      () => recordHeadroomSample(
        _newProvider,
        80,
        now,
        account: longAccount,
      ),
      returnsNormally,
    );
    expect(
      roleFile(
        'buckets_${_newProvider}_${accountStorageStem(longAccount)}.json',
      ).existsSync(),
      isTrue,
    );
  });

  test('released long legacy stems keep their filenames and lock domains',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final accounts = [
      for (final length in const [161, 170, 200, 220])
        List.filled(length, 'a').join(),
    ];
    for (var index = 0; index < accounts.length; index++) {
      final account = accounts[index];
      roleFile('${_oldProvider}_$account.json').writeAsStringSync(
        jsonEncode(snapshot(account, now + index, 10 + index.toDouble())),
      );
    }

    final report = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(report.state, 'complete');
    expect(report.carriedRecords, accounts.length);
    setProviderIdAliasesForTesting(_aliases);

    for (final account in accounts) {
      final digest = accountIdentityDigest(account);
      expect(
        roleFile('${_newProvider}_account_$digest.json').existsSync(),
        isTrue,
      );
      expect(roleFile('${_newProvider}_$account.json').existsSync(), isFalse);
      expect(loadAccountSnapshot(_newProvider, account)?.account, account);

      final acquired = <String>[];
      setEvidenceGuardObserverForTesting((phase, path) {
        if (phase == 'before_acquire') acquired.add(path);
      });
      withCacheEvidenceLockForTesting(
        _newProvider,
        account,
        () {},
        includeLegacy: true,
      );
      expect(
        acquired,
        contains(
          roleFile('evidence_${_oldProvider}_$account.lock').absolute.path,
        ),
      );
      expect(
        acquired,
        contains(
          roleFile('evidence_${_newProvider}_$account.lock').absolute.path,
        ),
      );
      expect(acquired.any((path) => path.contains('oversize_')), isFalse);
    }

    final canonicalBeforeConflict = <String, String>{};
    for (var index = 0; index < accounts.length; index++) {
      final account = accounts[index];
      final currentMap = snapshot(account, now + 10 + index, 30)
        ..['provider'] = _newProvider;
      final current = ProviderQuota.fromJson(currentMap);
      saveSnapshot(
        current,
        observedAtMicros: (now + 10 + index) * 1000000,
      );
      final target = roleFile(
        '${_newProvider}_account_${accountIdentityDigest(account)}.json',
      );
      canonicalBeforeConflict[account] = target.readAsStringSync();
      roleFile('${_oldProvider}_$account.json').writeAsStringSync(
        jsonEncode(snapshot(account, now + 20 + index, 60)),
      );
    }

    final conflict = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    expect(conflict.state, 'partial');
    expect(conflict.quarantinedRecords, accounts.length);
    for (final account in accounts) {
      final target = roleFile(
        '${_newProvider}_account_${accountIdentityDigest(account)}.json',
      );
      expect(target.readAsStringSync(), canonicalBeforeConflict[account]);
      expect(
        providerIdMigrationTierQuarantined(
          _newProvider,
          account,
          'quota',
        ),
        isTrue,
      );
    }
  });

  test('separate coordinators fail closed while one process owns startup',
      () async {
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final fixture = File(
      'test/fixtures/provider_id_migration_coordinator_holder.dart',
    ).absolute.path;
    final ready = File('${tempConfig.path}/coordinator.ready');
    final release = File('${tempConfig.path}/coordinator.release');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final baseline = jsonEncode(snapshot('default', now, 10));
    roleFile('$_oldProvider.json').writeAsStringSync(baseline);
    final holder = await Process.start(
      Platform.resolvedExecutable,
      [
        '--enable-asserts',
        '--packages=$packageConfig',
        fixture,
        root.path,
        _oldProvider,
        _newProvider,
        ready.path,
        release.path,
      ],
      workingDirectory: Directory.current.path,
    );
    final stdoutFuture = holder.stdout.transform(utf8.decoder).join();
    final stderrFuture = holder.stderr.transform(utf8.decoder).join();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!ready.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ready.existsSync(), isTrue);

    final blocked = await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
      limits: const ProviderIdMigrationLimits(
        maxDuration: Duration(milliseconds: 300),
        lockTimeout: Duration(milliseconds: 200),
      ),
    );
    expect(blocked.state, 'partial');
    expect(blocked.truncated, isTrue);
    expect(roleFile('$_newProvider.json').existsSync(), isFalse);

    setProviderIdAliasesForTesting(_aliases);
    final currentMap = snapshot('default', now + 1, 20)
      ..['provider'] = _newProvider;
    saveSnapshot(ProviderQuota.fromJson(currentMap));
    expect(roleFile('$_newProvider.json').existsSync(), isFalse);
    expect(
      providerIdMigrationTierQuarantined(
        _newProvider,
        'default',
        'quota',
      ),
      isTrue,
    );

    release.writeAsStringSync('release');
    final exitCode = await holder.exitCode.timeout(const Duration(seconds: 30));
    final output = await stdoutFuture;
    final errors = await stderrFuture;
    expect(exitCode, 0, reason: errors);
    expect((jsonDecode(output) as Map)['state'], 'complete');
    expect(roleFile('$_newProvider.json').readAsStringSync(), baseline);
  });

  test('cache transactions acquire retired locks before canonical locks',
      () async {
    await coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
    );
    setProviderIdAliasesForTesting(_aliases);
    final acquired = <String>[];
    setEvidenceGuardObserverForTesting((phase, path) {
      if (phase == 'before_acquire') acquired.add(path);
    });

    withCacheEvidenceLockForTesting(
      _newProvider,
      accountA,
      () {},
      includeLegacy: true,
    );

    final accountStem = accountStorageStem(accountA);
    final legacyAccount = accountA.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    expect(acquired, [
      File('${root.path}/evidence_${_oldProvider}_$legacyAccount.lock')
          .absolute
          .path,
      File('${root.path}/evidence_${_oldProvider}_$accountStem.lock')
          .absolute
          .path,
      File('${root.path}/evidence_${_newProvider}_$legacyAccount.lock')
          .absolute
          .path,
      File('${root.path}/evidence_${_newProvider}_$accountStem.lock')
          .absolute
          .path,
    ]);
  });

  test('released legacy writer excludes migration until its old lock releases',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final accountDigest = accountIdentityDigest(accountA);
    roleFile('${_oldProvider}_account_$accountDigest.json')
        .writeAsStringSync(jsonEncode(snapshot(accountA, now, 10)));
    final release = File('${tempConfig.path}/release-legacy-writer');
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final fixture =
        File('test/fixtures/provider_id_legacy_lock_holder.dart').absolute.path;
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--enable-asserts',
        '--packages=$packageConfig',
        fixture,
        root.path,
        _oldProvider,
        'account_$accountDigest',
        release.path,
      ],
      workingDirectory: Directory.current.path,
    );
    addTearDown(() {
      try {
        if (!release.existsSync()) release.writeAsStringSync('release');
      } catch (_) {}
      process.kill();
    });
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final locked = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 30));
    expect(locked, 'locked');

    final migration = coordinateProviderIdCacheMigration(
      aliases: _aliases,
      root: root,
      limits: const ProviderIdMigrationLimits(
        maxDuration: Duration(seconds: 30),
        lockTimeout: Duration(seconds: 30),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      roleFile('${_newProvider}_account_$accountDigest.json').existsSync(),
      isFalse,
    );
    release.writeAsStringSync('release');

    final report = await migration;
    expect(report.state, 'complete');
    expect(await process.exitCode, 0, reason: await stderrFuture);
    expect(
      roleFile('${_newProvider}_account_$accountDigest.json').existsSync(),
      isTrue,
    );
  });
}
