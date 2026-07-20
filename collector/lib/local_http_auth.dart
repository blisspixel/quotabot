import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'file_guard.dart';
import 'util.dart';

const _maxLocalHttpMutationTokenFileBytes = 4096;
final _localHttpMutationTokenPattern = RegExp(r'^[A-Za-z0-9_-]{32,128}$');

typedef LocalHttpMutationTokenFactory = String Function();

Directory localHttpMutationTokenDir() => quotabotDir('http');

File localHttpMutationTokenFile({Directory Function()? dirFactory}) {
  final dir = (dirFactory ?? localHttpMutationTokenDir)();
  return File('${dir.path}/mutation_token');
}

bool isValidLocalHttpMutationToken(Object? value) =>
    value is String && _localHttpMutationTokenPattern.hasMatch(value);

String randomLocalHttpMutationToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

T _withLocalHttpMutationTokenLock<T>(File tokenFile, T Function() run) {
  final lockFile = File('${tokenFile.path}.lock');
  if (!lockFile.existsSync()) {
    try {
      lockFile.createSync(exclusive: true);
    } on FileSystemException {
      if (!lockFile.existsSync()) rethrow;
    }
  }
  if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw FileSystemException(
      'invalid local HTTP mutation token lock',
      lockFile.path,
    );
  }
  enforceOwnerOnlyFile(lockFile);
  final guard = acquireInterprocessFileGuardSync(
    lockFile,
    hardenClaim: enforceOwnerOnlyFile,
  );
  try {
    return run();
  } finally {
    guard.release();
  }
}

File _createLocalHttpMutationTokenTemp(File tokenFile) {
  final random = Random.secure();
  for (var attempt = 0; attempt < 16; attempt++) {
    final suffix = base64UrlEncode(
      List<int>.generate(12, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final temporary = File('${tokenFile.path}.$pid.$suffix.tmp');
    try {
      temporary.createSync(exclusive: true);
      return temporary;
    } on FileSystemException {
      if (!temporary.existsSync()) rethrow;
    }
  }
  throw FileSystemException(
    'could not create local HTTP mutation token temporary file',
    tokenFile.path,
  );
}

/// Loads the stable per-user bearer token used by loopback HTTP mutations.
///
/// First-start creation is serialized across processes. The token is written to
/// an owner-only same-directory temporary file and published only after the
/// complete value is flushed. Existing files are permission-checked before they
/// are read. Any invalid or insecure token fails closed instead of being
/// silently replaced.
String loadOrCreateLocalHttpMutationToken({
  Directory Function()? dirFactory,
  LocalHttpMutationTokenFactory tokenFactory = randomLocalHttpMutationToken,
}) {
  final file = localHttpMutationTokenFile(dirFactory: dirFactory);
  enforceOwnerOnlyDirectory(file.parent);

  String readExisting() {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException(
          'local HTTP mutation token disappeared', file.path);
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'invalid local HTTP mutation token file',
        file.path,
      );
    }
    enforceOwnerOnlyFile(file);
    final size = file.lengthSync();
    if (size < 32 || size > _maxLocalHttpMutationTokenFileBytes) {
      throw FileSystemException('invalid local HTTP mutation token', file.path);
    }
    final token = file.readAsStringSync().trim();
    if (!isValidLocalHttpMutationToken(token)) {
      throw FileSystemException('invalid local HTTP mutation token', file.path);
    }
    return token;
  }

  if (file.existsSync()) return readExisting();

  return _withLocalHttpMutationTokenLock(file, () {
    if (file.existsSync()) return readExisting();

    final token = tokenFactory();
    if (!isValidLocalHttpMutationToken(token)) {
      throw StateError(
          'local HTTP mutation token factory returned invalid data');
    }
    if (file.existsSync()) return readExisting();

    final temporary = _createLocalHttpMutationTokenTemp(file);
    try {
      enforceOwnerOnlyFile(temporary);
      temporary.writeAsStringSync('$token\n', flush: true);
      if (file.existsSync()) return readExisting();
      try {
        temporary.renameSync(file.path);
      } on FileSystemException {
        if (file.existsSync()) return readExisting();
        rethrow;
      }
      return token;
    } finally {
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (_) {}
    }
  });
}
