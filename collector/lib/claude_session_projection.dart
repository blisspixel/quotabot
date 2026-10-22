/// Opt-in local projection of a Claude Code status-line payload.
///
/// The file is quotabot-owned. It is not an account cache, not a provider row,
/// and not a routing input. Collection never reads it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'drift.dart';
import 'labels.dart';
import 'parsing.dart';
import 'util.dart';

const claudeStatusProjectionSchema = 'quotabot.claude_session_projection.v1';
const claudeStatusProjectionSource = 'claude_status_line';

/// Status-line stdin ceiling. A documented payload is a few kilobytes.
const claudeStatusStdinLimitBytes = 64 * 1024;

const claudeStatusRejectionStdinEmpty = 'stdin_empty';
const claudeStatusRejectionStdinTooLarge = 'stdin_too_large';
const claudeStatusRejectionInvalidUtf8 = 'invalid_utf8';
const claudeStatusRejectionInvalidJson = 'invalid_json';
const claudeStatusRejectionStoreFailed = 'store_failed';

const _projectionDirectory = 'projections';
const _projectionFileName = 'claude_status.json';

const _rootKeys = {
  'schema',
  'source',
  'routing',
  'account_bound',
  'idle_machine_proof',
  'windows',
};
const _windowKeys = {'id', 'used_percent', 'resets_at', 'observed_at'};

enum ClaudeStatusLoadState { absent, ready, unreadable }

enum ClaudeStatusIngestKind { stored, cleared, unchanged, rejected }

/// One stored plan window plus the local time those values were first seen.
class ClaudeStatusStoredWindow {
  const ClaudeStatusStoredWindow({
    required this.id,
    required this.usedPercent,
    required this.resetsAt,
    required this.observedAt,
  });

  final String id;
  final double usedPercent;
  final int resetsAt;
  final int observedAt;

  Map<String, Object> toJson() => {
        'id': id,
        'used_percent': usedPercent,
        'resets_at': resetsAt,
        'observed_at': observedAt,
      };
}

class ClaudeStatusProjection {
  const ClaudeStatusProjection(this.windows);

  final List<ClaudeStatusStoredWindow> windows;

  List<ClaudeStatusStoredWindow> currentWindows(int now) => [
        for (final window in windows)
          if (window.resetsAt > now) window,
      ];
}

class ClaudeStatusLoad {
  const ClaudeStatusLoad._(this.state, this.projection);

  const ClaudeStatusLoad.absent() : this._(ClaudeStatusLoadState.absent, null);

  const ClaudeStatusLoad.unreadable()
      : this._(ClaudeStatusLoadState.unreadable, null);

  const ClaudeStatusLoad.ready(ClaudeStatusProjection projection)
      : this._(ClaudeStatusLoadState.ready, projection);

  final ClaudeStatusLoadState state;
  final ClaudeStatusProjection? projection;
}

class ClaudeStatusIngest {
  const ClaudeStatusIngest._(this.kind, this.rejection);

  const ClaudeStatusIngest.stored()
      : this._(ClaudeStatusIngestKind.stored, null);

  const ClaudeStatusIngest.cleared()
      : this._(ClaudeStatusIngestKind.cleared, null);

  const ClaudeStatusIngest.unchanged()
      : this._(ClaudeStatusIngestKind.unchanged, null);

  const ClaudeStatusIngest.rejected(String rejection)
      : this._(ClaudeStatusIngestKind.rejected, rejection);

  final ClaudeStatusIngestKind kind;
  final String? rejection;
}

