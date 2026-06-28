/// Minimal ANSI text styling, gated on whether the output wants color.
///
/// Shared by the one-shot CLI output and the live `top` dashboard so the escape
/// codes and the headroom color scale live in exactly one place. When [on] is
/// false every method returns its input unchanged, so the same rendering code
/// produces clean plain text for pipes, dumb terminals, and NO_COLOR.
library;

class AnsiStyle {
  final bool on;
  const AnsiStyle(this.on);

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
