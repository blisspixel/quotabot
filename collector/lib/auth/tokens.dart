import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../credential_identity.dart';
import '../util.dart';

export '../credential_identity.dart';

typedef TokenDirectoryHardener = void Function(Directory directory);
typedef TokenFileHardener = void Function(File file);

const _credentialIdentityDomain = 'quotabot-credential-identity-v1';

/// Returns an irreversible, collision-resistant identity for one credential
/// generation. The provider name is domain-separated so the same secret cannot
/// join evidence across providers. Callers may persist the result, never the
/// credential material used to derive it.
String opaqueCredentialIdentity(String provider, String credentialMaterial) {
  if (provider.isEmpty || credentialMaterial.isEmpty) {
    throw ArgumentError('provider and credential material must be non-empty');
  }
  final digest = sha256.convert(
    utf8.encode(
      '$_credentialIdentityDomain\u0000$provider\u0000$credentialMaterial',
    ),
  );
  return '$opaqueCredentialIdentityPrefix$digest';
}

TokenDirectoryHardener _hardenTokenDirectory = enforceOwnerOnlyDirectory;
TokenFileHardener _hardenTokenFile = enforceOwnerOnlyFile;

/// Overrides credential permission enforcement for deterministic failure tests.
/// Production code must leave this unset.
void setTokenPermissionHardeningForTesting({
  TokenDirectoryHardener? directoryHardener,
  TokenFileHardener? fileHardener,
}) {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw UnsupportedError(
        'test permission override is unavailable in release');
  }
  _hardenTokenDirectory = directoryHardener ?? enforceOwnerOnlyDirectory;
  _hardenTokenFile = fileHardener ?? enforceOwnerOnlyFile;
}

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
    // Treat an empty refresh_token as absent so a blank value cannot overwrite
    // a still-valid prior refresh token and leave a dead grant.
    final rotated = json['refresh_token'] as String?;
    return Tokens(
      accessToken: json['access_token'] as String?,
      refreshToken:
          (rotated != null && rotated.isNotEmpty) ? rotated : priorRefresh,
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

/// One immutable parse of a stored grant file.
///
/// [tokens] and [owner] always come from the same file generation. The private
/// revision and slot fields let [TokenStore.replaceIfCurrent] perform a
/// cross-process compare-and-swap without exposing credential-derived state.
class TokenRecord {
  final Tokens tokens;
  final String? owner;
  final String _provider;
  final String? _account;
  final String _revision;

  const TokenRecord._({
    required this.tokens,
    required this.owner,
    required String provider,
    required String? account,
    required String revision,
  })  : _provider = provider,
        _account = account,
        _revision = revision;
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

  /// Reads tokens and their ownership marker from one atomic file snapshot.
  static TokenRecord? loadRecord(String provider, {String? account}) {
    final accountName = _normalizeAccount(account);
    final f = _file(provider, account: accountName);
    return _readRecord(
      f,
      provider: provider,
      account: accountName,
      suppressIoErrors: true,
    );
  }

  static TokenRecord? _readRecord(
    File f, {
    required String provider,
    required String? account,
    required bool suppressIoErrors,
  }) {
    try {
      if (!f.existsSync()) return null;
      if (f.lengthSync() > _maxTokenBytes) return null;
      final raw = f.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final json = decoded.cast<String, dynamic>();
      final rawOwner = json[_accountKey];
      final owner = rawOwner is String ? _normalizeAccount(rawOwner) : null;
      return TokenRecord._(
        tokens: Tokens.fromJson(json),
        owner: owner,
        provider: provider,
        account: account,
        revision: sha256.convert(utf8.encode(raw)).toString(),
      );
    } on FileSystemException {
      if (!suppressIoErrors) rethrow;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Tokens? load(String provider, {String? account}) =>
      loadRecord(provider, account: account)?.tokens;

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
    _withFileLock(f, () {
      _writeUnlocked(f, tokens, ownerStamp: ownerStamp);
    });
  }

  /// Replaces [current] only when its slot still contains the exact generation
  /// that was loaded. All TokenStore writers take the same per-slot file lock,
  /// so a completed login or another refresh cannot be overwritten by a stale
  /// refresh response from this or another process.
  ///
  /// Returns false for a generation conflict. File-system failures still throw
  /// so callers can retain the existing best-effort behavior for an already
  /// rotated provider token without confusing that failure with a conflict.
  static bool replaceIfCurrent(
    TokenRecord current,
    Tokens tokens, {
    String? owner,
  }) {
    final f = _file(current._provider, account: current._account);
    final ownerStamp = owner == null ? current.owner : _normalizeAccount(owner);
    return _withFileLock(f, () {
      final latest = _readRecord(
        f,
        provider: current._provider,
        account: current._account,
        suppressIoErrors: false,
      );
      if (latest == null || latest._revision != current._revision) {
        return false;
      }
      _writeUnlocked(f, tokens, ownerStamp: ownerStamp);
      return true;
    });
  }

  static void _writeUnlocked(
    File f,
    Tokens tokens, {
    required String? ownerStamp,
  }) {
    // Write to a temp file and rename over the target so a crash or a
    // concurrent read never leaves a truncated grant: losing a rotated refresh
    // token this way would break every later refresh. Lock the temp down BEFORE
    // the secret lands so it is never briefly world-readable under the default
    // umask. The same-directory rename preserves that checked descriptor.
    final tmp = File('${f.path}.$pid.tmp');
    try {
      if (!tmp.existsSync()) {
        tmp.createSync(recursive: true);
      }
      _hardenTokenFile(tmp);
      tmp.writeAsStringSync(jsonEncode({
        ...tokens.toJson(),
        if (ownerStamp != null) _accountKey: ownerStamp,
      }));
      _replaceAtomically(tmp, f);
      // A same-directory rename preserves the checked temporary file's security
      // descriptor. Do not reset permissions after the secret has been written.
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }

  static void _replaceAtomically(File temporary, File target) {
    // Windows can reject a replace for the few milliseconds in which another
    // process has the old generation open for reading. The reader still sees a
    // complete old snapshot, so retry only that transient sharing condition.
    // Other access failures remain immediate, and the bounded delay prevents a
    // permanently blocked destination from stalling login or collection.
    const attempts = 9;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        temporary.renameSync(target.path);
        return;
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        final transientWindowsSharing = Platform.isWindows &&
            target.existsSync() &&
            (code == 5 || code == 32);
        if (!transientWindowsSharing || attempt == attempts - 1) rethrow;
        sleep(Duration(milliseconds: 1 << attempt));
      }
    }
  }

  static T _withFileLock<T>(File target, T Function() run) {
    final lockFile = File('${target.path}.lock');
    _hardenTokenDirectory(lockFile.parent);
    var created = false;
    if (!lockFile.existsSync()) {
      try {
        lockFile.createSync(recursive: true, exclusive: true);
        created = true;
      } on FileSystemException {
        if (!lockFile.existsSync()) rethrow;
      }
    }
    try {
      _hardenTokenFile(lockFile);
    } catch (_) {
      if (created) {
        try {
          lockFile.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
    final lock = lockFile.openSync(mode: FileMode.write);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      return run();
    } finally {
      try {
        lock.unlockSync();
      } catch (_) {}
      lock.closeSync();
    }
  }

  /// The account a provider-default grant is stamped for, or null when the
  /// default slot is absent, unreadable, or a legacy grant written without a
  /// stamp. Reads only the ownership marker, never exposing the token.
  static String? defaultOwner(String provider) => loadRecord(provider)?.owner;

  static void clear(String provider, {String? account}) {
    final f = _file(provider, account: account);
    _withFileLock(f, () {
      if (f.existsSync()) f.deleteSync();
    });
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
