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
    final f = _file(provider, account: accountName);
    // Lock down the directory and pre-create the file with restrictive
    // permissions BEFORE writing the secret, so the token is never briefly
    // world-readable under the default umask.
    _restrictDir(f.parent);
    if (!f.existsSync()) {
      f.createSync(recursive: true);
    }
    _restrictPermissions(f);
    f.writeAsStringSync(jsonEncode({
      ...tokens.toJson(),
      if (accountName != null) _accountKey: accountName,
    }));
    _restrictPermissions(f);
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

  /// Best-effort: restrict the refresh-token file to the current user. On POSIX
  /// this is `chmod 600`; on Windows it resets inheritance and grants only the
  /// current user, so other accounts on the machine cannot read the token.
  static void _restrictPermissions(File f) {
    try {
      if (Platform.isWindows) {
        final user = _windowsUser();
        if (user == null || user.isEmpty) return;
        // /inheritance:r removes inherited ACEs; then grant only this user.
        Process.runSync('icacls', [f.path, '/inheritance:r']);
        Process.runSync('icacls', [f.path, '/grant:r', '$user:F']);
      } else {
        Process.runSync('chmod', ['600', f.path]);
      }
    } catch (_) {}
  }

  /// Best-effort: make the auth directory owner-only so other local users
  /// cannot traverse or list the stored token files.
  static void _restrictDir(Directory d) {
    try {
      if (!d.existsSync()) d.createSync(recursive: true);
      if (Platform.isWindows) {
        final user = _windowsUser();
        if (user == null || user.isEmpty) return;
        Process.runSync('icacls', [d.path, '/inheritance:r']);
        Process.runSync('icacls', [d.path, '/grant:r', '${user}:(OI)(CI)F']);
      } else {
        Process.runSync('chmod', ['700', d.path]);
      }
    } catch (_) {}
  }

  static String? _windowsUser() {
    final username = Platform.environment['USERNAME'];
    if (username == null || username.isEmpty) return null;
    final domain = Platform.environment['USERDOMAIN'];
    if (domain == null || domain.isEmpty) return username;
    return '$domain\\$username';
  }
}
