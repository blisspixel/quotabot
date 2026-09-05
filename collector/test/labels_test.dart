import 'package:quotabot_collector/labels.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

void main() {
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
}
