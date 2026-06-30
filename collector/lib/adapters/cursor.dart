import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../sqlite_loader.dart';
import '../util.dart';
import '../vscode_state.dart';

/// Cursor adapter (VSCode fork with agentic features and credit system).
/// Local data in ~/.cursor (SQLite state.vscdb like other forks).
/// Opportunistic for free/Pro accounts. Parses for usage/credits if present.
class CursorAdapter {
  static const id = cursorProviderId;
  static const name = cursorProviderName;
  static bool _sqliteReady = false;
  final String? _dbPath;

  CursorAdapter({String? dbPath}) : _dbPath = dbPath;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final dbPath = _dbPath ?? _cursorDbPath();
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

      final state = _readCursorState(dbPath);
      final windows = cursorWindows(state.usage, asOf);

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
        account: state.account ?? 'default',
        plan: state.plan,
        asOf: asOf,
        windows: windows,
        error: err,
      );
    } catch (_) {
      return ProviderQuota.error(id, name, 'unable to read Cursor state', asOf);
    }
  }

  _CursorState _readCursorState(String dbPath) {
    _ensureSqlite();
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final rows = db.select(
        "SELECT value FROM ItemTable WHERE key LIKE '%usage%' OR key LIKE '%credit%' OR key LIKE '%plan%' OR key LIKE '%account%' OR key LIKE '%user%' LIMIT 40;",
      );
      Map<String, dynamic>? usage;
      String? account;
      String? plan;
      for (final row in rows) {
        final parsed = decodeStateJsonObject(row['value']);
        if (parsed == null) continue;
        account ??= firstNestedString(parsed, const [
          'email',
          'userEmail',
          'accountEmail',
          'username',
          'login',
        ]);
        plan ??= firstNestedString(parsed, const [
          'plan',
          'planName',
          'tier',
          'subscriptionPlan',
          'membershipType',
        ]);
        if (usage == null && _looksLikeUsage(parsed)) {
          usage = parsed;
        }
      }
      return _CursorState(usage: usage, account: account, plan: plan);
    } catch (_) {
      return const _CursorState();
    } finally {
      db.dispose();
    }
  }

  bool _looksLikeUsage(Map<String, dynamic> data) =>
      data.containsKey('usageBreakdowns') ||
      data.containsKey('planUsage') ||
      data.containsKey('credits') ||
      data.containsKey('monthlyUsage') ||
      data.containsKey('usagePool') ||
      data.containsKey('includedUsage') ||
      data.containsKey('billingUsage') ||
      data.containsKey('creditPool') ||
      (data.containsKey('usedCents') && data.containsKey('includedCents')) ||
      (data.containsKey('used') && data.containsKey('limit'));

  // Default path discovery reads real per-user application directories; tests
  // exercise Cursor reads through an injected state database path.
  // coverage:ignore-start
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
  // coverage:ignore-end

  void _ensureSqlite() {
    if (_sqliteReady) return;
    configureSqliteLibrary();
    _sqliteReady = true;
  }
}

class _CursorState {
  final Map<String, dynamic>? usage;
  final String? account;
  final String? plan;

  const _CursorState({this.usage, this.account, this.plan});
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
