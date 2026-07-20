import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'src/exclusive_create_collision.dart';

typedef GuardFileHardener = void Function(File file);

const _claimProbeGrace = Duration(seconds: 2);
const _sameProcessClaimStaleAfter = Duration(minutes: 2);
const _maxClaimBytes = 1024;
const defaultFileGuardAcquisitionTimeout = Duration(seconds: 30);

/// A claim-backed native file guard that serializes both processes and isolates.
///
/// POSIX advisory file locks are process-scoped, so a native lock alone does not
/// exclude another isolate in the same process. The exclusive claim file closes
/// that gap. The native lock remains authoritative for abandoned-claim recovery
/// after a process exits.
class InterprocessFileGuard {
  final RandomAccessFile _lock;
  final File _claimFile;
  final String _owner;
  bool _released = false;

  InterprocessFileGuard._(this._lock, this._claimFile, this._owner);

  void release() {
    if (_released) return;
    _released = true;

    // Keep the claim present until the native lock is released. Deleting it
    // first lets a peer isolate acquire a new claim while this process still
    // owns the process-scoped POSIX lock. The old guard's subsequent unlock
    // would then silently release the peer's protection from other processes.
    var nativeReleased = false;
    try {
      try {
        _lock.unlockSync();
        nativeReleased = true;
      } catch (_) {}
      try {
        _lock.closeSync();
        nativeReleased = true;
      } catch (_) {}
    } finally {
      if (nativeReleased) _deleteOwnedClaim(_claimFile, _owner);
    }
  }
}

InterprocessFileGuard acquireInterprocessFileGuardSync(
  File lockFile, {
  required GuardFileHardener hardenClaim,
  Duration acquisitionTimeout = defaultFileGuardAcquisitionTimeout,
}) {
  final elapsed = Stopwatch()..start();
  var attempted = false;
  var delayMs = 1;
  while (true) {
    if (attempted) {
      _requireAcquisitionTime(lockFile, elapsed, acquisitionTimeout);
    }
    attempted = true;
    final claim = _tryCreateClaim(lockFile, hardenClaim);
    if (claim != null) {
      try {
        final guard = _lockClaimSync(lockFile, claim);
        if (guard != null) return guard;
      } on _NativeLockContended {
        _waitForGuardRetrySync(
          lockFile,
          elapsed,
          acquisitionTimeout,
          delayMs,
        );
        if (delayMs < 32) delayMs *= 2;
      }
      continue;
    }
    try {
      if (_tryReclaimStaleClaim(lockFile)) continue;
    } on FileSystemException catch (error) {
      if (!_isTransientWindowsContention(error)) rethrow;
    }
    _waitForGuardRetrySync(
      lockFile,
      elapsed,
      acquisitionTimeout,
      delayMs,
    );
    if (delayMs < 32) delayMs *= 2;
  }
}

Future<InterprocessFileGuard> acquireInterprocessFileGuard(
  File lockFile, {
  required GuardFileHardener hardenClaim,
  Duration acquisitionTimeout = defaultFileGuardAcquisitionTimeout,
}) async {
  final elapsed = Stopwatch()..start();
  var attempted = false;
  var delayMs = 1;
  while (true) {
    if (attempted) {
      _requireAcquisitionTime(lockFile, elapsed, acquisitionTimeout);
    }
    attempted = true;
    final claim = _tryCreateClaim(lockFile, hardenClaim);
    if (claim != null) {
      try {
        final guard = await _lockClaim(lockFile, claim);
        if (guard != null) return guard;
      } on _NativeLockContended {
        await _waitForGuardRetry(
          lockFile,
          elapsed,
          acquisitionTimeout,
          delayMs,
        );
        if (delayMs < 32) delayMs *= 2;
      }
      continue;
    }
    try {
      if (_tryReclaimStaleClaim(lockFile)) continue;
    } on FileSystemException catch (error) {
      if (!_isTransientWindowsContention(error)) rethrow;
    }
    await _waitForGuardRetry(
      lockFile,
      elapsed,
      acquisitionTimeout,
      delayMs,
    );
    if (delayMs < 32) delayMs *= 2;
  }
}

void _requireAcquisitionTime(
  File lockFile,
  Stopwatch elapsed,
  Duration timeout,
) {
  if (timeout.isNegative || elapsed.elapsed >= timeout) {
    throw FileSystemException(
      'timed out acquiring file guard',
      lockFile.path,
    );
  }
}

Duration _guardRetryDelay(
  File lockFile,
  Stopwatch elapsed,
  Duration timeout,
  int delayMs,
) {
  _requireAcquisitionTime(lockFile, elapsed, timeout);
  final remaining = timeout - elapsed.elapsed;
  final requested = Duration(milliseconds: delayMs);
  return requested < remaining ? requested : remaining;
}

