import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import '../parsing.dart';
import '../sqlite_loader.dart';
import '../util.dart';

/// Windsurf / Devin adapter.
/// Supports both the legacy Windsurf IDE and the current Devin (Desktop + CLI).
/// IDE/Desktop: parses local state.vscdb cachedPlanInfo for daily/weekly quota.
/// CLI-only: passive detection via devin config/credentials (no rich local quota cache).
/// Passive for free tier or no sub.
class WindsurfAdapter {
  static const id = 'windsurf';
  static const name = 'Windsurf';
  static bool _sqliteReady = false;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final dbPath = _findWindsurfDbPath();
      final hasDevinCli = _hasDevinCli();
      if (dbPath == null) {
        String account = hasDevinCli ? 'cli' : 'installed';
        if (hasDevinCli) {
          // Try to pull org/account from devin CLI config for better identification
          final cfgPath = _findDevinConfigPath();
          if (cfgPath != null) {
            try {
              final cfg = jsonDecode(File(cfgPath).readAsStringSync());
              String? org;
              if (cfg is Map) {
                final devin = cfg['devin'];
                if (devin is Map) org = devin['org_id'] as String?;
              }
              if (org != null && org.isNotEmpty) {
                account = org.length > 12 ? org.substring(0, 12) + '...' : org;
              }
            } catch (_) {}
          }
        }
        final msg = hasDevinCli
            ? 'Devin (Windsurf) CLI installed (no local quota cache like state.vscdb; full data in Devin Desktop IDE or check app.devin.ai)'
            : 'Windsurf installed (free tier or no data; check IDE usage)';
        return ProviderQuota(
          provider: id,
          displayName: name,
          account: account,
          plan: null,
          asOf: asOf,
          ok: true,
          error: msg,
          windows: const [],
        );
      }

      final usageData = _readWindsurfUsage(dbPath);
      final windows = windsurfWindows(usageData, asOf);

      String? err;
      if (windows.isEmpty) {
        err = 'no quota data found in local state';
      } else {
        final main = windows.first;
        if ((main.percent ?? 0) >= 99.5) {
          err = 'out of quota (resets ${_resetLabel(main.resetsAt, asOf)})';
        }
      }

      return ProviderQuota(
        provider: id,
        displayName: name,
        account: 'default',
        plan: null,
        asOf: asOf,
        windows: windows,
        error: err,
      );
    } catch (_) {
      return ProviderQuota.error(
        id,
        name,
        'unable to read Windsurf state',
        asOf,
      );
    }
  }

  Map<String, dynamic>? _readWindsurfUsage(String dbPath) {
    _ensureSqlite();
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      // Preferred: exact key from research on Windsurf (post quota change) local cache.
      var rows = db.select(
        "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' LIMIT 1;",
      );
      if (rows.isEmpty) {
        rows = db.select(
          "SELECT value FROM ItemTable WHERE key LIKE '%cachedPlanInfo%' OR key LIKE '%codeium.windsurf%' LIMIT 3;",
        );
      }
      for (final row in rows) {
        final raw = row['value'];
        if (raw is List<int>) {
          try {
            final str = utf8.decode(raw, allowMalformed: true);
            final parsed = jsonDecode(str) as Map<String, dynamic>;
            if (parsed.isNotEmpty) return parsed;
          } catch (_) {
            // fallback to raw string scan
            final str = String.fromCharCodes(
              raw.where((b) => b < 128 && b > 31),
            );
            if (str.contains('quota') ||
                str.contains('usage') ||
                str.contains('messages')) {
              return {'raw': str};
            }
          }
        } else if (raw is String) {
          try {
            return jsonDecode(raw) as Map<String, dynamic>;
          } catch (_) {}
        }
      }
      // last resort broad scan
      rows = db.select(
        "SELECT value FROM ItemTable WHERE key LIKE '%usage%' OR key LIKE '%quota%' LIMIT 3;",
      );
      for (final row in rows) {
        final raw = row['value'];
        if (raw is List<int>) {
          try {
            final str = utf8.decode(raw, allowMalformed: true);
            final p = jsonDecode(str);
            if (p is Map) return Map<String, dynamic>.from(p);
          } catch (_) {}
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      db.dispose();
    }
  }

  static String? _findDevinConfigPath() {
    final app = Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
    final candidates = ['$app/devin/config.json', '$app/Devin/config.json'];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static bool _hasDevinCli() {
    final candidates = <String>[];
    if (Platform.isWindows) {
      final local =
          Platform.environment['LOCALAPPDATA'] ?? '${home()}/AppData/Local';
      final app =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      candidates.addAll([
        '$local/devin/cli/bin/devin.exe',
        '$app/devin/cli/bin/devin.exe',
        '$app/Devin/cli/bin/devin.exe',
      ]);
    } else {
      candidates.addAll([
        '${home()}/.devin/cli/bin/devin',
        '${home()}/.local/bin/devin',
      ]);
    }
    for (final p in candidates) {
      if (File(p).existsSync()) return true;
    }
    // Also detect pure CLI via config/credentials (common when only CLI is installed)
    final app = Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
    if (File('$app/devin/credentials.toml').existsSync() ||
        File('$app/devin/config.json').existsSync() ||
        File('$app/Devin/credentials.toml').existsSync()) {
      return true;
    }
    return false;
  }

  static String? _findWindsurfDbPath() {
    final candidates = <String>[];
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      final localApp =
          Platform.environment['LOCALAPPDATA'] ?? '${home()}/AppData/Local';
      candidates.addAll([
        '$appData/Windsurf/User/globalStorage/state.vscdb',
        '$appData/.codeium/windsurf/User/globalStorage/state.vscdb',
        '${home()}/AppData/Roaming/.codeium/windsurf/User/globalStorage/state.vscdb',
        '$appData/Devin/User/globalStorage/state.vscdb',
        '$appData/devin/User/globalStorage/state.vscdb',
        '$localApp/Programs/Devin/User/globalStorage/state.vscdb',
        '$appData/Devin/globalStorage/state.vscdb',
      ]);
    } else if (Platform.isMacOS) {
      candidates.addAll([
        '${home()}/Library/Application Support/Windsurf/User/globalStorage/state.vscdb',
        '${home()}/Library/Application Support/.codeium/windsurf/User/globalStorage/state.vscdb',
        '${home()}/Library/Application Support/Devin/User/globalStorage/state.vscdb',
      ]);
    } else {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '${home()}/.local/share';
      candidates.addAll([
        '$dataHome/Windsurf/User/globalStorage/state.vscdb',
        '$dataHome/.codeium/windsurf/User/globalStorage/state.vscdb',
        '$dataHome/Devin/User/globalStorage/state.vscdb',
      ]);
    }
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  void _ensureSqlite() {
    if (_sqliteReady) return;
    configureSqliteLibrary();
    _sqliteReady = true;
  }
}

String _resetLabel(int? resetsAt, int now) {
  if (resetsAt == null) return 'soon';
  final secs = resetsAt - now;
  if (secs <= 0) return 'now';
  final d = secs ~/ 86400;
  if (d > 0) return '${d}d';
  final h = secs ~/ 3600;
  return '${h}h';
}
