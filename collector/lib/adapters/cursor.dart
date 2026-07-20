import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../labels.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';
import '../vscode_state.dart';

/// Cursor adapter (VSCode fork with agentic features and credit system).
/// Local data in ~/.cursor (SQLite state.vscdb like other forks).
/// Opportunistic for free/Pro accounts. Parses for usage/credits if present.
class CursorAdapter {
  static const id = cursorProviderId;
  static const name = cursorProviderName;
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
      final observations = state.usages
          .map(
            (usage) => PassiveStateQuotaObservation(
              payload: usage,
              windows: cursorWindows(usage, asOf),
            ),
          )
          .where((observation) => observation.windows.isNotEmpty)
          .toList();
      final windows = _tightestCursorWindows(
        observations.expand((observation) => observation.windows),
      );
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
        final spent = _bindingCurrentSpentWindow(windows, asOf);
        if (spent != null) {
          err =
              'out of quota (resets ${resetCountdownLabel(spent.resetsAt, asOf)})';
        }
      }

      final quota = ProviderQuota(
        provider: id,
        displayName: name,
        account: state.account ?? 'default',
        plan: state.plan,
        // Zero is deliberate when the quota row carries no capture timestamp.
        // The database check time proves only when we looked, not when this
        // machine-scoped balance was produced.
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
      return ProviderQuota.error(id, name, 'unable to read Cursor state', asOf);
    }
  }

  _CursorState _readCursorState(String dbPath) {
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final placeholders = List.filled(
        _cursorStateRowKeys.length,
        '?',
      ).join(', ');
      final rows = db.select(
        'SELECT key, value FROM ItemTable WHERE key IN ($placeholders);',
        _cursorStateRowKeys,
      );
      final valuesByKey = <String, Object?>{
        for (final row in rows) row['key'] as String: row['value'],
      };
      final decodedByKey = <String, Map<String, dynamic>>{};
      for (final key in _cursorStateRowKeys) {
        final parsed = decodeStateJsonObject(valuesByKey[key]);
        if (parsed != null) decodedByKey[key] = parsed;
      }

      final usages = <Map<String, dynamic>>[];
      String? account;
      String? plan;
      for (final key in _cursorIdentityRowKeys) {
        final parsed = decodedByKey[key];
        if (parsed == null) continue;
        account ??= _firstCursorIdentityString(parsed, const [
          'email',
          'userEmail',
          'accountEmail',
          'username',
          'login',
        ]);
        plan ??= _firstCursorIdentityString(parsed, const [
          'plan',
          'planName',
          'tier',
          'subscriptionPlan',
          'membershipType',
        ]);
      }
      for (final key in _cursorStateRowKeys) {
        final parsed = decodedByKey[key];
        if (parsed == null) continue;
        final projected = _cursorQuotaProjection(parsed);
        if (_looksLikeUsage(projected)) usages.add(projected);
      }
      return _CursorState(usages: usages, account: account, plan: plan);
    } catch (_) {
      return const _CursorState();
    } finally {
      db.close();
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
}

// Shared VS Code state databases also contain editor history and chat state.
// Keep this list exact. Adding substring matching here would put those rows back
// in scope even though their JSON happens to mention usage or account words.
const List<String> _cursorUsageRowKeys = [
  'cursor.planUsage',
  'cursor.usage',
  'cursor.creditPool',
  'cursor.monthlyUsage',
  'cursor.usagePool',
  'cursor.includedUsage',
  'cursor.billingUsage',
  'cursor.usageBreakdowns',
];

const List<String> _cursorIdentityRowKeys = [
  'cursor.account',
  'cursor.user',
  'cursor.plan',
  ..._cursorUsageRowKeys,
];

const List<String> _cursorStateRowKeys = [
  ..._cursorIdentityRowKeys,
];

const List<String> _cursorIdentityContainers = [
  'profile',
  'user',
  'account',
  'identity',
  'subscription',
  'membership',
  'planInfo',
];

const List<String> _cursorPoolKeys = [
  'monthlyUsage',
  'usagePool',
  'includedUsage',
  'planUsage',
  'billingUsage',
  'creditPool',
];

const Set<String> _cursorPoolScalarKeys = {
  'usedCents',
  'used_cents',
  'currentUsageCents',
  'current_usage_cents',
  'usageCents',
  'spentCents',
  'used',
  'currentUsage',
  'amountUsed',
  'spent',
  'includedCents',
  'included_cents',
  'includedUsageCents',
  'limitCents',
  'monthlyLimitCents',
  'usageLimitCents',
  'includedUsage',
  'included',
  'limit',
  'usageLimit',
  'hardLimit',
  'resetAt',
  'resetsAt',
  'resetDate',
  'periodEnd',
  'currentPeriodEnd',
  'billingPeriodEnd',
  'nextResetAt',
};

