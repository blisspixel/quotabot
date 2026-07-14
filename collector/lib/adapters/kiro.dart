import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../analysis.dart';
import '../labels.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

/// Kiro (agentic CLI + IDE) adapter.
/// Kiro is a VS Code fork with credit-based usage (interactions/credits).
/// Reads from globalStorage/state.vscdb (kiro.kiroAgent key with usageState).
/// Handles out-of-quota (percentageUsed == 100) and cancelled plans gracefully.
/// Opportunistic (no login needed for local data).
class KiroAdapter {
  static const id = kiroProviderId;
  static const name = kiroProviderName;

  KiroAdapter({String? dbPath}) : _dbPath = dbPath;

  final String? _dbPath;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final dbPath = _dbPath ?? _kiroDbPath();
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
        if (windowHeadroom(main, asOf) <= kSpentHeadroomFloor) {
          err =
              'out of quota (resets ${resetCountdownLabel(main.resetsAt, asOf)})';
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
        perMachine: true,
      );
    } catch (_) {
      return ProviderQuota.error(id, name, 'unable to read Kiro state', asOf);
    }
  }

  Map<String, dynamic>? _readUsageState(String dbPath) {
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
      db.close();
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
}
