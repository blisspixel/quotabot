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
