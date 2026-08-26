import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/provider_connection.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota quota({
  String provider = 'antigravity',
  bool ok = false,
  bool stale = false,
  String? error,
  String? pipeHealth,
  int? httpStatus,
  List<QuotaWindow> windows = const [],
}) => ProviderQuota(
  provider: provider,
  displayName: provider,
  account: 'user@example.com',
  asOf: 1782000000,
  ok: ok,
  stale: stale,
  error: error,
  pipeHealth: pipeHealth,
  httpStatus: httpStatus,
  windows: windows,
);

void main() {
  test('inline Connect height follows desktop host availability', () {
    final reconnectable = quota(
      provider: 'grok',
      ok: true,
      error: 'no token - run: quotabot login grok',
    );

    expect(
      providerInlineConnectRowVisible(
        quota: reconnectable,
        hostIntegration: false,
        canConnect: true,
      ),
      isFalse,
    );
    expect(
      providerInlineConnectRowVisible(
        quota: reconnectable,
        hostIntegration: true,
        canConnect: true,
      ),
      isTrue,
    );
  });

  test('explicit provider login failures are connectable', () {
    expect(
      providerNeedsConnection(
        quota(
          provider: 'grok',
          ok: true,
          error: 'no token - run: quotabot login grok',
        ),
      ),
      isTrue,
    );
    expect(
      providerNeedsConnection(
        quota(
          ok: true,
          error:
              'no live quota (this machine only) - run: quotabot login '
              'antigravity',
        ),
      ),
      isTrue,
    );
    expect(
      providerNeedsConnection(
        quota(ok: true, error: 'token expired', httpStatus: 401),
      ),
      isTrue,
    );
    expect(
      providerNeedsConnection(
        quota(error: 'disconnected in quotabot (run quotabot login grok)'),
      ),
      isTrue,
    );
    // A denial for a CLI token already past its recorded expiry is proven
    // login expiry, so the collector's reclassified message must connect even
    // though the raw provider status alone would not.
    expect(
      providerNeedsConnection(
        quota(
          provider: 'grok',
          ok: true,
          error:
              'token expired (gRPC status 7; open Grok to refresh, or '
              'run: quotabot login grok) - account only',
          httpStatus: 200,
        ),
      ),
      isTrue,
    );
  });

  test('operational and quota states do not offer connection', () {
    final spent = quota(
      provider: 'grok',
      ok: true,
      windows: [QuotaWindow(label: 'weekly', usedPercent: 100)],
    );
    final throttled = quota(
      error: 'HTTP 429',
      pipeHealth: providerPipeHealthThrottled,
      httpStatus: 429,
    );
    final degraded = quota(
      error: 'HTTP 503',
      pipeHealth: providerPipeHealthDegraded,
      httpStatus: 503,
    );
    final grokForbidden = quota(
      provider: 'grok',
      error: 'HTTP 403',
      httpStatus: 403,
    );
    final cached = quota(
      provider: 'grok',
      ok: true,
      stale: true,
      error: 'temporary read failure',
      windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
    );
    final connectedWithoutWindows = quota(
      ok: true,
      error: 'connected; live quota windows are not exposed here yet',
    );

    for (final value in [
      spent,
      throttled,
      degraded,
      grokForbidden,
      cached,
      connectedWithoutWindows,
    ]) {
      expect(providerNeedsConnection(value), isFalse);
    }
  });

  test('rejected evidence never offers connection', () {
    final suspect = quota(
      ok: true,
      error: 'token expired',
    ).withSuspect('implausible movement');
    final drift = suspect.asProviderDriftQuarantine(
      'provider response drift',
      1782000001,
    );

    expect(providerNeedsConnection(suspect), isFalse);
    expect(providerNeedsConnection(drift), isFalse);
  });

  test('providers without an in-app login never offer connection', () {
    expect(
      providerNeedsConnection(
        quota(provider: 'claude', error: 'token expired', httpStatus: 401),
      ),
      isFalse,
    );
  });
}
