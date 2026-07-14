import 'dart:async';
import 'dart:io';

Directory? _quotabotDirOverrideForTesting;

/// User home directory across platforms.
String home() =>
    Platform.environment['USERPROFILE'] ??
    Platform.environment['HOME'] ??
    Directory.current.path;

/// Current unix epoch seconds.
int nowEpoch() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Parses an HTTP Retry-After header into a non-negative delay in seconds.
/// Accepts both RFC 9110 forms: delay seconds and HTTP-date.
int? retryAfterSeconds(String? value, {int? now}) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  final seconds = int.tryParse(raw);
  if (seconds != null) return seconds < 0 ? null : seconds;
  try {
    final retryAt = HttpDate.parse(raw).toUtc();
    final base = DateTime.fromMillisecondsSinceEpoch(
      (now ?? nowEpoch()) * 1000,
      isUtc: true,
    );
    final delta = retryAt.difference(base).inSeconds;
    return delta < 0 ? 0 : delta;
  } catch (_) {
    return null;
  }
}

/// Overrides quotabot's config root for tests that exercise persistent stores.
///
/// Production code must leave this unset. It exists so parallel package tests do
/// not read, write, or delete the developer's real local grants.
void setQuotabotDirOverrideForTesting(Directory? directory) {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw UnsupportedError('test config override is unavailable in release');
  }
  _quotabotDirOverrideForTesting = directory;
}

/// Per-user config/data base directory for quotabot, created if missing.
Directory quotabotDir(String sub) {
  final base = _quotabotDirOverrideForTesting?.path ??
      Platform.environment['LOCALAPPDATA'] ??
      Platform.environment['XDG_CONFIG_HOME'] ??
      '${home()}/.config';
  final dir = Directory('$base/quotabot/$sub');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

typedef PermissionCommandRunner = ProcessResult Function(
  String executable,
  List<String> arguments,
);

typedef AsyncPermissionCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
  Duration timeout,
);

ProcessResult _runPermissionCommand(
  String executable,
  List<String> arguments,
) =>
    Process.runSync(executable, arguments);

Future<ProcessResult> _runPermissionCommandAsync(
  String executable,
  List<String> arguments,
  Duration timeout,
) async {
  Process? process;
  final elapsed = Stopwatch()..start();
  try {
    process = await Process.start(executable, arguments).timeout(timeout);
    final stdout = process.stdout.transform(systemEncoding.decoder).join();
    final stderr = process.stderr.transform(systemEncoding.decoder).join();
    final remaining = timeout - elapsed.elapsed;
    if (remaining.inMicroseconds <= 0) throw TimeoutException('permission');
    final results = await Future.wait<Object>([
      process.exitCode,
      stdout,
      stderr,
    ]).timeout(remaining);
    return ProcessResult(
      process.pid,
      results[0] as int,
      results[1] as String,
      results[2] as String,
    );
  } on TimeoutException {
    process?.kill();
    throw const _PermissionHardeningFailed();
  }
}

Duration _remainingPermissionTime(Stopwatch elapsed, Duration timeout) {
  final remaining = timeout - elapsed.elapsed;
  if (remaining.inMicroseconds <= 0) {
    throw const _PermissionHardeningFailed();
  }
  return remaining;
}

/// Enforces owner-only permissions on [file] or throws without exposing command
/// output. Credential stores use this checked boundary before writing secrets.
void enforceOwnerOnlyFile(
  File file, {
  PermissionCommandRunner? run,
  WindowsIdentityLookup? identityLookup,
}) {
  final execute = run ?? _runPermissionCommand;
  try {
    if (Platform.isWindows) {
      final user = windowsAclPrincipal(lookup: identityLookup);
      if (user == null) throw const _PermissionHardeningFailed();
      _enforceWindowsOwnerOnly(
        execute,
        file.path,
        user,
        isDirectory: false,
      );
    } else {
      _requirePermissionCommand(execute('chmod', ['600', file.path]));
      if (Platform.isMacOS) {
        _requirePermissionCommand(execute('chmod', ['-N', file.path]));
      }
      if (file.statSync().mode & 0x3f != 0) {
        throw const _PermissionHardeningFailed();
      }
    }
  } on FileSystemException {
    rethrow;
  } catch (_) {
    throw FileSystemException(
      'could not enforce owner-only file permissions',
      file.path,
    );
  }
}

