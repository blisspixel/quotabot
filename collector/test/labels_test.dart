import 'package:quotabot_collector/labels.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

void main() {
  test('remaining headroom keeps the free scale when evidence is qualified',
      () {
    expect(remainingHeadroomPhrase(100), '100% free');
    expect(remainingHeadroomPhrase(100, 'last known'), '100% free, last known');
    expect(
      remainingHeadroomPhrase(40, 'last trusted'),
      '40% free, last trusted',
    );
    expect(remainingHeadroomPhrase(40, 'unverified'), '40% free, unverified');
    expect(remainingHeadroomPhrase(80, 'live shared'), '80% free, live shared');
  });

  test('local headlines preserve diagnostics but cannot invent cold state', () {
    ProviderQuota quota({String? status, List<ModelInfo> models = const []}) =>
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: 'default',
          asOf: 123,
          kind: ProviderQuotaKind.local,
          status: status,
          models: models,
        );
    expect(
        localRuntimeStatusLabel(quota(status: 'reachable - cloud routes only')),
        'reachable - cloud routes only');
    expect(localRuntimeStatusLabel(quota()), 'No eligible generation model');
    expect(
        localRuntimeStatusLabel(quota(models: const [ModelInfo(id: 'cold')])),
        'ready - no model loaded');
    expect(
        localRuntimeStatusLabel(
            quota(models: const [ModelInfo(id: 'warm', loaded: true)])),
        'loaded');
    expect(
        localRuntimeStatusLabel(quota(
          status: 'ready - no model loaded',
          models: const [ModelInfo(id: 'unknown', loadedStateKnown: false)],
        )),
        'reachable - load state unknown');
  });

  group('resetCountdownLabel', () {
    test('unknown, reached, and whole-unit labels', () {
      expect(resetCountdownLabel(null, 1000), 'soon');
      expect(resetCountdownLabel(1000, 1000), 'now');
      expect(resetCountdownLabel(500, 1000), 'now'); // already passed
      expect(resetCountdownLabel(1000 + 3 * 86400, 1000), '3d');
      expect(resetCountdownLabel(1000 + 5 * 3600, 1000), '5h');
      expect(resetCountdownLabel(1000 + 90 * 60, 1000), '1h'); // 1.5h floors
      expect(resetCountdownLabel(1000 + 45 * 60, 1000), '45m');
      expect(resetCountdownLabel(1059, 1000), '<1m');
    });
  });

  group('compactAge', () {
    test('rounds to the nearest single unit with an optional suffix', () {
      expect(compactAge(45), '45s');
      expect(compactAge(45, suffix: ' ago'), '45s ago');
      expect(compactAge(100), '2m'); // 100s rounds to 2m
      expect(compactAge(3600), '60m'); // still under the 5400 cutoff
      expect(compactAge(7200), '2h');
      expect(compactAge(3 * 86400), '3d');
    });

    test('floorNow reads sub-minute as now and drops the seconds unit', () {
      expect(compactAge(30, floorNow: true), 'now');
      expect(compactAge(59, floorNow: true), 'now');
      expect(compactAge(75, floorNow: true), '1m');
    });
  });

  group('capturedAgeLabel', () {
    test('uses natural copy only for an exact current capture', () {
      expect(capturedAgeLabel(1000, 1000), 'captured just now');
      expect(capturedAgeLabel(999, 1000), 'captured 1s ago');
      expect(capturedAgeLabel(940, 1000), 'captured 60s ago');
    });

    test('keeps missing and future captures explicit', () {
      expect(capturedAgeLabel(0, 1000), isEmpty);
      expect(capturedAgeLabel(1001, 1000), 'captured in the future');
    });
  });

  group('countdown', () {
    test('reached, day+hour, and hour+minute forms', () {
      expect(countdown(1000, 1000), 'now');
      expect(countdown(500, 1000), 'now');
      expect(countdown(1000 + 2 * 86400 + 3 * 3600, 1000), '2d3h');
      expect(countdown(1000 + 3 * 3600 + 20 * 60, 1000), '3h20m');
      expect(countdown(1000 + 45 * 60, 1000), '45m');
      expect(countdown(1059, 1000), '<1m');
    });
  });

  group('provider failure labels', () {
    ProviderQuota failure({
      required String pipeHealth,
      int? httpStatus,
      int? retryAfterSeconds,
    }) =>
        ProviderQuota.error(
          'antigravity',
          'Antigravity',
          'bounded diagnostic',
          1000,
          pipeHealth: pipeHealth,
          httpStatus: httpStatus,
          retryAfterSeconds: retryAfterSeconds,
        );

    test('distinguishes timeout rate limit and service error', () {
      expect(
        providerFailureSummary(
          failure(pipeHealth: providerPipeHealthThrottled),
        ),
        'quota check delayed',
      );
      expect(
        providerFailureSummary(
          failure(
            pipeHealth: providerPipeHealthThrottled,
            httpStatus: 429,
            retryAfterSeconds: 120,
          ),
        ),
        'quota check rate limited',
      );
      expect(
        providerFailureSummary(
          failure(
            pipeHealth: providerPipeHealthDegraded,
            httpStatus: 503,
            retryAfterSeconds: 45,
          ),
          showingLastKnown: true,
        ),
        'quota service error, showing last known',
      );
    });

    test('keeps auth and ordinary failures outside temporary copy', () {
      final auth = ProviderQuota.error(
        'antigravity',
        'Antigravity',
        'bounded auth diagnostic',
        1000,
        httpStatus: 403,
      );
      final ordinary = ProviderQuota.error(
        'antigravity',
        'Antigravity',
        'invalid response',
        1000,
      );

      expect(providerRetrySummary(auth), isNull);
      expect(providerFailureSummary(auth), 'live quota needs reconnecting');
      expect(providerFailureSummary(ordinary), 'invalid response');
    });

    test('keeps a bare Grok HTTP 403 diagnostic when reconnect is unavailable',
        () {
      final quota = ProviderQuota.error(
        'grok',
        'Grok',
        'Grok quota request failed (HTTP 403)',
        1000,
        httpStatus: 403,
      );

      expect(
        providerFailureSummary(quota),
        'Grok quota request failed (HTTP 403)',
      );
    });

    test('a gRPC resource-exhausted throttle is labeled rate limited', () {
      expect(
        providerFailureSummary(
          ProviderQuota.error(
            'grok',
            'Grok',
            'gRPC status 8',
            1000,
            pipeHealth: providerPipeHealthThrottled,
            httpStatus: 200,
          ),
        ),
        'quota check rate limited',
      );
    });

    test('an expired-login message is never displaced by the reconnect line',
        () {
      const message =
          'token expired (HTTP 403; open Grok to refresh, or run: quotabot '
          'login grok) - account only';
      final quota = ProviderQuota(
        provider: 'grok',
        displayName: 'Grok',
        account: 'a@example.com',
        asOf: 1000,
        ok: true,
        error: message,
        httpStatus: 403,
        windows: const [],
      );
      expect(providerFailureSummary(quota), message);
    });
  });

  group('spent window copy', () {
    const now = 1700000000;

    QuotaWindow weekly(double used, int? resetsAt) => QuotaWindow(
          label: 'weekly',
          usedPercent: used,
          resetsAt: resetsAt,
        );

    ProviderQuota claude({
      required double used,
      int? resetsAt,
      bool stale = false,
      String? error,
      String? pipeHealth,
      int? httpStatus,
    }) =>
        ProviderQuota(
          provider: 'claude',
          displayName: 'Claude',
          account: 'a',
          asOf: now,
          windows: [weekly(used, resetsAt)],
          stale: stale,
          error: error,
          pipeHealth: pipeHealth,
          httpStatus: httpStatus,
        );

    test('a far spent reset names the day and clock', () {
      expect(
        spentResetPhrase(now + 3 * 86400, now),
        matches(
          RegExp(
            r'^resets (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2}:\d{2} [AP]M$',
          ),
        ),
      );
    });

    test('a near spent reset stays a countdown', () {
      expect(
        spentResetPhrase(now + 3 * 3600 + 20 * 60, now),
        'resets 3h20m',
      );
    });

    test('a spent reset a week out includes the date', () {
      expect(
        spentResetPhrase(now + 9 * 86400, now),
        matches(
          RegExp(
            r'^resets (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2}/\d{1,2} '
            r'\d{1,2}:\d{2} [AP]M$',
          ),
        ),
      );
    });

    test('a cached spent window names the spend and the reset', () {
      final detail = doctorWindowDetail(
        weekly(100.0, now + 3 * 86400),
        now,
        'cached',
      );
      expect(detail, startsWith('weekly spent; resets '));
      expect(detail, isNot(contains('last known')));
      expect(
        detail,
        matches(RegExp(r'resets (Mon|Tue|Wed|Thu|Fri|Sat|Sun) ')),
      );
    });

    test('a cached percentage still says last known', () {
      expect(
        doctorWindowDetail(weekly(40.0, now + 3 * 86400), now, 'cached'),
        contains('40% used (last known)'),
      );
    });

    test('a passed cached reset still asks for confirmation', () {
      expect(
        doctorWindowDetail(weekly(100.0, now - 60), now, 'cached'),
        'weekly spent (last known); reset passed, refresh to confirm',
      );
    });

    test('a generic refresh note repeats a spent window', () {
      final deferred = claude(
        used: 100.0,
        resetsAt: now + 3 * 86400,
        stale: true,
        error: 'Claude usage read deferred',
      );
      final limited = claude(
        used: 100.0,
        resetsAt: now + 3 * 86400,
        stale: true,
        error: 'HTTP 429',
        pipeHealth: providerPipeHealthThrottled,
        httpStatus: 429,
      );
      final open = claude(
        used: 40.0,
        resetsAt: now + 3 * 86400,
        stale: true,
        error: 'Claude usage read deferred',
      );
      final signIn = claude(
        used: 100.0,
        resetsAt: now + 3 * 86400,
        stale: true,
        error: 'token expired',
      );

      expect(staleRefreshRepeatsSpentWindow(deferred, now), isTrue);
      expect(spentWindowRefreshNote(deferred, now), isNull);
      expect(staleRefreshRepeatsSpentWindow(limited, now), isFalse);
      expect(spentWindowRefreshNote(limited, now), 'quota check rate limited');
      expect(staleRefreshRepeatsSpentWindow(open, now), isFalse);
      expect(spentWindowRefreshNote(open, now), isNull);
      expect(staleRefreshRepeatsSpentWindow(signIn, now), isFalse);
      expect(spentWindowRefreshNote(signIn, now), isNull);
    });
  });

  group('local runtime glance details', () {
    const hardware = LocalHardwareInfo(
      asOf: 1000,
      gpuMemoryTotalBytes: 12 * 1024 * 1024 * 1024,
      gpuMemoryAvailableBytes: 8 * 1024 * 1024 * 1024,
    );

    ProviderQuota local({
      List<String> details = const [],
      LocalHardwareInfo? localHardware,
    }) =>
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: '14 models',
          asOf: 1000,
          kind: ProviderQuotaKind.local,
          status: 'qwen loaded',
          details: details,
          localHardware: localHardware,
        );

    test('keeps free VRAM and extra loaded models on the glance', () {
      final quota = local(
        localHardware: hardware,
        details: const [
          '4 GB GPU resident . 32K running context',
          '+2 more loaded',
          '14 installed . 203.3 GB on disk',
          'Local host RAM 32.8 GB of 63.9 GB used (51%)',
          'Local host VRAM 4.0 GB of 12.0 GB used (33%) . NVIDIA GeForce RTX 4090',
          'Local host GPU utilization 27%',
        ],
      );

      expect(
        localRuntimeVramFreeLabel(hardware),
        'VRAM 8.0 GB free of 12.0 GB',
      );
      expect(localRuntimeGlanceDetails(quota), [
        'VRAM 8.0 GB free of 12.0 GB',
        '+2 more loaded',
      ]);
      expect(localRuntimeExpandedDetails(quota), [
        '4 GB GPU resident . 32K running context',
        '14 installed . 203.3 GB on disk',
        'Local host RAM 32.8 GB of 63.9 GB used (51%)',
        'Local host VRAM 4.0 GB of 12.0 GB used (33%) . NVIDIA GeForce RTX 4090',
        'Local host GPU utilization 27%',
      ]);
    });

    test('falls back to the host VRAM line when free bytes are unknown', () {
      final quota = local(
        details: const [
          '3 installed . 18 GB on disk',
          'Local host VRAM 4.0 GB of 12.0 GB used (33%)',
        ],
      );

      expect(localRuntimeVramFreeLabel(null), isNull);
      expect(localRuntimeGlanceDetails(quota), [
        'Local host VRAM 4.0 GB of 12.0 GB used (33%)',
      ]);
      expect(localRuntimeExpandedDetails(quota), [
        '3 installed . 18 GB on disk',
      ]);
    });
  });
}
