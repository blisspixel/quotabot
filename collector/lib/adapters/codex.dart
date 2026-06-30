import 'dart:convert';
import 'dart:io';

import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

/// Reads Codex (OpenAI) usage from the rate_limits events Codex writes to its
/// session rollout files on every turn. No network or auth required.
///
/// Codex meters different models against separate limit buckets, and each
/// session only records the bucket it used. Reading a single newest session can
/// therefore show 0% on a fresh model bucket while real usage sits on another.
/// This reads the latest snapshot of each bucket across recent sessions and
/// keeps the binding (most-constrained) window per slot.
class CodexAdapter {
  static const id = codexProviderId;
  static const name = codexProviderName;
  final Directory? _sessionsDir;

  CodexAdapter({Directory? sessionsDir}) : _sessionsDir = sessionsDir;

  /// How many recent rollout files to scan for per-bucket snapshots. Enough to
  /// catch buckets touched across a normal working window without reading the
  /// whole history.
  static const _scanFiles = 16;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final sessionsDir =
          _sessionsDir ?? Directory('${home()}/.codex/sessions');
      if (!sessionsDir.existsSync()) {
        return ProviderQuota.error(id, name, 'no ~/.codex/sessions', asOf);
      }

      final rollouts =
          sessionsDir.listSync(recursive: true).whereType<File>().where((f) {
        final n = f.uri.pathSegments.last;
        return n.startsWith('rollout-') && n.endsWith('.jsonl');
      }).toList()
            ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
            );

      if (rollouts.isEmpty) {
        return ProviderQuota.error(id, name, 'no rollout files', asOf);
      }

      // Collect the latest snapshot of each distinct limit bucket. Files are
      // newest first, so the first snapshot seen for a bucket is its latest.
      final byBucket = <String, _Snapshot>{};
      for (final file in rollouts.take(_scanFiles)) {
        final snap = _lastRateLimits(file);
        if (snap == null) continue;
        final key = (snap.rl['limit_id'] ?? snap.rl['limit_name'] ?? 'default')
            .toString();
        byBucket.putIfAbsent(key, () => snap);
      }
      if (byBucket.isEmpty) {
        return ProviderQuota.error(
          id,
          name,
          'no rate_limits in recent sessions',
          asOf,
        );
      }
      return _toQuota(byBucket.values.toList());
    } catch (_) {
      return ProviderQuota.error(
        id,
        name,
        'unable to read Codex session data',
        asOf,
      );
    }
  }

  /// Returns the last `rate_limits` snapshot in a rollout file with the capture
  /// time (epoch seconds) from that same line's `timestamp`, or null. The
  /// capture time matters: Codex only rewrites rate_limits on a turn, so a file
  /// touched recently can still hold an hours-old snapshot. Falls back to the
  /// file mtime when the line carries no timestamp.
  _Snapshot? _lastRateLimits(File file) {
    if (file.lengthSync() > 10 * 1024 * 1024) return null;
    final lines = file.readAsLinesSync();
    for (final line in lines.reversed) {
      if (!line.contains('"rate_limits"')) continue;
      try {
        final obj = jsonDecode(line);
        final rl = findKey(obj, 'rate_limits');
        if (rl is! Map) continue;
        final ts = parseIsoToEpoch(findKey(obj, 'timestamp')) ??
            (file.statSync().modified.millisecondsSinceEpoch ~/ 1000);
        return _Snapshot(Map<String, dynamic>.from(rl), ts);
      } catch (_) {
        // skip malformed line
      }
    }
    return null;
  }

  ProviderQuota _toQuota(List<_Snapshot> snapshots) {
    final now = nowEpoch();
    // Freshness is governed by the most recently captured bucket.
    final capturedAt =
        snapshots.map((s) => s.capturedAt).reduce((a, b) => a > b ? a : b);
    final newest = snapshots.reduce(
      (a, b) => a.capturedAt >= b.capturedAt ? a : b,
    );
    final age = now - capturedAt;
    // Mark stale once the freshest snapshot is older than the shortest (primary)
    // window, since by then the numbers no longer reflect live usage. Defaults
    // to one hour when the primary window length is unknown.
    final primaryMinutes =
        (newest.rl['primary']?['window_minutes'] as num?)?.toInt();
    final staleAfter = primaryMinutes != null ? primaryMinutes * 60 : 3600;
    final stale = age > staleAfter;
    final base = ProviderQuota(
      provider: id,
      displayName: name,
      account: (newest.rl['plan_type'] ?? 'default').toString(),
      plan: newest.rl['plan_type']?.toString(),
      asOf: capturedAt,
      windows: codexBindingWindows(snapshots.map((s) => s.rl), now),
    );
    return stale ? base.asStale('snapshot ${_ageLabel(age)} old') : base;
  }

  String _ageLabel(int seconds) {
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    return '${seconds ~/ 86400}d';
  }
}

/// One bucket's latest rate_limits map plus when it was captured.
class _Snapshot {
  final Map<String, dynamic> rl;
  final int capturedAt;
  _Snapshot(this.rl, this.capturedAt);
}
