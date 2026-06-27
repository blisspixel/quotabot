import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import '../parsing.dart';
import '../sqlite_loader.dart';
import '../util.dart';

/// Cursor adapter (VSCode fork with agentic features and credit system).
/// Local data in ~/.cursor (SQLite state.vscdb like other forks).
/// Opportunistic for free/Pro accounts. Parses for usage/credits if present.
class CursorAdapter {
  static const id = 'cursor';
  static const name = 'Cursor';
  static bool _sqliteReady = false;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final dbPath = _cursorDbPath();
      if (!File(dbPath).existsSync()) {
        return ProviderQuota(
          provider: id,
          displayName: name,
          account: 'installed',
          plan: null,
          asOf: asOf,
          ok: true,
          error:
              'Cursor installed (free tier or no data; check Settings > Usage)',
          windows: const [],
        );
      }

      final usageData = _readCursorUsage(dbPath);
      final windows = cursorWindows(usageData, asOf);

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
      return ProviderQuota.error(id, name, 'unable to read Cursor state', asOf);
    }
  }

  Map<String, dynamic>? _readCursorUsage(String dbPath) {
    _ensureSqlite();
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      // Look for usage/credits keys, similar to Kiro. From research: planUsage, credits, etc in ItemTable.
      final rows = db.select(
        "SELECT value FROM ItemTable WHERE key LIKE '%usage%' OR key LIKE '%credit%' OR key LIKE '%plan%' LIMIT 5;",
      );
      if (rows.isEmpty) return null;
      for (final row in rows) {
        final raw = row['value'];
        if (raw is List<int>) {
          try {
            final str = utf8.decode(raw, allowMalformed: true);
            final parsed = jsonDecode(str) as Map<String, dynamic>;
            if (parsed.containsKey('usageBreakdowns') ||
                parsed.containsKey('planUsage') ||
                parsed.containsKey('credits')) {
              return parsed;
            }
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

  static String _cursorDbPath() {
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      return '$appData/Cursor/User/globalStorage/state.vscdb';
    } else if (Platform.isMacOS) {
      return '${home()}/Library/Application Support/Cursor/User/globalStorage/state.vscdb';
    } else {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '${home()}/.local/share';
      return '$dataHome/Cursor/User/globalStorage/state.vscdb';
    }
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
