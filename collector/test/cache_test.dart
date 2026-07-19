import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:quotabot_collector/storage_keys.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

ProviderQuota? _plainSnapshot(String provider) => loadSnapshot(provider);

ProviderQuota? _plainSnapshotForAdmission(String provider) =>
    loadSnapshotForAdmission(provider);

void main() {
  const id = codexProviderId;
  late Directory tempConfig;

  ProviderQuota? loadSnapshot(String provider) => provider == id
      ? loadAccountSnapshot(provider, 'acct')
      : _plainSnapshot(provider);
  ProviderQuota? loadSnapshotForAdmission(String provider) => provider == id
      ? loadAccountSnapshotForAdmission(provider, 'acct')
      : _plainSnapshotForAdmission(provider);
  File accountCacheFile([String account = 'acct']) => File(
        '${cacheDir().path}/${id}_${accountStorageStem(account)}.json',
      );
  String accountLockPath([String account = 'acct']) =>
      '${cacheDir().path}/evidence_${id}_${accountStorageStem(account)}.lock';

  setUp(() {
    tempConfig = Directory.systemTemp.createTempSync('quotabot_cache_test_');
    setQuotabotDirOverrideForTesting(tempConfig);
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    if (tempConfig.existsSync()) tempConfig.deleteSync(recursive: true);
  });

  test('saveSnapshot then loadSnapshot round-trips', () {
    final now = nowEpoch();
    final reset = now + 3600;
    final q = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: '5h', usedPercent: 33, resetsAt: reset)],
      modelQuotas: [
        ModelQuota(
          model: 'GPT-5.3-Codex-Spark',
          usedPercent: 20,
          resetsAt: reset,
          windowLabel: 'weekly',
        ),
      ],
    );
    saveSnapshot(q);

    final back = loadSnapshot(id);
    expect(back, isNotNull);
    expect(back!.provider, id);
    expect(back.windows.single.usedPercent, 33);
    expect(back.windows.single.resetsAt, reset);
    expect(back.modelQuotas.single.windowLabel, 'weekly');
  });

  test('reset credits are fresh-read only and never return from cache', () {
    final q = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 33)],
      resetCreditsAvailable: 2,
    );
    saveSnapshot(q);
    // The cached snapshot must not resurrect the redeemable-reset count, which
    // would assert a reset from stale evidence against the field's contract.
    expect(loadSnapshot(id)!.resetCreditsAvailable, 0);
  });

  test('untrusted snapshots cannot replace last-known-good cache', () {
    final trusted = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 40)],
    );
    saveSnapshot(trusted);

    saveSnapshot(trusted.asStale('adapter fallback'));
    saveSnapshot(trusted.withSuspect('legacy drift concern'));

    final back = loadSnapshot(id);
    expect(back, isNotNull);
    expect(back!.asOf, trusted.asOf);
    expect(back.windows.single.usedPercent, 40);
    expect(back.stale, isFalse);
    expect(back.suspect, isNull);
  });

  test('Claude credential generations isolate cache and drift evidence', () {
    final now = nowEpoch();
    final accountA = opaqueCredentialIdentity('claude', 'grant-a');
    final accountB = opaqueCredentialIdentity('claude', 'grant-b');
    ProviderQuota quota(String account, double used) => ProviderQuota(
          provider: claudeProviderId,
          displayName: claudeProviderName,
          account: account,
          plan: 'max',
          asOf: now,
          windows: [
            QuotaWindow(
              label: 'weekly',
              usedPercent: used,
              resetsAt: now + 3600,
            ),
          ],
        );
    final first = quota(accountA, 20);
    final replacement = quota(accountB, 70);

    saveSnapshot(first);
    saveSnapshot(replacement);
    saveProviderDriftObservation(
      first,
      'simulated first-generation drift',
      now,
    );

    expect(loadSnapshot(claudeProviderId), isNull);
    expect(
      loadAccountSnapshot(claudeProviderId, accountA)
          ?.windows
          .single
          .usedPercent,
      20,
    );
    expect(
      loadAccountSnapshot(claudeProviderId, accountB)
          ?.windows
          .single
          .usedPercent,
      70,
    );
    expect(
      attachProviderDriftObservation(first, now: now).driftReason,
      contains('first-generation'),
    );
    expect(
      attachProviderDriftObservation(replacement, now: now).driftReason,
      isNull,
    );

    final fallbacks = currentAccountFallbacks(
      liveResults: const [],
      cachedSnapshots: [first, replacement],
      currentAccounts: {accountB},
    );
    expect(fallbacks.map((quota) => quota.account), [accountB]);
    expect(fallbacks.single.windows.single.usedPercent, 70);
  });

  test('cached invalid percents are rejected instead of normalized', () {
    final file = accountCacheFile();
    final now = nowEpoch();
    for (final invalid in const [-25, 125]) {
      final json = ProviderQuota(
        provider: id,
        displayName: 'Claude',
        account: 'acct',
        plan: 'max',
        asOf: now,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: invalid.toDouble(),
            resetsAt: now + 3600,
          ),
        ],
      ).toJson();
      file.writeAsStringSync(jsonEncode(json));

      expect(loadSnapshot(id), isNull, reason: 'invalid percent $invalid');
      expect(
        loadCachedSnapshots(now: now).where((quota) => quota.provider == id),
        isEmpty,
      );
    }
  });

  test('cached invalid Fable percent cannot become full model headroom', () {
    final file = accountCacheFile();
    final now = nowEpoch();
    final json = ProviderQuota(
      provider: id,
      displayName: 'Claude',
      account: 'acct',
      plan: 'max',
      asOf: now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 30,
          resetsAt: now + 3600,
        ),
      ],
      modelQuotas: [
        ModelQuota(
          model: 'Fable',
          usedPercent: -25,
          resetsAt: now + 3600,
        ),
      ],
    ).toJson();
    file.writeAsStringSync(jsonEncode(json));

    expect(loadSnapshot(id), isNull);
    expect(loadCachedSnapshots(now: now), isEmpty);
  });

  test('cached invalid model window labels cannot reach routing', () {
    final file = accountCacheFile();
    final now = nowEpoch();
    final labels = [
      '',
      ' weekly',
      'week\u001b[31mly',
      List.filled(kMaxModelQuotaWindowLabelCharacters + 1, 'w').join(),
    ];

    for (final label in labels) {
      final json = ProviderQuota(
        provider: id,
        displayName: 'Codex',
        account: 'acct',
        plan: 'pro',
        asOf: now,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 30,
            resetsAt: now + 3600,
          ),
        ],
        modelQuotas: [
          ModelQuota(
            model: 'GPT-5.3-Codex-Spark',
            usedPercent: 20,
            resetsAt: now + 3600,
            windowLabel: label,
          ),
        ],
      ).toJson();
      file.writeAsStringSync(jsonEncode(json));

      expect(loadSnapshot(id), isNull, reason: label);
    }
  });

  test('live passed reset is quarantined until the provider advances it', () {
    final observedAt = nowEpoch();
    final rejected = admitAndCacheQuotaEvidence(
      ProviderQuota(
        provider: id,
        displayName: 'Claude',
        account: 'acct',
        plan: 'max',
        asOf: observedAt,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 100,
            resetsAt: observedAt - 1,
          ),
        ],
      ),
      observedAt: observedAt,
      observedAtMicros: DateTime.now().microsecondsSinceEpoch,
    );

    expect(rejected.ok, isFalse);
    expect(rejected.stale, isTrue);
    expect(rejected.windows, isEmpty);
    expect(rejected.driftReason, contains('new quota window'));
    expect(providerAvailability(rejected, observedAt).available, isFalse);
    expect(loadSnapshot(id), isNull);
  });

  test('passed reset preserves an expired trusted baseline as last observed',
      () {
    final capturedAt = nowEpoch();
    final reset = capturedAt + 60;
    final baseline = ProviderQuota(
      provider: id,
      displayName: 'Claude',
      account: 'acct',
      plan: 'max',
      asOf: capturedAt,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 72,
          resetsAt: reset,
        ),
      ],
    );
    saveSnapshot(baseline);

    final observedAt = reset + 1;
    final rejected = admitAndCacheQuotaEvidence(
      ProviderQuota(
        provider: id,
        displayName: 'Claude',
        account: 'acct',
        plan: 'max',
        asOf: observedAt,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 0,
            resetsAt: reset,
          ),
        ],
      ),
      observedAt: observedAt,
      observedAtMicros: DateTime.now().microsecondsSinceEpoch + 1,
    );

    expect(rejected.ok, isTrue);
    expect(rejected.stale, isTrue);
    expect(rejected.windows.single.usedPercent, 72);
    expect(rejected.windows.single.resetsAt, reset);
    expect(rejected.driftReason, contains('new quota window'));
    expect(providerHeadroom(rejected, observedAt), 28);
    expect(providerAvailability(rejected, observedAt).available, isFalse);
    expect(loadSnapshot(id)!.windows.single.usedPercent, 72);
  });

  test('implausibly distant shared reset is quarantined', () {
    final observedAt = nowEpoch();
    final rejected = admitAndCacheQuotaEvidence(
      ProviderQuota(
        provider: id,
        displayName: 'Claude',
        account: 'acct',
        plan: 'max',
        asOf: observedAt,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 30,
            resetsAt: observedAt + 401 * 86400,
          ),
        ],
      ),
      observedAt: observedAt,
      observedAtMicros: DateTime.now().microsecondsSinceEpoch,
    );

    expect(rejected.ok, isFalse);
    expect(rejected.stale, isTrue);
    expect(rejected.windows, isEmpty);
    expect(rejected.driftReason, contains('implausibly far'));
    expect(providerAvailability(rejected, observedAt).available, isFalse);
    expect(loadSnapshot(id), isNull);
  });

  test('new provider observation with a future reset remains routable', () {
    final observedAt = nowEpoch();
    final admitted = admitAndCacheQuotaEvidence(
      ProviderQuota(
        provider: id,
        displayName: 'Claude',
        account: 'acct',
        plan: 'max',
        asOf: observedAt,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 30,
            resetsAt: observedAt + 3600,
          ),
        ],
      ),
      observedAt: observedAt,
      observedAtMicros: DateTime.now().microsecondsSinceEpoch,
    );

    expect(admitted.ok, isTrue);
    expect(admitted.stale, isFalse);
    expect(providerAvailability(admitted, observedAt).available, isTrue);
    expect(providerHeadroom(admitted, observedAt), 70);
    expect(loadSnapshot(id), isNotNull);
  });

  test('drift diagnostics persist separately and clear on recovery', () {
    final trusted = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 60)],
    );
    saveSnapshot(
      trusted,
      observedAtMicros: 1782000000000100,
    );
    saveProviderDriftObservation(
      trusted,
      '5h usage fell 60% to 10% with no reset',
      1782000100,
      observedAtMicros: 1782000100000200,
    );

    final raw = loadSnapshot(id)!;
    expect(raw.stale, isFalse);
    expect(raw.driftReason, isNull);
    final routed = loadCachedSnapshots(now: 1782000200)
        .singleWhere((quota) => quota.provider == id);
    expect(routed.stale, isTrue);
    expect(routed.windows.single.usedPercent, 60);
    expect(routed.driftReason, contains('usage fell'));
    expect(routed.driftObservedAt, 1782000100);

    saveProviderDriftObservation(
      trusted,
      '\x1b[31m${List.filled(600, 'x').join()}',
      1782000150,
      observedAtMicros: 1782000150000300,
    );
    final bounded = loadCachedSnapshots(now: 1782000200)
        .singleWhere((quota) => quota.provider == id)
        .driftReason!;
    expect(bounded, isNot(contains('\x1b')));
    expect(bounded.length, lessThanOrEqualTo(512));

    final olderCleanWriter = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000150,
      windows: [QuotaWindow(label: '5h', usedPercent: 64)],
    );
    saveSnapshot(
      olderCleanWriter,
      observedAtMicros: 1782000120000250,
    );
    expect(
      attachProviderDriftObservation(
        loadSnapshot(id)!,
        now: 1782000200,
      ).driftReason,
      isNotNull,
      reason: 'an older clean writer cannot erase a newer drift observation',
    );

    final recovered = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000300,
      windows: [QuotaWindow(label: '5h', usedPercent: 65)],
    );
    saveSnapshot(
      recovered,
      observedAtMicros: 1782000300000400,
    );
    saveProviderDriftObservation(
      trusted,
      'late write from an older drift observation',
      1782000150,
      observedAtMicros: 1782000150000300,
    );
    final afterRecovery = loadCachedSnapshots(now: 1782000400)
        .singleWhere((quota) => quota.provider == id);
    expect(afterRecovery.stale, isFalse);
    expect(afterRecovery.driftReason, isNull);
    expect(afterRecovery.asOf, 1782000300);
  });

  test('same-second drift is ordered by local observation generation', () {
    final trusted = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 60)],
    );
    saveSnapshot(
      trusted,
      observedAtMicros: 1782000000000100,
    );
    saveProviderDriftObservation(
      trusted,
      'same-second provider drift',
      1782000000,
      observedAtMicros: 1782000000000200,
    );

    final visible = attachProviderDriftObservation(
      loadSnapshot(id)!,
      now: 1782000001,
    );
    expect(visible.driftReason, 'same-second provider drift');
  });

  test('older cache and drift writers cannot overwrite newer generations', () {
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: id,
          displayName: 'Test',
          account: 'acct',
          asOf: asOf,
          windows: [QuotaWindow(label: '5h', usedPercent: used)],
        );
    final baseline = quota(40, 1782000000);
    saveSnapshot(baseline, observedAtMicros: 1782000000000100);
    final newer = quota(55, 1782000100);
    saveSnapshot(newer, observedAtMicros: 1782000100000400);
    saveSnapshot(quota(45, 1782000050), observedAtMicros: 1782000050000200);
    saveSnapshot(quota(42, 1782000040), observedAtMicros: 1782000200000500);
    expect(loadSnapshot(id)!.windows.single.usedPercent, 55);

    saveProviderDriftObservation(
      newer,
      'newer drift',
      1782000200,
      observedAtMicros: 1782000200000600,
    );
    saveProviderDriftObservation(
      newer,
      'older drift',
      1782000150,
      observedAtMicros: 1782000150000500,
    );
    final visible = attachProviderDriftObservation(
      loadSnapshot(id)!,
      now: 1782000300,
    );
    expect(visible.driftReason, 'newer drift');
    expect(visible.driftObservedAt, 1782000200);
  });

  test('atomic admission returns newer evidence to a stalled older reader', () {
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: id,
          displayName: 'Test',
          account: 'acct',
          asOf: asOf,
          windows: [
            QuotaWindow(
              label: '5h',
              usedPercent: used,
              resetsAt: 1782010000,
            ),
          ],
        );
    saveSnapshot(
      quota(40, 1782000000),
      observedAtMicros: 1782000000000100,
    );
    final newest = admitAndCacheQuotaEvidence(
      quota(60, 1782000200),
      observedAt: 1782000200,
      observedAtMicros: 1782000200000300,
    );
    final stalled = admitAndCacheQuotaEvidence(
      quota(50, 1782000100),
      observedAt: 1782000300,
      observedAtMicros: 1782000300000400,
    );

    expect(newest.windows.single.usedPercent, 60);
    expect(stalled.windows.single.usedPercent, 60);
    expect(loadSnapshot(id)!.windows.single.usedPercent, 60);
  });

  test('live admission rejects noncanonical cache baselines', () {
    final file = accountCacheFile();
    ProviderQuota quota({
      String provider = id,
      String account = 'acct',
      int asOf = 1782000000,
      double used = 40,
    }) =>
        ProviderQuota(
          provider: provider,
          displayName: 'Test',
          account: account,
          asOf: asOf,
          windows: [QuotaWindow(label: '5h', usedPercent: used)],
        );

    ProviderQuota admitFresh() => admitAndCacheQuotaEvidence(
          quota(asOf: 1782000100, used: 60),
          observedAt: 1782000100,
          observedAtMicros: 1782000100000200,
        );

    file.writeAsStringSync(jsonEncode(quota(provider: 'forged').toJson()));
    expect(loadSnapshot(id), isNull);
    expect(admitFresh().windows.single.usedPercent, 60);

    file.writeAsStringSync(jsonEncode(quota(asOf: -1).toJson()));
    expect(loadSnapshot(id), isNull);
    expect(admitFresh().windows.single.usedPercent, 60);

    final futureAsOf = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;
    file.writeAsStringSync(
        jsonEncode(quota(asOf: futureAsOf, used: 10).toJson()));
    expect(loadSnapshot(id), isNull);
    expect(admitFresh().windows.single.usedPercent, 60);

    final forgedGeneration = quota().toJson()
      ..['cache_observed_at_micros'] =
          DateTime.now().add(const Duration(days: 365)).microsecondsSinceEpoch;
    file.writeAsStringSync(jsonEncode(forgedGeneration));
    expect(admitFresh().windows.single.usedPercent, 60);
    expect(loadSnapshot(id)!.windows.single.usedPercent, 60);

    final staleUntrusted = quota().asStale('old fallback').toJson()
      ..['cache_observed_at_micros'] = 1782000200000300;
    file.writeAsStringSync(jsonEncode(staleUntrusted));
    expect(admitFresh().windows.single.usedPercent, 60);
    expect(
      loadSnapshot(id)!.windows.single.usedPercent,
      60,
      reason: 'an untrusted cache generation cannot bypass persistence',
    );
  });

  test('non-positive fresh timestamps are quarantined without persistence', () {
    const observedAt = 1782000100;
    for (final invalidAsOf in [-1, 0]) {
      final rejected = admitAndCacheQuotaEvidence(
        ProviderQuota(
          provider: id,
          displayName: 'Test',
          account: 'acct',
          asOf: invalidAsOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
        ),
        observedAt: observedAt,
        observedAtMicros: 1782000100000200 + invalidAsOf + 1,
      );

      expect(rejected.ok, isFalse);
      expect(rejected.stale, isTrue);
      expect(rejected.windows, isEmpty);
      expect(rejected.asOf, observedAt);
      expect(rejected.driftReason, contains('non-positive'));
      expect(providerAvailability(rejected, observedAt).available, isFalse);
      expect(suggestRoute([rejected], observedAt).recommended, isNull);
    }
    expect(loadSnapshot(id), isNull);
    expect(
      loadCachedSnapshots(now: observedAt)
          .where((quota) => quota.provider == id),
      isEmpty,
    );
  });

  test('future fresh timestamp preserves only trusted cached evidence', () {
    const observedAt = 1782000100;
    final trusted = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
    );
    saveSnapshot(trusted, observedAtMicros: 1782000000000100);

    final rejected = admitAndCacheQuotaEvidence(
      ProviderQuota(
        provider: id,
        displayName: 'Test',
        account: 'acct',
        asOf: observedAt + kQuotaEvidenceClockSkewSeconds + 1,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
      ),
      observedAt: observedAt,
      observedAtMicros: 1782000100000200,
    );

    expect(rejected.ok, isTrue);
    expect(rejected.stale, isTrue);
    expect(rejected.asOf, trusted.asOf);
    expect(rejected.windows.single.usedPercent, 40);
    expect(rejected.driftReason, contains('future'));
    expect(providerAvailability(rejected, observedAt).available, isFalse);
    expect(suggestRoute([rejected], observedAt).recommended, isNull);
    expect(loadSnapshot(id)?.windows.single.usedPercent, 40);
    expect(
      loadHistory(id).any(
        (quota) => quota.asOf > observedAt + kQuotaEvidenceClockSkewSeconds,
      ),
      isFalse,
    );
    final persisted = loadCachedSnapshots(now: observedAt)
        .singleWhere((quota) => quota.provider == id);
    expect(persisted.windows.single.usedPercent, 40);
    expect(persisted.driftReason, contains('future'));
  });

  test('account-scoped admission rejects a mismatched cached account', () {
    final file = File('${cacheDir().path}/grok_test-account.json');
    final forged = ProviderQuota(
      provider: 'grok',
      displayName: 'Grok',
      account: 'different-account',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'monthly', usedPercent: 10)],
    );
    file.writeAsStringSync(jsonEncode(forged.toJson()));
    expect(loadGrokSnapshot('test-account'), isNull);

    final admitted = admitAndCacheQuotaEvidence(
      ProviderQuota(
        provider: 'grok',
        displayName: 'Grok',
        account: 'test-account',
        asOf: 1782000100,
        windows: [QuotaWindow(label: 'monthly', usedPercent: 60)],
      ),
      observedAt: 1782000100,
      observedAtMicros: 1782000100000200,
    );

    expect(admitted.account, 'test-account');
    expect(admitted.windows.single.usedPercent, 60);
    expect(loadGrokSnapshot('test-account')?.account, 'test-account');
  });

  test('Codex replacement account cannot reuse or drift-compare prior cache',
      () {
    final now = nowEpoch();
    final accountA = opaqueCredentialIdentity(id, 'account-a');
    final accountB = opaqueCredentialIdentity(id, 'account-b');
    ProviderQuota quota(String account, double used, int asOf) => ProviderQuota(
          provider: id,
          displayName: 'Codex',
          account: account,
          plan: 'pro',
          asOf: asOf,
          windows: [
            QuotaWindow(
              label: '5h',
              usedPercent: used,
              resetsAt: now + 3600,
            ),
          ],
        );

    final first = admitAndCacheQuotaEvidence(
      quota(accountA, 80, now - 10),
      observedAt: now - 10,
      observedAtMicros: (now - 10) * Duration.microsecondsPerSecond,
    );
    final replacement = admitAndCacheQuotaEvidence(
      quota(accountB, 5, now),
      observedAt: now,
      observedAtMicros: now * Duration.microsecondsPerSecond,
    );

    expect(first.driftReason, isNull);
    expect(replacement.driftReason, isNull);
    expect(replacement.stale, isFalse);
    expect(loadAccountSnapshot(id, accountA)?.account, accountA);
    expect(loadAccountSnapshot(id, accountB)?.account, accountB);
    expect(loadAccountSnapshots(id).map((quota) => quota.account).toSet(), {
      accountA,
      accountB,
    });
    expect(
      currentAccountFallbacks(
        liveResults: [replacement],
        cachedSnapshots: loadAccountSnapshots(id),
        currentAccounts: {accountB},
      ),
      isEmpty,
    );
  });

  test('lock failure never exposes fresh quota as routable evidence', () {
    ProviderQuota quota(double used) => ProviderQuota(
          provider: id,
          displayName: 'Test',
          account: 'acct',
          asOf: 1782000000 + used.round(),
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    final lockPath = accountLockPath();
    final lockFile = File(lockPath);
    final lockDirectory = Directory(lockPath);
    void forceLockFailure() {
      if (lockFile.existsSync()) lockFile.deleteSync();
      if (!lockDirectory.existsSync()) lockDirectory.createSync();
    }

    addTearDown(() {
      if (lockDirectory.existsSync()) lockDirectory.deleteSync();
    });

    final trusted = quota(40);
    saveSnapshot(trusted, observedAtMicros: 1782000040000100);
    forceLockFailure();
    final fallback = admitAndCacheQuotaEvidence(
      quota(60),
      observedAt: 1782000060,
      observedAtMicros: 1782000060000200,
    );
    expect(fallback.ok, isTrue);
    expect(fallback.stale, isTrue);
    expect(fallback.windows.single.usedPercent, 40);
    expect(fallback.error, contains('admission unavailable'));
    expect(isTrustedQuotaEvidence(fallback), isFalse);

    lockDirectory.deleteSync();
    accountCacheFile().deleteSync();
    forceLockFailure();
    final unavailable = admitAndCacheQuotaEvidence(
      quota(70),
      observedAt: 1782000070,
      observedAtMicros: 1782000070000300,
    );
    expect(unavailable.ok, isFalse);
    expect(unavailable.stale, isTrue);
    expect(unavailable.windows, isEmpty);
    expect(unavailable.error, contains('admission unavailable'));
  });

  test('lock failure preserves legacy evidence quarantine', () {
    final legacy = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
    ).withSuspect('legacy drift concern');
    accountCacheFile().writeAsStringSync(jsonEncode(legacy.toJson()));
    final lockPath = accountLockPath();
    final lockFile = File(lockPath);
    if (lockFile.existsSync()) lockFile.deleteSync();
    final lockDirectory = Directory(lockPath)..createSync();
    addTearDown(() {
      if (lockDirectory.existsSync()) lockDirectory.deleteSync();
    });

    final result = admitAndCacheQuotaEvidence(
      ProviderQuota(
        provider: id,
        displayName: 'Test',
        account: 'acct',
        asOf: 1782000100,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 50)],
      ),
      observedAt: 1782000100,
      observedAtMicros: 1782000100000200,
    );

    expect(result.ok, isFalse);
    expect(result.windows, isEmpty);
    expect(result.driftReason, contains('unresolved legacy'));
  });

  test('collection-start generation defeats a stalled Grok re-rating read', () {
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: 'grok',
          displayName: 'Grok',
          account: 'test-account',
          asOf: asOf,
          windows: [
            QuotaWindow(
              label: 'monthly',
              usedPercent: used,
              resetsAt: 1782010000,
            ),
          ],
        );
    saveSnapshot(
      quota(40, 1782000000),
      observedAtMicros: 1782000000000100,
    );

    final laterStarted = admitAndCacheQuotaEvidence(
      quota(60, 1782000200),
      observedAt: 1782000200,
      observedAtMicros: 1782000200000300,
    );
    final earlierStartedButStalled = admitAndCacheQuotaEvidence(
      quota(10, 1782000300),
      observedAt: 1782000300,
      observedAtMicros: 1782000100000200,
    );

    expect(laterStarted.windows.single.usedPercent, 60);
    expect(earlierStartedButStalled.windows.single.usedPercent, 60);
    expect(
      loadGrokSnapshot('test-account')!.windows.single.usedPercent,
      60,
      reason: 'Grok re-rating permits a usage drop, so generation ordering '
          'must reject the stalled observation before drift comparison',
    );
  });

  test('unusable successful evidence persists and returns provider drift', () {
    final trusted = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
    );
    saveSnapshot(
      trusted,
      observedAtMicros: 1782000000000100,
    );
    final unusable = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000100,
      windows: [
        QuotaWindow(
          label: '\x1b[31m${List.filled(700, 'x').join()}',
        ),
      ],
    );

    final rejected = admitAndCacheQuotaEvidence(
      unusable,
      observedAt: 1782000100,
      observedAtMicros: 1782000100000200,
    );

    expect(rejected.stale, isTrue);
    expect(rejected.windows.single.usedPercent, 40);
    expect(rejected.driftReason, contains('no usable percent'));
    expect(rejected.driftReason, isNot(contains('\x1b')));
    expect(
      rejected.driftReason!.length,
      lessThanOrEqualTo(kMaxQuotaDriftReasonCharacters),
    );
    final persisted = loadCachedSnapshots(now: 1782000200)
        .singleWhere((quota) => quota.provider == id);
    expect(persisted.driftReason, rejected.driftReason);
    expect(loadSnapshot(id)!.windows.single.usedPercent, 40);
  });

  test('forced admission rejection preserves cache and persists diagnostic',
      () {
    final trusted = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
    );
    saveSnapshot(
      trusted,
      observedAtMicros: 1782000000000100,
    );
    final invalidFresh = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000100,
      sourceClass: ProviderSourceClass.passiveLocalEvidence,
      perMachine: true,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 45)],
    );

    final rejected = admitAndCacheQuotaEvidence(
      invalidFresh,
      observedAt: 1782000100,
      observedAtMicros: 1782000100000200,
      rejectionReason:
          'invalid provider source class: passive local is not admitted',
    );

    expect(rejected.stale, isTrue);
    expect(rejected.sourceClass, ProviderSourceClass.authoritativeLive);
    expect(rejected.windows.single.usedPercent, 40);
    expect(rejected.driftReason, contains('invalid provider source class'));
    final persisted = loadCachedSnapshots(now: 1782000200)
        .singleWhere((quota) => quota.provider == id);
    expect(persisted.driftReason, rejected.driftReason);
    expect(loadSnapshot(id)!.windows.single.usedPercent, 40);
  });

  test('unusable successful evidence without a baseline is quarantined', () {
    final unusable = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000100,
      windows: [QuotaWindow(label: 'weekly')],
    );

    final rejected = admitAndCacheQuotaEvidence(
      unusable,
      observedAt: 1782000100,
      observedAtMicros: 1782000100000200,
    );

    expect(rejected.ok, isFalse);
    expect(rejected.stale, isTrue);
    expect(rejected.windows, isEmpty);
    expect(rejected.driftReason, contains('no usable percent'));
    expect(rejected.error, contains('no trusted snapshot'));
    expect(loadSnapshot(id), isNull);
  });

  test('legacy stale and suspect cache and history rows are quarantined', () {
    final trustedShape = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 5)],
    );
    final file = accountCacheFile();
    file.writeAsStringSync(jsonEncode(trustedShape.asStale('legacy').toJson()));
    expect(loadSnapshot(id), isNull);
    expect(
      loadCachedSnapshots(now: 1782000100)
          .where((quota) => quota.provider == id),
      isEmpty,
    );

    final suspect = trustedShape.withSuspect('legacy drift concern');
    file.writeAsStringSync(jsonEncode(suspect.toJson()));
    expect(loadSnapshot(id), isNull);
    expect(loadSnapshotForAdmission(id)?.suspect, 'legacy drift concern');
    final quarantine = loadCachedSnapshots(now: 1782000100)
        .singleWhere((quota) => quota.provider == id);
    expect(quarantine.ok, isFalse);
    expect(quarantine.windows, isEmpty);
    expect(quarantine.driftReason, contains('unresolved legacy'));
    expect(quarantine.driftObservedAt, 1782000100);
    File('${cacheDir().path}/history_$id.jsonl')
        .writeAsStringSync('${jsonEncode(suspect.toJson())}\n');
    expect(loadHistory(id), isEmpty);
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
    final hist = loadHistory(id, account: 'acct');
    expect(hist.length, greaterThanOrEqualTo(1));
  });

  test('history retains a sample that was valid before its reset', () {
    final now = nowEpoch();
    final sample = ProviderQuota(
      provider: id,
      displayName: 'Claude',
      account: 'acct',
      plan: 'max',
      asOf: now - 7200,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 65,
          resetsAt: now - 3600,
        ),
      ],
    );
    File('${cacheDir().path}/history_$id.jsonl')
        .writeAsStringSync('${jsonEncode(sample.toJson())}\n');

    final history = loadHistory(id);

    expect(history, hasLength(1));
    expect(history.single.windows.single.usedPercent, 65);
    expect(isTrustedQuotaEvidenceAtCapture(history.single), isTrue);
    expect(isTrustedQuotaEvidenceAt(history.single, now), isFalse);
    expect(providerHeadroom(history.single, now), 35);
    expect(providerAvailability(history.single, now).available, isFalse);
  });

  test('loadSnapshot returns null for an unknown provider', () {
    expect(loadSnapshot('__nope_does_not_exist__'), isNull);
  });

  test('sweepStaleTempFiles deletes old atomic-write leftovers', () {
    final stale = File('${cacheDir().path}/old-cache-write.tmp')
      ..writeAsStringSync('stale');
    final fresh = File('${cacheDir().path}/fresh-cache-write.tmp')
      ..writeAsStringSync('fresh');
    stale.setLastModifiedSync(
      DateTime.now().subtract(const Duration(minutes: 10)),
    );
    fresh.setLastModifiedSync(DateTime.now());
    addTearDown(() {
      if (stale.existsSync()) stale.deleteSync();
      if (fresh.existsSync()) fresh.deleteSync();
    });

    sweepStaleTempFiles();

    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('loadCachedSnapshots scans last-known provider files only', () {
    final q = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782000000,
      windows: [QuotaWindow(label: '5h', usedPercent: 25)],
    );
    saveSnapshot(q);
    recordHeadroomSample(id, 75, 1782000000);

    final cached = loadCachedSnapshots()
        .where((provider) => provider.provider == id)
        .toList();
    expect(cached, hasLength(1));
    expect(cached.single.account, 'acct');
    expect(cached.single.windows.single.usedPercent, 25);
  });

  test('loadCachedSnapshots rejects noncanonical and future cache entries', () {
    final forged = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: 'forged',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 0)],
    );
    File('${cacheDir().path}/rogue-cache-entry.json')
        .writeAsStringSync(jsonEncode(forged.toJson()));

    final future = ProviderQuota(
      provider: id,
      displayName: 'Test',
      account: 'acct',
      asOf: 1782003601,
      windows: [QuotaWindow(label: '5h', usedPercent: 1)],
    );
    accountCacheFile().writeAsStringSync(jsonEncode(future.toJson()));

    final cached = loadCachedSnapshots(now: 1782000000);
    expect(
      cached.any((provider) =>
          provider.provider == 'claude' && provider.account == 'forged'),
      isFalse,
    );
    expect(cached.any((provider) => provider.provider == id), isFalse);

    accountCacheFile().writeAsStringSync(
      jsonEncode(
        ProviderQuota(
          provider: id,
          displayName: 'Test',
          account: 'acct',
          asOf: -1,
          windows: [QuotaWindow(label: '5h', usedPercent: 1)],
        ).toJson(),
      ),
    );
    expect(
      loadCachedSnapshots(now: 1782000000)
          .any((provider) => provider.provider == id),
      isFalse,
    );
  });

  test('loadCachedSnapshots rejects unknown provider kind cache entries', () {
    final q = ProviderQuota(
      provider: 'future-kind',
      displayName: 'Future Kind',
      account: 'default',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 5)],
    ).toJson()
      ..['kind'] = 'future-kind';
    File('${cacheDir().path}/future-kind.json').writeAsStringSync(
      jsonEncode(q),
    );

    final cached = loadCachedSnapshots(now: 1782000000);

    expect(
        cached.any((provider) => provider.provider == 'future-kind'), isFalse);
    expect(loadSnapshot('future-kind'), isNull);
  });

  test('loadCachedSnapshots rejects unknown source-class cache entries', () {
    final q = ProviderQuota(
      provider: 'future-source',
      displayName: 'Future Source',
      account: 'default',
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 5)],
    ).toJson()
      ..['source_class'] = 'future_class';
    File('${cacheDir().path}/future-source.json').writeAsStringSync(
      jsonEncode(q),
    );

    final cached = loadCachedSnapshots(now: 1782000000);

    expect(cached.any((provider) => provider.provider == 'future-source'),
        isFalse);
    expect(loadSnapshot('future-source'), isNull);
  });

  test('loadCachedSnapshots rejects unclassified legacy custom providers', () {
    const provider = 'legacy-unregistered';
    File('${cacheDir().path}/$provider.json').writeAsStringSync(jsonEncode({
      'provider': provider,
      'display_name': 'Legacy unregistered',
      'account': 'default',
      'kind': providerQuotaSubscriptionKind,
      'ok': true,
      'as_of': 1782000000,
      'windows': [
        {'label': 'weekly', 'used_percent': 5},
      ],
    }));

    final cached = loadCachedSnapshots(now: 1782000100);

    expect(cached.any((quota) => quota.provider == provider), isFalse);
  });

  test('loadCachedSnapshots rejects registered-looking custom providers', () {
    const provider = 'explicit-unregistered';
    final forged = ProviderQuota(
      provider: provider,
      displayName: 'Explicit unregistered',
      account: 'default',
      sourceClass: ProviderSourceClass.authoritativeLive,
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 5)],
    );
    File('${cacheDir().path}/$provider.json')
        .writeAsStringSync(jsonEncode(forged.toJson()));
    File('${cacheDir().path}/history_$provider.jsonl')
        .writeAsStringSync('${jsonEncode(forged.toJson())}\n');

    final cached = loadCachedSnapshots(now: 1782000100);

    expect(cached.any((quota) => quota.provider == provider), isFalse);
    expect(loadSnapshot(provider), isNull);
    expect(loadHistory(provider), isEmpty);
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

  test('loadBuckets drops a malformed element and keeps the rest', () {
    // Previously one stray non-object element discarded the whole file, losing
    // up to 90 days of history. Only the bad element should be dropped now.
    final good1 = HeadroomBucket(start: 3600)..add(80);
    final good2 = HeadroomBucket(start: 7200)..add(40);
    File('${cacheDir().path}/buckets_$id.json').writeAsStringSync(jsonEncode([
      good1.toJson(),
      'garbage',
      42,
      null,
      good2.toJson(),
    ]));
    final buckets = loadBuckets(id);
    expect(buckets.map((b) => b.start).toList(), [3600, 7200]);
    expect(buckets.first.count, 1);
  });

  test('recentBurnByProvider reads bucket stats by provider', () {
    final now = 1782000000;
    recordHeadroomSample(id, 80, now - 3600);
    recordHeadroomSample(id, 70, now);

    final stats = recentBurnStatsByProvider([id], now);
    expect(stats[id], isNotNull);
    expect(recentBurnByProvider([id], now)[id], stats[id]!.perHour);
  });

  test('recentBurnStatsByQuota keeps accounts separate', () {
    final now = 1782000000;
    recordHeadroomSample(id, 90, now - 3600, account: 'work');
    recordHeadroomSample(id, 70, now, account: 'work');
    recordHeadroomSample(id, 40, now - 3600, account: 'home');
    recordHeadroomSample(id, 38, now, account: 'home');

    final stats = recentBurnStatsByQuota([
      ProviderQuota(
        provider: id,
        displayName: 'Test',
        account: 'work',
        asOf: now,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 30)],
      ),
      ProviderQuota(
        provider: id,
        displayName: 'Test',
        account: 'home',
        asOf: now,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 62)],
      ),
    ], now);

    expect(stats[quotaIdentityKey(id, 'work')]?.perHour, closeTo(20, 0.001));
    expect(stats[quotaIdentityKey(id, 'home')]?.perHour, closeTo(2, 0.001));
  });

  test('colliding legacy account stems stay isolated across local evidence',
      () {
    const provider = grokProviderId;
    const plus = 'nick+work@example.com';
    const underscore = 'nick_work@example.com';
    const now = 1782000000;
    ProviderQuota quota(String account, double used) => ProviderQuota(
          provider: provider,
          displayName: 'Grok',
          account: account,
          asOf: now,
          windows: [
            QuotaWindow(label: 'monthly', usedPercent: used),
          ],
        );

    final plusQuota = quota(plus, 20);
    final underscoreQuota = quota(underscore, 70);
    saveSnapshot(plusQuota, observedAtMicros: 1782000000000100);
    saveSnapshot(underscoreQuota, observedAtMicros: 1782000000000200);
    saveProviderDriftObservation(
      plusQuota,
      'plus account drift',
      now + 10,
      observedAtMicros: 1782000010000300,
    );
    saveProviderDriftObservation(
      underscoreQuota,
      'underscore account drift',
      now + 20,
      observedAtMicros: 1782000020000400,
    );

    expect(loadAccountSnapshot(provider, plus)?.windows.single.usedPercent, 20);
    expect(
      loadAccountSnapshot(provider, underscore)?.windows.single.usedPercent,
      70,
    );
    expect(
      loadAccountSnapshots(provider).map((quota) => quota.account).toSet(),
      {plus, underscore},
    );
    expect(
      attachProviderDriftObservation(plusQuota, now: now + 30).driftReason,
      'plus account drift',
    );
    expect(
      attachProviderDriftObservation(
        underscoreQuota,
        now: now + 30,
      ).driftReason,
      'underscore account drift',
    );
    expect(
      loadHistory(provider, account: plus)
          .map((quota) => quota.account)
          .toSet(),
      {plus},
    );
    expect(
      loadHistory(provider, account: underscore)
          .map((quota) => quota.account)
          .toSet(),
      {underscore},
    );

    recordHeadroomSample(provider, 90, now - 3600, account: plus);
    recordHeadroomSample(provider, 60, now, account: plus);
    recordHeadroomSample(provider, 50, now - 3600, account: underscore);
    recordHeadroomSample(provider, 48, now, account: underscore);
    expect(
      loadBuckets(provider, account: plus, fallbackToProvider: false).last.mean,
      closeTo(60, 0.001),
    );
    expect(
      loadBuckets(provider, account: underscore, fallbackToProvider: false)
          .last
          .mean,
      closeTo(48, 0.001),
    );
    final stats = recentBurnStatsByQuota([plusQuota, underscoreQuota], now);
    expect(
      stats[quotaIdentityKey(provider, plus)]?.perHour,
      closeTo(30, 0.001),
    );
    expect(
      stats[quotaIdentityKey(provider, underscore)]?.perHour,
      closeTo(2, 0.001),
    );

    final names = cacheDir()
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList();
    for (final prefix in [
      '${provider}_account_',
      'drift_${provider}_account_',
      'history_${provider}_account_',
      'buckets_${provider}_account_',
      'evidence_${provider}_account_',
    ]) {
      expect(names.where((name) => name.startsWith(prefix)), hasLength(2));
    }
    expect(names.any((name) => name.contains('nick')), isFalse);
    expect(names.any((name) => name.contains('example.com')), isFalse);
  });

  test('legacy colliding files are read only for their exact identity', () {
    const provider = grokProviderId;
    const plus = 'nick+work@example.com';
    const underscore = 'nick_work@example.com';
    const legacyStem = 'nick_work_example.com';
    const now = 1782000000;
    ProviderQuota quota(String account, double used) => ProviderQuota(
          provider: provider,
          displayName: 'Grok',
          account: account,
          asOf: now,
          windows: [QuotaWindow(label: 'monthly', usedPercent: used)],
        );
    final plusQuota = quota(plus, 20);
    final underscoreQuota = quota(underscore, 70);
    File('${cacheDir().path}/${provider}_$legacyStem.json')
        .writeAsStringSync(jsonEncode(plusQuota.toJson()));
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$legacyStem.jsonl',
    );
    legacyHistory.writeAsStringSync(
      '${jsonEncode(plusQuota.toJson())}\n'
      '${jsonEncode(underscoreQuota.toJson())}\n',
    );

    expect(loadAccountSnapshot(provider, plus)?.account, plus);
    expect(loadAccountSnapshot(provider, underscore), isNull);
    expect(loadHistory(provider, account: plus).single.account, plus);
    expect(
        loadHistory(provider, account: underscore).single.account, underscore);

    legacyHistory.writeAsStringSync('${jsonEncode(plusQuota.toJson())}\n');
    final legacyBucket = HeadroomBucket(start: now)..add(75);
    File('${cacheDir().path}/buckets_${provider}_$legacyStem.json')
        .writeAsStringSync(jsonEncode([legacyBucket.toJson()]));
    expect(
      loadBuckets(provider, account: plus, fallbackToProvider: false),
      hasLength(1),
    );
    expect(
      loadBuckets(provider, account: underscore, fallbackToProvider: false),
      isEmpty,
    );

    recordHeadroomSample(provider, 65, now + 30, account: plus);
    File('${cacheDir().path}/${provider}_$legacyStem.json')
        .writeAsStringSync(jsonEncode(underscoreQuota.toJson()));
    legacyHistory
        .writeAsStringSync('${jsonEncode(underscoreQuota.toJson())}\n');
    expect(
      loadBuckets(provider, account: underscore, fallbackToProvider: false),
      isEmpty,
    );
    final ownerMarker = cacheDir().listSync().whereType<File>().singleWhere(
        (file) =>
            file.uri.pathSegments.last.startsWith('legacy_bucket_owner_'));
    expect(ownerMarker.uri.pathSegments.last, isNot(contains('nick')));
    expect(ownerMarker.readAsStringSync(), isNot(contains(plus)));
  });

  test('canonical and legacy snapshots coexist as one newest identity', () {
    const provider = grokProviderId;
    const account = 'nick+work@example.com';
    const legacyStem = 'nick_work_example.com';
    const now = 1782000000;
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Grok',
          account: account,
          asOf: asOf,
          windows: [QuotaWindow(label: 'monthly', usedPercent: used)],
        );
    File('${cacheDir().path}/${provider}_$legacyStem.json')
        .writeAsStringSync(jsonEncode(quota(20, now).toJson()));
    saveSnapshot(
      quota(65, now + 100),
      observedAtMicros: 1782000100000200,
    );

    final accountRows = loadAccountSnapshots(provider)
        .where((snapshot) => snapshot.account == account)
        .toList();
    expect(accountRows, hasLength(1));
    expect(accountRows.single.windows.single.usedPercent, 65);
    final cachedRows = loadCachedSnapshots(now: now + 200)
        .where((snapshot) =>
            snapshot.provider == provider && snapshot.account == account)
        .toList();
    expect(cachedRows, hasLength(1));
    expect(cachedRows.single.windows.single.usedPercent, 65);
  });

  test('recentBurnStatsByQuota honors an explicit shorter burn lookback', () {
    final now = 1782000000;
    // Flat for several hours, then a steep recent draw-down. A shorter lookback
    // sees only the steep part and reports a faster burn than the default.
    for (var h = 6; h >= 2; h--) {
      recordHeadroomSample(id, 100, now - h * 3600);
    }
    recordHeadroomSample(id, 70, now - 3600);
    recordHeadroomSample(id, 40, now);
    final q = ProviderQuota(
      provider: id,
      displayName: 'T',
      account: 'default',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 60)],
    );
    final key = quotaIdentityKey(id, 'default');
    final byDefault = recentBurnStatsByQuota([q], now)[key]!;
    final short = recentBurnStatsByQuota([q], now, lookbackHours: 2)[key]!;
    expect(byDefault.perHour, isNotNull);
    expect(short.perHour, isNotNull);
    expect(short.perHour!, greaterThan(byDefault.perHour!));
  });

  test('provider cache filenames stay inside the cache directory', () {
    final q = ProviderQuota(
      provider: '../escape',
      displayName: 'Test',
      account: 'acct',
      source: providerQuotaManualSource,
      asOf: 1,
      windows: [QuotaWindow(label: '5h', usedPercent: 10)],
    );
    saveSnapshot(q);
    recordHeadroomSample('../escape', 80, 1782000000);

    expect(loadSnapshot('../escape'), isNotNull);
    expect(loadHistory('../escape', account: 'acct'), isNotEmpty);
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
    const ap = grokProviderId;

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
      for (final n in ['drift_${ap}_work.json', 'drift_${ap}_home.json']) {
        final f = File('${cacheDir().path}/$n');
        if (f.existsSync()) f.deleteSync();
      }
      for (final n in [
        'evidence_${ap}_provider.lock',
      ]) {
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

    test('account cache loaders quarantine legacy suspect evidence', () {
      File('${cacheDir().path}/${ap}_work.json').writeAsStringSync(
        jsonEncode(
            aq('work', 20).withSuspect('legacy provider drift').toJson()),
      );

      expect(loadAccountSnapshot(ap, 'work'), isNull);
      expect(
        loadAccountSnapshotForAdmission(ap, 'work')?.suspect,
        'legacy provider drift',
      );
      expect(loadAccountSnapshots(ap), isEmpty);
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

    test('currentAccountFallbacks preserves unresolved drift diagnostics', () {
      final home = aq('home', 40);
      saveProviderDriftObservation(
        home,
        '5h usage fell 40% to 5% with no reset',
        1782000030,
      );

      final fallbacks = currentAccountFallbacks(
        liveResults: [aq('work', 20)],
        cachedSnapshots: [home],
        currentAccounts: {'work', 'home'},
      );

      expect(fallbacks, hasLength(1));
      expect(fallbacks.single.account, 'home');
      expect(fallbacks.single.stale, isTrue);
      expect(fallbacks.single.driftReason, contains('usage fell'));
    });
  });
}