class ClaudeStatusCliResult {
  const ClaudeStatusCliResult({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;
}

/// True when a terminal invocation should print help instead of reading stdin.
bool claudeStatusShouldShowHelp({
  required bool show,
  required bool stdinIsTerminal,
}) =>
    !show && stdinIsTerminal;

File claudeStatusProjectionFile({bool create = false}) {
  final dir = quotabotDir(_projectionDirectory, create: create);
  return File('${dir.path}/$_projectionFileName');
}

ClaudeStatusLoad loadClaudeStatusProjection(int now) {
  final file = claudeStatusProjectionFile();
  if (!file.existsSync()) return const ClaudeStatusLoad.absent();
  Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } catch (_) {
    return const ClaudeStatusLoad.unreadable();
  }
  final projection = _projectionFromStoredJson(decoded, now);
  if (projection == null) return const ClaudeStatusLoad.unreadable();
  return ClaudeStatusLoad.ready(projection);
}

/// Projects one already-decoded status-line value into the local file.
ClaudeStatusIngest ingestClaudeStatusObject(
  Object? decoded, {
  required int now,
}) {
  final parsed = parseClaudeStatusPayload(decoded, now: now);
  switch (parsed.kind) {
    case ClaudeStatusParseKind.leave:
      return const ClaudeStatusIngest.unchanged();
    case ClaudeStatusParseKind.reject:
      return ClaudeStatusIngest.rejected(
        parsed.rejection ?? claudeStatusRejectionMalformedWindow,
      );
    case ClaudeStatusParseKind.apply:
      if (parsed.windows.isEmpty) {
        return _deleteProjection();
      }
      final previous = loadClaudeStatusProjection(now);
      final prior = previous.state == ClaudeStatusLoadState.ready
          ? previous.projection
          : null;
      final stored = ClaudeStatusProjection([
        for (final window in parsed.windows)
          ClaudeStatusStoredWindow(
            id: window.id,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            observedAt: _observedAt(window, prior, now),
          ),
      ]);
      try {
        _writeProjection(stored);
      } catch (_) {
        return const ClaudeStatusIngest.rejected(
          claudeStatusRejectionStoreFailed,
        );
      }
      return const ClaudeStatusIngest.stored();
  }
}

/// Projects raw stdin bytes. Oversized input is rejected before decoding.
ClaudeStatusIngest ingestClaudeStatusBytes(
  List<int> bytes, {
  required int now,
}) {
  if (bytes.isEmpty) {
    return const ClaudeStatusIngest.rejected(claudeStatusRejectionStdinEmpty);
  }
  if (bytes.length > claudeStatusStdinLimitBytes) {
    return const ClaudeStatusIngest.rejected(
      claudeStatusRejectionStdinTooLarge,
    );
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return const ClaudeStatusIngest.rejected(claudeStatusRejectionInvalidUtf8);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const ClaudeStatusIngest.rejected(claudeStatusRejectionInvalidJson);
  }
  return ingestClaudeStatusObject(decoded, now: now);
}

/// Reads [input] through [maxBytes]. Returns null when the stream is larger.
Future<List<int>?> readBoundedStdin(
  Stream<List<int>> input,
  int maxBytes,
) async {
  final builder = BytesBuilder(copy: false);
  var overflow = false;
  await for (final chunk in input) {
    if (overflow) continue;
    if (builder.length + chunk.length > maxBytes) {
      overflow = true;
      continue;
    }
    builder.add(chunk);
  }
  if (overflow) return null;
  return builder.takeBytes();
}

Future<ClaudeStatusCliResult> runClaudeStatusCommand({
  required bool show,
  required bool asJson,
  required Stream<List<int>> stdin,
  required int now,
}) async {
  if (show) return _renderLoad(loadClaudeStatusProjection(now), asJson, now);
  final bytes = await readBoundedStdin(stdin, claudeStatusStdinLimitBytes);
  if (bytes == null) {
    return _rejected(claudeStatusRejectionStdinTooLarge);
  }
  final ingest = ingestClaudeStatusBytes(bytes, now: now);
  return _renderIngest(ingest, asJson, now);
}

/// Doctor text. Empty when no projection file exists.
List<String> claudeStatusDoctorLines(int now) {
  final load = loadClaudeStatusProjection(now);
  switch (load.state) {
    case ClaudeStatusLoadState.absent:
      return const [];
    case ClaudeStatusLoadState.unreadable:
      return const [
        'Claude session projection',
        '  Stored projection is unreadable and is not quota evidence.',
      ];
    case ClaudeStatusLoadState.ready:
      final projection = load.projection!;
      final current = projection.currentWindows(now);
      final expired = projection.windows.length - current.length;
      return [
        'Claude session projection',
        '  Session-fed status line. This machine only. Not account-wide. '
            'Not a route.',
        for (final window in current) '  ${_windowLine(window, now)}',
        if (expired > 0)
          '  $expired stored ${expired == 1 ? 'window is' : 'windows are'} '
              'past reset and not quota evidence.',
      ];
  }
}

/// Doctor JSON. Null when no projection file exists.
Map<String, Object?>? claudeStatusDoctorJson(int now) {
  final load = loadClaudeStatusProjection(now);
  switch (load.state) {
    case ClaudeStatusLoadState.absent:
      return null;
    case ClaudeStatusLoadState.unreadable:
      return _envelope(readable: false);
    case ClaudeStatusLoadState.ready:
      final projection = load.projection!;
      final current = projection.currentWindows(now);
      final expired = projection.windows.length - current.length;
      return {
        ..._envelope(readable: true),
        'source': claudeStatusProjectionSource,
        'windows': [for (final window in current) window.toJson()],
        if (expired > 0) 'expired_window_count': expired,
      };
  }
}

String claudeStatusStatusLine(ClaudeStatusProjection projection, int now) {
  final current = projection.currentWindows(now);
  if (current.isEmpty) return 'session quota not reported';
  return current
      .map(
        (window) =>
            '${_windowLabel(window.id)} ${_formatUsed(window.usedPercent)}% used',
      )
      .join(' | ');
}

int _observedAt(
  ClaudeStatusParsedWindow window,
  ClaudeStatusProjection? previous,
  int now,
) {
  if (previous == null) return now;
  for (final prior in previous.windows) {
    if (prior.id == window.id &&
        prior.usedPercent == window.usedPercent &&
        prior.resetsAt == window.resetsAt) {
      return prior.observedAt;
    }
  }
  return now;
}

ClaudeStatusIngest _deleteProjection() {
  final file = claudeStatusProjectionFile();
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {
    return const ClaudeStatusIngest.rejected(claudeStatusRejectionStoreFailed);
  }
  return const ClaudeStatusIngest.cleared();
}

void _writeProjection(ClaudeStatusProjection projection) {
  final file = claudeStatusProjectionFile(create: true);
  final parent = file.parent;
  restrictOwnerOnlyDirectory(parent);
  final tmp = File('${file.path}.$pid.tmp');
  tmp.createSync(recursive: true);
  restrictOwnerOnlyFile(tmp);
  try {
    tmp.writeAsStringSync(_encodeStored(projection), flush: true);
    tmp.renameSync(file.path);
  } catch (_) {
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
    rethrow;
  }
  restrictOwnerOnlyFile(file);
}

String _encodeStored(ClaudeStatusProjection projection) =>
    '${const JsonEncoder.withIndent('  ').convert({
          'schema': claudeStatusProjectionSchema,
          'source': claudeStatusProjectionSource,
          'routing': false,
          'account_bound': false,
          'idle_machine_proof': false,
          'windows': [for (final window in projection.windows) window.toJson()],
        })}\n';

