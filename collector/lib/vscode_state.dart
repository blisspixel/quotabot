import 'dart:convert';

import 'models.dart';
import 'util.dart';

/// Upper bound on a VS Code-fork `state.vscdb` value blob before it is decoded.
/// The usage-state JSON quotabot reads is a few KB; this cap only exists so a
/// pathological or malicious same-user-written value cell (Cursor/Windsurf/Kiro
/// SQLite state is not quotabot's file) cannot exhaust memory when decoded. Every
/// other local file quotabot reads has a comparable byte cap.
const int _maxStateValueBytes = 8 * 1024 * 1024;

/// Passive IDE quota is not refreshed by quotabot itself. Once the underlying
/// state is more than an hour old, it is no longer strong enough to route work:
/// another device or a background provider change may have consumed the pool.
const int kPassiveStateEvidenceMaxAgeSeconds = 60 * 60;

const int _stateEvidenceClockSkewSeconds = 60;
const int _earliestPlausibleStateEvidenceEpoch = 946684800; // 2000-01-01 UTC
const int _maxStateEvidenceNodes = 10000;

const Set<String> _stateEvidenceTimeKeys = {
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

const Set<String> _quotaStateKeys = {
  'used',
  'limit',
  'currentusage',
  'usagelimit',
  'usedcents',
  'includedcents',
  'percentageused',
  'percentused',
  'usedpercent',
  'remainingpercent',
  'dailyquotaremainingpercent',
  'weeklyquotaremainingpercent',
  'usagebreakdowns',
  'planusage',
  'monthlyusage',
  'usagepool',
  'includedusage',
  'billingusage',
  'creditpool',
  'quotausage',
  'usagequotas',
  'quotas',
  'quota',
  'daily',
  'weekly',
  'kiroresourcenotificationsusagestate',
};

class PassiveStateQuotaObservation {
  final Map<String, dynamic> payload;
  final List<QuotaWindow> windows;

  const PassiveStateQuotaObservation({
    required this.payload,
    required this.windows,
  });
}

Map<String, dynamic>? decodeStateJsonObject(Object? raw) {
  try {
    if (raw is List<int> && raw.length > _maxStateValueBytes) return null;
    final text = raw is List<int>
        ? utf8.decode(raw, allowMalformed: true)
        : raw?.toString();
    if (text == null || text.trim().isEmpty) return null;
    if (text.length > _maxStateValueBytes) return null;
    final parsed = jsonDecode(text);
    return parsed is Map ? Map<String, dynamic>.from(parsed) : null;
  } catch (_) {
    // Also catches a StackOverflowError from decoding a deeply-nested blob.
    return null;
  }
}

String? firstNestedString(Map<String, dynamic> data, List<String> keys) {
  for (final key in keys) {
    final found = findKey(data, key);
    if (found is String && found.trim().isNotEmpty) return found.trim();
  }
  return null;
}

/// Returns the capture time for quota values read from a VS Code-fork state DB.
///
/// A provider-owned update timestamp inside a row that supplied a selected
/// window is required. Whole-database and WAL modification times are not quota
/// provenance because these shared state stores receive unrelated writes. The
/// oldest time across selected windows wins, so one recent short window cannot
/// make an older binding window look current. Identical copies of one selected
/// window use their newest safe row. A zero result means no trustworthy row-owned
/// provenance was available and must be treated as stale.
int passiveStateEvidenceAsOf({
  required int checkedAt,
  required Iterable<PassiveStateQuotaObservation> observations,
  required Iterable<QuotaWindow> selectedWindows,
}) {
  int? oldest;
  var sawWindow = false;
  final candidates = observations.toList();
  for (final selected in selectedWindows) {
    sawWindow = true;
    int? newestCopy;
    for (final observation in candidates) {
      if (!observation.windows.any((window) => _sameWindow(window, selected))) {
        continue;
      }
      final payloadTime =
          _embeddedStateUpdateAt(observation.payload, checkedAt);
      if (payloadTime == null) continue;
      if (newestCopy == null || payloadTime > newestCopy) {
        newestCopy = payloadTime;
      }
    }
    if (newestCopy == null) return 0;
    if (oldest == null || newestCopy < oldest) oldest = newestCopy;
  }
  return sawWindow ? oldest ?? 0 : checkedAt;
}

bool passiveStateEvidenceIsStale(int evidenceAsOf, int checkedAt) =>
    evidenceAsOf <= 0 ||
    evidenceAsOf > checkedAt + _stateEvidenceClockSkewSeconds ||
    checkedAt - evidenceAsOf > kPassiveStateEvidenceMaxAgeSeconds;

String passiveStateStaleMessage(
  String displayName,
  int evidenceAsOf,
  int checkedAt,
) {
  if (evidenceAsOf <= 0 ||
      evidenceAsOf > checkedAt + _stateEvidenceClockSkewSeconds) {
    return 'local quota evidence time is unavailable; open $displayName and '
        'refresh its usage view before routing';
  }
  return 'local quota evidence is ${_stateEvidenceAgeLabel(checkedAt - evidenceAsOf)} old; '
      'open $displayName and refresh its usage view before routing';
}

int? _embeddedStateUpdateAt(Map<String, dynamic> payload, int checkedAt) {
  final pending = <Object?>[payload];
  var visited = 0;
  int? oldest;
  while (pending.isNotEmpty && visited < _maxStateEvidenceNodes) {
    final value = pending.removeLast();
    visited++;
    if (value is Map) {
      final normalizedKeys =
          value.keys.map((key) => _normalizedStateKey(key.toString())).toSet();
      final carriesQuota = normalizedKeys.any(_quotaStateKeys.contains);
      for (final entry in value.entries) {
        final key = _normalizedStateKey(entry.key.toString());
        if (carriesQuota && _stateEvidenceTimeKeys.contains(key)) {
          final parsed = _parseStateEvidenceEpoch(entry.value, checkedAt);
          if (parsed != null && (oldest == null || parsed < oldest)) {
            oldest = parsed;
          }
        }
        final nested = entry.value;
        if (nested is Map || nested is List) pending.add(nested);
      }
    } else if (value is List) {
      pending.addAll(value);
    }
  }
  return oldest;
}

String _normalizedStateKey(String key) =>
    key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

bool _sameWindow(QuotaWindow a, QuotaWindow b) =>
    a.label == b.label &&
    a.usedPercent == b.usedPercent &&
    a.used == b.used &&
    a.limit == b.limit &&
    a.resetsAt == b.resetsAt;

int? _parseStateEvidenceEpoch(Object? value, int checkedAt) {
  int? epoch;
  if (value is num) {
    final numeric = value.toDouble();
    if (!numeric.isFinite || numeric.truncateToDouble() != numeric) return null;
    epoch = _normalizeStateEvidenceEpoch(value.toInt());
  } else if (value is String) {
    final text = value.trim();
    final numeric = int.tryParse(text);
    if (numeric != null) {
      epoch = _normalizeStateEvidenceEpoch(numeric);
    } else {
      // A timezone-free wall clock is ambiguous and not safe quota provenance.
      if (!RegExp(r'(?:Z|[+-]\d\d:\d\d)$', caseSensitive: false)
          .hasMatch(text)) {
        return null;
      }
      final parsed = DateTime.tryParse(text);
      if (parsed != null) epoch = parsed.toUtc().millisecondsSinceEpoch ~/ 1000;
    }
  }
  if (epoch == null || !_plausibleStateEvidenceEpoch(epoch, checkedAt)) {
    return null;
  }
  return epoch;
}

int _normalizeStateEvidenceEpoch(int value) {
  final magnitude = value.abs();
  if (magnitude >= 100000000000000000) return value ~/ 1000000000;
  if (magnitude >= 100000000000000) return value ~/ 1000000;
  if (magnitude >= 100000000000) return value ~/ 1000;
  return value;
}

bool _plausibleStateEvidenceEpoch(int value, int checkedAt) =>
    value >= _earliestPlausibleStateEvidenceEpoch &&
    value <= checkedAt + _stateEvidenceClockSkewSeconds;

String _stateEvidenceAgeLabel(int seconds) {
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}d';
}
