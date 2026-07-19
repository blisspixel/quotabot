import 'dart:io';

import 'package:quotabot_collector/adapters/codex.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/collector.dart';
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
}
