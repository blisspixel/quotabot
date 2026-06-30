import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

bool _configured = false;

/// Configures sqlite3 to load only from trusted absolute system paths.
///
/// Avoid unqualified names such as `sqlite3.dll` because they can be resolved
/// from the process working directory or another attacker-controlled search
/// path on some platforms.
void configureSqliteLibrary() {
  if (_configured) return;
  open.overrideForAll(() {
    for (final path in trustedSqliteCandidates()) {
      try {
        return DynamicLibrary.open(path);
      } catch (_) {}
    }
    throw StateError('no trusted sqlite3 library available');
  });
  _configured = true;
}

List<String> trustedSqliteCandidates({bool? isWindows, bool? isMacOS}) {
  final windows = isWindows ?? Platform.isWindows;
  final macOS = isMacOS ?? Platform.isMacOS;
  if (windows) {
    return const [r'C:\Windows\System32\winsqlite3.dll'];
  }
  if (macOS) {
    return const [
      '/usr/lib/libsqlite3.dylib',
      '/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib',
      '/usr/local/opt/sqlite/lib/libsqlite3.dylib',
      '/opt/homebrew/lib/libsqlite3.dylib',
      '/usr/local/lib/libsqlite3.dylib',
    ];
  }
  return const [
    '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
    '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
    '/lib/x86_64-linux-gnu/libsqlite3.so.0',
    '/lib/aarch64-linux-gnu/libsqlite3.so.0',
    '/usr/lib/libsqlite3.so',
    '/usr/lib64/libsqlite3.so',
  ];
}