void _waitForGuardRetrySync(
  File lockFile,
  Stopwatch elapsed,
  Duration timeout,
  int delayMs,
) {
  sleep(_guardRetryDelay(lockFile, elapsed, timeout, delayMs));
  _requireAcquisitionTime(lockFile, elapsed, timeout);
}

Future<void> _waitForGuardRetry(
  File lockFile,
  Stopwatch elapsed,
  Duration timeout,
  int delayMs,
) async {
  await Future<void>.delayed(
    _guardRetryDelay(lockFile, elapsed, timeout, delayMs),
  );
  _requireAcquisitionTime(lockFile, elapsed, timeout);
}

_FileClaim? _tryCreateClaim(
  File lockFile,
  GuardFileHardener hardenClaim,
) {
  final claimFile = File('${lockFile.path}.claim');
  final owner = '$pid.${_randomSuffix(18)}';
  try {
    claimFile.createSync(exclusive: true);
  } on FileSystemException catch (error) {
    final type = FileSystemEntity.typeSync(
      claimFile.path,
      followLinks: false,
    );
    if (shouldRetryExclusiveCreateFailure(error, type)) {
      // The owner can release and delete its claim after this process loses
      // the exclusive create but before the type probe. That is ordinary lock
      // contention, not an unavailable store, so return to the retry loop.
      return null;
    }
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.notFound) {
      rethrow;
    }
    throw FileSystemException('invalid lock claim', claimFile.path);
  }
  try {
    claimFile.writeAsStringSync(
      jsonEncode({'pid': pid, 'owner': owner}),
      flush: true,
    );
    hardenClaim(claimFile);
    return _FileClaim(claimFile, owner);
  } catch (_) {
    _deleteOwnedClaim(claimFile, owner);
    rethrow;
  }
}

InterprocessFileGuard? _lockClaimSync(File lockFile, _FileClaim claim) {
  final lock = lockFile.openSync(mode: FileMode.write);
  try {
    try {
      lock.lockSync(FileLock.exclusive);
    } on FileSystemException catch (error) {
      if (_isNativeLockContention(error)) throw const _NativeLockContended();
      rethrow;
    }
    if (!_claimIsOwnedBy(claim.file, claim.owner)) {
      if (!_releaseNativeLock(lock)) {
        throw FileSystemException('could not release lock', lockFile.path);
      }
      return null;
    }
    return InterprocessFileGuard._(lock, claim.file, claim.owner);
  } catch (_) {
    if (_releaseNativeLock(lock)) {
      _deleteOwnedClaim(claim.file, claim.owner);
    }
    rethrow;
  }
}

Future<InterprocessFileGuard?> _lockClaim(
  File lockFile,
  _FileClaim claim,
) async {
  final lock = lockFile.openSync(mode: FileMode.write);
  try {
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      if (_isNativeLockContention(error)) throw const _NativeLockContended();
      rethrow;
    }
    if (!_claimIsOwnedBy(claim.file, claim.owner)) {
      if (!_releaseNativeLock(lock)) {
        throw FileSystemException('could not release lock', lockFile.path);
      }
      return null;
    }
    return InterprocessFileGuard._(lock, claim.file, claim.owner);
  } catch (_) {
    if (_releaseNativeLock(lock)) {
      _deleteOwnedClaim(claim.file, claim.owner);
    }
    rethrow;
  }
}

bool _tryReclaimStaleClaim(File lockFile) {
  final claimFile = File('${lockFile.path}.claim');
  final before = _readClaimSnapshot(claimFile);
  if (before == null) return true;
  final age = DateTime.now().difference(before.modified);
  if (age < _claimProbeGrace || age.isNegative) return false;

  // A same-process POSIX lock cannot distinguish isolates. Internal guarded
  // operations are bounded well below this interval, which also lets an
  // abandoned isolate claim recover without waiting for process exit.
  if (!Platform.isWindows &&
      (before.pid == null || before.pid == pid) &&
      age < _sameProcessClaimStaleAfter) {
    return false;
  }

  final lock = lockFile.openSync(mode: FileMode.write);
  var locked = false;
  var nativeReleased = false;
  try {
    try {
      lock.lockSync(FileLock.exclusive);
      locked = true;
    } on FileSystemException catch (error) {
      if (_isNativeLockContention(error)) return false;
      rethrow;
    }
    final after = _readClaimSnapshot(claimFile);
    if (after == null) return true;
    if (!before.sameGeneration(after)) return false;
    final currentAge = DateTime.now().difference(after.modified);
    if (currentAge < _claimProbeGrace || currentAge.isNegative) return false;
    if (!Platform.isWindows &&
        (after.pid == null || after.pid == pid) &&
        currentAge < _sameProcessClaimStaleAfter) {
      return false;
    }
    // Mark this generation dead while the native lock is still held. Keeping a
    // claim at the path prevents a peer isolate from publishing a successor
    // until after the native lock is released. A suspended original claimant
    // also rechecks ownership after it acquires the native lock and cannot enter
    // with this tombstoned generation.
    final tombstoneOwner = 'reclaimed.$pid.${_randomSuffix(18)}';
    claimFile.writeAsStringSync(
      jsonEncode({'pid': pid, 'owner': tombstoneOwner, 'reclaimed': true}),
      flush: true,
    );
    nativeReleased = _releaseNativeLock(lock);
    if (!nativeReleased) {
      throw FileSystemException('could not release lock', lockFile.path);
    }
    locked = false;
    _deleteOwnedClaim(claimFile, tombstoneOwner);
    return true;
  } finally {
    if (!nativeReleased) {
      if (locked) {
        try {
          lock.unlockSync();
        } catch (_) {}
      }
      lock.closeSync();
    }
  }
}