/// Asynchronously enforces owner-only permissions on [file] within [timeout].
/// Desktop startup uses this boundary so a stalled platform helper cannot block
/// the first window indefinitely.
Future<void> enforceOwnerOnlyFileAsync(
  File file, {
  Duration timeout = const Duration(seconds: 3),
  AsyncPermissionCommandRunner? run,
}) async {
  final execute = run ?? _runPermissionCommandAsync;
  final elapsed = Stopwatch()..start();
  try {
    if (Platform.isWindows) {
      final remaining = _remainingPermissionTime(elapsed, timeout);
      await _enforceWindowsOwnerOnlyAsync(
        execute,
        file.path,
        isDirectory: false,
        timeout: remaining,
      ).timeout(remaining);
    } else {
      Future<void> checked(String executable, List<String> arguments) async {
        final remaining = _remainingPermissionTime(elapsed, timeout);
        final result = await execute(
          executable,
          arguments,
          remaining,
        ).timeout(remaining);
        _requirePermissionCommand(result);
      }

      await checked('chmod', ['600', file.path]);
      if (Platform.isMacOS) await checked('chmod', ['-N', file.path]);
      if (file.statSync().mode & 0x3f != 0) {
        throw const _PermissionHardeningFailed();
      }
    }
  } on FileSystemException {
    rethrow;
  } catch (_) {
    throw FileSystemException(
      'could not enforce owner-only file permissions',
      file.path,
    );
  }
}

/// Best-effort owner-only permissions for non-secret local metadata files.
///
/// Failures are intentionally ignored so cache and history writes stay
/// fail-soft on locked-down enterprise machines. Credential stores must call
/// [enforceOwnerOnlyFile] instead.
void restrictOwnerOnlyFile(File file) {
  try {
    if (Platform.isWindows) {
      final user = windowsAclPrincipal();
      if (user == null) return;
      Process.runSync('icacls', [file.path, '/inheritance:r']);
      Process.runSync('icacls', [file.path, '/grant:r', '$user:F']);
    } else {
      Process.runSync('chmod', ['600', file.path]);
      if (Platform.isMacOS) Process.runSync('chmod', ['-N', file.path]);
    }
  } catch (_) {}
}

/// Enforces owner-only permissions on [dir] or throws without exposing command
/// output. Credential stores use this checked boundary before creating files.
void enforceOwnerOnlyDirectory(
  Directory dir, {
  PermissionCommandRunner? run,
  WindowsIdentityLookup? identityLookup,
}) {
  final execute = run ?? _runPermissionCommand;
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (Platform.isWindows) {
      final user = windowsAclPrincipal(lookup: identityLookup);
      if (user == null) throw const _PermissionHardeningFailed();
      _enforceWindowsOwnerOnly(
        execute,
        dir.path,
        user,
        isDirectory: true,
      );
    } else {
      _requirePermissionCommand(execute('chmod', ['700', dir.path]));
      if (Platform.isMacOS) {
        _requirePermissionCommand(execute('chmod', ['-N', dir.path]));
      }
      if (dir.statSync().mode & 0x3f != 0) {
        throw const _PermissionHardeningFailed();
      }
    }
  } on FileSystemException {
    rethrow;
  } catch (_) {
    throw FileSystemException(
      'could not enforce owner-only directory permissions',
      dir.path,
    );
  }
}

/// Asynchronously enforces owner-only permissions on [dir] within [timeout].
Future<void> enforceOwnerOnlyDirectoryAsync(
  Directory dir, {
  Duration timeout = const Duration(seconds: 3),
  AsyncPermissionCommandRunner? run,
}) async {
  final execute = run ?? _runPermissionCommandAsync;
  final elapsed = Stopwatch()..start();
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (Platform.isWindows) {
      final remaining = _remainingPermissionTime(elapsed, timeout);
      await _enforceWindowsOwnerOnlyAsync(
        execute,
        dir.path,
        isDirectory: true,
        timeout: remaining,
      ).timeout(remaining);
    } else {
      Future<void> checked(String executable, List<String> arguments) async {
        final remaining = _remainingPermissionTime(elapsed, timeout);
        final result = await execute(
          executable,
          arguments,
          remaining,
        ).timeout(remaining);
        _requirePermissionCommand(result);
      }

      await checked('chmod', ['700', dir.path]);
      if (Platform.isMacOS) await checked('chmod', ['-N', dir.path]);
      if (dir.statSync().mode & 0x3f != 0) {
        throw const _PermissionHardeningFailed();
      }
    }
  } on FileSystemException {
    rethrow;
  } catch (_) {
    throw FileSystemException(
      'could not enforce owner-only directory permissions',
      dir.path,
    );
  }
}

/// Best-effort owner-only permissions for non-secret metadata directories.
void restrictOwnerOnlyDirectory(Directory dir) {
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (Platform.isWindows) {
      final user = windowsAclPrincipal();
      if (user == null) return;
      Process.runSync('icacls', [dir.path, '/inheritance:r']);
      Process.runSync('icacls', [dir.path, '/grant:r', '$user:(OI)(CI)F']);
    } else {
      Process.runSync('chmod', ['700', dir.path]);
      if (Platform.isMacOS) Process.runSync('chmod', ['-N', dir.path]);
    }
  } catch (_) {}
}