const Set<String> _cursorBreakdownScalarKeys = {
  'currentUsage',
  'usageLimit',
  'percentageUsed',
  'resetDate',
  'displayName',
};

const Set<String> _passiveCaptureTimeKeys = {
  'timestamp',
  'updatedat',
  'lastupdatedat',
  'lastupdatetime',
  'refreshedat',
  'lastrefreshedat',
  'fetchedat',
  'lastfetchedat',
  'observedat',
  'capturedat',
  'syncedat',
  'lastsyncedat',
  'usageupdatedat',
  'usagerefreshedat',
  'quotaupdatedat',
  'quotarefreshedat',
  'cacheupdatedat',
  'cachetimestamp',
};

String? _firstCursorIdentityString(
  Map<String, dynamic> data,
  List<String> keys,
) {
  final direct = _firstDirectString(data, keys);
  if (direct != null) return direct;
  for (final containerKey in _cursorIdentityContainers) {
    final container = _stringMap(data[containerKey]);
    if (container == null) continue;
    final nested = _firstDirectString(container, keys);
    if (nested != null) return nested;
    for (final childKey in _cursorIdentityContainers) {
      final child = _stringMap(container[childKey]);
      if (child == null) continue;
      final childValue = _firstDirectString(child, keys);
      if (childValue != null) return childValue;
    }
  }
  return null;
}

String? _firstDirectString(
  Map<String, dynamic> data,
  Iterable<String> keys,
) {
  for (final key in keys) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

Map<String, dynamic> _cursorQuotaProjection(Map<String, dynamic> data) {
  // Project only fields consumed by cursorWindows and quota provenance. This
  // intentionally does not recurse into chat, prompt, or code-context objects.
  final projected = <String, dynamic>{};
  _copyScalarFields(data, projected, _cursorPoolScalarKeys);

  for (final key in _cursorPoolKeys) {
    final source = _stringMap(data[key]);
    if (source == null) continue;
    final pool = <String, dynamic>{};
    _copyScalarFields(source, pool, _cursorPoolScalarKeys);
    _copyCaptureTimeFields(source, pool);
    if (pool.isNotEmpty) projected[key] = pool;
  }

  final rawBreakdowns = data['usageBreakdowns'];
  if (rawBreakdowns is List) {
    final breakdowns = <Map<String, dynamic>>[];
    for (final raw in rawBreakdowns) {
      final source = _stringMap(raw);
      if (source == null) continue;
      final block = <String, dynamic>{};
      _copyScalarFields(source, block, _cursorBreakdownScalarKeys);
      _copyCaptureTimeFields(source, block);
      if (block.isNotEmpty) breakdowns.add(block);
    }
    if (breakdowns.isNotEmpty) projected['usageBreakdowns'] = breakdowns;
  }

  if (projected.isNotEmpty) _copyCaptureTimeFields(data, projected);
  return projected;
}

Map<String, dynamic>? _stringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return value.cast<String, dynamic>();
  }
  return null;
}

void _copyScalarFields(
  Map<String, dynamic> source,
  Map<String, dynamic> target,
  Set<String> keys,
) {
  for (final key in keys) {
    final value = source[key];
    if (value is String || value is num) target[key] = value;
  }
}

void _copyCaptureTimeFields(
  Map<String, dynamic> source,
  Map<String, dynamic> target,
) {
  for (final entry in source.entries) {
    final normalized =
        entry.key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    final value = entry.value;
    if (_passiveCaptureTimeKeys.contains(normalized) &&
        (value is String || value is num)) {
      target[entry.key] = value;
    }
  }
}

class _CursorState {
  final List<Map<String, dynamic>> usages;
  final String? account;
  final String? plan;

  const _CursorState({this.usages = const [], this.account, this.plan});
}

List<QuotaWindow> _tightestCursorWindows(Iterable<QuotaWindow> windows) {
  final byLabel = <String, QuotaWindow>{};
  for (final candidate in windows) {
    final current = byLabel[candidate.label];
    final used = candidate.usedPercent;
    final currentUsed = current?.usedPercent;
    if (current == null ||
        (used != null &&
            (currentUsed == null ||
                used > currentUsed ||
                (used == currentUsed &&
                    (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1))))) {
      byLabel[candidate.label] = candidate;
    }
  }
  return byLabel.values.toList();
}

QuotaWindow? _bindingCurrentSpentWindow(List<QuotaWindow> windows, int asOf) {
  QuotaWindow? binding;
  for (final window in windows) {
    if (!window.exhausted ||
        (window.resetsAt != null && window.resetsAt! <= asOf)) {
      continue;
    }
    if (binding == null ||
        (binding.resetsAt != null &&
            (window.resetsAt == null ||
                window.resetsAt! > binding.resetsAt!))) {
      binding = window;
    }
  }
  return binding;
}
