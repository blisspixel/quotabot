import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../labels.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';
import '../vscode_state.dart';

/// Windsurf / Devin adapter.
/// Supports both the legacy Windsurf IDE and the current Devin (Desktop + CLI).
/// IDE/Desktop: parses local state.vscdb cachedPlanInfo for daily/weekly quota.
/// CLI-only: passive detection via devin config/credentials (no rich local quota cache).
/// Passive for free tier or no sub.
class WindsurfAdapter {
  static const id = windsurfProviderId;
  static const name = windsurfProviderName;
  final String? _dbPath;
  final bool? _hasDevinCli;
  final String? _devinConfigPath;

  WindsurfAdapter({
    String? dbPath,
    bool? hasDevinCli,
    String? devinConfigPath,
  })  : _dbPath = dbPath,
        _hasDevinCli = hasDevinCli,
        _devinConfigPath = devinConfigPath;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final dbPath = _dbPath ?? _findWindsurfDbPath();
      final hasDevinCli = _hasDevinCli ?? _hasDevinCliInstalled();
      if (dbPath == null || !File(dbPath).existsSync()) {
        String account = hasDevinCli ? 'cli' : 'installed';
        if (hasDevinCli) {
          // Try to pull org/account from devin CLI config for better identification
          final cfgPath = _devinConfigPath ?? _findDevinConfigPath();
          if (cfgPath != null) {
            try {
              final cfg = jsonDecode(File(cfgPath).readAsStringSync());
              String? org;
              if (cfg is Map) {
                final devin = cfg['devin'];
                if (devin is Map) org = devin['org_id'] as String?;
              }
              if (org != null && org.isNotEmpty) {
                account = org.length > 12 ? '${org.substring(0, 12)}...' : org;
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

      final state = _readWindsurfState(dbPath);
      final windows = windsurfWindows(state.usage, asOf);

      String? err;
      if (windows.isEmpty) {
        err = 'no quota data found in local state';
      } else {
        final main = windows.first;
        if (main.exhausted) {
          err =
              'out of quota (resets ${resetCountdownLabel(main.resetsAt, asOf)})';
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
        perMachine: true,
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

  _WindsurfState _readWindsurfState(String dbPath) {
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final rows = db.select(
        "SELECT key, value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' OR key LIKE '%cachedPlanInfo%' OR key LIKE '%codeium.windsurf%' OR key LIKE '%windsurf%' OR key LIKE '%devin%' OR key LIKE '%usage%' OR key LIKE '%quota%' OR key LIKE '%plan%' OR key LIKE '%account%' OR key LIKE '%user%' ORDER BY CASE WHEN key = 'windsurf.settings.cachedPlanInfo' THEN 0 WHEN key LIKE '%cachedPlanInfo%' THEN 1 ELSE 2 END LIMIT 80;",
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
          'orgName',
          'org_id',
          'orgId',
          'teamName',
        ]);
        plan ??= firstNestedString(parsed, const [
          'plan',
          'planName',
          'tier',
          'planTier',
          'subscriptionPlan',
          'membershipType',
          'quotaPlan',
          'currentPlan',
        ]);
        if (usage == null && _looksLikeWindsurfUsage(parsed)) {
          usage = parsed;
        }
      }
      return _WindsurfState(usage: usage, account: account, plan: plan);
    } catch (_) {
      return const _WindsurfState();
    } finally {
      db.close();
    }
  }

  bool _looksLikeWindsurfUsage(Map<String, dynamic> data) =>
      data.containsKey('daily_quota_remaining_percent') ||
      data.containsKey('dailyQuotaRemainingPercent') ||
      data.containsKey('weekly_quota_remaining_percent') ||
      data.containsKey('weeklyQuotaRemainingPercent') ||
      data.containsKey('daily') ||
      data.containsKey('weekly') ||
      data.containsKey('quotaUsage') ||
      data.containsKey('usageQuotas') ||
      data.containsKey('quotas') ||
      data.containsKey('quota') ||
      data.containsKey('usedMessages') ||
      data.containsKey('usedFlowActions') ||
      data.containsKey('usageBreakdowns') ||
      data.containsKey('credits');

  // Real-user application and CLI discovery is environment-specific; tests use
  // injected database and config paths for deterministic coverage.
  // coverage:ignore-start
  static String? _findDevinConfigPath() {
    final app = Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
    final candidates = ['$app/devin/config.json', '$app/Devin/config.json'];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static bool _hasDevinCliInstalled() {
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
  // coverage:ignore-end
}

class _WindsurfState {
  final Map<String, dynamic>? usage;
  final String? account;
  final String? plan;

  const _WindsurfState({this.usage, this.account, this.plan});
}