ClaudeStatusProjection? _projectionFromStoredJson(Object? decoded, int now) {
  if (decoded is! Map || !_exactKeys(decoded, _rootKeys)) return null;
  if (decoded['schema'] != claudeStatusProjectionSchema) return null;
  if (decoded['source'] != claudeStatusProjectionSource) return null;
  if (decoded['routing'] != false ||
      decoded['account_bound'] != false ||
      decoded['idle_machine_proof'] != false) {
    return null;
  }
  final rawWindows = decoded['windows'];
  if (rawWindows is! List || rawWindows.isEmpty) return null;
  final windows = <ClaudeStatusStoredWindow>[];
  final seen = <String>{};
  for (final raw in rawWindows) {
    final window = _storedWindow(raw, now);
    if (window == null || !seen.add(window.id)) return null;
    windows.add(window);
  }
  final ids = windows.map((window) => window.id).toList();
  final ordered = [...ids]..sort();
  const expected = [claudeStatusFiveHourId, claudeStatusSevenDayId];
  if (ordered.length == 1) {
    if (!expected.contains(ordered.single)) return null;
  } else if (ordered.length != 2 ||
      ordered[0] != expected[0] ||
      ordered[1] != expected[1]) {
    return null;
  }
  final byId = {for (final window in windows) window.id: window};
  return ClaudeStatusProjection([
    for (final id in expected)
      if (byId.containsKey(id)) byId[id]!,
  ]);
}

ClaudeStatusStoredWindow? _storedWindow(Object? raw, int now) {
  if (raw is! Map || !_exactKeys(raw, _windowKeys)) return null;
  final id = raw['id'];
  if (id != claudeStatusFiveHourId && id != claudeStatusSevenDayId) return null;
  final used = raw['used_percent'];
  final resets = raw['resets_at'];
  final observed = raw['observed_at'];
  if (used is! num || resets is! num || observed is! num) return null;
  final usedPercent = used.toDouble();
  final resetsDouble = resets.toDouble();
  final observedDouble = observed.toDouble();
  if (!usedPercent.isFinite || usedPercent < 0 || usedPercent > 100) {
    return null;
  }
  if (!_whole(resetsDouble) || !_whole(observedDouble)) return null;
  final resetsAt = resets.toInt();
  final observedAt = observed.toInt();
  if (resetsAt <= 0 || observedAt <= 0) return null;
  if (observedAt > now + kQuotaEvidenceClockSkewSeconds) return null;
  return ClaudeStatusStoredWindow(
    id: id as String,
    usedPercent: usedPercent,
    resetsAt: resetsAt,
    observedAt: observedAt,
  );
}

