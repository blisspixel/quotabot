/// Minimal ANSI text styling, gated on whether the output wants color.
///
/// Shared by the one-shot CLI output and the live `top` dashboard so the escape
/// codes and the headroom color scale live in exactly one place. When [on] is
/// false every method returns its input unchanged, so the same rendering code
/// produces clean plain text for pipes, dumb terminals, and NO_COLOR.
library;

/// How much color the terminal can render, so the live view can use smooth
/// 24-bit gradient meters where supported and degrade cleanly everywhere else.
enum ColorDepth { none, ansi16, ansi256, truecolor }

/// Detects color depth from the environment: NO_COLOR/CLICOLOR=0 or no terminal
/// means none; COLORTERM=truecolor/24bit means truecolor; a 256-color TERM means
/// ansi256; otherwise basic 16-color. Pure for testing.
ColorDepth detectColorDepth(Map<String, String> env,
    {required bool hasTerminal}) {
  if (env.containsKey('NO_COLOR')) return ColorDepth.none;
  if (env['CLICOLOR'] == '0') return ColorDepth.none;
  if (!hasTerminal) return ColorDepth.none;
  final ct = (env['COLORTERM'] ?? '').toLowerCase();
  if (ct.contains('truecolor') || ct.contains('24bit')) {
    return ColorDepth.truecolor;
  }
  final term = (env['TERM'] ?? '').toLowerCase();
  if (term.contains('256')) return ColorDepth.ansi256;
  return ColorDepth.ansi16;
}

class AnsiStyle {
  final bool on;

  /// Color resolution for gradient rendering. Ignored when [on] is false.
  final ColorDepth depth;

  const AnsiStyle(this.on, {this.depth = ColorDepth.ansi16});

  /// True when 24-bit gradients can be drawn.
  bool get truecolor => on && depth == ColorDepth.truecolor;

  /// A 24-bit foreground color, or the plain string when truecolor is off (the
  /// caller falls back to a named color in that case).
  String rgb(int r, int g, int b, String s) =>
      truecolor ? '\x1B[38;2;$r;$g;${b}m$s\x1B[0m' : s;

  String _w(String code, String s) => on ? '\x1B[${code}m$s\x1B[0m' : s;

  String bold(String s) => _w('1', s);
  String dim(String s) => _w('2', s);
  String green(String s) => _w('32', s);
  String yellow(String s) => _w('33', s);
  String orange(String s) => _w('38;5;208', s);
  String red(String s) => _w('31', s);
  String cyan(String s) => _w('36', s);

  /// Colors text on the shared headroom scale (input is remaining percent):
  /// green when healthy, amber as it tightens, orange when low, red when spent.
  String health(num remaining, String s) {
    if (remaining >= 50) return green(s);
    if (remaining >= 25) return yellow(s);
    if (remaining > 0) return orange(s);
    return red(s);
  }
}