void _requirePermissionCommand(ProcessResult result) {
  if (result.exitCode != 0) throw const _PermissionHardeningFailed();
}

void _enforceWindowsOwnerOnly(
  PermissionCommandRunner execute,
  String path,
  String user, {
  required bool isDirectory,
}) {
  // Ownership carries implicit WRITE_DAC on Windows. Reject a foreign owner,
  // then apply one complete protected DACL so a crash cannot leave a partially
  // reset ACL around existing credentials.
  final sid = user.startsWith('*') ? user.substring(1) : user;
  final command = _windowsOwnerOnlyCommand(
    path,
    isDirectory: isDirectory,
    knownSid: sid,
  );
  _requirePermissionCommand(
    execute('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]),
  );
}

Future<void> _enforceWindowsOwnerOnlyAsync(
  AsyncPermissionCommandRunner execute,
  String path, {
  required bool isDirectory,
  required Duration timeout,
}) async {
  final command = _windowsOwnerOnlyCommand(path, isDirectory: isDirectory);
  final result = await execute(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        command,
      ],
      timeout);
  _requirePermissionCommand(result);
}

String _windowsOwnerOnlyCommand(
  String path, {
  required bool isDirectory,
  String? knownSid,
}) {
  final securityClass = isDirectory ? 'DirectorySecurity' : 'FileSecurity';
  final ioClass = isDirectory ? 'Directory' : 'File';
  final inheritance = isDirectory ? 'ContainerInherit, ObjectInherit' : 'None';
  final sidSetup = knownSid == null
      ? '\$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User;'
      : "\$sid=[System.Security.Principal.SecurityIdentifier]::new('$knownSid');";
  return "\$ErrorActionPreference='Stop';$sidSetup"
      "\$owner=[System.IO.$ioClass]::GetAccessControl("
      "'${path.replaceAll("'", "''")}').GetOwner("
      '[System.Security.Principal.SecurityIdentifier]);'
      "if(\$owner.Value -ne \$sid.Value){throw 'owner mismatch'};"
      "\$acl=[System.Security.AccessControl.$securityClass]::new();"
      '\$acl.SetAccessRuleProtection(\$true,\$false);'
      '\$rule=[System.Security.AccessControl.FileSystemAccessRule]::new('
      '\$sid,[System.Security.AccessControl.FileSystemRights]::FullControl,'
      "[System.Security.AccessControl.InheritanceFlags]'$inheritance',"
      '[System.Security.AccessControl.PropagationFlags]::None,'
      '[System.Security.AccessControl.AccessControlType]::Allow);'
      '\$acl.AddAccessRule(\$rule);'
      "[System.IO.$ioClass]::SetAccessControl("
      "'${path.replaceAll("'", "''")}',\$acl);"
      "\$finalOwner=[System.IO.$ioClass]::GetAccessControl("
      "'${path.replaceAll("'", "''")}').GetOwner("
      '[System.Security.Principal.SecurityIdentifier]);'
      "if(\$finalOwner.Value -ne \$sid.Value){throw 'owner changed'};";
}

class _PermissionHardeningFailed implements Exception {
  const _PermissionHardeningFailed();
}

typedef WindowsIdentityLookup = ProcessResult Function();

String? windowsAclPrincipal({WindowsIdentityLookup? lookup}) {
  try {
    final result = lookup?.call() ??
        Process.runSync('whoami', const ['/user', '/fo', 'csv']);
    if (result.exitCode != 0) return null;
    return parseWhoamiUserSid(result.stdout.toString());
  } catch (_) {
    return null;
  }
}

String? parseWhoamiUserSid(String output) {
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final columns = _parseCsvLine(line);
    if (columns.length >= 2 && columns[1].startsWith('S-1-')) {
      return '*${columns[1]}';
    }
  }
  return null;
}

List<String> _parseCsvLine(String line) {
  final values = <String>[];
  final current = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        current.write(char);
      }
    } else if (char == ',') {
      values.add(current.toString());
      current.clear();
    } else if (char == '"') {
      quoted = true;
    } else {
      current.write(char);
    }
  }
  values.add(current.toString());
  return values;
}

/// Recursively find the first value stored under [key] anywhere in a decoded
/// JSON tree (maps/lists). Returns null if absent. [maxDepth] bounds the
/// recursion so a deeply-nested tree (for example from an attacker-written
/// `state.vscdb` value) cannot overflow the stack; legitimate provider blobs are
/// only a few levels deep.
dynamic findKey(dynamic node, String key, {int maxDepth = 64}) {
  if (maxDepth <= 0) return null;
  if (node is Map) {
    if (node.containsKey(key)) return node[key];
    for (final v in node.values) {
      final found = findKey(v, key, maxDepth: maxDepth - 1);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final v in node) {
      final found = findKey(v, key, maxDepth: maxDepth - 1);
      if (found != null) return found;
    }
  }
  return null;
}