bool _exactKeys(Map<dynamic, dynamic> value, Set<String> allowed) {
  if (value.length != allowed.length) return false;
  for (final key in value.keys) {
    if (key is! String || !allowed.contains(key)) return false;
  }
  return true;
}

bool _whole(double value) =>
    value.isFinite && value.truncateToDouble() == value;

String _windowLabel(String id) => id == claudeStatusFiveHourId ? '5h' : '7d';

String _formatUsed(double value) {
  final rounded = (value * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return rounded.round().toString();
  return rounded.toStringAsFixed(1);
}

String _windowLine(ClaudeStatusStoredWindow window, int now) {
  final ageSeconds = (now - window.observedAt).clamp(0, 1 << 31);
  final age = compactAge(ageSeconds, suffix: ' ago');
  final reset = resetCountdownLabel(window.resetsAt, now);
  return '${_windowLabel(window.id)} ${_formatUsed(window.usedPercent)}% used, '
      'resets in $reset, observed $age';
}

Map<String, Object?> _envelope({required bool readable}) => {
      'schema': claudeStatusProjectionSchema,
      'present': true,
      'readable': readable,
      'routing': false,
      'account_bound': false,
      'idle_machine_proof': false,
    };

ClaudeStatusCliResult _renderLoad(ClaudeStatusLoad load, bool asJson, int now) {
  switch (load.state) {
    case ClaudeStatusLoadState.absent:
      return ClaudeStatusCliResult(
        exitCode: 0,
        stdoutText: asJson
            ? _pretty({
                'schema': claudeStatusProjectionSchema,
                'present': false,
                'routing': false,
                'account_bound': false,
                'idle_machine_proof': false,
              })
            : 'No Claude session projection is stored.',
        stderrText: '',
      );
    case ClaudeStatusLoadState.unreadable:
      return const ClaudeStatusCliResult(
        exitCode: 1,
        stdoutText: '',
        stderrText: 'quotabot: stored Claude session projection is unreadable',
      );
    case ClaudeStatusLoadState.ready:
      final projection = load.projection!;
      final doctor = claudeStatusDoctorJson(now);
      return ClaudeStatusCliResult(
        exitCode: 0,
        stdoutText: asJson
            ? _pretty(doctor ?? _envelope(readable: false))
            : claudeStatusStatusLine(projection, now),
        stderrText: '',
      );
  }
}

ClaudeStatusCliResult _renderIngest(
  ClaudeStatusIngest ingest,
  bool asJson,
  int now,
) {
  switch (ingest.kind) {
    case ClaudeStatusIngestKind.rejected:
      return _rejected(ingest.rejection ?? claudeStatusRejectionInvalidJson);
    case ClaudeStatusIngestKind.cleared:
      return ClaudeStatusCliResult(
        exitCode: 0,
        stdoutText: asJson
            ? _pretty({
                'schema': claudeStatusProjectionSchema,
                'present': false,
                'routing': false,
                'account_bound': false,
                'idle_machine_proof': false,
                'outcome': 'cleared',
              })
            : 'session quota not reported',
        stderrText: '',
      );
    case ClaudeStatusIngestKind.unchanged:
      final load = loadClaudeStatusProjection(now);
      if (asJson) {
        final body = load.state == ClaudeStatusLoadState.ready
            ? claudeStatusDoctorJson(now)
            : {
                'schema': claudeStatusProjectionSchema,
                'present': false,
                'routing': false,
                'account_bound': false,
                'idle_machine_proof': false,
              };
        return ClaudeStatusCliResult(
          exitCode: 0,
          stdoutText: _pretty({...?body, 'outcome': 'unchanged'}),
          stderrText: '',
        );
      }
      return const ClaudeStatusCliResult(
        exitCode: 0,
        stdoutText: 'session quota not reported yet',
        stderrText: '',
      );
    case ClaudeStatusIngestKind.stored:
      final load = loadClaudeStatusProjection(now);
      final projection = load.projection;
      if (projection == null) {
        return _rejected(claudeStatusRejectionStoreFailed);
      }
      final doctor = claudeStatusDoctorJson(now);
      return ClaudeStatusCliResult(
        exitCode: 0,
        stdoutText: asJson
            ? _pretty({...?doctor, 'outcome': 'stored'})
            : claudeStatusStatusLine(projection, now),
        stderrText: '',
      );
  }
}

ClaudeStatusCliResult _rejected(String rejection) => ClaudeStatusCliResult(
      exitCode: 1,
      stdoutText: '',
      stderrText:
          'quotabot: claude status input was not a usable quota projection '
          '($rejection)',
    );

String _pretty(Map<String, Object?> value) =>
    const JsonEncoder.withIndent('  ').convert(value);
