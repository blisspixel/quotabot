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
/// clock (via [elapsedSeconds]); this class only sequences the header, the
/// committed per-provider lines, and the single rewritten status line. It never
/// emits an escape-based clear - only a carriage return and trailing spaces - so
/// it renders correctly on terminals without VT support such as cmd.exe.
class FleetProgress {
  final StringSink _sink;
  final String Function(String) _dim;
  final int Function() _elapsedSeconds;
  final int total;
  final Set<String> _pending;
  int _done = 0;
  int _tick = 0;
  int _lastLen = 0;

  FleetProgress({
    required StringSink sink,
    required Iterable<String> pending,
    required int Function() elapsedSeconds,
    String Function(String)? dim,
  })  : _sink = sink,
        _pending = {...pending},
        total = {...pending}.length,
        _elapsedSeconds = elapsedSeconds,
        _dim = dim ?? _identity;

  static String _identity(String s) => s;

  /// Prints the time-expectation header and the first status line.
  void start() {
    _sink.writeln(_dim(fleetReadHeader(total)));
    _drawStatus();
  }

  /// Advances the spinner and repaints the status line (call on a timer).
  void tick() {
    _tick++;
    _drawStatus();
  }

  /// Commits one settled provider above the live status line, then repaints it.
  void providerDone(String displayName, bool ok) {
    _done++;
    _pending.remove(displayName);
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
    final line = fleetProgressLine(
      spinner: fleetSpinnerFrame(_tick),
      done: _done,
      total: total,
      elapsedSeconds: _elapsedSeconds(),
      pending: _pending.toList(),
    );
    _clearStatus();
    _sink.write(_dim(line));
    _lastLen = line.length;
  }

  void _clearStatus() {
    if (_lastLen > 0) {
      _sink.write('\r${' ' * _lastLen}\r');
      _lastLen = 0;
    }
  }

  /// Erases the live status line, leaving the committed lines as scrollback.
  void stop() => _clearStatus();
}
