import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../util.dart';

/// An OAuth token set for one provider.
class Tokens {
  final String? accessToken;
  final String? refreshToken;

  /// Unix epoch seconds when [accessToken] expires.
  final int? expiresAt;

  const Tokens({this.accessToken, this.refreshToken, this.expiresAt});

  /// True when the access token is present and not within a 60s expiry margin.
  bool get isFresh =>
      accessToken != null && expiresAt != null && expiresAt! > nowEpoch() + 60;

  /// Builds tokens from an OAuth token-endpoint JSON response, carrying the
  /// previous refresh token forward when the response omits a new one.
  factory Tokens.fromOAuth(Map<String, dynamic> json, {String? priorRefresh}) {
    final expiresIn = (json['expires_in'] as num?)?.toInt();
    return Tokens(
      accessToken: json['access_token'] as String?,
      refreshToken: (json['refresh_token'] as String?) ?? priorRefresh,
      expiresAt: expiresIn == null ? null : nowEpoch() + expiresIn,
    );
  }

  Map<String, dynamic> toJson() => {
        if (accessToken != null) 'access_token': accessToken,
        if (refreshToken != null) 'refresh_token': refreshToken,
        if (expiresAt != null) 'expires_at': expiresAt,
      };

  factory Tokens.fromJson(Map<String, dynamic> j) => Tokens(
        accessToken: j['access_token'] as String?,
        refreshToken: j['refresh_token'] as String?,
        expiresAt: j['expires_at'] as int?,
      );
}

/// Persists quotabot's own OAuth tokens per provider, separately from the host
/// applications' credentials. Critically, rotated refresh tokens must be saved
/// on every refresh, or the next refresh will fail.
class TokenStore {
  static final _providerPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static const _accountKey = '_account';
  static const _maxTokenBytes = 128 * 1024;

  static File _file(String provider, {String? account}) {
    final providerName = _providerFileName(provider);
    final accountName = _normalizeAccount(account);
    final stem = accountName == null
        ? providerName
        : '${providerName}_account_${_accountHash(accountName)}';
    return File('${quotabotDir('auth').path}/$stem.json');
  }

  static String _providerFileName(String provider) {
    if (!_providerPattern.hasMatch(provider)) {
      throw ArgumentError.value(
        provider,
        'provider',
        'must contain only letters, numbers, underscore, or dash',
      );
    }
    return provider;
  }

  static String? _normalizeAccount(String? account) {
    if (account == null) return null;
    final trimmed = account.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 512 ||
        trimmed.runes.any((c) => c < 0x20 || c == 0x7f)) {
      throw ArgumentError.value(
        account,
        'account',
        'must be a non-empty printable account identifier',
      );
    }
    return trimmed;
  }

  static String _accountHash(String account) =>
      sha256.convert(utf8.encode(account)).toString();

  static Tokens? load(String provider, {String? account}) {
    final f = _file(provider, account: account);
    try {
      if (!f.existsSync()) return null;
      if (f.lengthSync() > _maxTokenBytes) return null;
      return Tokens.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  static void save(String provider, Tokens tokens, {String? account}) {
    final accountName = _normalizeAccount(account);
    _write(provider, tokens, fileAccount: accountName, ownerStamp: accountName);
  }

  /// Writes the provider-default grant while recording which account it belongs
  /// to. The grant still lives in the default slot; [owner] is only an ownership
  /// marker in the file content, so a fallback consumer can refuse to lend the
  /// default grant to a different account (see [defaultOwner]).
  static void saveDefaultOwnedBy(String provider, Tokens tokens, String owner) {
    _write(provider, tokens,
        fileAccount: null, ownerStamp: _normalizeAccount(owner));
  }

  static void _write(
    String provider,
    Tokens tokens, {
    required String? fileAccount,
    required String? ownerStamp,
  }) {
    final f = _file(provider, account: fileAccount);
    // Write to a temp file and rename over the target so a crash or a
    // concurrent read never leaves a truncated grant: losing a rotated refresh
    // token this way would break every later refresh. Lock the temp down BEFORE
    // the secret lands so it is never briefly world-readable under the default
    // umask, then re-lock after the rename.
    restrictOwnerOnlyDirectory(f.parent);
    final tmp = File('${f.path}.$pid.tmp');
    if (!tmp.existsSync()) {
      tmp.createSync(recursive: true);
    }
    restrictOwnerOnlyFile(tmp);
    tmp.writeAsStringSync(jsonEncode({
      ...tokens.toJson(),
      if (ownerStamp != null) _accountKey: ownerStamp,
    }));
    tmp.renameSync(f.path);
    restrictOwnerOnlyFile(f);
  }

  /// The account a provider-default grant is stamped for, or null when the
  /// default slot is absent, unreadable, or a legacy grant written without a
  /// stamp. Reads only the ownership marker, never exposing the token.
  static String? defaultOwner(String provider) {
    final f = _file(provider);
    try {
      if (!f.existsSync() || f.lengthSync() > _maxTokenBytes) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map && decoded[_accountKey] is String) {
        return _normalizeAccount(decoded[_accountKey] as String);
      }
    } catch (_) {}
    return null;
  }

  static void clear(String provider, {String? account}) {
    final f = _file(provider, account: account);
    if (f.existsSync()) f.deleteSync();
  }

  static bool exists(String provider, {String? account}) =>
      _file(provider, account: account).existsSync();

  static List<String> accounts(String provider) {
    final prefix = '${_providerFileName(provider)}_account_';
    final dir = quotabotDir('auth');
    final found = <String>{};
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(prefix) || !name.endsWith('.json')) continue;
        if (entity.lengthSync() > _maxTokenBytes) continue;
        try {
          final decoded =
              jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
          final account = decoded[_accountKey];
          if (account is String && _normalizeAccount(account) != null) {
            found.add(account);
          }
        } catch (_) {}
      }
    } catch (_) {}
    return found.toList()..sort();
  }

  static void clearAccounts(String provider) {
    for (final account in accounts(provider)) {
      clear(provider, account: account);
    }
  }
}
