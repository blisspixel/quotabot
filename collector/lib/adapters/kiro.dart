import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../sqlite_loader.dart';
import '../util.dart';

/// Kiro (agentic CLI + IDE) adapter.
/// Kiro is a VS Code fork with credit-based usage (interactions/credits).
/// Reads from globalStorage/state.vscdb (kiro.kiroAgent key with usageState).
/// Handles out-of-quota (percentageUsed == 100) and cancelled plans gracefully.
/// Opportunistic (no login needed for local data).
class KiroAdapter {
  static const id = kiroProviderId;
  static const name = kiroProviderName;
  static bool _sqliteReady = false;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final dbPath = _kiroDbPath();
      if (!File(dbPath).existsSync()) {
        // Passive detection for installed but no (or expired) data
        return ProviderQuota(
          provider: id,
          displayName: name,
          account: 'installed',
          plan: null,
          asOf: asOf,
          ok: true,
          error:
              'Kiro installed (no active data or quota read; plan may be cancelled)',
          windows: const [],
        );
      }

      final usageState = _readUsageState(dbPath);
      final windows = kiroWindows(usageState, asOf);

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
      return ProviderQuota.error(id, name, 'unable to read Kiro state', asOf);
    }
  }

  Map<String, dynamic>? _readUsageState(String dbPath) {
    _ensureSqlite();
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final rows = db.select(
        "SELECT value FROM ItemTable WHERE key = 'kiro.kiroAgent';",
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['value'];
      String jsonStr;
      if (raw is List<int>) {
        jsonStr = utf8.decode(raw, allowMalformed: true);
      } else {
        jsonStr = raw.toString();
      }
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return parsed['kiro.resourceNotifications.usageState']
          as Map<String, dynamic>?;
    } catch (_) {
      return null;
    } finally {
      db.dispose();
    }
  }

  static String _kiroDbPath() {
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      return '$appData/Kiro/User/globalStorage/state.vscdb';
    } else if (Platform.isMacOS) {
      return '${home()}/Library/Application Support/Kiro/User/globalStorage/state.vscdb';
    } else {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '${home()}/.local/share';
      return '$dataHome/Kiro/User/globalStorage/state.vscdb';
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
