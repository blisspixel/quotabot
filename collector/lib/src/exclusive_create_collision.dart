import 'dart:io';

/// Whether an exclusive claim create lost ordinary file-exists contention.
///
/// The observed path can disappear after the failed create when its owner
/// releases it. Platform file-exists errors and Windows sharing or lock
/// collisions are retryable under the caller's acquisition deadline.
/// Permission, path, and other I/O failures remain fatal even if a later probe
/// happens to find a regular file.
bool shouldRetryExclusiveCreateFailure(
  FileSystemException error,
  FileSystemEntityType observedType,
) {
  if (observedType != FileSystemEntityType.file &&
      observedType != FileSystemEntityType.notFound) {
    return false;
  }
  final code = error.osError?.errorCode;
  // EEXIST on POSIX, plus ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION,
  // ERROR_FILE_EXISTS, and ERROR_ALREADY_EXISTS on Windows.
  return code == 17 || code == 32 || code == 33 || code == 80 || code == 183;
}
