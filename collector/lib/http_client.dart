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

http.Client get sharedHttpClient => _sharedHttpClient ??= http.Client();

/// Releases pooled keep-alive connections held by a completed entrypoint.
///
/// The next read creates a fresh client. That keeps repeated in-process CLI
/// calls and tests safe while still letting the desktop and servers reuse one
/// client for as long as they run.
void closeSharedHttpClient() {
  final client = _sharedHttpClient;
  _sharedHttpClient = null;
  client?.close();
}