bool _claimIsOwnedBy(File claimFile, String owner) {
  try {
    return _readClaimSnapshot(claimFile)?.owner == owner;
  } catch (_) {
    return false;
  }
}

bool _releaseNativeLock(RandomAccessFile lock) {
  var released = false;
  try {
    lock.unlockSync();
    released = true;
  } catch (_) {}
  try {
    lock.closeSync();
    released = true;
  } catch (_) {}
  return released;
}

bool _isNativeLockContention(FileSystemException error) {
  final code = error.osError?.errorCode;
  if (Platform.isWindows) return code == 32 || code == 33;
  // POSIX F_SETLK reports a held lock as EAGAIN or EACCES. EAGAIN is 11 on
  // Linux but 35 on macOS/BSD; EACCES is 13. The handle is already open for
  // write, so an EACCES here is lock contention, not a permission failure.
  return code == 11 || code == 13 || code == 35;
}

bool _isTransientWindowsContention(FileSystemException error) {
  if (!Platform.isWindows) return false;
  final code = error.osError?.errorCode;
  return code == 32 || code == 33;
}

_FileClaimSnapshot? _readClaimSnapshot(File claimFile) {
  RandomAccessFile? handle;
  try {
    if (!claimFile.existsSync()) return null;
    if (FileSystemEntity.typeSync(claimFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('invalid lock claim', claimFile.path);
    }
    final before = claimFile.statSync();
    if (before.size > _maxClaimBytes) {
      throw FileSystemException('oversized lock claim', claimFile.path);
    }
    handle = claimFile.openSync(mode: FileMode.read);
    final bytes = handle.readSync(_maxClaimBytes + 1);
    if (bytes.length > _maxClaimBytes) {
      throw FileSystemException('oversized lock claim', claimFile.path);
    }
    final afterType = FileSystemEntity.typeSync(
      claimFile.path,
      followLinks: false,
    );
    if (afterType == FileSystemEntityType.notFound) return null;
    if (afterType != FileSystemEntityType.file) {
      throw FileSystemException('invalid lock claim', claimFile.path);
    }
    final after = claimFile.statSync();
    if (before.size != after.size || before.modified != after.modified) {
      return null;
    }
    final raw = utf8.decode(bytes);
    int? ownerPid;
    String? owner;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        ownerPid = decoded['pid'] is int ? decoded['pid'] as int : null;
        owner = decoded['owner'] is String ? decoded['owner'] as String : null;
      }
    } catch (_) {}
    return _FileClaimSnapshot(
      raw: raw,
      modified: after.modified,
      pid: ownerPid,
      owner: owner,
    );
  } on FileSystemException catch (error) {
    final code = error.osError?.errorCode;
    if (code == 2 || code == 3) return null;
    if (!claimFile.existsSync()) return null;
    rethrow;
  } finally {
    handle?.closeSync();
  }
}

void _deleteOwnedClaim(File claimFile, String owner) {
  try {
    final snapshot = _readClaimSnapshot(claimFile);
    if (snapshot?.owner != owner) return;
    claimFile.deleteSync();
  } catch (_) {}
}

String _randomSuffix(int byteCount) {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(byteCount, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

class _FileClaim {
  final File file;
  final String owner;

  const _FileClaim(this.file, this.owner);
}

class _NativeLockContended implements Exception {
  const _NativeLockContended();
}

class _FileClaimSnapshot {
  final String raw;
  final DateTime modified;
  final int? pid;
  final String? owner;

  const _FileClaimSnapshot({
    required this.raw,
    required this.modified,
    required this.pid,
    required this.owner,
  });

  bool sameGeneration(_FileClaimSnapshot other) =>
      raw == other.raw && modified == other.modified;
}
