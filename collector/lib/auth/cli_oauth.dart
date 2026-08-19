import 'dart:convert';

/// Parsed OAuth material from Gemini CLI `oauth_creds.json` or the nested JSON
/// blob `agy` stores in the OS keyring (`gemini` / `antigravity`).
class CliOauthMaterial {
  final String? accessToken;
  final String? refreshToken;
  final int? expiryMs;
  final String? idToken;

  /// True when the refresh token must be exchanged with Antigravity's OAuth
  /// client. Gemini CLI file tokens use the Gemini CLI client instead.
  final bool antigravityClient;

  const CliOauthMaterial({
    this.accessToken,
    this.refreshToken,
    this.expiryMs,
    this.idToken,
    this.antigravityClient = false,
  });
}

int? parseOauthExpiryMs(Object? value) {
  if (value is int) {
    if (value <= 0) return null;
    return value < 100000000000 ? value * 1000 : value;
  }
  if (value is num) return parseOauthExpiryMs(value.toInt());
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(_rfc3339ForDart(value))?.millisecondsSinceEpoch;
  }
  return null;
}

/// Dart [DateTime.parse] accepts at most 6 fractional second digits. Go's
/// `time.Time` JSON uses up to 9, which is what `agy` stores as `expiry`.
String _rfc3339ForDart(String value) {
  final match = RegExp(
    r'^(.*T\d{2}:\d{2}:\d{2})(\.(\d+))?((?:[Zz]|[+-]\d{2}:\d{2}))$',
  ).firstMatch(value.trim());
  if (match == null) return value;
  final frac = match.group(3);
  if (frac == null || frac.length <= 6) return value;
  return '${match.group(1)}.${frac.substring(0, 6)}${match.group(4)}';
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

CliOauthMaterial? parseCliOauthSecret(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final root = Map<Object?, Object?>.from(decoded);
  final nested = root['token'];
  if (nested is Map) {
    return _materialFromMap(
      Map<Object?, Object?>.from(nested),
      antigravityClient: true,
    );
  }
  final hasGoExpiry = root['expiry'] is String;
  return _materialFromMap(root, antigravityClient: hasGoExpiry);
}

CliOauthMaterial? _materialFromMap(
  Map<Object?, Object?> map, {
  required bool antigravityClient,
}) {
  final access = _nonEmptyString(map['access_token']);
  final refresh = _nonEmptyString(map['refresh_token']);
  final idToken = _nonEmptyString(map['id_token']);
  final expiryMs = parseOauthExpiryMs(map['expiry_date']) ??
      parseOauthExpiryMs(map['expiry']);
  if (access == null && refresh == null && idToken == null) return null;
  return CliOauthMaterial(
    accessToken: access,
    refreshToken: refresh,
    expiryMs: expiryMs,
    idToken: idToken,
    antigravityClient: antigravityClient,
  );
}

bool cliOauthAccessIsFresh(CliOauthMaterial material, {int? nowMs}) {
  final access = material.accessToken;
  final expiryMs = material.expiryMs;
  if (access == null || expiryMs == null) return false;
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return now < expiryMs - 60000;
}
