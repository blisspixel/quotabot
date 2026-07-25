// Cache tests exercise real owner-only ACL and cross-process lock boundaries.
// Windows permission helpers launch native subprocesses, so the default
// 30-second budget is not sufficient for the larger lifecycle scenarios on a
// loaded CI host. Functional latency assertions remain independently bounded.
@Timeout(Duration(minutes: 2))
library;

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

  test('explicit recovery replaces only one baseline and preserves history',
      () {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    ProviderQuota quota(String account, double used, int asOf) => ProviderQuota(
          provider: id,
          displayName: 'Codex',
          account: account,
          plan: 'pro',
          asOf: asOf,
          windows: [
            QuotaWindow(
              label: 'weekly',
              usedPercent: used,
              resetsAt: now + 86400,
            ),
          ],
        );

    final first = quota('acct', 70, now - 20);
    final other = quota('other-account', 55, now - 20);
    saveSnapshot(first, observedAtMicros: generation - 4000);
    saveSnapshot(other, observedAtMicros: generation - 4000);
    saveProviderDriftObservation(
      first,
      'weekly usage fell without a reset',
      now - 10,
      observedAtMicros: generation - 3000,
    );
    saveProviderDriftObservation(
      other,
      'other account drift',
      now - 10,
      observedAtMicros: generation - 3000,
    );
    final historyBefore = loadHistory(id, account: 'acct');

    final fresh = quota('acct', 25, now);
    final result = recoverProviderDriftBaseline(
      fresh,
      observedAt: now,
      observedAtMicros: generation,
    );

    expect(result.recovered, isTrue);
    expect(result.status, 'recovered');
    expect(loadAccountSnapshot(id, 'acct')?.windows.single.usedPercent, 25);
    expect(
      attachProviderDriftObservation(
        loadAccountSnapshot(id, 'acct')!,
        now: now,
      ).driftReason,
      isNull,
    );
    expect(
      attachProviderDriftObservation(
        loadAccountSnapshot(id, 'other-account')!,
        now: now,
      ).driftReason,
      'other account drift',
    );
    expect(loadHistory(id, account: 'acct'), hasLength(historyBefore.length));
    expect(
      loadHistory(id, account: 'acct').single.windows.single.usedPercent,
      historyBefore.single.windows.single.usedPercent,
    );
  });

  test('explicit recovery rejects untrusted fresh evidence without mutation',
      () {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    final baseline = ProviderQuota(
      provider: id,
      displayName: 'Codex',
      account: 'acct',
      asOf: now - 20,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 70,
          resetsAt: now + 86400,
        ),
      ],
    );
    saveSnapshot(baseline, observedAtMicros: generation - 3000);
    saveProviderDriftObservation(
      baseline,
      'active drift',
      now - 10,
      observedAtMicros: generation - 2000,
    );

    final candidates = <ProviderQuota>[
      baseline.asStale('cached fallback'),
      ProviderQuota(
        provider: id,
        displayName: 'Codex',
        account: 'acct',
        asOf: now,
        ok: false,
        error: 'live read failed',
      ),
      ProviderQuota(
        provider: id,
        displayName: 'Codex',
        account: 'acct',
        asOf: now,
        windows: [QuotaWindow(label: 'weekly')],
      ),
      ProviderQuota(
        provider: id,
        displayName: 'Codex',
        account: 'acct',
        asOf: now + kQuotaEvidenceClockSkewSeconds + 1,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 20,
            resetsAt: now + 86400,
          ),
        ],
      ),
    ];

    for (final candidate in candidates) {
      final result = recoverProviderDriftBaseline(
        candidate,
        observedAt: now,
        observedAtMicros: generation,
      );
      expect(result.recovered, isFalse, reason: candidate.toJson().toString());
      expect(result.status, 'invalid_live_evidence');
      expect(loadAccountSnapshot(id, 'acct')?.windows.single.usedPercent, 70);
      expect(
        attachProviderDriftObservation(
          loadAccountSnapshot(id, 'acct')!,
          now: now,
        ).driftReason,
        'active drift',
      );
    }
  });

  test('explicit recovery requires active drift and rejects newer generations',
      () {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: id,
          displayName: 'Codex',
          account: 'acct',
          asOf: asOf,
          windows: [
            QuotaWindow(
              label: 'weekly',
              usedPercent: used,
              resetsAt: now + 86400,
            ),
          ],
        );
    final baseline = quota(70, now - 20);
    saveSnapshot(baseline, observedAtMicros: generation - 3000);

    final clean = recoverProviderDriftBaseline(
      quota(25, now),
      observedAt: now,
      observedAtMicros: generation,
    );
    expect(clean.recovered, isFalse);
    expect(clean.status, 'no_active_drift');

    saveProviderDriftObservation(
      baseline,
      'newer concurrent drift',
      now,
      observedAtMicros: generation + 1000,
    );
    final superseded = recoverProviderDriftBaseline(
      quota(25, now),
      observedAt: now,
      observedAtMicros: generation,
    );
    expect(superseded.recovered, isFalse);
    expect(superseded.status, 'superseded');
    expect(loadAccountSnapshot(id, 'acct')?.windows.single.usedPercent, 70);
  });

  test('explicit recovery can replace an exact legacy suspect quarantine', () {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    final legacy = ProviderQuota(
      provider: id,
      displayName: 'Codex',
      account: 'acct',
      asOf: now - 20,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 70,
          resetsAt: now + 86400,
        ),
      ],
    ).withSuspect('legacy drift concern');
    accountCacheFile().writeAsStringSync(jsonEncode({
      ...legacy.toJson(),
      'cache_observed_at_micros': generation - 2000,
    }));
    final fresh = ProviderQuota(
      provider: id,
      displayName: 'Codex',
      account: 'acct',
      asOf: now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 25,
          resetsAt: now + 86400,
        ),
      ],
    );

    final result = recoverProviderDriftBaseline(
      fresh,
      observedAt: now,
      observedAtMicros: generation,
    );

    expect(result.recovered, isTrue);
    expect(loadAccountSnapshot(id, 'acct')?.suspect, isNull);
    expect(loadAccountSnapshot(id, 'acct')?.windows.single.usedPercent, 25);
    expect(loadHistory(id, account: 'acct'), isEmpty);
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

  test('mixed-version analytics writes fail closed without losing evidence',
      () async {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          plan: 'pro',
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );

    final initial = quota(20, now);
    saveSnapshot(initial);
    recordHeadroomSample(provider, 90, now - 3600, account: account);
    recordHeadroomSample(provider, 80, now, account: account);
    recordHeadroomSample(provider, 90, now - 3600);
    recordHeadroomSample(provider, 40, now);
    final competitor = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'other',
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 25)],
    );
    final burnBefore = recentBurnStatsByQuota([initial], now);
    final accountKey = quotaIdentityKey(provider, account);
    expect(burnBefore[accountKey]?.perHour, closeTo(10, 0.001));
    expect(
      suggestRoute(
        [initial, competitor],
        now,
        burnStatsByProvider: burnBefore,
      ).recommended?.provider,
      claudeProviderId,
    );

    final stem = accountStorageStem(account);
    final canonicalHistory = File(
      '${cacheDir().path}/history_${provider}_$stem.jsonl',
    );
    final canonicalBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$stem.json',
    );
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    );
    final legacyBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    );
    final migration = cacheDir().listSync().whereType<File>().singleWhere(
        (file) => file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));

    expect(analyticsStorageNotice(provider, account: account), isNull);
    expect(loadHistory(provider, account: account), hasLength(1));
    expect(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      hasLength(2),
    );
    final canonicalHistoryBefore = canonicalHistory.readAsBytesSync();
    final canonicalBucketsBefore = canonicalBuckets.readAsBytesSync();

    final oldWriterQuota = quota(35, now + 60);
    legacyHistory.writeAsStringSync(
      '${jsonEncode(oldWriterQuota.toJson())}\n',
    );
    final oldWriterBucket = HeadroomBucket(start: bucketStart(now))..add(65);
    legacyBuckets.writeAsStringSync(
      jsonEncode([oldWriterBucket.toJson()]),
    );

    final notice = analyticsStorageNotice(provider, account: account);
    expect(notice, isNotNull);
    expect(notice!.tiers, ['history', 'buckets']);
    expect(notice.summary, contains('Close every older quotabot process'));
    expect(loadHistory(provider, account: account), isEmpty);
    expect(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      isEmpty,
    );
    final visibleInventory = await analyticsStorageIncidentInventory([initial]);
    expect(
      visibleInventory.complete,
      isTrue,
      reason: jsonEncode(visibleInventory.toJson()),
    );
    expect(visibleInventory.incidents, hasLength(1));
    expect(
      visibleInventory.incidents.single.exactAccountInSnapshot,
      isTrue,
    );
    expect(visibleInventory.incidents.single.providerRowIndex, 0);
    final initialIncidentId = visibleInventory.incidents.single.incidentId;
    expect(initialIncidentId, matches(RegExp(r'^[a-f0-9]{32}$')));
    final burnAfter = recentBurnStatsByQuota([initial], now);
    expect(burnAfter[accountKey]?.perHour, burnBefore[accountKey]?.perHour);
    expect(
      suggestRoute(
        [initial, competitor],
        now,
        burnStatsByProvider: burnAfter,
      ).recommended?.provider,
      claudeProviderId,
      reason: 'a storage conflict must not improve the provider route position',
    );
    final later = now + 24 * 3600;
    final laterQuota = quota(20, later);
    final laterCompetitor = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'other',
      plan: 'pro',
      asOf: later,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 25)],
    );
    final burnLater = recentBurnStatsByQuota([laterQuota], later);
    expect(burnLater[accountKey]?.perHour, burnBefore[accountKey]?.perHour);
    expect(
      suggestRoute(
        [laterQuota, laterCompetitor],
        later,
        burnStatsByProvider: burnLater,
      ).recommended?.provider,
      claudeProviderId,
      reason: 'frozen trusted burn must not age into an optimistic route',
    );

    saveSnapshot(quota(45, now + 120));
    recordHeadroomSample(provider, 55, now + 120, account: account);
    expect(canonicalHistory.readAsBytesSync(), canonicalHistoryBefore);
    expect(canonicalBuckets.readAsBytesSync(), canonicalBucketsBefore);
    expect(legacyHistory.existsSync(), isTrue);
    expect(legacyBuckets.existsSync(), isTrue);

    final markerText = migration.readAsStringSync();
    final marker = jsonDecode(markerText) as Map<String, dynamic>;
    expect(marker['schema'], 'quotabot.analytics-migration.v1');
    expect(marker['provider'], provider);
    expect(marker['account_digest'], accountIdentityDigest(account));
    expect(marker['history_conflict'], isTrue);
    expect(marker['buckets_conflict'], isTrue);
    expect(marker['incident_id'], initialIncidentId);
    expect(marker['incident_observed_at'], isA<int>());
    expect(markerText, isNot(contains(account)));
    expect(markerText, isNot(contains(cacheDir().path)));
    expect(
      analyticsStorageNoticesForQuotas([initial]).single.toJson(),
      containsPair('state', 'diverged'),
    );
    final hiddenInventory = await analyticsStorageIncidentInventory(const []);
    expect(hiddenInventory.complete, isTrue);
    expect(hiddenInventory.incidents, hasLength(1));
    expect(
      hiddenInventory.incidents.single.exactAccountInSnapshot,
      isFalse,
    );
    expect(hiddenInventory.incidents.single.incidentId, marker['incident_id']);
    expect(hiddenInventory.incidents.single.tiers, ['history', 'buckets']);
    final inventoryJson = jsonEncode(hiddenInventory.toJson());
    expect(inventoryJson, contains('"exact_account_in_snapshot":false'));
    expect(inventoryJson, contains('"state":"complete"'));
    expect(inventoryJson, isNot(contains(account)));
    expect(inventoryJson, isNot(contains(accountIdentityDigest(account))));
    expect(inventoryJson, isNot(contains(cacheDir().path)));
  });

  test('analytics recovery exactly merges uniquely aligned raw history', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          plan: 'pro',
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );

    final baseline = quota(20, now);
    final canonicalOnly = quota(25, now + 30);
    final legacyOnly = quota(35, now + 60);
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    )..writeAsStringSync('${jsonEncode(baseline.toJson())}\n');

    saveSnapshot(canonicalOnly);
    legacyHistory.writeAsStringSync(
      '${legacyHistory.readAsStringSync()}${jsonEncode(legacyOnly.toJson())}\n',
    );

    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['history'],
    );
    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'history');
    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isTrue);
    expect(inspection.toJson()['impact'], {
      'selected_tier': 'would be archived, then exactly merged',
      'exact_merge_available': true,
      'exact_merge_performed': false,
      'preserved': isA<List<dynamic>>(),
    });

    final result = recoverAnalyticsStorage(provider, account, 'history');
    expect(result.recovered, isTrue);
    expect(result.exactMergeAvailable, isTrue);
    expect(result.exactMergePerformed, isTrue);
    expect(result.status, 'recovered');
    expect(result.detail, contains('exactly merged'));
    expect(legacyHistory.existsSync(), isFalse);
    expect(analyticsStorageNotice(provider, account: account), isNull);
    expect(
      loadHistory(provider, account: account).map((row) => row.asOf),
      [now, now + 30, now + 60],
    );

    final canonicalHistory = File(
      '${cacheDir().path}/history_${provider}_${accountStorageStem(account)}.jsonl',
    );
    final manifestFile = File('${result.evidenceBundle}/manifest.json');
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    expect(manifest['exact_merge_performed'], isTrue);
    expect(manifest['selected_tier_action'], 'archived_then_exactly_merged');
    expect(manifest['merged_rows'], 3);
    expect(manifest['merged_sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(manifest['merged_bytes'], canonicalHistory.lengthSync());
    final manifestText = jsonEncode(manifest);
    expect(manifestText, isNot(contains(account)));
    expect(manifestText, isNot(contains(cacheDir().path)));

    manifest['state'] = 'checkpoint_pending';
    manifest['exact_merge_performed'] = false;
    manifestFile.writeAsStringSync(jsonEncode(manifest));
    final interrupted = recoverAnalyticsStorage(provider, account, 'history');
    expect(interrupted.status, 'recovered_receipt_incomplete');
    expect(interrupted.exactMergePerformed, isTrue);

    manifest['state'] = 'complete';
    manifest['exact_merge_performed'] = true;
    manifestFile.writeAsStringSync(jsonEncode(manifest));
    final retry = recoverAnalyticsStorage(provider, account, 'history');
    expect(retry.status, 'already_recovered');
    expect(retry.exactMergePerformed, isTrue);

    legacyHistory
        .writeAsStringSync('${jsonEncode(quota(40, now + 90).toJson())}\n');
    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['history'],
    );
    expect(loadHistory(provider, account: account), isEmpty);
  });

  test('ambiguous raw history overlap retains archive-and-reset recovery', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final repeated = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    final later = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now + 60,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 30)],
    );
    final encoded = jsonEncode(repeated.toJson());
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    )..writeAsStringSync('$encoded\n$encoded\n');

    saveSnapshot(later);
    legacyHistory.writeAsStringSync(
      '${legacyHistory.readAsStringSync()}${jsonEncode(later.toJson())}\n',
    );

    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'history');
    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isFalse);
    expect(
      (inspection.toJson()['impact'] as Map)['selected_tier'],
      'would be archived, then restarted empty',
    );
  });

  test('nonmonotonic raw history retains archive-and-reset recovery', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    final baseline = [quota(20, now), quota(25, now + 60)];
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    )..writeAsStringSync(
        '${baseline.map((row) => jsonEncode(row.toJson())).join('\n')}\n',
      );

    saveSnapshot(quota(30, now + 120));
    legacyHistory.writeAsStringSync(
      '${baseline.map((row) => jsonEncode(row.toJson())).join('\n')}\n'
      '${jsonEncode(quota(40, now + 240).toJson())}\n'
      '${jsonEncode(quota(35, now + 180).toJson())}\n',
    );

    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'history');
    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isFalse);
    expect(
      (inspection.toJson()['impact'] as Map)['selected_tier'],
      'would be archived, then restarted empty',
    );
  });

  test('exact raw history merge retains the newest capped union', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    ProviderQuota quota(int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
        );
    final baseline = [
      for (var index = 0; index < 200; index++)
        jsonEncode(quota(now + index * 60).toJson()),
    ];
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    )..writeAsStringSync('${baseline.join('\n')}\n');

    saveSnapshot(quota(now + 200 * 60));
    legacyHistory.writeAsStringSync(
      '${baseline.skip(1).join('\n')}\n'
      '${jsonEncode(quota(now + 201 * 60).toJson())}\n',
    );

    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'history');
    expect(inspection.exactMergeAvailable, isTrue);
    final result = recoverAnalyticsStorage(provider, account, 'history');
    expect(result.exactMergePerformed, isTrue);

    final canonicalHistory = File(
      '${cacheDir().path}/history_${provider}_${accountStorageStem(account)}.jsonl',
    );
    final rows = canonicalHistory
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => ProviderQuota.fromJson(
              jsonDecode(line) as Map<String, dynamic>,
            ))
        .toList();
    expect(rows, hasLength(200));
    expect(rows.first.asOf, now + 2 * 60);
    expect(rows.last.asOf, now + 201 * 60);
  });

  test('analytics recovery exactly merges checkpoint-proven buckets', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final alignedNow = bucketStart(now);
    HeadroomBucket bucket(int start, List<double> values) {
      final result = HeadroomBucket(start: start);
      for (final value in values) {
        result.add(value);
      }
      return result;
    }

    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    File('${cacheDir().path}/${provider}_$account.json')
        .writeAsStringSync(jsonEncode(quota.toJson()));
    final older = bucket(alignedNow - 3600, [90]);
    final shared = bucket(alignedNow, [80]);
    final legacyBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    )..writeAsStringSync(jsonEncode([
        older.toJson(),
        shared.toJson(),
      ]));

    recordHeadroomSample(provider, 70, now, account: account);
    shared.add(40);
    legacyBuckets.writeAsStringSync(jsonEncode([
      older.toJson(),
      shared.toJson(),
    ]));

    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['buckets'],
    );
    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'buckets');
    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isTrue);
    expect(
      (inspection.toJson()['impact'] as Map)['selected_tier'],
      'would be archived, then exactly merged',
    );

    final result = recoverAnalyticsStorage(provider, account, 'buckets');
    expect(result.recovered, isTrue);
    expect(result.exactMergePerformed, isTrue);
    expect(result.detail, contains('aggregate'));
    expect(legacyBuckets.existsSync(), isFalse);
    expect(analyticsStorageNotice(provider, account: account), isNull);
    final merged =
        loadBuckets(provider, account: account, fallbackToProvider: false);
    expect(merged, hasLength(2));
    expect(merged.first.start, alignedNow - 3600);
    expect(merged.first.count, 1);
    expect(merged.last.start, alignedNow);
    expect(merged.last.count, 3);
    expect(merged.last.sum, closeTo(190, 0.000001));
    expect(merged.last.sumSq, closeTo(12900, 0.000001));
    expect(merged.last.min, 40);
    expect(merged.last.max, 80);
    expect(merged.last.hist.reduce((left, right) => left + right), 3);

    final manifestFile = File('${result.evidenceBundle}/manifest.json');
    final manifest = jsonDecode(
      manifestFile.readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(manifest['exact_merge_performed'], isTrue);
    expect(manifest['merged_buckets'], 2);
    expect(manifest['merged_rows'], isNull);
    expect(manifest['merged_sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));

    manifest['state'] = 'checkpoint_pending';
    manifest['exact_merge_performed'] = false;
    manifestFile.writeAsStringSync(jsonEncode(manifest));
    final interrupted = recoverAnalyticsStorage(provider, account, 'buckets');
    expect(interrupted.status, 'recovered_receipt_incomplete');
    expect(interrupted.exactMergePerformed, isTrue);

    manifest['state'] = 'complete';
    manifest['exact_merge_performed'] = true;
    manifestFile.writeAsStringSync(jsonEncode(manifest));
    final retry = recoverAnalyticsStorage(provider, account, 'buckets');
    expect(retry.status, 'already_recovered');
    expect(retry.exactMergePerformed, isTrue);

    legacyBuckets.writeAsStringSync(
      jsonEncode([
        bucket(alignedNow, [30]).toJson()
      ]),
    );
    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['buckets'],
    );
    expect(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      isEmpty,
    );
  });

  test('exact bucket merge accepts retention suffixes and new buckets', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final alignedNow = bucketStart(now);
    HeadroomBucket bucket(int start, List<double> values) {
      final result = HeadroomBucket(start: start);
      for (final value in values) {
        result.add(value);
      }
      return result;
    }

    final baseline = [
      bucket(alignedNow - 7200, [90]),
      bucket(alignedNow - 3600, [80]),
      bucket(alignedNow, [70]),
    ];
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    File('${cacheDir().path}/${provider}_$account.json')
        .writeAsStringSync(jsonEncode(quota.toJson()));
    final legacy = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    )..writeAsStringSync(
        jsonEncode(baseline.map((item) => item.toJson()).toList()),
      );
    recordHeadroomSample(provider, 60, now, account: account);

    final canonical = File(
      '${cacheDir().path}/buckets_${provider}_${accountStorageStem(account)}.json',
    );
    canonical.writeAsStringSync(jsonEncode([
      bucket(alignedNow - 3600, [80, 50]).toJson(),
      bucket(alignedNow, [70, 60]).toJson(),
    ]));
    legacy.writeAsStringSync(jsonEncode([
      bucket(alignedNow, [70, 40]).toJson(),
      bucket(alignedNow + 3600, [30]).toJson(),
    ]));

    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'buckets');
    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isTrue);
    final recovery = recoverAnalyticsStorage(provider, account, 'buckets');
    expect(recovery.exactMergePerformed, isTrue);
    final merged =
        loadBuckets(provider, account: account, fallbackToProvider: false);
    expect(merged.map((item) => item.start), [
      alignedNow - 3600,
      alignedNow,
      alignedNow + 3600,
    ]);
    expect(merged.map((item) => item.count), [2, 3, 1]);
    expect(merged[0].sum, closeTo(130, 0.000001));
    expect(merged[1].sum, closeTo(170, 0.000001));
    expect(merged[2].sum, closeTo(30, 0.000001));
  });

  test('exact bucket merge accepts independent branches from empty baseline',
      () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final alignedNow = bucketStart(now);
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    File('${cacheDir().path}/${provider}_$account.json')
        .writeAsStringSync(jsonEncode(quota.toJson()));
    final legacy = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    )..writeAsStringSync('[]');

    recordHeadroomSample(provider, 70, now, account: account);
    final legacyBucket = HeadroomBucket(start: alignedNow)..add(40);
    legacy.writeAsStringSync(jsonEncode([legacyBucket.toJson()]));

    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'buckets');
    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isTrue);
    final recovery = recoverAnalyticsStorage(provider, account, 'buckets');
    expect(recovery.exactMergePerformed, isTrue);
    final merged =
        loadBuckets(provider, account: account, fallbackToProvider: false);
    expect(merged, hasLength(1));
    expect(merged.single.count, 2);
    expect(merged.single.sum, closeTo(110, 0.000001));
    expect(merged.single.min, 40);
    expect(merged.single.max, 70);
  });

  test('exact bucket merge rejects ambiguous checkpoint evidence', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final alignedNow = bucketStart(now);
    HeadroomBucket bucket(int start, List<double> values) {
      final result = HeadroomBucket(start: start);
      for (final value in values) {
        result.add(value);
      }
      return result;
    }

    void clearStorage() {
      final directory = cacheDir();
      for (final entity in directory.listSync()) {
        entity.deleteSync(recursive: true);
      }
    }

    void expectRejected(
      String reason,
      List<Map<String, dynamic>> canonicalRows,
      List<Map<String, dynamic>> legacyRows,
    ) {
      clearStorage();
      final baseline = [
        bucket(alignedNow - 7200, [90]),
        bucket(alignedNow - 3600, [80]),
        bucket(alignedNow, [70]),
      ];
      final quota = ProviderQuota(
        provider: provider,
        displayName: 'Codex',
        account: account,
        asOf: now,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
      );
      File('${cacheDir().path}/${provider}_$account.json')
          .writeAsStringSync(jsonEncode(quota.toJson()));
      final legacy = File(
        '${cacheDir().path}/buckets_${provider}_$account.json',
      )..writeAsStringSync(
          jsonEncode(baseline.map((item) => item.toJson()).toList()),
        );
      recordHeadroomSample(provider, 60, now, account: account);
      File(
        '${cacheDir().path}/buckets_${provider}_${accountStorageStem(account)}.json',
      ).writeAsStringSync(jsonEncode(canonicalRows));
      legacy.writeAsStringSync(jsonEncode(legacyRows));

      final inspection =
          inspectAnalyticsStorageRecovery(provider, account, 'buckets');
      expect(inspection.ready, isTrue, reason: reason);
      expect(inspection.exactMergeAvailable, isFalse, reason: reason);
    }

    final first = bucket(alignedNow - 7200, [90]).toJson();
    final middle = bucket(alignedNow - 3600, [80]).toJson();
    final last = bucket(alignedNow, [70]).toJson();
    expectRejected(
      'a retained checkpoint branch must be a complete suffix',
      [first, last],
      [middle, last],
    );
    expectRejected(
      'a branch cannot remove checkpoint samples',
      [
        bucket(alignedNow - 3600, [80]).toJson(),
        bucket(alignedNow, [70]).toJson(),
      ],
      [
        bucket(alignedNow - 3600, [80]).toJson(),
        bucket(alignedNow, [60]).toJson(),
      ],
    );
    expectRejected(
      'duplicate bucket starts are ambiguous',
      [middle, middle, last],
      [last],
    );
    final impossibleMoment = bucket(alignedNow, [70, 40]).toJson()
      ..['sq'] = 6700;
    expectRejected(
      'aggregate moments must be possible for their extrema',
      [middle, last],
      [impossibleMoment],
    );
    expectRejected(
      'a new pre-checkpoint bucket cannot be distinguished from a gap',
      [
        bucket(alignedNow - 10800, [85]).toJson(),
        last,
      ],
      [last],
    );
  });

  test('exact bucket merge keeps the newest bounded aggregate union', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final firstStart = bucketStart(now);
    final cap = kRetentionDays * 24 + 2;
    Map<String, dynamic> bucket(int start, double value) =>
        (HeadroomBucket(start: start)..add(value)).toJson();
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    File('${cacheDir().path}/${provider}_$account.json')
        .writeAsStringSync(jsonEncode(quota.toJson()));
    final legacy = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    )..writeAsStringSync('[]');
    recordHeadroomSample(provider, 90, now, account: account);

    final canonical = File(
      '${cacheDir().path}/buckets_${provider}_${accountStorageStem(account)}.json',
    );
    canonical.writeAsStringSync(jsonEncode([
      for (var index = 0; index < cap; index++)
        bucket(firstStart + index * kBucketSpan, 80),
    ]));
    legacy.writeAsStringSync(jsonEncode([
      for (var index = 0; index < cap; index++)
        bucket(firstStart + (cap + index) * kBucketSpan, 70),
    ]));

    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'buckets');
    expect(inspection.exactMergeAvailable, isTrue);
    final recovery = recoverAnalyticsStorage(provider, account, 'buckets');
    expect(recovery.exactMergePerformed, isTrue);
    final merged =
        loadBuckets(provider, account: account, fallbackToProvider: false);
    expect(merged, hasLength(cap));
    expect(merged.first.start, firstStart + cap * kBucketSpan);
    expect(merged.last.start, firstStart + (2 * cap - 1) * kBucketSpan);
  });

  test('inconsistent bucket aggregate retains archive-and-reset recovery', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final alignedNow = bucketStart(now);
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    File('${cacheDir().path}/${provider}_$account.json')
        .writeAsStringSync(jsonEncode(quota.toJson()));
    final baseline = HeadroomBucket(start: alignedNow)..add(80);
    final legacyBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    )..writeAsStringSync(jsonEncode([baseline.toJson()]));

    recordHeadroomSample(provider, 70, now, account: account);
    legacyBuckets.writeAsStringSync(jsonEncode([
      {
        ...baseline.toJson(),
        'n': 2,
        'sum': 120,
        'sq': 8000,
        'min': 40,
        'h': List<int>.filled(kHistBins, 0),
      },
    ]));

    final inspection =
        inspectAnalyticsStorageRecovery(provider, account, 'buckets');
    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isFalse);
    expect(
      (inspection.toJson()['impact'] as Map)['selected_tier'],
      'would be archived, then restarted empty',
    );
  });

  test('analytics incident inventory validates markers and stays bounded',
      () async {
    const provider = codexProviderId;
    final dir = cacheDir();
    for (var index = 0; index < 300; index++) {
      final digest = accountIdentityDigest('account-$index');
      File(
        '${dir.path}/analytics_migration_${provider}_account_$digest.json',
      ).writeAsStringSync(
        jsonEncode({
          'schema': 'quotabot.analytics-migration.v1',
          'provider': provider,
          'account_digest': digest,
          'observed_at': 1782000000 + index,
          'history_conflict': true,
          'incident_id': index.toRadixString(16).padLeft(32, '0'),
        }),
      );
    }
    final ignoredDigest = accountIdentityDigest('ignored');
    File(
      '${dir.path}/analytics_migration_${provider}_account_$ignoredDigest.json',
    ).writeAsStringSync(
      jsonEncode({
        'schema': 'quotabot.analytics-migration.v1',
        'provider': provider,
        'account_digest': ignoredDigest,
        'observed_at': 1782000500,
      }),
    );
    File('${dir.path}/analytics_migration_forged.json').writeAsStringSync(
      jsonEncode({
        'schema': 'quotabot.analytics-migration.v1',
        'provider': provider,
        'account_digest': ignoredDigest,
        'observed_at': 1782000500,
        'buckets_conflict': true,
      }),
    );

    final inventory = await analyticsStorageIncidentInventory(const []);
    final incidents = inventory.incidents;

    expect(incidents.length, inInclusiveRange(1, 256));
    expect(inventory.complete, isFalse);
    expect(inventory.truncated, isTrue);
    expect(inventory.globalUncertainty, isTrue);
    expect(
        incidents.every((incident) => incident.provider == provider), isTrue);
    expect(
      incidents.every((incident) => incident.tiers.length == 1),
      isTrue,
    );
    expect(jsonEncode(incidents.map((entry) => entry.toJson()).toList()),
        isNot(contains(ignoredDigest)));
  });

  test('analytics incident inventory respects visible scope and reports gaps',
      () async {
    final now = nowEpoch();
    const visibleAccount = 'visible-account';
    final visibleQuota = ProviderQuota(
      provider: codexProviderId,
      displayName: 'Codex',
      account: visibleAccount,
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    saveSnapshot(visibleQuota);
    final dir = cacheDir();
    void writeMarker(
      String provider,
      String digest,
      Map<String, dynamic> fields,
    ) {
      File(
        '${dir.path}/analytics_migration_${provider}_account_$digest.json',
      ).writeAsStringSync(
        jsonEncode({
          'schema': 'quotabot.analytics-migration.v1',
          'provider': provider,
          'account_digest': digest,
          'observed_at': now,
          ...fields,
        }),
      );
    }

    final visibleDigest = accountIdentityDigest(visibleAccount);
    final hiddenDigest = accountIdentityDigest('hidden-account');
    final unverifiableDigest = accountIdentityDigest('unverifiable-account');
    final invalidDigest = accountIdentityDigest('invalid-account');
    writeMarker(codexProviderId, visibleDigest, {
      'history_conflict': true,
      'incident_id': '0123456789abcdef0123456789abcdef',
    });
    writeMarker(claudeProviderId, hiddenDigest, {
      'buckets_conflict': true,
    });
    writeMarker(grokProviderId, unverifiableDigest, {
      'history': {'digest': 'unverifiable', 'count': 0},
    });
    final invalidMarker = File(
      '${dir.path}/analytics_migration_${antigravityProviderId}_account_$invalidDigest.json',
    );
    invalidMarker.writeAsStringSync('{}');

    final visible = await analyticsStorageIncidentInventory(
      [visibleQuota],
      includeUnavailable: false,
      now: now,
    );
    expect(visible.complete, isTrue);
    expect(visible.scope, 'visible_snapshot');
    expect(visible.scannedMarkers, 0);
    expect(visible.incidents, hasLength(1));
    expect(visible.incidents.single.provider, codexProviderId);
    expect(visible.incidents.single.providerRowIndex, 0);
    expect(jsonEncode(visible.toJson()), isNot(contains(hiddenDigest)));
    expect(jsonEncode(visible.toJson()), isNot(contains(claudeProviderId)));

    final full = await analyticsStorageIncidentInventory(
      const [],
      now: now,
    );
    expect(full.complete, isFalse);
    expect(full.scope, 'all_local');
    expect(
      full.incidents,
      hasLength(2),
      reason: jsonEncode(full.toJson()),
    );
    expect(full.unverifiableMarkers, 1);
    expect(full.invalidMarkers, 1);
    expect(full.uncertainProviders, contains(grokProviderId));
    expect(full.globalUncertainty, isTrue);
    final hiddenIncident = full.incidents.singleWhere(
      (incident) => incident.provider == claudeProviderId,
    );
    expect(hiddenIncident.recordedAt, now);
    expect(hiddenIncident.incidentId, matches(RegExp(r'^[a-f0-9]{32}$')));
    final upgradedHidden = jsonDecode(
      File(
        '${dir.path}/analytics_migration_${claudeProviderId}_account_$hiddenDigest.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(upgradedHidden['incident_observed_at'], now);
    final healthyMarker = jsonDecode(
      File(
        '${dir.path}/analytics_migration_${grokProviderId}_account_$unverifiableDigest.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(healthyMarker, isNot(contains('incident_id')));
    expect(healthyMarker, isNot(contains('incident_observed_at')));
    final fullJson = jsonEncode(full.toJson());
    expect(fullJson, contains('"state":"partial"'));
    expect(fullJson, isNot(contains(visibleDigest)));
    expect(fullJson, isNot(contains(hiddenDigest)));
    expect(fullJson, isNot(contains(unverifiableDigest)));
    expect(fullJson, isNot(contains(invalidDigest)));
  });

  test('analytics incident inventory fails soft on identity lock failure',
      () async {
    final now = nowEpoch();
    const provider = codexProviderId;
    const account = 'contended-account';
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    saveSnapshot(quota);
    final digest = accountIdentityDigest(account);
    final marker = File(
      '${cacheDir().path}/analytics_migration_${provider}_account_$digest.json',
    );
    marker.writeAsStringSync(
      jsonEncode({
        'schema': 'quotabot.analytics-migration.v1',
        'provider': provider,
        'account_digest': digest,
        'observed_at': now,
        'history_conflict': true,
      }),
    );
    final lockFile = File(
      '${cacheDir().path}/evidence_${provider}_account_$digest.lock',
    );
    if (lockFile.existsSync()) lockFile.deleteSync();
    Directory(lockFile.path).createSync();
    final clock = Stopwatch()..start();
    final inventory = await analyticsStorageIncidentInventory(
      [quota],
      includeUnavailable: false,
      now: now,
    );
    clock.stop();

    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    expect(inventory.state, 'partial');
    expect(inventory.uncertainProviders, {provider});
    expect(inventory.globalUncertainty, isFalse);
    expect(inventory.incidents, hasLength(1));
    expect(inventory.incidents.single.incidentId, isNull);
    final output = jsonEncode(inventory.toJson());
    expect(output, isNot(contains(digest)));
    expect(output, isNot(contains(cacheDir().path)));
  });

  test('analytics recovery inspection is read-only and recovery is scoped', () {
    const provider = codexProviderId;
    const account = 'acct';
    const otherAccount = 'other-account';
    const now = 1782000000;
    ProviderQuota quota(String targetAccount, double used, int asOf) =>
        ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: targetAccount,
          plan: 'pro',
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );

    saveSnapshot(quota(account, 20, now));
    saveSnapshot(quota(otherAccount, 30, now));
    recordHeadroomSample(provider, 90, now - 3600, account: account);
    recordHeadroomSample(provider, 80, now, account: account);
    recordHeadroomSample(provider, 70, now, account: otherAccount);
    recordHeadroomSample(provider, 60, now);

    final accountStem = accountStorageStem(account);
    File('${cacheDir().path}/history_${provider}_$account.jsonl')
        .writeAsStringSync(
      '${jsonEncode(quota(account, 35, now + 60).toJson())}\n',
    );
    final canonicalBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$accountStem.json',
    );
    final providerBuckets = File('${cacheDir().path}/buckets_$provider.json');
    final otherHistory = File(
      '${cacheDir().path}/history_${provider}_${accountStorageStem(otherAccount)}.jsonl',
    );
    final snapshotBefore = accountCacheFile().readAsBytesSync();
    final bucketsBefore = canonicalBuckets.readAsBytesSync();
    final providerBucketsBefore = providerBuckets.readAsBytesSync();
    final otherHistoryBefore = otherHistory.readAsBytesSync();
    final cacheBefore = {
      for (final file in cacheDir().listSync().whereType<File>())
        file.uri.pathSegments.last: file.readAsBytesSync(),
    };
    final recoveryRoot = Directory(
      '${tempConfig.path}/quotabot/analytics-recovery',
    );
    expect(recoveryRoot.existsSync(), isFalse);

    final inspection = inspectAnalyticsStorageRecovery(
      provider,
      account,
      'history',
    );

    expect(inspection.ready, isTrue);
    expect(inspection.exactMergeAvailable, isTrue);
    expect(inspection.status, 'ready');
    expect(inspection.activeTiers, ['history']);
    expect(inspection.toJson()['schema'], 'quotabot.analytics-recovery.v1');
    expect(recoveryRoot.existsSync(), isFalse);
    expect(
      {
        for (final file in cacheDir().listSync().whereType<File>())
          file.uri.pathSegments.last: file.readAsBytesSync(),
      },
      cacheBefore,
      reason: 'inspection must not create a lock, receipt, or storage write',
    );

    final recovered = recoverAnalyticsStorage(provider, account, 'history');

    expect(recovered.recovered, isTrue);
    expect(recovered.exactMergePerformed, isTrue);
    expect(recovered.status, 'recovered');
    expect(recovered.activeTiers, isEmpty);
    expect(recovered.archivedRoles, contains('canonical-history'));
    expect(recovered.archivedRoles, contains('legacy-history'));
    expect(recovered.archivedRoles, contains('migration-marker'));
    expect(analyticsStorageNotice(provider, account: account), isNull);
    expect(
      loadHistory(provider, account: account).map((row) => row.asOf),
      [now, now + 60],
    );
    expect(accountCacheFile().readAsBytesSync(), snapshotBefore);
    expect(canonicalBuckets.readAsBytesSync(), bucketsBefore);
    expect(providerBuckets.readAsBytesSync(), providerBucketsBefore);
    expect(otherHistory.readAsBytesSync(), otherHistoryBefore);

    final bundle = Directory(recovered.evidenceBundle!);
    final manifest = File('${bundle.path}/manifest.json');
    final manifestText = manifest.readAsStringSync();
    final manifestJson = jsonDecode(manifestText) as Map<String, dynamic>;
    expect(bundle.existsSync(), isTrue);
    expect(manifestJson['schema'], 'quotabot.analytics-recovery-evidence.v1');
    expect(manifestJson['state'], 'complete');
    expect(manifestJson['account_digest'], accountIdentityDigest(account));
    expect(manifestJson['exact_merge_performed'], isTrue);
    expect(manifestText, isNot(contains(account)));
    expect(manifestText, isNot(contains(cacheDir().path)));
    expect(
      File('${bundle.path}/legacy-history.jsonl').readAsBytesSync(),
      isNotEmpty,
    );

    final bundleCount = recoveryRoot.listSync().whereType<Directory>().length;
    final second = recoverAnalyticsStorage(provider, account, 'history');
    expect(second.recovered, isTrue);
    expect(second.status, 'already_recovered');
    expect(second.evidenceBundle, recovered.evidenceBundle);
    expect(recoveryRoot.listSync().whereType<Directory>().length, bundleCount);
    final interruptedManifest = jsonDecode(manifest.readAsStringSync())
        as Map<String, dynamic>
      ..['state'] = 'checkpoint_pending';
    manifest.writeAsStringSync(jsonEncode(interruptedManifest));
    final interruptedRetry =
        recoverAnalyticsStorage(provider, account, 'history');
    expect(interruptedRetry.recovered, isTrue);
    expect(interruptedRetry.status, 'recovered_receipt_incomplete');
    expect(interruptedRetry.evidenceBundle, recovered.evidenceBundle);
    interruptedManifest['state'] = 'complete';
    manifest.writeAsStringSync(jsonEncode(interruptedManifest));

    saveSnapshot(quota(account, 45, now + 120));
    expect(
      loadHistory(provider, account: account).map((row) => row.asOf),
      [now, now + 60, now + 120],
    );
  });

  test('analytics recovery clears only the selected conflicted tier', () async {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );

    saveSnapshot(quota(20, now));
    recordHeadroomSample(provider, 90, now - 3600, account: account);
    recordHeadroomSample(provider, 80, now, account: account);
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    )..writeAsStringSync(
        '${jsonEncode(quota(35, now + 60).toJson())}\n',
      );
    final legacyBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    )..writeAsStringSync(
        jsonEncode([
          (HeadroomBucket(start: bucketStart(now))..add(65)).toJson(),
        ]),
      );
    final canonicalBuckets = File(
      '${cacheDir().path}/buckets_${provider}_${accountStorageStem(account)}.json',
    );
    final canonicalBucketsBefore = canonicalBuckets.readAsBytesSync();
    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['history', 'buckets'],
    );
    final initialInventory = await analyticsStorageIncidentInventory([
      quota(20, now),
    ]);
    final incidentId = initialInventory.incidents.single.incidentId;
    final recordedAt = initialInventory.incidents.single.recordedAt;

    final historyRecovery =
        recoverAnalyticsStorage(provider, account, 'history');

    expect(historyRecovery.recovered, isTrue);
    expect(historyRecovery.exactMergePerformed, isTrue);
    expect(historyRecovery.activeTiers, ['buckets']);
    expect(legacyHistory.existsSync(), isFalse);
    expect(legacyBuckets.existsSync(), isTrue);
    expect(canonicalBuckets.readAsBytesSync(), canonicalBucketsBefore);
    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['buckets'],
    );
    final partialInventory = await analyticsStorageIncidentInventory([
      quota(20, now),
    ]);
    expect(partialInventory.incidents.single.tiers, ['buckets']);
    expect(partialInventory.incidents.single.incidentId, incidentId);
    expect(partialInventory.incidents.single.recordedAt, recordedAt);
    expect(
      loadHistory(provider, account: account).map((row) => row.asOf),
      [now, now + 60],
    );
    expect(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      isEmpty,
    );

    final bucketsRecovery =
        recoverAnalyticsStorage(provider, account, 'buckets');

    expect(bucketsRecovery.recovered, isTrue);
    expect(bucketsRecovery.exactMergePerformed, isTrue);
    expect(bucketsRecovery.activeTiers, isEmpty);
    expect(analyticsStorageNotice(provider, account: account), isNull);
    expect(legacyBuckets.existsSync(), isFalse);
    expect(canonicalBuckets.existsSync(), isTrue);
    final recoveredBuckets =
        loadBuckets(provider, account: account, fallbackToProvider: false);
    expect(recoveredBuckets, hasLength(2));
    expect(recoveredBuckets.first.count, 1);
    expect(recoveredBuckets.first.sum, closeTo(90, 0.000001));
    expect(recoveredBuckets.last.count, 2);
    expect(recoveredBuckets.last.sum, closeTo(145, 0.000001));
    final resolvedInventory = await analyticsStorageIncidentInventory([
      quota(20, now),
    ]);
    expect(resolvedInventory.incidents, isEmpty);
    expect(resolvedInventory.complete, isTrue);
  });

  test('malformed analytics marker can be archived one tier at a time', () {
    const provider = codexProviderId;
    const account = 'acct';
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    saveSnapshot(quota);
    final marker = cacheDir().listSync().whereType<File>().singleWhere((file) =>
        file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    marker.writeAsStringSync('{not-json');

    final result = recoverAnalyticsStorage(provider, account, 'history');

    expect(result.recovered, isTrue);
    expect(result.activeTiers, ['buckets']);
    expect(
      File('${result.evidenceBundle}/migration-marker.json').readAsStringSync(),
      '{not-json',
    );
    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['buckets'],
    );
    final lockNames = cacheDir()
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.startsWith('evidence_${provider}_'))
        .toSet();
    expect(lockNames, contains('evidence_${provider}_$account.lock'));
    expect(
      lockNames,
      contains(
        'evidence_${provider}_${accountStorageStem(account)}.lock',
      ),
    );
    File('${cacheDir().path}/history_${provider}_$account.jsonl')
        .writeAsStringSync('${jsonEncode(quota.toJson())}\n');
    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['history', 'buckets'],
      reason: 'a late old writer must differ from the immutable empty baseline',
    );
  });

  test('invalid confirmed analytics recovery creates no storage artifacts', () {
    final result = recoverAnalyticsStorage(
      'not-a-provider',
      'acct',
      'history',
    );

    expect(result.recovered, isFalse);
    expect(result.status, 'unsupported_target');
    expect(Directory('${tempConfig.path}/quotabot').existsSync(), isFalse);
  });

  test('unsafe analytics evidence is rejected without a recovery write', () {
    const provider = codexProviderId;
    const account = 'acct';
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    saveSnapshot(quota);
    final marker = cacheDir().listSync().whereType<File>().singleWhere((file) =>
        file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    final record = jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>
      ..['history_conflict'] = true;
    marker.writeAsStringSync(jsonEncode(record));
    Directory('${cacheDir().path}/history_${provider}_$account.jsonl')
        .createSync();

    final inspection = inspectAnalyticsStorageRecovery(
      provider,
      account,
      'history',
    );

    expect(inspection.ready, isFalse);
    expect(inspection.status, 'unsafe_evidence');
    expect(
      Directory('${tempConfig.path}/quotabot/analytics-recovery').existsSync(),
      isFalse,
    );
  });

  test(
      'analytics recovery refuses a legacy history shared by colliding accounts',
      () {
    const provider = grokProviderId;
    const target = 'nick+work@example.com';
    const other = 'nick_work@example.com';
    const legacyStem = 'nick_work_example.com';
    const now = 1782000000;
    ProviderQuota quota(String account, double used) => ProviderQuota(
          provider: provider,
          displayName: 'Grok',
          account: account,
          asOf: now,
          windows: [QuotaWindow(label: 'monthly', usedPercent: used)],
        );
    saveSnapshot(quota(target, 20));
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$legacyStem.jsonl',
    )..writeAsStringSync(
        '${jsonEncode(quota(target, 30).toJson())}\n'
        '${jsonEncode(quota(other, 70).toJson())}\n',
      );
    final before = legacyHistory.readAsBytesSync();

    final inspection = inspectAnalyticsStorageRecovery(
      provider,
      target,
      'history',
    );
    final recovery = recoverAnalyticsStorage(provider, target, 'history');

    expect(inspection.ready, isFalse);
    expect(inspection.status, 'shared_legacy_evidence');
    expect(inspection.toJson()['impact'],
        containsPair('selected_tier', 'unchanged'));
    expect(recovery.recovered, isFalse);
    expect(recovery.status, 'shared_legacy_evidence');
    expect(legacyHistory.readAsBytesSync(), before);
    expect(loadHistory(provider, account: other).single.account, other);
    expect(
      Directory('${tempConfig.path}/quotabot/analytics-recovery').existsSync(),
      isFalse,
    );
  });

  test('analytics recovery refuses a legacy bucket owned by another account',
      () {
    const provider = grokProviderId;
    const target = 'nick+work@example.com';
    const other = 'nick_work@example.com';
    const legacyStem = 'nick_work_example.com';
    const now = 1782000000;
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Grok',
      account: target,
      asOf: now,
      windows: [QuotaWindow(label: 'monthly', usedPercent: 20)],
    );
    saveSnapshot(quota);
    recordHeadroomSample(provider, 80, now, account: target);
    final legacyBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$legacyStem.json',
    )..writeAsStringSync(
        jsonEncode([
          (HeadroomBucket(start: bucketStart(now))..add(65)).toJson(),
        ]),
      );
    File(
      '${cacheDir().path}/legacy_bucket_owner_${provider}_${accountStorageStem(legacyStem)}.json',
    ).writeAsStringSync(
      jsonEncode({
        'schema': 'quotabot.legacy-bucket-owner.v1',
        'provider': provider,
        'account_digest': accountIdentityDigest(other),
      }),
    );
    final before = legacyBuckets.readAsBytesSync();

    final inspection = inspectAnalyticsStorageRecovery(
      provider,
      target,
      'buckets',
    );
    final recovery = recoverAnalyticsStorage(provider, target, 'buckets');

    expect(inspection.ready, isFalse);
    expect(inspection.status, 'shared_legacy_evidence');
    expect(recovery.recovered, isFalse);
    expect(recovery.status, 'shared_legacy_evidence');
    expect(legacyBuckets.readAsBytesSync(), before);
    expect(
      Directory('${tempConfig.path}/quotabot/analytics-recovery').existsSync(),
      isFalse,
    );
  });

  test('unsafe analytics archive root leaves selected evidence quarantined',
      () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    saveSnapshot(quota);
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    )..writeAsStringSync(
        '${jsonEncode(ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          asOf: now + 60,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 35)],
        ).toJson())}\n',
      );
    final recoveryRoot = File('${tempConfig.path}/quotabot/analytics-recovery')
      ..writeAsStringSync('not a directory');

    final result = recoverAnalyticsStorage(provider, account, 'history');

    expect(result.recovered, isFalse);
    expect(result.status, 'archive_failed');
    expect(result.evidenceBundle, isNull);
    expect(recoveryRoot.readAsStringSync(), 'not a directory');
    expect(legacyHistory.existsSync(), isTrue);
    expect(
      analyticsStorageNotice(provider, account: account)?.tiers,
      ['history'],
    );
  });

  test('malformed analytics migration marker quarantines canonical history',
      () {
    const provider = codexProviderId;
    const account = 'acct';
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      asOf: 1782000000,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    saveSnapshot(quota);
    final marker = cacheDir().listSync().whereType<File>().singleWhere((file) =>
        file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    marker.writeAsStringSync('{not-json');

    expect(loadHistory(provider, account: account), isEmpty);
    final notice = analyticsStorageNotice(provider, account: account);
    expect(notice, isNotNull);
    expect(notice!.tiers, ['history', 'buckets']);
  });

  test('conflict retains an unambiguous provider burn fallback', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    ProviderQuota quota(int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          plan: 'pro',
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
        );
    recordHeadroomSample(provider, 90, now - 3600);
    recordHeadroomSample(provider, 80, now);
    saveSnapshot(quota(now));
    final key = quotaIdentityKey(provider, account);
    final burnBefore = recentBurnStatsByQuota([quota(now)], now);
    expect(burnBefore[key]?.perHour, closeTo(10, 0.001));

    final marker = cacheDir().listSync().whereType<File>().singleWhere((file) =>
        file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    marker.writeAsStringSync('{not-json');
    final later = now + 24 * 3600;
    final laterQuota = quota(later);
    final competitor = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'other',
      plan: 'pro',
      asOf: later,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 25)],
    );
    final burnAfter = recentBurnStatsByQuota([laterQuota], later);
    expect(burnAfter[key]?.perHour, burnBefore[key]?.perHour);
    expect(
      suggestRoute(
        [laterQuota, competitor],
        later,
        burnStatsByProvider: burnAfter,
      ).recommended?.provider,
      claudeProviderId,
    );
    expect(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      isEmpty,
    );
  });

  test('conflict cannot improve a mid-hour burn window', () {
    const provider = codexProviderId;
    const account = 'acct';
    const latestStart = 1782000000;
    const now = latestStart + 1800;
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    const headroom = [90.0, 100.0, 90.0, 80.0, 70.0, 60.0, 50.0];
    saveSnapshot(quota);
    for (var index = 0; index < headroom.length; index++) {
      recordHeadroomSample(
        provider,
        headroom[index],
        latestStart - (headroom.length - index - 1) * 3600,
        account: account,
      );
    }

    final key = quotaIdentityKey(provider, account);
    final healthy = recentBurnStatsByQuota([quota], now)[key]!;
    expect(healthy.perHour, closeTo(10, 0.001));
    expect(healthy.samples, 6);
    final aligned = burnRateWithError(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      latestStart,
    );
    expect(
      aligned.perHour,
      lessThan(healthy.perHour!),
      reason: 'the fixture must expose the former exact-hour optimism',
    );
    final competitor = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'other',
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 28)],
    );
    expect(
      suggestRoute(
        [quota, competitor],
        now,
        burnStatsByProvider: {key: healthy},
      ).recommended?.provider,
      claudeProviderId,
    );

    final marker = cacheDir().listSync().whereType<File>().singleWhere((file) =>
        file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    marker.writeAsStringSync('{not-json');

    final conflicted = recentBurnStatsByQuota([quota], now)[key]!;
    expect(conflicted.perHour, greaterThanOrEqualTo(healthy.perHour!));
    expect(conflicted.sePerHour, greaterThanOrEqualTo(healthy.sePerHour!));
    expect(conflicted.samples, lessThanOrEqualTo(healthy.samples));
    expect(
      suggestRoute(
        [quota, competitor],
        now,
        burnStatsByProvider: {key: conflicted},
      ).recommended?.provider,
      claudeProviderId,
      reason: 'quarantine must not improve the affected provider route',
    );
  });

  test('conflict remains conservative after three-provider burn pooling', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );
    final competitor = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'other',
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 26.25)],
    );
    final third = ProviderQuota(
      provider: grokProviderId,
      displayName: 'Grok',
      account: 'third',
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 60)],
    );
    const headroom = [100.0, 90.0, 80.0, 70.0, 60.0, 50.0, 40.0];
    saveSnapshot(quota);
    for (var index = 0; index < headroom.length; index++) {
      final sampledAt = now - (headroom.length - index - 1) * 3600;
      recordHeadroomSample(
        provider,
        headroom[index],
        sampledAt,
        account: account,
      );
      recordHeadroomSample(claudeProviderId, 70, sampledAt);
      recordHeadroomSample(grokProviderId, 60, sampledAt);
    }
    final quotas = [quota, competitor, third];
    final key = quotaIdentityKey(provider, account);
    final healthy = recentBurnStatsByQuota(quotas, now);
    expect(healthy[key]!.samples, 7);
    expect(
      suggestRoute(
        quotas,
        now,
        burnStatsByProvider: healthy,
      ).recommended?.provider,
      claudeProviderId,
    );

    final marker = cacheDir().listSync().whereType<File>().singleWhere((file) =>
        file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    marker.writeAsStringSync('{not-json');

    final conflicted = recentBurnStatsByQuota(quotas, now);
    expect(
        conflicted[key]!.perHour, greaterThanOrEqualTo(healthy[key]!.perHour!));
    expect(
      suggestRoute(
        quotas,
        now,
        burnStatsByProvider: conflicted,
      ).recommended?.provider,
      claudeProviderId,
      reason: 'post-pooling quarantine must not improve the affected route',
    );
  });

  test('conflict pooling does not penalize healthy route competitors', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    final quota = ProviderQuota(
      provider: provider,
      displayName: 'Codex',
      account: account,
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 30)],
    );
    final competitor = ProviderQuota(
      provider: claudeProviderId,
      displayName: 'Claude',
      account: 'other',
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 17.5)],
    );
    final third = ProviderQuota(
      provider: grokProviderId,
      displayName: 'Grok',
      account: 'third',
      plan: 'pro',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 60)],
    );
    const recovering = [12.0, 50.0, 51.0, 52.0, 53.0, 54.0, 55.0];
    const burning = [67.0, 65.0, 63.0, 61.0, 59.0, 57.0, 55.0];
    saveSnapshot(quota);
    for (var index = 0; index < recovering.length; index++) {
      final sampledAt = now - (recovering.length - index - 1) * 3600;
      recordHeadroomSample(
        provider,
        recovering[index],
        sampledAt,
        account: account,
      );
      recordHeadroomSample(claudeProviderId, burning[index], sampledAt);
      recordHeadroomSample(grokProviderId, burning[index], sampledAt);
    }
    final quotas = [quota, competitor, third];
    final key = quotaIdentityKey(provider, account);
    final competitorKey = quotaIdentityKeyFor(competitor);
    final healthy = recentBurnStatsByQuota(quotas, now);
    expect(healthy[key]!.perHour, isNegative);
    final healthySuggestion = suggestRoute(
      quotas,
      now,
      burnStatsByProvider: healthy,
    );
    expect(
      healthySuggestion.recommended?.provider,
      claudeProviderId,
      reason: 'the fixture must favor the healthy competitor before conflict',
    );

    final marker = cacheDir().listSync().whereType<File>().singleWhere((file) =>
        file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    marker.writeAsStringSync('{not-json');

    final conflicted = recentBurnStatsByQuota(quotas, now);
    expect(
        conflicted[key]!.perHour, greaterThanOrEqualTo(healthy[key]!.perHour!));
    expect(
      conflicted[competitorKey]!.perHour,
      closeTo(healthy[competitorKey]!.perHour!, 0.000001),
      reason: 'conflict uncertainty must not penalize a healthy competitor',
    );
    expect(
      suggestRoute(
        quotas,
        now,
        burnStatsByProvider: conflicted,
      ).recommended?.provider,
      claudeProviderId,
      reason: 'a recovering conflict must not improve its relative route rank',
    );
  });

  test('changed checkpoints stay visible without canonical tier files', () {
    const provider = codexProviderId;
    const account = 'acct';
    const now = 1782000000;
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    )..writeAsStringSync('${jsonEncode(quota(20, now).toJson())}\n');
    final legacyBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$account.json',
    )..writeAsStringSync(
        jsonEncode([
          (HeadroomBucket(start: bucketStart(now) - 3600)..add(90)).toJson(),
          (HeadroomBucket(start: bucketStart(now))..add(80)).toJson(),
        ]),
      );

    saveSnapshot(quota(20, now));
    recordHeadroomSample(provider, 80, now, account: account);
    final stem = accountStorageStem(account);
    final canonicalHistory = File(
      '${cacheDir().path}/history_${provider}_$stem.jsonl',
    )..deleteSync();
    final canonicalBuckets = File(
      '${cacheDir().path}/buckets_${provider}_$stem.json',
    )..deleteSync();

    legacyHistory.writeAsStringSync(
      '${jsonEncode(quota(35, now + 60).toJson())}\n',
    );
    legacyBuckets.writeAsStringSync(
      jsonEncode([
        (HeadroomBucket(start: bucketStart(now))..add(65)).toJson(),
      ]),
    );

    final notice = analyticsStorageNotice(provider, account: account);
    expect(notice, isNotNull);
    expect(notice!.tiers, ['history', 'buckets']);
    expect(loadHistory(provider, account: account), isEmpty);
    expect(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      isEmpty,
    );
    expect(
      recentBurnStatsByQuota(
        [quota(20, now)],
        now,
      )[quotaIdentityKey(provider, account)]
          ?.perHour,
      closeTo(10, 0.001),
    );

    saveSnapshot(quota(40, now + 120));
    recordHeadroomSample(provider, 60, now + 120, account: account);
    expect(canonicalHistory.existsSync(), isFalse);
    expect(canonicalBuckets.existsSync(), isFalse);
  });

  test('full retention analytics baseline fits the bounded checkpoint', () {
    const provider = codexProviderId;
    const account = 'acct';
    final now = nowEpoch();
    ProviderQuota quota(int asOf) => ProviderQuota(
          provider: provider,
          displayName: 'Codex',
          account: account,
          plan: 'pro',
          asOf: asOf,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
        );
    final legacyHistory = File(
      '${cacheDir().path}/history_${provider}_$account.jsonl',
    );
    legacyHistory.writeAsStringSync(
      '${[
        for (var index = 199; index >= 0; index--)
          jsonEncode(quota(now - index * 60).toJson()),
      ].join('\n')}\n',
    );
    final alignedNow = bucketStart(now);
    final legacyBuckets = [
      for (var index = 90 * 24 - 1; index >= 0; index--)
        HeadroomBucket(start: alignedNow - index * 3600)..add(70),
    ];
    File('${cacheDir().path}/buckets_${provider}_$account.json')
        .writeAsStringSync(
      jsonEncode(legacyBuckets.map((bucket) => bucket.toJson()).toList()),
    );

    saveSnapshot(quota(now));
    recordHeadroomSample(provider, 65, now, account: account);

    final migration = cacheDir().listSync().whereType<File>().singleWhere(
        (file) => file.uri.pathSegments.last
            .startsWith('analytics_migration_${provider}_'));
    expect(migration.lengthSync(), lessThan(1024 * 1024));
    expect(analyticsStorageNotice(provider, account: account), isNull);
    expect(
      loadBuckets(provider, account: account, fallbackToProvider: false),
      hasLength(90 * 24),
    );
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
