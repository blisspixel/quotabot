/// Pure formatters for the interactive fleet-read progress display.
///
/// A live provider read can take tens of seconds because each cloud adapter
/// makes a real metadata round trip. Rather than show a single static spinner
/// for the whole wait - which looks indistinguishable from a hang - the CLI
/// streams one committed line per provider as it settles and keeps a live
/// status line with the running count, elapsed time, and which providers are
/// still outstanding. These functions hold only the string shaping so they can
/// be unit tested without a terminal; the I/O and timer live in the CLI.
library;

import 'cli_layout.dart';

/// Braille spinner frames for the live status line.
const List<String> kFleetSpinnerFrames = [
  '⠋',
  '⠙',
  '⠹',
  '⠸',
  '⠼',
  '⠴',
  '⠦',
  '⠧',
  '⠇',
  '⠏',
];

/// The spinner glyph for animation step [tick] (any non-negative int).
String fleetSpinnerFrame(int tick) =>
    kFleetSpinnerFrames[tick % kFleetSpinnerFrames.length];

/// The one committed line printed when a provider settles, for example
/// "  [6/11] Grok - live (14s)" or "  [7/11] LM Studio - no data (6s)".
String fleetProviderDoneLine({
  required int done,
  required int total,
  required String displayName,
  required bool ok,
  required int elapsedSeconds,
}) =>
    '  [$done/$total] $displayName - ${ok ? 'live' : 'no data'} '
    '(${elapsedSeconds}s)';

/// The header printed once before a read starts, setting the time expectation
/// so a multi-second wait is understood rather than mistaken for a freeze.
String fleetReadHeader(int total) =>
    'reading quota from $total providers - live reads, usually under a minute';

/// The one line left after a quiet read, for example
/// "read 11 providers in 0 s: 1 live, 10 no data".
String fleetReadSummary({
  required int total,
  required int elapsedSeconds,
  required int live,
  required int quiet,
}) {
  final noun = total == 1 ? 'provider' : 'providers';
  return 'read $total $noun in $elapsedSeconds s: $live live, $quiet no data';
}

/// The live, in-place status line while a read is in flight, for example
/// "  ⠇ reading quota  6/11 - 27s - waiting: Grok, Antigravity". At most
/// three outstanding providers are named; any remainder is summarized as
/// "+N more" so the line never grows unbounded.
String fleetProgressLine({
  required String spinner,
  required int done,
  required int total,
  required int elapsedSeconds,
  required List<String> pending,
}) {
  final buf = StringBuffer(
    '  $spinner reading quota  $done/$total - ${elapsedSeconds}s',
  );
  if (pending.isNotEmpty) {
    final shown = pending.take(3).join(', ');
    final extra = pending.length > 3 ? ' +${pending.length - 3} more' : '';
    buf.write(' - waiting: $shown$extra');
  }
  return buf.toString();
}

/// Drives the interactive fleet-read progress display against an injected
/// [StringSink], so the terminal control sequence is unit testable without a
/// real terminal. The caller owns the animation timer (calling [tick]) and the
/// clock (via [elapsedSeconds]). A quiet read prints the header and one summary.
/// [verbose] keeps one committed line per provider. The live status is truncated
/// to one column inside [columns] and cleared with CSI K, so a wrapped fragment
/// does not survive the next paint.
class FleetProgress {
  final StringSink _sink;
  final String Function(String) _dim;
  final int Function() _elapsedSeconds;
  final int Function() _columns;
  final bool verbose;
  final int total;
  final Set<String> _pending;
  int _done = 0;
  int _live = 0;
  int _quiet = 0;
  int _tick = 0;
  bool _statusVisible = false;

  FleetProgress({
    required StringSink sink,
    required Iterable<String> pending,
    required int Function() elapsedSeconds,
    String Function(String)? dim,
    int Function()? columns,
    this.verbose = false,
  })  : _sink = sink,
        _pending = {...pending},
        total = {...pending}.length,
        _elapsedSeconds = elapsedSeconds,
        _columns = columns ?? (() => 10000),
        _dim = dim ?? _identity;

  static String _identity(String s) => s;

  /// Prints the time-expectation header and the first status line.
  void start() {
    for (final line in wrapCliLine(fleetReadHeader(total), _width())) {
      _sink.writeln(_dim(line));
    }
    _drawStatus();
  }

  /// Advances the spinner and repaints the status line (call on a timer).
  void tick() {
    _tick++;
    _drawStatus();
  }

  /// Records one settled provider. Verbose mode commits its line above the
  /// status; a quiet read only updates the summary counts.
  void providerDone(String displayName, bool ok) {
    _done++;
    if (ok) {
      _live++;
    } else {
      _quiet++;
    }
    _pending.remove(displayName);
    if (!verbose) {
      _drawStatus();
      return;
    }
    _clearStatus();
    _sink.writeln(
      _dim(
        fleetProviderDoneLine(
          done: _done,
          total: total,
          displayName: displayName,
          ok: ok,
          elapsedSeconds: _elapsedSeconds(),
        ),
      ),
    );
    _drawStatus();
  }

  void _drawStatus() {
    final limit = _width() - 1;
    var line = fleetProgressLine(
      spinner: fleetSpinnerFrame(_tick),
      done: _done,
      total: total,
      elapsedSeconds: _elapsedSeconds(),
      pending: _pending.toList(),
    );
    if (limit > 0 && line.length > limit) {
      line = line.substring(0, limit);
    }
    _clearStatus();
    _sink.write(_dim(line));
    _statusVisible = true;
  }

  int _width() {
    final columns = _columns();
    return columns < 8 ? 8 : columns;
  }

  void _clearStatus() {
    if (!_statusVisible) return;
    _sink.write('\r\x1b[K');
    _statusVisible = false;
  }

  /// Erases the live status line. A quiet read then leaves one summary.
  void stop() {
    _clearStatus();
    if (verbose) return;
    final summary = fleetReadSummary(
      total: total,
      elapsedSeconds: _elapsedSeconds(),
      live: _live,
      quiet: _quiet,
    );
    for (final line in wrapCliLine(summary, _width())) {
      _sink.writeln(_dim(line));
    }
  }
}
