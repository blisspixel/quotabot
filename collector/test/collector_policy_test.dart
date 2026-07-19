import 'dart:io';

import 'package:quotabot_collector/adapters/codex.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempConfig;

  setUp(() {
    tempConfig =
        Directory.systemTemp.createTempSync('quotabot_collector_policy_test_');
    setQuotabotDirOverrideForTesting(tempConfig);
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    if (tempConfig.existsSync()) tempConfig.deleteSync(recursive: true);
  });

  test('collection hides offline local runtimes but retains provenance faults',
      () {
    ProviderQuota local({
      required bool ok,
      ProviderSourceClass sourceClass = ProviderSourceClass.localRuntime,
    }) =>
        ProviderQuota(
          provider: ollamaProviderId,
          displayName: 'Ollama',
          account: 'local',
          asOf: 1782000000,
          ok: ok,
          kind: ProviderQuotaKind.local,
          sourceClass: sourceClass,
        );

    expect(retainCollectedProviderQuota(local(ok: false)), isFalse);
    expect(retainCollectedProviderQuota(local(ok: true)), isTrue);
    expect(
      retainCollectedProviderQuota(
        local(
          ok: false,
          sourceClass: ProviderSourceClass.authoritativeLive,
        ),
      ),
      isTrue,
    );
  });

  test('wrong adapter identity cannot read or poison another provider cache',
      () {
    final now = nowEpoch();
    ProviderQuota baseline(String provider, double used) => ProviderQuota(
          provider: provider,
          displayName: provider,
          account: 'default',
          asOf: now - 60,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    saveSnapshot(baseline(claudeProviderId, 20));
    saveSnapshot(baseline(codexProviderId, 30));
    final emittedAsCodex = ProviderQuota(
      provider: codexProviderId,
      displayName: 'Codex',
      account: 'default',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
    );

    final rejected = admitRegisteredProviderObservation(
      providerAdapterById(claudeProviderId)!,
      emittedAsCodex,
      evidenceGenerationMicros: DateTime.now().microsecondsSinceEpoch + 1000,
      observedAt: now,
    );

    expect(rejected.provider, claudeProviderId);
    expect(rejected.driftReason, contains('does not match registered adapter'));
    final visible = loadCachedSnapshots(now: now);
    final claude =
        visible.singleWhere((quota) => quota.provider == claudeProviderId);
    final codex =
        visible.singleWhere((quota) => quota.provider == codexProviderId);
    expect(claude.driftReason, rejected.driftReason);
    expect(codex.driftReason, isNull);
    expect(codex.windows.single.usedPercent, 30);
  });

  test('same-account Codex parser failure serves stale shared and scoped cache',
      () async {
    final now = nowEpoch();
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'same-account-parser-failure',
    );
    final sharedReset = now + 6 * 86400;
    final sparkReset = now + 5 * 86400;
    final trusted = ProviderQuota(
      provider: codexProviderId,
      displayName: codexProviderName,
      account: account,
      plan: 'pro',
      asOf: now - 10,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 63,
          resetsAt: sharedReset,
        ),
      ],
      modelQuotas: [
        ModelQuota(
          model: 'GPT-5.3-Codex-Spark',
          usedPercent: 20,
          resetsAt: sparkReset,
          windowLabel: 'weekly',
        ),
      ],
    );
    TokenStore.saveDefaultOwnedBy(
      OpenAiAuth.provider,
      Tokens(
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        expiresAt: now + 3600,
      ),
      account,
    );
    saveSnapshot(
      trusted,
      observedAtMicros: (now - 10) * Duration.microsecondsPerSecond,
    );

    final failedRead = await CodexAdapter(
      usageCredentialIdentity: account,
      usageFetcher: () async => {
        'plan_type': 'pro',
        'rate_limit': {
          'primary_window': {
            'used_percent': 63,
            'limit_window_seconds': 604800,
            'reset_at': sharedReset,
          },
          'secondary_window': null,
        },
        'additional_rate_limits': [
          {
            'limit_name': 'GPT-5.3-Codex-Spark',
            'rate_limit': {
              'primary_window': {
                'used_percent': 0,
                'limit_window_seconds': 61,
                'reset_at': sparkReset,
              },
              'secondary_window': null,
            },
          },
        ],
      },
    ).collect();

    expect(failedRead.ok, isFalse);
    expect(failedRead.account, account);
    expect(failedRead.error, contains('invalid Codex usage response'));

    final fallback = admitRegisteredProviderObservation(
      providerAdapterById(codexProviderId)!,
      failedRead,
      evidenceGenerationMicros: DateTime.now().microsecondsSinceEpoch + 1000,
      observedAt: now,
    );

    expect(fallback.ok, isTrue);
    expect(fallback.stale, isTrue);
    expect(fallback.account, account);
    expect(fallback.error, contains('invalid Codex usage response'));
    expect(fallback.windows.single.label, 'weekly');
    expect(fallback.windows.single.usedPercent, 63);
    expect(fallback.windows.single.resetsAt, sharedReset);
    expect(fallback.modelQuotas.single.model, 'GPT-5.3-Codex-Spark');
    expect(fallback.modelQuotas.single.usedPercent, 20);
    expect(fallback.modelQuotas.single.resetsAt, sparkReset);
    expect(fallback.modelQuotas.single.windowLabel, 'weekly');
    expect(providerAvailability(fallback, now).available, isFalse);
    expect(suggestRoute([fallback], now).recommended, isNull);

    final persisted = loadAccountSnapshot(codexProviderId, account);
    expect(persisted, isNotNull);
    expect(persisted!.stale, isFalse);
    expect(persisted.error, isNull);
    expect(persisted.asOf, trusted.asOf);
    expect(persisted.windows.single.label, 'weekly');
    expect(persisted.windows.single.usedPercent, 63);
    expect(persisted.windows.single.resetsAt, sharedReset);
    expect(persisted.modelQuotas.single.model, 'GPT-5.3-Codex-Spark');
    expect(persisted.modelQuotas.single.usedPercent, 20);
    expect(persisted.modelQuotas.single.resetsAt, sparkReset);
    expect(persisted.modelQuotas.single.windowLabel, 'weekly');
  });

  test('adapter output ids must already be canonical', () {
    final now = nowEpoch();
    final noncanonical = ProviderQuota(
      provider: ' CLAUDE ',
      displayName: 'Claude',
      account: 'default',
      asOf: now,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
    );

    final rejected = admitRegisteredProviderObservation(
      providerAdapterById(claudeProviderId)!,
      noncanonical,
      evidenceGenerationMicros: DateTime.now().microsecondsSinceEpoch,
      observedAt: now,
    );

    expect(rejected.provider, claudeProviderId);
    expect(rejected.ok, isFalse);
    expect(rejected.driftReason, contains('does not match registered adapter'));
    expect(loadSnapshot(' CLAUDE '), isNull);
  });

  test('targeted live verification recovers one exact drift baseline',
      () async {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'recovery-success',
    );
    ProviderQuota quota(double used, int asOf) => ProviderQuota(
          provider: codexProviderId,
          displayName: codexProviderName,
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
    final baseline = quota(70, now - 20);
    saveSnapshot(baseline, observedAtMicros: generation - 3000);
    saveProviderDriftObservation(
      baseline,
      'weekly usage fell without a reset',
      now - 10,
      observedAtMicros: generation - 2000,
    );
    final historyBefore = loadHistory(codexProviderId, account: account);
    final fresh = quota(25, now);
    final registration = ProviderAdapterRegistration(
      id: codexProviderId,
      displayName: codexProviderName,
      adapterClass: ProviderAdapterClass.subscription,
      sourceClasses: const {ProviderSourceClass.authoritativeLive},
      collect: () async => [fresh],
      multiAccount: true,
      currentAccounts: () => {account},
      fixtureKind: ProviderFixtureKind.codexUsage,
      fixtureFile: 'codex_usage.json',
    );

    final report = await verifyAndRecoverProviderDriftBaseline(
      provider: codexProviderId,
      account: account,
      registration: registration,
      observedAt: now,
      observedAtMicros: generation,
    );

    expect(report.recovered, isTrue);
    expect(report.status, 'recovered');
    expect(report.verification?.liveReadSucceeded, isTrue);
    expect(report.verification?.passed, isTrue);
    expect(report.runtimeAccess?.collectionExecuted, isTrue);
    expect(report.toJson()['schema'], quotabotDriftRecoveryV1SchemaId);
    expect(
      loadAccountSnapshot(codexProviderId, account)?.windows.single.usedPercent,
      25,
    );
    expect(
      loadHistory(codexProviderId, account: account),
      hasLength(historyBefore.length),
    );
  });

  test('targeted recovery preflight does not read a provider without drift',
      () async {
    final now = nowEpoch();
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'recovery-without-drift',
    );
    final baseline = ProviderQuota(
      provider: codexProviderId,
      displayName: codexProviderName,
      account: account,
      plan: 'pro',
      asOf: now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 30,
          resetsAt: now + 86400,
        ),
      ],
    );
    saveSnapshot(baseline);
    var collected = false;
    final registration = ProviderAdapterRegistration(
      id: codexProviderId,
      displayName: codexProviderName,
      adapterClass: ProviderAdapterClass.subscription,
      sourceClasses: const {ProviderSourceClass.authoritativeLive},
      collect: () async {
        collected = true;
        return [baseline];
      },
      multiAccount: true,
      currentAccounts: () => {account},
      fixtureKind: ProviderFixtureKind.codexUsage,
      fixtureFile: 'codex_usage.json',
    );

    final report = await verifyAndRecoverProviderDriftBaseline(
      provider: codexProviderId,
      account: account,
      registration: registration,
      observedAt: now,
    );

    expect(report.recovered, isFalse);
    expect(report.status, 'no_active_drift');
    expect(collected, isFalse);
    expect(report.runtimeAccess, isNull);
  });

  test('targeted recovery rejects an injected observation clock outside skew',
      () async {
    final now = nowEpoch();
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'recovery-observation-clock',
    );
    final baseline = ProviderQuota(
      provider: codexProviderId,
      displayName: codexProviderName,
      account: account,
      plan: 'pro',
      asOf: now - 20,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 70,
          resetsAt: now + 86400,
        ),
      ],
    );
    saveSnapshot(baseline);
    saveProviderDriftObservation(baseline, 'active drift', now - 10);
    var collected = false;
    final registration = ProviderAdapterRegistration(
      id: codexProviderId,
      displayName: codexProviderName,
      adapterClass: ProviderAdapterClass.subscription,
      sourceClasses: const {ProviderSourceClass.authoritativeLive},
      collect: () async {
        collected = true;
        return [baseline];
      },
      multiAccount: true,
      currentAccounts: () => {account},
      fixtureKind: ProviderFixtureKind.codexUsage,
      fixtureFile: 'codex_usage.json',
    );

    for (final skewDirection in const [-1, 1]) {
      final injectedAt =
          nowEpoch() + skewDirection * (kQuotaEvidenceClockSkewSeconds + 1);
      final report = await verifyAndRecoverProviderDriftBaseline(
        provider: codexProviderId,
        account: account,
        registration: registration,
        observedAt: injectedAt,
      );

      expect(report.recovered, isFalse);
      expect(report.status, 'invalid_live_evidence');
      expect(report.detail, contains('real-clock trust boundary'));
      expect(report.runtimeAccess, isNull);
    }
    expect(collected, isFalse);
    expect(
      attachProviderDriftObservation(
        loadAccountSnapshot(codexProviderId, account)!,
        now: now,
      ).driftReason,
      'active drift',
    );
  });

  test('targeted recovery sanitizes provider text before report and cache',
      () async {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'recovery-provider-text',
    );
    final baseline = ProviderQuota(
      provider: codexProviderId,
      displayName: codexProviderName,
      account: account,
      plan: 'pro',
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
    ProviderAdapterRegistration registrationFor(ProviderQuota quota) =>
        ProviderAdapterRegistration(
          id: codexProviderId,
          displayName: codexProviderName,
          adapterClass: ProviderAdapterClass.subscription,
          sourceClasses: const {ProviderSourceClass.authoritativeLive},
          collect: () async => [quota],
          multiAccount: true,
          currentAccounts: () => {account},
          fixtureKind: ProviderFixtureKind.codexUsage,
          fixtureFile: 'codex_usage.json',
        );

    final malformed = ProviderQuota(
      provider: codexProviderId,
      displayName: 'Codex\x1b',
      account: account,
      plan: 'pro',
      asOf: now,
      windows: [
        QuotaWindow(
          label: 'week\x1bly',
          usedPercent: -1,
          resetsAt: now + 86400,
        ),
      ],
    );
    final rejected = await verifyAndRecoverProviderDriftBaseline(
      provider: codexProviderId,
      account: account,
      registration: registrationFor(malformed),
      observedAt: now,
      observedAtMicros: generation,
    );
    final boundsCheck = rejected.verification!.checks
        .singleWhere((check) => check.id == 'percent_bounds');
    expect(rejected.status, 'live_verification_failed');
    expect(stripTerminalControl(boundsCheck.detail), boundsCheck.detail);

    final valid = ProviderQuota(
      provider: codexProviderId,
      displayName: 'Codex\x1b',
      account: account,
      plan: 'pro',
      source: 'provider\x1b metadata',
      asOf: now,
      details: const ['quota\x1b detail'],
      windows: [
        QuotaWindow(
          label: 'week\x1bly',
          usedPercent: 25,
          resetsAt: now + 86400,
        ),
      ],
    );
    final recovered = await verifyAndRecoverProviderDriftBaseline(
      provider: codexProviderId,
      account: account,
      registration: registrationFor(valid),
      observedAt: now,
      observedAtMicros: generation + 1000,
    );
    final stored = loadAccountSnapshot(codexProviderId, account)!;

    expect(recovered.recovered, isTrue);
    expect(recovered.verification?.displayName, 'Codex');
    expect(stored.displayName, 'Codex');
    expect(stored.source, 'provider metadata');
    expect(stored.details.single, 'quota detail');
    expect(stored.windows.single.label, 'weekly');
  });

  test('targeted recovery records runtime access when the adapter fails',
      () async {
    final now = nowEpoch();
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'recovery-adapter-failure',
    );
    final baseline = ProviderQuota(
      provider: codexProviderId,
      displayName: codexProviderName,
      account: account,
      plan: 'pro',
      asOf: now - 20,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 70,
          resetsAt: now + 86400,
        ),
      ],
    );
    saveSnapshot(baseline);
    saveProviderDriftObservation(baseline, 'active drift', now - 10);
    final registration = ProviderAdapterRegistration(
      id: codexProviderId,
      displayName: codexProviderName,
      adapterClass: ProviderAdapterClass.subscription,
      sourceClasses: const {ProviderSourceClass.authoritativeLive},
      collect: () async => throw StateError('provider failed'),
      multiAccount: true,
      currentAccounts: () => {account},
      fixtureKind: ProviderFixtureKind.codexUsage,
      fixtureFile: 'codex_usage.json',
    );

    final report = await verifyAndRecoverProviderDriftBaseline(
      provider: codexProviderId,
      account: account,
      registration: registration,
      observedAt: now,
    );

    expect(report.recovered, isFalse);
    expect(report.status, 'live_read_failed');
    expect(report.runtimeAccess?.collectionExecuted, isTrue);
    expect(report.runtimeAccess?.providers.single.observed, isTrue);
    expect(loadAccountSnapshot(codexProviderId, account), isNotNull);
  });

  test('targeted recovery rejects failed stale and malformed live evidence',
      () async {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'recovery-rejection',
    );
    final baseline = ProviderQuota(
      provider: codexProviderId,
      displayName: codexProviderName,
      account: account,
      plan: 'pro',
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
        provider: codexProviderId,
        displayName: codexProviderName,
        account: account,
        asOf: now,
        ok: false,
        error: 'provider read failed',
      ),
      ProviderQuota(
        provider: codexProviderId,
        displayName: codexProviderName,
        account: account,
        asOf: now,
        windows: [QuotaWindow(label: 'weekly')],
      ),
      ProviderQuota(
        provider: 'co\x1bdex',
        displayName: codexProviderName,
        account: account,
        asOf: now,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 25,
            resetsAt: now + 86400,
          ),
        ],
      ),
      ProviderQuota(
        provider: codexProviderId,
        displayName: codexProviderName,
        account: account,
        asOf: now,
        sourceClass: ProviderSourceClass.thisMachineFallback,
        perMachine: true,
        windows: [
          QuotaWindow(
            label: 'weekly',
            usedPercent: 25,
            resetsAt: now + 86400,
          ),
        ],
      ),
    ];

    for (final candidate in candidates) {
      final registration = ProviderAdapterRegistration(
        id: codexProviderId,
        displayName: codexProviderName,
        adapterClass: ProviderAdapterClass.subscription,
        sourceClasses: const {ProviderSourceClass.authoritativeLive},
        collect: () async => [candidate],
        multiAccount: true,
        currentAccounts: () => {account},
        fixtureKind: ProviderFixtureKind.codexUsage,
        fixtureFile: 'codex_usage.json',
      );
      final report = await verifyAndRecoverProviderDriftBaseline(
        provider: codexProviderId,
        account: account,
        registration: registration,
        observedAt: now,
        observedAtMicros: generation,
      );

      expect(report.recovered, isFalse, reason: candidate.toJson().toString());
      expect(report.status, 'live_verification_failed');
      expect(
        loadAccountSnapshot(codexProviderId, account)
            ?.windows
            .single
            .usedPercent,
        70,
      );
      expect(
        attachProviderDriftObservation(
          loadAccountSnapshot(codexProviderId, account)!,
          now: now,
        ).driftReason,
        'active drift',
      );
    }
  });

  test('targeted recovery refuses missing and duplicate account rows',
      () async {
    final now = nowEpoch();
    final generation = DateTime.now().microsecondsSinceEpoch;
    final account = opaqueCredentialIdentity(
      codexProviderId,
      'recovery-selection',
    );
    ProviderQuota quota(String target) => ProviderQuota(
          provider: codexProviderId,
          displayName: codexProviderName,
          account: target,
          plan: 'pro',
          asOf: now,
          windows: [
            QuotaWindow(
              label: 'weekly',
              usedPercent: 25,
              resetsAt: now + 86400,
            ),
          ],
        );
    final baseline = quota(account);
    saveSnapshot(
      ProviderQuota(
        provider: baseline.provider,
        displayName: baseline.displayName,
        account: baseline.account,
        plan: baseline.plan,
        asOf: now - 20,
        windows: baseline.windows,
      ),
      observedAtMicros: generation - 3000,
    );
    saveProviderDriftObservation(
      loadAccountSnapshot(codexProviderId, account)!,
      'active drift',
      now - 10,
      observedAtMicros: generation - 2000,
    );

    ProviderAdapterRegistration registrationFor(List<ProviderQuota> rows) =>
        ProviderAdapterRegistration(
          id: codexProviderId,
          displayName: codexProviderName,
          adapterClass: ProviderAdapterClass.subscription,
          sourceClasses: const {ProviderSourceClass.authoritativeLive},
          collect: () async => rows,
          multiAccount: true,
          currentAccounts: () => {account},
          fixtureKind: ProviderFixtureKind.codexUsage,
          fixtureFile: 'codex_usage.json',
        );

    final missing = await verifyAndRecoverProviderDriftBaseline(
      provider: codexProviderId,
      account: account,
      registration: registrationFor([quota('different-account')]),
      observedAt: now,
      observedAtMicros: generation,
    );
    expect(missing.status, 'target_not_returned');
    expect(missing.runtimeAccess?.collectionExecuted, isTrue);

    final duplicate = await verifyAndRecoverProviderDriftBaseline(
      provider: codexProviderId,
      account: account,
      registration: registrationFor([quota(account), quota(account)]),
      observedAt: now,
      observedAtMicros: generation,
    );
    expect(duplicate.status, 'ambiguous_live_read');
    expect(duplicate.runtimeAccess?.collectionExecuted, isTrue);
    expect(loadAccountSnapshot(codexProviderId, account), isNotNull);
  });
}
