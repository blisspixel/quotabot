import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'credential_identity.dart';
import 'file_guard.dart';
import 'provider_ids.dart';
import 'util.dart';

/// A previous same-credential profile association, for last-known cache lookup.
/// It does not establish current plan, pool identity, entitlement, or quota.
class CachedCredentialPool {
  const CachedCredentialPool(this.pool, this.observedAtMicros);

  final String pool;
  final int observedAtMicros;
}

/// Keeps bounded opaque associations across collector isolates and restarts.
/// Callers must first discover the exact credential generation currently present
/// and use this association only to recover its stale cache after a failed read.
/// Fresh profile evidence, never this file, establishes a live account pool.
class CredentialPoolStore {
  CredentialPoolStore(
    this.provider, {
    Directory? directory,
    int Function()? clockMicros,
  })  : _directoryOverride = directory,
        _clockMicros =
            clockMicros ?? (() => DateTime.now().microsecondsSinceEpoch);

  static const schema = 'quotabot.credential-pools.v1';
  static const maxAssociations = 32;
  static const maxBytes = 16 * 1024;
  static const _futureToleranceMicros = 5 * 60 * 1000000;
  static final _random = Random.secure();

  final String provider;
  final Directory? _directoryOverride;
  final int Function() _clockMicros;

  CachedCredentialPool? lookup(String credential) {
    if (!kCurrentProviderIds.contains(provider) ||
        !isOpaqueCredentialIdentity(credential)) {
      return null;
    }
    try {
      final row = _load(_file())?[credential];
      return row?.pool == null
          ? null
          : CachedCredentialPool(row!.pool!, row.observedAtMicros);
    } catch (_) {
      // Missing or unusable association evidence cannot lend a cached account.
      return null;
    }
  }

  /// Records only an association proven by the same credential's profile read.
  /// [observedAtMicros] is the request's start, not its eventual completion.
  /// A late earlier read cannot replace newer account evidence. Conflicting
  /// observations with the same generation are unresolved until a later read.
  bool remember(
    String credential,
    String pool, {
    required int observedAtMicros,
  }) {
    if (!kCurrentProviderIds.contains(provider) ||
        !isOpaqueCredentialIdentity(credential) ||
        !isOpaqueCredentialIdentity(pool) ||
        !_validTime(observedAtMicros)) {
      return false;
    }
    InterprocessFileGuard? guard;
    try {
      final file = _file();
      restrictOwnerOnlyDirectory(file.parent);
      final lock = File('${file.path}.lock');
      _prepareLock(lock);
      guard = acquireInterprocessFileGuardSync(
        lock,
        hardenClaim: restrictOwnerOnlyFile,
        acquisitionTimeout: const Duration(milliseconds: 100),
        reclaimSameProcessClaims: false,
      );
      _checkDirectory(file.parent);
      _requireRegularOrMissing(lock, allowMissing: false);
      final rows = _load(file) ?? <String, _PoolRow>{};
      final previous = rows[credential];
      if (previous != null && previous.observedAtMicros > observedAtMicros) {
        return false;
      }
      if (previous != null && previous.observedAtMicros == observedAtMicros) {
        if (previous.pool == pool) return true;
        rows[credential] = _PoolRow(null, observedAtMicros);
      } else {
        rows[credential] = _PoolRow(pool, observedAtMicros);
      }
      final sorted = rows.entries.toList()
        ..sort((a, b) {
          final byTime =
              b.value.observedAtMicros.compareTo(a.value.observedAtMicros);
          return byTime != 0 ? byTime : a.key.compareTo(b.key);
        });
      final retained = sorted.take(maxAssociations).toList(growable: false);
      final contents = jsonEncode({
        'schema': schema,
        'provider': provider,
        'associations': [
          for (final entry in retained)
            {
              'credential': entry.key,
              'pool': entry.value.pool,
              'observed_at_micros': entry.value.observedAtMicros,
            },
        ],
      });
      if (utf8.encode(contents).length > maxBytes) return false;
      _write(file, contents);
      return retained
          .any((entry) => entry.key == credential && entry.value.pool == pool);
    } catch (_) {
      // A metadata-write failure must not discard the successful live read.
      return false;
    } finally {
      guard?.release();
    }
  }

  File _file() {
    final directory = _directoryOverride ?? quotabotDir('credential_pools');
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      directory.createSync(recursive: true);
    }
    _checkDirectory(directory);
    return File('${directory.path}/$provider.json');
  }

  bool _validTime(int value) =>
      value > 0 && value <= _clockMicros() + _futureToleranceMicros;

  Map<String, _PoolRow>? _load(File file) {
    _checkDirectory(file.parent);
    _requireRegularOrMissing(file);
    if (!file.existsSync()) return <String, _PoolRow>{};
    final handle = file.openSync();
    late final List<int> bytes;
    try {
      bytes = handle.readSync(maxBytes + 1);
    } finally {
      handle.closeSync();
    }
    if (bytes.length > maxBytes) return null;
    late final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } catch (_) {
      return null;
    }
    if (decoded is! Map ||
        decoded['schema'] != schema ||
        decoded['provider'] != provider) {
      return null;
    }
    final entries = decoded['associations'];
    if (entries is! List || entries.length > maxAssociations) return null;
    final rows = <String, _PoolRow>{};
    for (final entry in entries) {
      if (entry is! Map) return null;
      final credential = entry['credential'];
      final pool = entry['pool'];
      final observed = entry['observed_at_micros'];
      if (credential is! String ||
          !isOpaqueCredentialIdentity(credential) ||
          !entry.containsKey('pool') ||
          (pool != null &&
              (pool is! String || !isOpaqueCredentialIdentity(pool))) ||
          observed is! int ||
          !_validTime(observed) ||
          rows.containsKey(credential)) {
        return null;
      }
      rows[credential] = _PoolRow(pool as String?, observed);
    }
    return rows;
  }

  static void _checkDirectory(Directory directory) {
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException(
          'invalid credential association directory');
    }
  }

  static void _requireRegularOrMissing(File file, {bool allowMissing = true}) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        !(allowMissing && type == FileSystemEntityType.notFound)) {
      throw const FileSystemException('invalid credential association file');
    }
  }

  static void _prepareLock(File file) {
    _requireRegularOrMissing(file);
    if (!file.existsSync()) {
      try {
        file.createSync(exclusive: true);
      } on FileSystemException {
        _requireRegularOrMissing(file, allowMissing: false);
      }
    }
    _requireRegularOrMissing(file, allowMissing: false);
    restrictOwnerOnlyFile(file);
  }

  static void _write(File file, String contents) {
    _checkDirectory(file.parent);
    _requireRegularOrMissing(file);
    final temporary = File(
      '${file.path}.$pid.${_random.nextInt(0x7fffffff)}.tmp',
    );
    temporary.createSync(exclusive: true);
    try {
      restrictOwnerOnlyFile(temporary);
      temporary.writeAsStringSync(contents, flush: true);
      _checkDirectory(file.parent);
      _requireRegularOrMissing(file);
      _requireRegularOrMissing(temporary, allowMissing: false);
      temporary.renameSync(file.path);
    } finally {
      if (FileSystemEntity.typeSync(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        temporary.deleteSync();
      }
    }
  }
}

class _PoolRow {
  const _PoolRow(this.pool, this.observedAtMicros);

  final String? pool;
  final int observedAtMicros;
}
