import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// Loads the stable per-user bearer token used by loopback HTTP mutations.
///
/// A new token file is created empty, locked to the current user, and only then
/// populated. Existing files are permission-checked before they are read. Any
/// invalid or insecure token fails closed instead of being silently replaced.
String loadOrCreateLocalHttpMutationToken({
  Directory Function()? dirFactory,
  LocalHttpMutationTokenFactory tokenFactory = randomLocalHttpMutationToken,
}) {
  final file = localHttpMutationTokenFile(dirFactory: dirFactory);
  enforceOwnerOnlyDirectory(file.parent);

  String readExisting() {
    if (!file.existsSync()) {
      throw FileSystemException(
          'local HTTP mutation token disappeared', file.path);
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

  try {
    file.createSync(exclusive: true);
  } on FileSystemException {
    if (file.existsSync()) return readExisting();
    rethrow;
  }

  try {
    enforceOwnerOnlyFile(file);
    final token = tokenFactory();
    if (!isValidLocalHttpMutationToken(token)) {
      throw StateError(
          'local HTTP mutation token factory returned invalid data');
    }
    file.writeAsStringSync('$token\n', flush: true);
    return token;
  } catch (_) {
    try {
      if (file.existsSync() && file.lengthSync() == 0) file.deleteSync();
    } catch (_) {}
    rethrow;
  }
}
