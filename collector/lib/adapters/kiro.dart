import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../analysis.dart';
import '../labels.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';
import '../vscode_state.dart';

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

      final state = _readState(dbPath);
      final windows = kiroWindows(state.usage, asOf);
      final observations = [
        if (state.usage != null && windows.isNotEmpty)
          PassiveStateQuotaObservation(
            // Kiro's producer stores both the quota breakdowns and their
            // timestamp in this exact child. Do not traverse unrelated agent
            // state solely to establish quota provenance.
            payload: state.usage!,
            windows: windows,
          ),
      ];
      final evidenceAsOf = windows.isEmpty
          ? asOf
          : passiveStateEvidenceAsOf(
              checkedAt: asOf,
              observations: observations,
              selectedWindows: windows,
            );

      String? err;
      if (windows.isEmpty) {
        err = 'no quota data found in local state';
      } else {
        final main = windows.first;
        // Once this passive window's reset has passed, the stored percentage is
        // last-known evidence rather than proof that the new pool is spent. The
        // collector marks it stale; do not also claim current out-of-quota.
        if (!windowHasRolledOver(main, asOf) &&
            windowHeadroom(main, asOf) <= kSpentHeadroomFloor) {
          err =
              'out of quota (resets ${resetCountdownLabel(main.resetsAt, asOf)})';
        }
      }

      final quota = ProviderQuota(
        provider: id,
        displayName: name,
        account: 'default',
        plan: null,
        // Preserve unknown capture provenance. A read performed now does not
        // prove when the embedded quota value was captured.
        asOf: evidenceAsOf,
        windows: windows,
        error: err,
        perMachine: true,
      );
      return windows.isNotEmpty &&
              passiveStateEvidenceIsStale(evidenceAsOf, asOf)
          ? quota.asStale(
              passiveStateStaleMessage(name, evidenceAsOf, asOf),
            )
          : quota;
    } catch (_) {
      return ProviderQuota.error(id, name, 'unable to read Kiro state', asOf);
    }
  }

  _KiroState _readState(String dbPath) {
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final rows = db.select(
        "SELECT value FROM ItemTable WHERE key = 'kiro.kiroAgent';",
      );
      if (rows.isEmpty) return const _KiroState();
      final parsed = decodeStateJsonObject(rows.first['value']);
      if (parsed == null) return const _KiroState();
      final rawUsage = parsed['kiro.resourceNotifications.usageState'];
      final usage =
          rawUsage is Map ? Map<String, dynamic>.from(rawUsage) : null;
      return _KiroState(usage: usage);
    } catch (_) {
      return const _KiroState();
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

class _KiroState {
  final Map<String, dynamic>? usage;

  const _KiroState({this.usage});
}
