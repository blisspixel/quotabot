import 'dart:convert';
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
        err = state.planEvidenceSource ==
                ProviderPlanEvidenceSource.hostCredential
            ? 'Cursor ${state.plan} plan detected, but current Cursor quota is '
                'unavailable from local state; quotabot cannot route Cursor, '
                'so check Cursor Settings > Usage'
            : 'no quota data found in local state';
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
        planEvidenceSource: state.planEvidenceSource,
        planEvidenceAsOf: state.planEvidenceSource == null ? null : asOf,
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
      for (final key in _cursorIdentityRowKeys) {
        final parsed = decodeStateJsonObject(valuesByKey[key]);
        if (parsed != null) decodedByKey[key] = parsed;
      }

      final usages = <Map<String, dynamic>>[];
      String? account;
      String? plan;
      ProviderPlanEvidenceSource? planEvidenceSource;
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
      final authPlan = _authenticatedCursorPlan(valuesByKey);
      if (valuesByKey.containsKey(_cursorMembershipTypeKey)) {
        plan = authPlan;
        if (authPlan != null) {
          planEvidenceSource = ProviderPlanEvidenceSource.hostCredential;
        }
      }
      final membershipPresent =
          valuesByKey.containsKey(_cursorMembershipTypeKey);
      for (final key in _cursorIdentityRowKeys) {
        final parsed = decodedByKey[key];
        if (parsed == null) continue;
        // Cursor 3.x membership metadata is diagnostic only. Leftover
        // planUsage/usage rows are not current Cursor Models or Other Models
        // balances, so they must not become routable windows.
        if (membershipPresent) continue;
        final projected = _cursorQuotaProjection(parsed);
        if (_looksLikeUsage(projected)) usages.add(projected);
      }
      return _CursorState(
        usages: usages,
        account: account,
        plan: plan,
        planEvidenceSource: planEvidenceSource,
      );
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
  ..._cursorAuthRowKeys,
];

const String _cursorAccessTokenKey = 'cursorAuth/accessToken';
const String _cursorMembershipTypeKey = 'cursorAuth/stripeMembershipType';
const String _cursorSubscriptionStatusKey =
    'cursorAuth/stripeSubscriptionStatus';
const String _cursorMembershipOwnerKey = 'cursorAuth/stripeMembershipAuthId';

const List<String> _cursorAuthRowKeys = [
  _cursorAccessTokenKey,
  _cursorMembershipTypeKey,
  _cursorSubscriptionStatusKey,
  _cursorMembershipOwnerKey,
];

const Map<String, String> _cursorPlanLabels = {
  'free': 'Free',
  'pro': 'Pro',
  'pro_plus': 'Pro Plus',
  'ultra': 'Ultra',
  'express': 'Express',
  'enterprise': 'Enterprise',
};

const Set<String> _cursorCurrentSubscriptionStatuses = {'active', 'trialing'};

String? _authenticatedCursorPlan(Map<String, Object?> valuesByKey) {
  final membership = _boundedCursorScalar(
    valuesByKey[_cursorMembershipTypeKey],
    maxBytes: 64,
  );
  final plan = _cursorPlanLabels[membership];
  if (plan == null) return null;

  final status = _boundedCursorScalar(
    valuesByKey[_cursorSubscriptionStatusKey],
    maxBytes: 64,
  );
  if (!_cursorCurrentSubscriptionStatuses.contains(status)) return null;

  final owner = _boundedCursorScalar(
    valuesByKey[_cursorMembershipOwnerKey],
    maxBytes: 256,
  );
  final token = _boundedCursorScalar(
    valuesByKey[_cursorAccessTokenKey],
    maxBytes: 16 * 1024,
  );
  final subject = _cursorJwtSubject(token);
  return owner != null && subject == owner ? plan : null;
}

String? _cursorJwtSubject(String? token) {
  if (token == null) return null;
  final segments = token.split('.');
  if (segments.length != 3 || segments[1].length > 8 * 1024) return null;
  try {
    // This is local ownership correlation only, not token validation. The
    // resulting plan stays host-credential evidence, and no claim other than
    // the bounded subject is used.
    final payloadBytes = base64Url.decode(base64Url.normalize(segments[1]));
    if (payloadBytes.length > 8 * 1024) return null;
    final payload = jsonDecode(
      utf8.decode(payloadBytes, allowMalformed: false),
    );
    if (payload is! Map<String, dynamic>) return null;
    return _boundedCursorScalar(payload['sub'], maxBytes: 256);
  } catch (_) {
    return null;
  }
}

String? _boundedCursorScalar(Object? value, {required int maxBytes}) {
  String decoded;
  if (value is String) {
    if (value.length > maxBytes) return null;
    decoded = value;
  } else if (value is List<int>) {
    if (value.length > maxBytes) return null;
    try {
      decoded = utf8.decode(value, allowMalformed: false);
    } catch (_) {
      return null;
    }
  } else {
    return null;
  }
  final trimmed = decoded.trim();
  if (trimmed.isEmpty || utf8.encode(trimmed).length > maxBytes) return null;
  return trimmed;
}

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
  final ProviderPlanEvidenceSource? planEvidenceSource;

  const _CursorState({
    this.usages = const [],
    this.account,
    this.plan,
    this.planEvidenceSource,
  });
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
