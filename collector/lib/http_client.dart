import 'package:http/http.dart' as http;

/// A single process-wide HTTP client for provider-metadata reads.
///
/// The top-level `http.get` / `http.post` helpers create and discard a client
/// on every call, so each read opens a fresh DNS, TCP, and TLS connection with
/// no reuse. A concurrent fleet poll then opens many cold connections at once,
/// and the heavier endpoints (behind Cloudflare or Google front ends) can miss
/// their timeout during that burst even though the same call is fast in
/// isolation. Reusing one pooled, keep-alive client lets connections stay warm
/// and lets a multi-call adapter (a load-then-fetch sequence) reuse a single
/// connection. Long-lived surfaces keep it for their process lifetime, while
/// one-shot entrypoints close it after their final read so keep-alive sockets do
/// not delay process exit. Adapters still accept an injected client for tests.
http.Client? _sharedHttpClient;
bool _sharedHttpClientRetired = false;

http.Client get sharedHttpClient {
  if (_sharedHttpClientRetired) {
    throw StateError('shared HTTP client has been retired');
  }
  return _sharedHttpClient ??= http.Client();
}

/// Whether [retireSharedHttpClient] has closed the pool for this isolate.
bool get isSharedHttpClientRetired => _sharedHttpClientRetired;

/// Releases pooled keep-alive connections held by a completed entrypoint.
///
/// The next read creates a fresh client. That keeps repeated in-process CLI
/// calls and tests safe while still letting the desktop and servers reuse one
/// client for as long as they run. MCP shutdown uses [retireSharedHttpClient]
/// instead so a late snapshot cannot open a new pool after the entrypoint
/// returns.
void closeSharedHttpClient() {
  final client = _sharedHttpClient;
  _sharedHttpClient = null;
  client?.close();
}

/// Closes the pooled client and refuses recreation in this isolate.
///
/// A bounded MCP drain can return while an already-started snapshot is still
/// finishing. Retirement makes that continuation fail closed rather than
/// restarting keep-alive sockets the process is trying to leave.
void retireSharedHttpClient() {
  _sharedHttpClientRetired = true;
  closeSharedHttpClient();
}

/// Restores [sharedHttpClient] after a test that retired the pool.
void resetSharedHttpClientForTesting() {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw UnsupportedError('test HTTP client reset is unavailable in release');
  }
  _sharedHttpClientRetired = false;
  closeSharedHttpClient();
}
