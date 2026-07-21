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
/// connection. It lives for the process and is intentionally never closed;
/// adapters still accept an injected client for tests.
final http.Client sharedHttpClient = http.Client();
