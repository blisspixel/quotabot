import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

void main() {
  group('QuotaWindow', () {
    test('uses usedPercent directly when present', () {
      expect(QuotaWindow(label: '5h', usedPercent: 42).percent, 42);
    });

    test('derives percent from used and limit', () {
      expect(QuotaWindow(label: 'w', used: 30, limit: 120).percent, 25);
    });

    test('returns null percent with no usable inputs', () {
      expect(QuotaWindow(label: 'w').percent, isNull);
      expect(QuotaWindow(label: 'w', used: 5, limit: 0).percent, isNull);
    });

    test(
        'percent is left unclamped so the trust boundary can flag out-of-range',
        () {
      // used > limit (>100%) and negative values must survive to verify/drift,
      // which reject or flag them rather than route on them; clamping here would
      // hide that. Display-time consumers clamp separately (windowUsedPercent).
      expect(QuotaWindow(label: 'w', used: 1050, limit: 1000).percent, 105);
    });

    test('exhausted at or above the shared spent headroom floor', () {
      expect(QuotaWindow(label: 'w', usedPercent: 100).exhausted, isTrue);
      expect(QuotaWindow(label: 'w', usedPercent: 98.6).exhausted, isTrue);
      expect(QuotaWindow(label: 'w', usedPercent: 98.4).exhausted, isFalse);
      expect(QuotaWindow(label: 'w', usedPercent: 90).exhausted, isFalse);
      expect(QuotaWindow(label: 'w', usedPercent: -1).exhausted, isTrue);
      expect(QuotaWindow(label: 'w', usedPercent: 101).exhausted, isTrue);
    });

    test('toJson omits null fields', () {
      final json = QuotaWindow(
        label: '5h',
        usedPercent: 7,
        resetsAt: 100,
      ).toJson();
      expect(json, {'label': '5h', 'used_percent': 7, 'resets_at': 100});
      expect(json.containsKey('used'), isFalse);
    });

    test('round-trips through json', () {
      final w = QuotaWindow(label: 'w', used: 3, limit: 10, resetsAt: 50);
      final back = QuotaWindow.fromJson(w.toJson());
      expect(back.used, 3);
      expect(back.limit, 10);
      expect(back.resetsAt, 50);
    });

    test('fromJson drops non-finite numbers from a corrupt cache file', () {
      // 1e400 decodes to Infinity; left raw, it survives to crash jsonEncode.
      final w = QuotaWindow.fromJson({
        'label': '5h',
        'used_percent': double.infinity,
        'used': double.nan,
        'limit': double.negativeInfinity,
        'resets_at': double.infinity,
      });
      expect(w.usedPercent, isNull);
      expect(w.used, isNull);
      expect(w.limit, isNull);
      expect(w.resetsAt, isNull);
      expect(() => jsonEncode(w.toJson()), returnsNormally);
    });

    test('fromJson preserves finite invalid percents for trust validation', () {
      final high = QuotaWindow.fromJson({'label': 'w', 'used_percent': 250});
      final negative =
          QuotaWindow.fromJson({'label': 'w', 'used_percent': -25});

      expect(high.usedPercent, 250);
      expect(negative.usedPercent, -25);
    });
  });

  group('ModelQuota', () {
    test('preserves provider window identity through JSON and sanitization',
        () {
      const quota = ModelQuota(
        model: 'GPT-5.3-Codex-Spark',
        usedPercent: 20,
        resetsAt: 2000,
        windowLabel: 'weekly',
      );

      expect(quota.toJson()['window_label'], 'weekly');
      expect(ModelQuota.fromJson(quota.toJson()).windowLabel, 'weekly');

      final provider = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'opaque',
        asOf: 1000,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
        modelQuotas: const [quota],
      );
      expect(
        sanitizeProviderQuota(provider).modelQuotas.single.windowLabel,
        'weekly',
      );
    });
  });

  group('ProviderQuota', () {
    test('plan evidence provenance round-trips and survives safe copies', () {
      final q = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'opaque',
        plan: 'max',
        planEvidenceSource: ProviderPlanEvidenceSource.providerMetadata,
        planEvidenceAsOf: 1000,
        asOf: 1000,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
      );

      final json = q.toJson();
      expect(json['plan_evidence_source'], 'provider_metadata');
      expect(json['plan_evidence_as_of'], 1000);
      final decoded = ProviderQuota.fromJson(json);
      expect(
        decoded.planEvidenceSource,
        ProviderPlanEvidenceSource.providerMetadata,
      );
      expect(decoded.planEvidenceAsOf, 1000);
      expect(
        sanitizeProviderQuota(q).planEvidenceSource,
        ProviderPlanEvidenceSource.providerMetadata,
      );
      expect(
        q.withSuspect('review').planEvidenceAsOf,
        1000,
      );
      expect(
        q.withProviderDrift('changed', 1001).planEvidenceAsOf,
        1000,
      );

      final corrupt = ProviderQuota.fromJson({
        ...json,
        'plan_evidence_source': 'unknown_source',
      });
      expect(corrupt.planEvidenceSource, isNull);
      expect(corrupt.planEvidenceAsOf, isNull);
      expect(corrupt.toJson().containsKey('plan_evidence_source'), isFalse);
      expect(corrupt.toJson().containsKey('plan_evidence_as_of'), isFalse);
    });

    test('error factory marks not ok with no windows', () {
      final q = ProviderQuota.error(
        'grok',
        'Grok',
        'boom',
        99,
        pipeHealth: providerPipeHealthThrottled,
        httpStatus: 429,
        retryAfterSeconds: 60,
      );
      expect(q.ok, isFalse);
      expect(q.error, 'boom');
      expect(q.hasWindows, isFalse);
      expect(q.toJson()['pipe_health'], providerPipeHealthThrottled);
      expect(q.toJson()['http_status'], 429);
      expect(q.toJson()['retry_after_seconds'], 60);
      final decoded = ProviderQuota.fromJson(q.toJson());
      expect(decoded.pipeHealth, providerPipeHealthThrottled);
      expect(decoded.httpStatus, 429);
      expect(decoded.retryAfterSeconds, 60);
    });

    test('sanitize preserves a cloud-offloaded model flag', () {
      // sanitizeProviderQuota runs on every collected snapshot; dropping this
      // flag would reset a cloud-offloaded model to on-device and let a billable
      // -cloud model satisfy --budget=local and free budgets.
      final q = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'local',
        asOf: 1000,
        kind: ProviderQuotaKind.local,
        models: const [
          ModelInfo(
              id: 'qwen3-coder:480b-cloud', local: true, cloudOffloaded: true),
        ],
      );
      expect(sanitizeProviderQuota(q).models.single.cloudOffloaded, isTrue);
    });

    test('local hardware evidence round-trips and survives sanitization', () {
      const gib = 1024 * 1024 * 1024;
      final q = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'local',
        asOf: 1000,
        kind: ProviderQuotaKind.local,
        localHardware: const LocalHardwareInfo(
          asOf: 999,
          systemMemoryTotalBytes: 32 * gib,
          systemMemoryAvailableBytes: 20 * gib,
          gpuMemoryTotalBytes: 12 * gib,
          gpuMemoryAvailableBytes: 8 * gib,
          gpuCount: 1,
        ),
      );

      final decoded = ProviderQuota.fromJson(q.toJson());
      final sanitized = sanitizeProviderQuota(q);

      expect(decoded.localHardware?.systemMemoryTotalBytes, 32 * gib);
      expect(decoded.localHardware?.gpuMemoryAvailableBytes, 8 * gib);
      expect(decoded.localHardware?.gpuCount, 1);
      expect(sanitized.localHardware?.asOf, 999);
    });

    test('local hardware parsing bounds malformed capacity metadata', () {
      final hardware = LocalHardwareInfo.fromJson({
        'as_of': -1,
        'system_memory_total_bytes': 100,
        'system_memory_available_bytes': 200,
        'gpu_memory_total_bytes': 'large',
        'gpu_count': 1000,
      });

      expect(hardware.asOf, 0);
      expect(hardware.systemMemoryTotalBytes, 100);
      expect(hardware.systemMemoryAvailableBytes, isNull);
      expect(hardware.gpuMemoryTotalBytes, isNull);
      expect(hardware.gpuCount, 0);
    });

    test('subscription provenance rejects attached local hardware evidence',
        () {
      final q = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'default',
        asOf: 1000,
        localHardware: const LocalHardwareInfo(
          asOf: 1000,
          systemMemoryTotalBytes: 1024,
        ),
      );

      expect(
        q.sourceClassViolation,
        'local hardware evidence requires kind=local',
      );
    });

    test('reset credits round-trip and drive the escape-hatch message', () {
      final q = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'pro',
        asOf: 1000,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 100)],
        resetCreditsAvailable: 2,
      );
      expect(q.toJson()['reset_credits_available'], 2);
      expect(ProviderQuota.fromJson(q.toJson()).resetCreditsAvailable, 2);
      expect(sanitizeProviderQuota(q).resetCreditsAvailable, 2);
      expect(resetAvailableMessage(q), contains('2 resets available in Codex'));
    });

    test('the escape-hatch message is omitted from stale or drifted evidence',
        () {
      final fresh = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'pro',
        asOf: 1000,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 100)],
        resetCreditsAvailable: 2,
      );
      // A redeemable-reset claim must not be asserted from non-fresh data.
      expect(resetAvailableMessage(fresh.asStale('cached')), isNull);
      expect(
        resetAvailableMessage(fresh.withProviderDrift('weekly drift', 1001)),
        isNull,
      );
      // The guard does not depend on withSuspect zeroing the field: a suspect
      // quota that still carries the count is suppressed by the message guard.
      expect(
        resetAvailableMessage(
          ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'pro',
            asOf: 1000,
            windows: [QuotaWindow(label: 'weekly', usedPercent: 100)],
            suspect: 'plausibility flagged',
            resetCreditsAvailable: 2,
          ),
        ),
        isNull,
      );
      // toJson omits the field when zero.
      expect(
        ProviderQuota(
          provider: 'codex',
          displayName: 'Codex',
          account: 'pro',
          asOf: 1000,
        ).toJson().containsKey('reset_credits_available'),
        isFalse,
      );
    });

    test('asStale preserves windows, capture time, and kind', () {
      final q = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'pro',
        asOf: 1000,
        kind: ProviderQuotaKind.local,
        windows: [QuotaWindow(label: '5h', usedPercent: 10)],
      );
      final stale = q.asStale('cached');
      expect(stale.stale, isTrue);
      expect(stale.asOf, 1000);
      expect(stale.error, 'cached');
      expect(stale.hasWindows, isTrue);
      expect(stale.kind, ProviderQuotaKind.local);
    });

    test('asStale can preserve cached windows with fresh metadata', () {
      final cached = ProviderQuota(
        provider: 'antigravity',
        displayName: 'Antigravity',
        account: 'blisspixel@gmail.com',
        plan: 'Antigravity',
        asOf: 1000,
        status: 'old status',
        windows: [QuotaWindow(label: '5h', usedPercent: 20)],
      );
      final fresh = ProviderQuota(
        provider: 'antigravity',
        displayName: 'Antigravity',
        account: 'blisspixel@gmail.com',
        plan: 'Google AI Pro',
        asOf: 2000,
        status: 'Gemini 3.1 Pro (High)',
        details: const ['Local Antigravity status reports higher rate limits'],
      );

      final stale =
          cached.asStale('fresh metadata, cached quota', metadataFrom: fresh);

      expect(stale.stale, isTrue);
      expect(stale.asOf, 1000);
      expect(stale.plan, 'Google AI Pro');
      expect(stale.status, 'Gemini 3.1 Pro (High)');
      expect(stale.details, fresh.details);
      expect(stale.windows.single.usedPercent, 20);
      expect(stale.error, 'fresh metadata, cached quota');
    });

    test('asStale carries fresh native pipe-health diagnostics', () {
      final cached = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'max',
        asOf: 1000,
        windows: [QuotaWindow(label: '5h', usedPercent: 20)],
      );
      final freshError = ProviderQuota.error(
        'claude',
        'Claude',
        'HTTP 429',
        2000,
        pipeHealth: providerPipeHealthThrottled,
        httpStatus: 429,
        retryAfterSeconds: 120,
      );

      final stale = cached.asStale('HTTP 429', metadataFrom: freshError);

      expect(stale.stale, isTrue);
      expect(stale.account, 'max');
      expect(stale.windows.single.usedPercent, 20);
      expect(stale.pipeHealth, providerPipeHealthThrottled);
      expect(stale.httpStatus, 429);
      expect(stale.retryAfterSeconds, 120);
    });

    test('defaults to subscription kind and exposes isLocal', () {
      final sub = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'a',
        asOf: 0,
      );
      expect(sub.kind, ProviderQuotaKind.subscription);
      expect(sub.isLocal, isFalse);
      final local = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'local',
        asOf: 0,
        kind: ProviderQuotaKind.local,
      );
      expect(local.isLocal, isTrue);
      expect(local.toJson()['kind'], providerQuotaLocalKind);
      expect(ProviderQuotaKind.fromWire(providerQuotaLocalKind),
          ProviderQuotaKind.local);
      expect(ProviderQuotaKind.fromWire(null), ProviderQuotaKind.subscription);
      expect(
        () => ProviderQuotaKind.fromWire('future-kind'),
        throwsFormatException,
      );
    });

    test('manual source exposes isManual while preserving the wire value', () {
      final q = ProviderQuota(
        provider: 'manual-ai',
        displayName: 'Manual AI',
        account: 'default',
        asOf: 0,
        source: providerQuotaManualSource,
      );

      expect(q.isManual, isTrue);
      expect(q.toJson()['source'], 'manual');
      expect(ProviderQuota.fromJson(q.toJson()).isManual, isTrue);
    });

    test('round-trips every normalized source class', () {
      expect(
        ProviderSourceClass.values.map((value) => value.wireName),
        ProviderSourceClass.wireValues,
      );
      for (final sourceClass in ProviderSourceClass.values) {
        final isLocal = sourceClass == ProviderSourceClass.localRuntime;
        final isManual = sourceClass == ProviderSourceClass.manual;
        final machineScoped = sourceClass.isMachineScoped;
        final q = ProviderQuota(
          provider: isLocal ? 'ollama' : 'custom',
          displayName: 'Provider',
          account: 'default',
          asOf: 1,
          source: isManual ? providerQuotaManualSource : null,
          sourceClass: sourceClass,
          kind: isLocal
              ? ProviderQuotaKind.local
              : ProviderQuotaKind.subscription,
          perMachine: machineScoped,
        );

        expect(q.toJson()['source_class'], sourceClass.wireName);
        expect(ProviderQuota.fromJson(q.toJson()).sourceClass, sourceClass);
      }
    });

    test('infers legacy source classes without upgrading weak evidence', () {
      ProviderQuota legacy(String provider,
              {String? source,
              String kind = providerQuotaSubscriptionKind,
              bool perMachine = false}) =>
          ProviderQuota.fromJson({
            'provider': provider,
            'display_name': provider,
            'account': 'default',
            'source': source,
            'kind': kind,
            'per_machine': perMachine,
            'as_of': 1,
            'windows': const <Map<String, Object?>>[],
          });

      expect(
          legacy('claude').sourceClass, ProviderSourceClass.authoritativeLive);
      expect(legacy('codex', perMachine: true).sourceClass,
          ProviderSourceClass.thisMachineFallback);
      expect(legacy('cursor').sourceClass,
          ProviderSourceClass.passiveLocalEvidence);
      expect(legacy('ollama', kind: providerQuotaLocalKind).sourceClass,
          ProviderSourceClass.localRuntime);
      expect(legacy('nvidia').sourceClass, ProviderSourceClass.statusOnly);
      expect(legacy('custom', source: providerQuotaManualSource).sourceClass,
          ProviderSourceClass.manual);
      expect(
        () => legacy('custom'),
        throwsFormatException,
        reason: 'legacy inference must not admit an unregistered provider',
      );
    });

    test('rejects an explicit unknown source class', () {
      expect(
        () => ProviderQuota.fromJson({
          'provider': 'claude',
          'display_name': 'Claude',
          'account': 'default',
          'source_class': 'future_class',
          'as_of': 1,
          'windows': const <Map<String, Object?>>[],
        }),
        throwsFormatException,
      );
    });

    test('round-trips through json', () {
      final q = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'max',
        plan: 'max',
        asOf: 123,
        windows: [QuotaWindow(label: '5h', usedPercent: 18, resetsAt: 456)],
      );
      final back = ProviderQuota.fromJson(q.toJson());
      expect(back.provider, 'claude');
      expect(back.plan, 'max');
      expect(back.asOf, 123);
      expect(back.kind, ProviderQuotaKind.subscription);
      expect(back.windows.single.usedPercent, 18);
    });

    test('classifies reliable native HTTP pipe-health statuses', () {
      expect(providerPipeHealthForHttpStatus(429), providerPipeHealthThrottled);
      expect(providerPipeHealthForHttpStatus(503), providerPipeHealthDegraded);
      expect(providerPipeHealthForHttpStatus(529), providerPipeHealthDegraded);
      expect(providerPipeHealthForHttpStatus(401), isNull);
      expect(providerPipeHealthForHttpStatus(404), isNull);
    });

    test('classifies a read timeout as throttled, other errors as unknown', () {
      expect(
        providerPipeHealthForReadError(
          TimeoutException('read', const Duration(seconds: 10)),
        ),
        providerPipeHealthThrottled,
      );
      expect(
        providerPipeHealthForReadError(const SocketException('refused')),
        isNull,
      );
      expect(
          providerPipeHealthForReadError(const FormatException('bad')), isNull);
    });

    test('drops malformed cached native pipe-health diagnostics', () {
      final q = ProviderQuota.fromJson({
        'provider': 'claude',
        'display_name': 'Claude',
        'account': 'max',
        'kind': providerQuotaSubscriptionKind,
        'ok': false,
        'as_of': 1000,
        'stale': false,
        'pipe_health': 'overheated',
        'http_status': 99,
        'retry_after_seconds': -1,
        'windows': const <Map<String, Object?>>[],
      });

      expect(q.pipeHealth, isNull);
      expect(q.httpStatus, isNull);
      expect(q.retryAfterSeconds, isNull);
      expect(q.toJson().containsKey('pipe_health'), isFalse);
      expect(q.toJson().containsKey('http_status'), isFalse);
      expect(q.toJson().containsKey('retry_after_seconds'), isFalse);
    });

    test('round-trips local kind through json', () {
      final q = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: '3 models',
        plan: 'local',
        kind: ProviderQuotaKind.local,
        asOf: 1,
        windows: [QuotaWindow(label: 'local', usedPercent: 0)],
      );
      expect(q.toJson()['kind'], providerQuotaLocalKind);
      expect(ProviderQuota.fromJson(q.toJson()).kind, ProviderQuotaKind.local);
    });
  });
}
