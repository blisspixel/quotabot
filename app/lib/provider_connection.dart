import 'package:quotabot_collector/collector.dart';

/// Whether an in-app provider login is a truthful recovery action.
///
/// A provider can be non-routable for many reasons that authentication cannot
/// repair, including spent quota, throttling, provider outages, stale evidence
/// by itself, and drift quarantine. Only explicit authentication evidence for
/// a provider with an in-app login exposes the Connect action.
bool providerNeedsConnection(ProviderQuota quota) {
  if ((quota.provider != 'grok' && quota.provider != 'antigravity') ||
      quota.isLocal ||
      quota.sourceClassViolation != null ||
      quota.driftReason != null ||
      quota.suspect != null ||
      quota.pipeHealth == providerPipeHealthThrottled ||
      quota.pipeHealth == providerPipeHealthDegraded) {
    return false;
  }

  final error = (quota.error ?? '').trim().toLowerCase();
  if (error.isEmpty) return false;
  if (quota.httpStatus == 401) return true;

  if (error.contains('disconnected in quotabot') ||
      error.contains('not logged in') ||
      error.contains('signed out') ||
      error.contains('token expired')) {
    return true;
  }

  if (quota.provider == 'grok') {
    return error.contains('no ~/.grok/auth.json') ||
        error.contains('no grok account') ||
        error.contains('no token') ||
        error.contains('run: quotabot login grok');
  }
  if (quota.provider == 'antigravity') {
    return error.contains('run: quotabot login antigravity') ||
        error.contains('live quota token is signed in to another account');
  }
  return false;
}

/// Whether the provider card can render its inline Connect row.
///
/// Test and preview dashboards can inject provider data without desktop host
/// services. Their first-frame height must follow the same condition as the
/// rendered card instead of reserving space for an action that cannot appear.
bool providerInlineConnectRowVisible({
  required ProviderQuota quota,
  required bool hostIntegration,
  required bool canConnect,
}) => hostIntegration && canConnect && providerNeedsConnection(quota);
