import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Whether [url] targets the local loopback interface (127.0.0.0/8, ::1, or the
/// "localhost" name) over http(s). The alert webhook stays loopback-only unless
/// the user explicitly opts into an external host, so a mistyped or stale URL
/// cannot quietly send even quota metadata off the machine.
bool isLoopbackUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost') return true;
  final addr = InternetAddress.tryParse(host);
  if (addr == null) return false;
  return switch (addr.type) {
    InternetAddressType.IPv4 => host.startsWith('127.'),
    InternetAddressType.IPv6 => addr.address == '::1',
    _ => false,
  };
}

/// The outcome of attempting to deliver an alert to a webhook. Delivery is
/// best-effort: a failure is reported, never thrown, so alerting fails soft.
class WebhookResult {
  final bool ok;
  final int? statusCode;
  final String? error;
  const WebhookResult({required this.ok, this.statusCode, this.error});
}

/// Posts [payload] as JSON to [url]. A non-loopback host is refused unless
/// [allowExternal] is set, so the default can never reach an external service by
/// accident. Never throws: transport and HTTP errors come back as a
/// [WebhookResult] the caller can ignore or log. An injected [client] is used
/// for tests; otherwise a one-shot client is created and closed.
Future<WebhookResult> postAlert(
  String url,
  Map<String, dynamic> payload, {
  bool allowExternal = false,
  Duration timeout = const Duration(seconds: 5),
  http.Client? client,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return const WebhookResult(ok: false, error: 'invalid webhook url');
  }
  if (!allowExternal && !isLoopbackUrl(url)) {
    return const WebhookResult(
      ok: false,
      error: 'refusing non-loopback host (pass allowExternal to permit it)',
    );
  }
  final c = client ?? http.Client();
  try {
    final request = http.Request('POST', uri)
      ..followRedirects = allowExternal
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(payload);
    final resp =
        await c.send(request).then(http.Response.fromStream).timeout(timeout);
    final ok = resp.statusCode >= 200 && resp.statusCode < 300;
    return WebhookResult(ok: ok, statusCode: resp.statusCode);
  } catch (_) {
    return const WebhookResult(ok: false, error: 'transport failure');
  } finally {
    if (client == null) c.close();
  }
}
