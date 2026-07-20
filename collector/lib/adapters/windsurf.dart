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
      final observations = state.usages
          .map(
            (usage) => PassiveStateQuotaObservation(
              payload: usage,
              windows: windsurfWindows(usage, asOf),
            ),
          )
          .where((observation) => observation.windows.isNotEmpty)
          .toList();
      final windows = _tightestWindsurfWindows(
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
        // Preserve unknown capture provenance. Substituting the check time here
        // would make an old local row look freshly captured.
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
      final placeholders = List.filled(
        _windsurfStateRowKeys.length,
        '?',
      ).join(', ');
      final rows = db.select(
        'SELECT key, value FROM ItemTable WHERE key IN ($placeholders);',
        _windsurfStateRowKeys,
      );
      final valuesByKey = <String, Object?>{
        for (final row in rows) row['key'] as String: row['value'],
      };
      final decodedByKey = <String, Map<String, dynamic>>{};
      for (final key in _windsurfStateRowKeys) {
        final parsed = decodeStateJsonObject(valuesByKey[key]);
        if (parsed != null) decodedByKey[key] = parsed;
      }

      final usages = <Map<String, dynamic>>[];
      String? account;
      String? plan;
      for (final key in _windsurfIdentityRowKeys) {
        final parsed = decodedByKey[key];
        if (parsed == null) continue;
        account ??= _firstWindsurfIdentityString(parsed, const [
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
        plan ??= _firstWindsurfIdentityString(parsed, const [
          'plan',
          'planName',
          'tier',
          'planTier',
          'subscriptionPlan',
          'membershipType',
          'quotaPlan',
          'currentPlan',
        ]);
      }
      for (final key in _windsurfStateRowKeys) {
        final parsed = decodedByKey[key];
        if (parsed == null) continue;
        final projected = _windsurfQuotaProjection(parsed);
        if (_looksLikeWindsurfUsage(projected)) usages.add(projected);
      }
      return _WindsurfState(usages: usages, account: account, plan: plan);
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
      data.containsKey('usage') ||
      data.containsKey('planInfo') ||
      data.containsKey('cachedPlanInfo') ||
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

// Shared VS Code state databases also contain editor history and chat state.
// Keep this list exact. Adding substring matching here would put those rows back
// in scope even though their JSON happens to mention usage or account words.
const List<String> _windsurfUsageRowKeys = [
  'windsurf.settings.cachedPlanInfo',
  'windsurf.cachedPlanInfo',
  'codeium.windsurf.cachedPlanInfo',
  'codeium.settings.cachedPlanInfo',
  'devin.cachedPlanInfo',
  'windsurf.usage',
  'windsurf.quota',
  'codeium.windsurf.usage',
  'codeium.windsurf.quota',
  'codeium.cachedPlanInfo',
  'codeium.usage',
  'codeium.quota',
  'devin.usage',
  'devin.quota',
];

const List<String> _windsurfIdentityRowKeys = [
  'windsurf.account',
  'windsurf.user',
  'windsurf.plan',
  'codeium.windsurf.account',
  'codeium.windsurf.user',
  'codeium.windsurf.plan',
  'codeium.account',
  'codeium.user',
  'codeium.plan',
  'devin.account',
  'devin.user',
  'devin.plan',
  ..._windsurfUsageRowKeys,
];

const List<String> _windsurfStateRowKeys = [
  ..._windsurfIdentityRowKeys,
];

const List<String> _windsurfIdentityContainers = [
  'profile',
  'user',
  'account',
  'identity',
  'organization',
  'org',
  'team',
  'subscription',
  'membership',
  'planInfo',
  'cachedPlanInfo',
];

const List<String> _windsurfQuotaContainerKeys = [
  'quotaUsage',
  'usageQuotas',
  'quota',
  'quotas',
  'usage',
  'planInfo',
  'cachedPlanInfo',
];

const Set<String> _windsurfCounterScalarKeys = {
  'usedMessages',
  'messages',
  'messageLimit',
  'usedFlowActions',
  'flowActions',
  'flowActionLimit',
};

const Set<String> _windsurfQuotaBlockScalarKeys = {
  'remainingPercent',
  'remaining_percent',
  'quotaRemainingPercent',
  'quota_remaining_percent',
  'freePercent',
  'free_percent',
  'usedPercent',
  'used_percent',
  'usagePercent',
  'usage_percent',
  'percentageUsed',
  'percentUsed',
  'quotaUsedPercent',
  'quota_used_percent',
  'used',
  'currentUsage',
  'usage',
  'consumed',
  'count',
  'limit',
  'usageLimit',
  'quota',
  'quotaLimit',
  'allowance',
  'total',
  'resetsAt',
  'resetAt',
  'resetDate',
  'periodEnd',
};

const Set<String> _windsurfBreakdownScalarKeys = {
  'currentUsage',
  'usageLimit',
  'percentageUsed',
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

String? _firstWindsurfIdentityString(
  Map<String, dynamic> data,
  List<String> keys,
) {
  final direct = _firstDirectString(data, keys);
  if (direct != null) return direct;
  for (final containerKey in _windsurfIdentityContainers) {
    final container = _stringMap(data[containerKey]);
    if (container == null) continue;
    final nested = _firstDirectString(container, keys);
    if (nested != null) return nested;
    for (final childKey in _windsurfIdentityContainers) {
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

Map<String, dynamic> _windsurfQuotaProjection(Map<String, dynamic> data) {
  // Project only fields consumed by windsurfWindows and quota provenance. This
  // intentionally does not recurse into chat, prompt, or code-context objects.
  final projected = <String, dynamic>{};
  _copyScalarFields(data, projected, _windsurfCounterScalarKeys);
  for (final label in const ['daily', 'weekly']) {
    _copyDirectQuotaFields(data, projected, label);
  }
  _copyNestedQuotaFields(data, projected);

  for (final key in _windsurfQuotaContainerKeys) {
    final source = _stringMap(data[key]);
    if (source == null) continue;
    final container = <String, dynamic>{};
    _copyNestedQuotaFields(source, container);
    _copyCaptureTimeFields(source, container);
    if (container.isNotEmpty) projected[key] = container;
  }

  for (final key in const ['usageBreakdowns', 'credits']) {
    final rawBreakdowns = data[key];
    if (rawBreakdowns is! List) continue;
    final breakdowns = <Map<String, dynamic>>[];
    for (final raw in rawBreakdowns) {
      final source = _stringMap(raw);
      if (source == null) continue;
      final block = <String, dynamic>{};
      _copyScalarFields(source, block, _windsurfBreakdownScalarKeys);
      _copyCaptureTimeFields(source, block);
      if (block.isNotEmpty) breakdowns.add(block);
    }
    if (breakdowns.isNotEmpty) projected[key] = breakdowns;
  }

  if (projected.isNotEmpty) _copyCaptureTimeFields(data, projected);
  return projected;
}

void _copyDirectQuotaFields(
  Map<String, dynamic> source,
  Map<String, dynamic> target,
  String label,
) {
  final cap = '${label[0].toUpperCase()}${label.substring(1)}';
  final keys = <String>{
    '${label}_quota_remaining_percent',
    '${label}QuotaRemainingPercent',
    '${label}_remaining_percent',
    '${label}RemainingPercent',
    '${label}_quota_used_percent',
    '${label}QuotaUsedPercent',
    '${label}_used_percent',
    '${label}UsedPercent',
    '${label}_used',
    '${label}Used',
    '${label}_usage',
    '${label}Usage',
    'used$cap',
    'used${cap}Quota',
    '${label}_limit',
    '${label}Limit',
    '${label}_quota',
    '${label}Quota',
    '${label}_quota_limit',
    '${label}QuotaLimit',
    'resetsAt',
    'resetAt',
    'resetDate',
    'periodEnd',
    '${label}ResetAt',
    '${label}QuotaResetAt',
    'next${cap}ResetAt',
    '${label}_reset_at',
    '${label}_quota_reset_at',
  };
  _copyScalarFields(source, target, keys);
}

void _copyNestedQuotaFields(
  Map<String, dynamic> source,
  Map<String, dynamic> target,
) {
  for (final label in const ['daily', 'weekly', 'cascade']) {
    final cap = '${label[0].toUpperCase()}${label.substring(1)}';
    for (final key in [
      label,
      '${label}Quota',
      '${label}Usage',
      '${label}UsageQuota',
      '${label}Allowance',
      '${label}_quota',
      '${label}_usage',
      '${label}_usage_quota',
      '${label}_allowance',
      'quota$cap',
      'usage$cap',
    ]) {
      final raw = _stringMap(source[key]);
      if (raw == null) continue;
      final block = <String, dynamic>{};
      _copyScalarFields(raw, block, _windsurfQuotaBlockScalarKeys);
      _copyResetFields(raw, block, label);
      _copyCaptureTimeFields(raw, block);
      if (block.isNotEmpty) target[key] = block;
    }
  }
}

void _copyResetFields(
  Map<String, dynamic> source,
  Map<String, dynamic> target,
  String label,
) {
  final cap = '${label[0].toUpperCase()}${label.substring(1)}';
  _copyScalarFields(source, target, {
    'resetsAt',
    'resetAt',
    'resetDate',
    'periodEnd',
    '${label}ResetAt',
    '${label}QuotaResetAt',
    'next${cap}ResetAt',
    '${label}_reset_at',
    '${label}_quota_reset_at',
  });
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

class _WindsurfState {
  final List<Map<String, dynamic>> usages;
  final String? account;
  final String? plan;

  const _WindsurfState({this.usages = const [], this.account, this.plan});
}

List<QuotaWindow> _tightestWindsurfWindows(Iterable<QuotaWindow> windows) {
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
