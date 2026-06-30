import 'dart:io';

/// User home directory across platforms.
String home() =>
    Platform.environment['USERPROFILE'] ??
    Platform.environment['HOME'] ??
    Directory.current.path;

/// Current unix epoch seconds.
int nowEpoch() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Per-user config/data base directory for quotabot, created if missing.
Directory quotabotDir(String sub) {
  final base = Platform.environment['LOCALAPPDATA'] ??
      Platform.environment['XDG_CONFIG_HOME'] ??
      '${home()}/.config';
  final dir = Directory('$base/quotabot/$sub');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Best-effort owner-only permissions for local metadata files.
///
/// On POSIX this is `chmod 600`. On Windows it removes inherited ACEs and grants
/// full control only to the current user. Failures are intentionally ignored so
/// metadata writes stay fail-soft on locked-down enterprise machines.
void restrictOwnerOnlyFile(File file) {
  try {
    if (Platform.isWindows) {
      final user = windowsAclPrincipal();
      if (user == null) return;
      Process.runSync('icacls', [file.path, '/inheritance:r']);
      Process.runSync('icacls', [file.path, '/grant:r', '$user:F']);
    } else {
      Process.runSync('chmod', ['600', file.path]);
    }
  } catch (_) {}
}

/// Best-effort owner-only permissions for local metadata directories.
///
/// On POSIX this is `chmod 700`. On Windows it removes inherited ACEs and grants
/// recursive full control only to the current user.
void restrictOwnerOnlyDirectory(Directory dir) {
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (Platform.isWindows) {
      final user = windowsAclPrincipal();
      if (user == null) return;
      Process.runSync('icacls', [dir.path, '/inheritance:r']);
      Process.runSync('icacls', [dir.path, '/grant:r', '${user}:(OI)(CI)F']);
    } else {
      Process.runSync('chmod', ['700', dir.path]);
    }
  } catch (_) {}
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
/// JSON tree (maps/lists). Returns null if absent.
dynamic findKey(dynamic node, String key) {
  if (node is Map) {
    if (node.containsKey(key)) return node[key];
    for (final v in node.values) {
      final found = findKey(v, key);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final v in node) {
      final found = findKey(v, key);
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
/// recursing into nested messages.
Iterable<String> protoStrings(List<int> b) sync* {
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
      if (i + len > b.length) break;
      final chunk = b.sublist(i, i + len);
      i += len;
      final txt = asciiString(chunk);
      if (txt != null) {
        yield txt;
      } else {
        yield* protoStrings(chunk);
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