/// Reads a base-128 varint from [b] at [i]. Returns (value, nextIndex), or
/// (null, i) if the buffer ends mid-varint.
(int?, int) readVarint(List<int> b, int i) {
  var result = 0, shift = 0;
  while (i < b.length) {
    final x = b[i++];
    result |= (x & 0x7f) << shift;
    if (x & 0x80 == 0) return (result, i);
    shift += 7;
    if (shift > 63) break;
  }
  return (null, i);
}

/// Yields printable, length-delimited strings from a protobuf byte stream,
/// recursing into nested messages. The depth cap matches the other schema-less
/// walkers so a deeply nested untrusted payload cannot exhaust the stack.
Iterable<String> protoStrings(List<int> b, [int depth = 0]) sync* {
  if (depth > 8) return;
  var i = 0;
  while (i < b.length) {
    final (tag, ni) = readVarint(b, i);
    if (tag == null) break;
    i = ni;
    final wt = tag & 7;
    if (wt == 0) {
      final (_, n2) = readVarint(b, i);
      i = n2;
    } else if (wt == 2) {
      final (len, n2) = readVarint(b, i);
      if (len == null) break;
      i = n2;
      // Subtraction form: a hostile length varint near 2^62 wraps `i + len`
      // negative and would pass an addition-form check into the sublist.
      if (len < 0 || len > b.length - i) break;
      final chunk = b.sublist(i, i + len);
      i += len;
      final txt = asciiString(chunk);
      if (txt != null) {
        yield txt;
      } else {
        yield* protoStrings(chunk, depth + 1);
      }
    } else if (wt == 5) {
      i += 4;
    } else if (wt == 1) {
      i += 8;
    } else {
      break;
    }
  }
}

/// Returns [chunk] as a string if it is mostly printable ASCII, else null.
String? asciiString(List<int> chunk) {
  if (chunk.length < 2) return null;
  var printable = 0;
  for (final c in chunk) {
    if (c >= 0x20 && c < 0x7f) printable++;
  }
  if (printable / chunk.length < 0.9) return null;
  return String.fromCharCodes(chunk);
}

/// Formats model storage or memory bytes for compact quota/status text.
String formatCompactBytes(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
  return '${(bytes / (1024 * 1024)).round()} MB';
}

/// Formats a model context window for compact quota/status text.
String formatContextTokens(int tokens) =>
    tokens >= 1000 ? '${(tokens / 1024).round()}K' : '$tokens';

/// Detects installed popular agentic dev coding CLI/IDE tools by common data dirs.
/// Used for passive robustness even if no active subscription or full adapter data.
Set<String> detectInstalledAgenticTools({
  String? homePath,
  String? appDataPath,
  String? xdgDataPath,
  bool Function(String path)? exists,
}) {
  final detected = <String>{};
  final h = homePath ?? home();
  final appData =
      appDataPath ?? Platform.environment['APPDATA'] ?? '$h/AppData/Roaming';
  final xdg =
      xdgDataPath ?? Platform.environment['XDG_DATA_HOME'] ?? '$h/.local/share';
  final pathExists = exists ?? (path) => Directory(path).existsSync();

  // Kiro (CLI + IDE, VSCode fork, credits)
  if (pathExists('$h/.kiro') ||
      pathExists('$appData/Kiro') ||
      pathExists('$h/Library/Application Support/Kiro') ||
      pathExists('$xdg/kiro')) {
    detected.add('kiro');
  }

  // Cursor (popular IDE with agentic, credits on Pro, local usage)
  if (pathExists('$h/.cursor') ||
      pathExists('$appData/Cursor') ||
      pathExists('$h/Library/Application Support/Cursor') ||
      pathExists('$xdg/cursor')) {
    detected.add('cursor');
  }

  // Windsurf / Devin (now Devin Desktop / Devin CLI; Cascade agentic with daily/weekly quota)
  if (pathExists('$h/.windsurf') ||
      pathExists('$appData/Windsurf') ||
      pathExists('$h/.codeium/windsurf') ||
      pathExists('$appData/.codeium/windsurf') ||
      pathExists('$h/.devin') ||
      pathExists('$appData/devin') ||
      pathExists('$appData/Devin') ||
      pathExists('$appData/Local/devin')) {
    detected.add('windsurf');
  }

  // Antigravity (Google agentic IDE/CLI)
  if (pathExists('$h/.antigravity') ||
      pathExists('$appData/Antigravity') ||
      pathExists('$h/Library/Application Support/Antigravity') ||
      pathExists('$xdg/antigravity')) {
    detected.add('antigravity');
  }

  // Note: Aider, Cline are often model-agnostic (use API keys from Codex/Claude etc.)
  // so covered indirectly. Add if they gain dedicated local quota data.

  return detected;
}
