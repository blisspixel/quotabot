import 'dart:io';

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
