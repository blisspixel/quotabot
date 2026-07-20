/// Default loopback ports used by supported local model runtimes.
///
/// Keep adapter discovery and the dry-run runtime access manifest on the same
/// constants so a runtime release cannot silently split their behavior.
const ollamaDefaultPort = 11434;
const lmStudioDefaultPort = 1234;
const lemonadeDefaultPort = 13305;

typedef LocalRuntimeOrigin = ({
  String baseUrl,
  String scheme,
  String authority,
});

/// Resolves a local runtime origin from environment-style host and port values.
///
/// [rawHost] may be a bare host, host with port, or HTTP(S) URL. A valid
/// [rawPort] takes precedence over a port embedded in [rawHost]. Without an
/// explicit port, HTTPS keeps its standard port while HTTP uses [defaultPort].
/// Paths, credentials, queries, and fragments are deliberately discarded.
LocalRuntimeOrigin resolveLocalRuntimeOrigin(
  String? rawHost,
  int defaultPort, {
  String? rawPort,
}) {
  final configuredPort = _validPort(rawPort);
  final trimmed = rawHost?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return _origin('http', '127.0.0.1', configuredPort ?? defaultPort);
  }

  final withScheme =
      trimmed.startsWith('http://') || trimmed.startsWith('https://')
          ? trimmed
          : trimmed == '::1'
              ? 'http://[::1]'
              : 'http://$trimmed';
  try {
    final parsed = Uri.parse(withScheme);
    if (parsed.host.isEmpty) {
      return _origin('http', '127.0.0.1', configuredPort ?? defaultPort);
    }
    final scheme = parsed.scheme == 'https' ? 'https' : 'http';
    final port = configuredPort ??
        (parsed.hasPort
            ? parsed.port
            : (scheme == 'https' ? null : defaultPort));
    return _origin(scheme, parsed.host, port);
  } on FormatException {
    return _origin('http', '127.0.0.1', configuredPort ?? defaultPort);
  }
}

/// Whether a configured runtime host is an exact loopback destination.
///
/// Runtime adapters are eligible as local routing capacity only when their
/// metadata endpoint is on this host. Environment overrides remain visible in
/// the runtime-access audit, but a LAN or public endpoint must not be promoted
/// to an on-device fallback. User-info is refused even when the parsed host is
/// loopback so credential-bearing lookalikes never cross this trust boundary.
bool isLoopbackRuntimeHost(String? rawHost) {
  final trimmed = rawHost?.trim();
  if (trimmed == null || trimmed.isEmpty) return true;

  final withScheme =
      trimmed.startsWith('http://') || trimmed.startsWith('https://')
          ? trimmed
          : trimmed == '::1'
              ? 'http://[::1]'
              : 'http://$trimmed';
  try {
    final parsed = Uri.parse(withScheme);
    if (parsed.host.isEmpty || parsed.userInfo.isNotEmpty) return false;
    final host = parsed.host.toLowerCase();
    if (host == 'localhost' || host == 'localhost.' || host == '::1') {
      return true;
    }
    final octets = host.split('.');
    if (octets.length != 4) return false;
    final values = <int>[];
    for (final octet in octets) {
      if (octet.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(octet)) return false;
      final value = int.parse(octet);
      if (value > 255) return false;
      values.add(value);
    }
    return values.first == 127;
  } on FormatException {
    return false;
  }
}

/// Compatibility wrapper for callers that only need the resolved base URL.
String localBaseUrl(
  String? rawHost,
  int defaultPort, {
  String? rawPort,
}) =>
    resolveLocalRuntimeOrigin(
      rawHost,
      defaultPort,
      rawPort: rawPort,
    ).baseUrl;

LocalRuntimeOrigin _origin(String scheme, String host, int? port) {
  final uri = Uri(scheme: scheme, host: host, port: port);
  return (baseUrl: uri.origin, scheme: scheme, authority: uri.authority);
}

int? _validPort(String? raw) {
  final port = int.tryParse(raw?.trim() ?? '');
  return port != null && port > 0 && port <= 65535 ? port : null;
}
