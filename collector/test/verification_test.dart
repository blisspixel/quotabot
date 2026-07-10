import 'package:quotabot_collector/collector.dart';
import 'package:test/test.dart';

void main() {
  const now = 1782000000;

  ProviderQuota healthy({
    String provider = 'claude',
    String displayName = 'Claude',
    String account = 'work@example.com',
  }) =>
      ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: account,
        asOf: now - 5,
        windows: [
          QuotaWindow(label: '5h', usedPercent: 24, resetsAt: now + 3 * 3600),
          QuotaWindow(
              label: 'weekly', usedPercent: 41, resetsAt: now + 3 * 86400),
        ],
      );

  VerifyCheck checkById(ProviderVerification p, String id) =>
      p.checks.firstWhere((c) => c.id == id);

  group('verifyState', () {
    test('maps each snapshot shape to its stable state id', () {
      expect(verifyState(healthy(), now), 'live');
      expect(
        verifyState(
          ProviderQuota(
            provider: 'ollama',
            displayName: 'Ollama',
            account: '2 models',
            kind: ProviderQuotaKind.local,
            asOf: now,
          ),
          now,
        ),
        'local',
      );
      expect(
        verifyState(
          ProviderQuota.error('grok', 'Grok', 'no ~/.grok/auth.json', now),
          now,
        ),
        'error',
      );
      expect(
        verifyState(
          ProviderQuota(
            provider: 'kiro',
            displayName: 'Kiro',
            account: 'installed',
            asOf: now,
          ),
          now,
        ),
        'no_data',
      );
      expect(
        verifyState(healthy().asStale('token expired'), now),
        'cached',
      );
      expect(
        verifyState(
          healthy().withProviderDrift('5h usage fell with no reset', now - 30),
          now,
        ),
        'cached',
        reason: 'the state describes the trusted windows; the additive check '
            'describes why they are stale',
      );
      expect(
        verifyState(
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'default',
            asOf: now,
            windows: [
              QuotaWindow(label: '5h', usedPercent: 98.6, resetsAt: now + 1200),
            ],
          ),
          now,
        ),
        'out_of_quota',
      );
    });
  });

  group('buildVerificationReport provider checks', () {
    test('a healthy live snapshot passes every check', () {
      final report = buildVerificationReport(
        [healthy()],
        now,
        os: 'windows',
        filtered: true,
      );
      final p = report.providers.single;
      expect(p.state, 'live');
      expect(p.passed, isTrue);
      expect(p.stalenessSeconds, 5);
      expect(p.crossCheck, contains('/usage'));
      expect(checkById(p, 'reset_sanity').status, VerifyStatus.pass);
      expect(report.passed, isTrue);
    });

    test('provider drift fails distinctly while preserving trusted windows',
        () {
      final drifted = healthy().withProviderDrift(
        '5h usage fell 60% to 10% with no reset',
        now - 30,
      );
      final report = buildVerificationReport(
        [drifted],
        now,
        os: 'windows',
        filtered: true,
      );

      final provider = report.providers.single;
      expect(provider.state, 'cached');
      expect(provider.driftReason, contains('usage fell'));
      expect(provider.driftObservedAt, now - 30);
      expect(provider.windows, hasLength(2));
      expect(provider.passed, isFalse);
      final check = checkById(provider, 'provider_drift');
      expect(check.status, VerifyStatus.fail);
      expect(check.detail, contains('last trusted snapshot'));
      expect(report.passed, isFalse);
    });

    test('legacy provider drift fails with no trusted windows', () {
      final quarantined = healthy()
          .withSuspect('legacy usage concern')
          .asProviderDriftQuarantine(
            'unresolved legacy provider drift: legacy usage concern',
            now - 30,
          );
      final report = buildVerificationReport(
        [quarantined],
        now,
        os: 'windows',
        filtered: true,
      );

      final provider = report.providers.single;
      final check = checkById(provider, 'provider_drift');
      expect(provider.state, 'error');
      expect(provider.windows, isEmpty);
      expect(provider.passed, isFalse);
      expect(check.detail, contains('no trusted snapshot is available'));
    });

    test('blank provider drift reason fails instead of passing silently', () {
      final malformed = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'work@example.com',
        asOf: now,
        stale: true,
        error: 'provider drift detected',
        driftReason: '   ',
        driftObservedAt: now - 30,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
      );
      final report = buildVerificationReport(
        [malformed],
        now,
        os: 'windows',
        filtered: true,
      );

      final check = checkById(report.providers.single, 'provider_drift');
      expect(check.status, VerifyStatus.fail);
      expect(check.detail, contains('reason is blank'));
      expect(report.passed, isFalse);
    });

    test('a truthful failure passes read_or_reason', () {
      final report = buildVerificationReport(
        [ProviderQuota.error('grok', 'Grok', 'no ~/.grok/auth.json', now)],
        now,
        os: 'linux',
        filtered: true,
      );
      final p = report.providers.single;
      expect(p.state, 'error');
      expect(p.passed, isTrue);
      expect(checkById(p, 'read_or_reason').detail,
          contains('no ~/.grok/auth.json'));
    });

    test('a failure without an error note fails read_or_reason', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'grok',
            displayName: 'Grok',
            account: 'unknown',
            asOf: now,
            ok: false,
          ),
        ],
        now,
        os: 'linux',
        filtered: true,
      );
      final p = report.providers.single;
      expect(p.passed, isFalse);
      expect(checkById(p, 'read_or_reason').status, VerifyStatus.fail);
    });

    test('a label-only quota window fails usable-percent verification', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'default',
            asOf: now,
            windows: [QuotaWindow(label: 'weekly', resetsAt: now + 3600)],
          ),
        ],
        now,
        os: 'windows',
        filtered: true,
      );

      final check = checkById(report.providers.single, 'percent_bounds');
      expect(check.status, VerifyStatus.fail);
      expect(check.detail, contains('no usable percent'));
      expect(report.passed, isFalse);
    });

    test('an ok subscription with no windows and no reason fails', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'kiro',
            displayName: 'Kiro',
            account: 'installed',
            asOf: now,
          ),
        ],
        now,
        os: 'macos',
        filtered: true,
      );
      expect(
        checkById(report.providers.single, 'read_or_reason').status,
        VerifyStatus.fail,
      );
    });

    test('an ok subscription with no windows but a status note passes', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'kiro',
            displayName: 'Kiro',
            account: 'installed',
            asOf: now,
            status: 'installed, no readable quota state',
          ),
        ],
        now,
        os: 'macos',
        filtered: true,
      );
      expect(
        checkById(report.providers.single, 'read_or_reason').status,
        VerifyStatus.pass,
      );
    });

    test('out-of-bounds percentages fail percent_bounds', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'default',
            asOf: now,
            windows: [
              QuotaWindow(label: '5h', usedPercent: 140),
              QuotaWindow(label: 'raw', used: -2, limit: 0),
            ],
          ),
        ],
        now,
        os: 'windows',
        filtered: true,
      );
      final check = checkById(report.providers.single, 'percent_bounds');
      expect(check.status, VerifyStatus.fail);
      expect(check.detail, contains('5h percent 140'));
      expect(check.detail, contains('raw used -2'));
      expect(check.detail, contains('raw limit 0'));
    });

    test('a future as_of beyond clock skew fails as_of_sane', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'default',
            asOf: now + kVerifyClockSkewSeconds + 60,
            windows: [QuotaWindow(label: '5h', usedPercent: 10)],
          ),
        ],
        now,
        os: 'windows',
        filtered: true,
      );
      expect(
        checkById(report.providers.single, 'as_of_sane').status,
        VerifyStatus.fail,
      );
    });

    test('a zero as_of fails as_of_sane', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'default',
            asOf: 0,
            windows: [QuotaWindow(label: '5h', usedPercent: 10)],
          ),
        ],
        now,
        os: 'windows',
        filtered: true,
      );
      final p = report.providers.single;
      expect(checkById(p, 'as_of_sane').status, VerifyStatus.fail);
      expect(p.stalenessSeconds, isNull);
    });

    test('a labeled stale snapshot passes and an unlabeled one fails', () {
      final labeled = buildVerificationReport(
        [healthy().asStale('token expired (re-run claude)')],
        now,
        os: 'windows',
        filtered: true,
      ).providers.single;
      expect(labeled.state, 'cached');
      expect(checkById(labeled, 'stale_honesty').status, VerifyStatus.pass);

      final unlabeled = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'claude',
            displayName: 'Claude',
            account: 'work@example.com',
            asOf: now - 3600,
            stale: true,
            windows: [QuotaWindow(label: '5h', usedPercent: 24)],
          ),
        ],
        now,
        os: 'windows',
        filtered: true,
      ).providers.single;
      expect(checkById(unlabeled, 'stale_honesty').status, VerifyStatus.fail);
    });

    test('reset edge is an info, an implausible reset is a failure', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'default',
            asOf: now,
            windows: [
              QuotaWindow(label: '5h', usedPercent: 100, resetsAt: now - 60),
              QuotaWindow(
                label: 'weekly',
                usedPercent: 10,
                resetsAt: now + kVerifyMaxResetHorizonSeconds + 86400,
              ),
            ],
          ),
        ],
        now,
        os: 'windows',
        filtered: true,
      );
      final p = report.providers.single;
      final resets = p.checks.where((c) => c.id == 'reset_sanity').toList();
      expect(resets.map((c) => c.status),
          containsAll([VerifyStatus.info, VerifyStatus.fail]));
      expect(p.passed, isFalse);
    });
  });

  group('buildVerificationReport fleet checks', () {
    VerifyCheck fleet(VerificationReport r, String id) =>
        r.fleetChecks.firstWhere((c) => c.id == id);

    test('an unfiltered read records every claimed provider', () {
      final report = buildVerificationReport([healthy()], now, os: 'windows');
      final ids = report.providers.map((p) => p.provider).toSet();
      for (final entry in kProviderAdapterRegistry) {
        expect(ids, contains(entry.id));
      }
      final ollama = report.providers.firstWhere((p) => p.provider == 'ollama');
      expect(ollama.state, 'undetected');
      expect(ollama.passed, isTrue);
      final codex = report.providers.firstWhere((p) => p.provider == 'codex');
      expect(codex.state, 'undetected');
      expect(codex.passed, isFalse,
          reason: 'a claimed subscription that produced no snapshot at all '
              'is a coverage failure, not a truthful absence');
    });

    test('a filtered read skips coverage and says so', () {
      final report = buildVerificationReport(
        [healthy()],
        now,
        os: 'windows',
        filtered: true,
      );
      expect(report.providers, hasLength(1));
      expect(fleet(report, 'claimed_coverage').status, VerifyStatus.info);
    });

    test('the live snapshot is validated against quotabot.v1', () {
      final report = buildVerificationReport(
        [healthy()],
        now,
        os: 'windows',
        filtered: true,
      );
      expect(fleet(report, 'schema_contract').status, VerifyStatus.pass);
    });

    test('duplicate provider/account pairs fail unique_accounts', () {
      final report = buildVerificationReport(
        [healthy(), healthy()],
        now,
        os: 'windows',
        filtered: true,
      );
      final check = fleet(report, 'unique_accounts');
      expect(check.status, VerifyStatus.fail);
      expect(check.detail, contains('claude/work@example.com'));
      expect(report.passed, isFalse);
    });

    test('manual entries are noted as self-reported, never failed', () {
      final report = buildVerificationReport(
        [
          ProviderQuota(
            provider: 'tabnine',
            displayName: 'Tabnine',
            account: 'default',
            source: providerQuotaManualSource,
            asOf: now,
            windows: [
              QuotaWindow(label: 'monthly', used: 10, limit: 100),
            ],
          ),
        ],
        now,
        os: 'windows',
        filtered: true,
      );
      expect(fleet(report, 'manual_entries').status, VerifyStatus.info);
      expect(report.passed, isTrue);
    });
  });

  group('quotabot.verify.v1 JSON', () {
    test('carries schema id, os, verdicts, and per-check details', () {
      final report = buildVerificationReport(
        [healthy()],
        now,
        os: 'linux',
        filtered: true,
      );
      final json = report.toJson();
      expect(json['schema'], quotabotVerifyV1SchemaId);
      expect(json['generated_at'], now);
      expect(json['os'], 'linux');
      expect(json['passed'], isTrue);
      final provider = (json['providers'] as List).single as Map;
      expect(provider['provider'], 'claude');
      expect(provider['state'], 'live');
      expect(provider['passed'], isTrue);
      expect(provider['cross_check'], isNotEmpty);
      final windows = provider['windows'] as List;
      expect(windows, hasLength(2));
      final first = windows.first as Map;
      expect(first['resets_in_seconds'], 3 * 3600);
      final checks = provider['checks'] as List;
      expect(checks, isNotEmpty);
      for (final c in checks) {
        expect((c as Map)['detail'], isNotEmpty);
      }
      expect(json['fleet_checks'], isNotEmpty);
    });

    test('can attach a runtime access observation with a boundary check', () {
      final runtimeAccess = buildRuntimeAccessReport(
        generatedAt: now,
        includeReads: true,
        includeNetwork: true,
        observedProviderIds: const {'claude'},
        collectionExecuted: true,
        environment: const {'HOME': '/home/tester'},
        os: 'linux',
      );
      final report = buildVerificationReport(
        [healthy()],
        now,
        os: 'linux',
        filtered: true,
        runtimeAccess: runtimeAccess,
      );

      final access = report.toJson()['runtime_access'] as Map;
      expect(access['mode'], 'runtime_access_observation');
      expect(access['collection_executed'], isTrue);
      expect((access['providers'] as List).single['provider'], 'claude');
      final runtimeCheck = report.fleetChecks.firstWhere(
        (c) => c.id == 'runtime_access_boundary',
      );
      expect(runtimeCheck.status, VerifyStatus.pass);
      expect(runtimeCheck.detail, contains('no prompts'));
      expect(runtimeCheck.detail, contains('token spend'));
    });

    test('flags generation-looking runtime network endpoints', () {
      final runtimeAccess = buildRuntimeAccessReport(
        generatedAt: now,
        includeReads: true,
        includeNetwork: true,
        providers: const [
          ProviderRuntimeAccess(
            provider: 'bad',
            displayName: 'Bad',
            kind: 'subscription',
            network: [
              RuntimeAccessRecord(
                kind: RuntimeAccessKind.network,
                target: 'https://example.invalid/v1/messages',
                method: 'POST',
                scheme: 'https',
                host: 'example.invalid',
                path: '/v1/messages',
                purpose: 'bad generation call',
                dataClass: 'unknown',
                access: 'request',
              ),
            ],
          ),
        ],
        collectionExecuted: true,
        os: 'linux',
      );
      final report = buildVerificationReport(
        [healthy()],
        now,
        os: 'linux',
        filtered: true,
        runtimeAccess: runtimeAccess,
      );

      final runtimeCheck = report.fleetChecks.firstWhere(
        (c) => c.id == 'runtime_access_boundary',
      );
      expect(runtimeCheck.status, VerifyStatus.fail);
      expect(runtimeCheck.detail, contains('generation endpoint'));
    });
  });
}
