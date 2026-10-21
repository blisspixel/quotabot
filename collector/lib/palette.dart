/// Color palettes for the live `quotabot top` view.
///
/// A palette is the four headroom-scale colors (healthy, tightening, low, spent)
/// plus an accent. With no `--theme`, `top` uses the terminal's own ANSI colors.
/// A named or custom palette is an explicit opt-in for 24-bit gradients.
///
/// Retired names (`light`, `dark`, `green`, `matrix`, `synthwave`, `rainbow`)
/// do not change colors. Community palettes stay, with no neon, magenta, pink,
/// or purple accent.
library;

/// A 24-bit color.
class Rgb {
  final int r;
  final int g;
  final int b;
  const Rgb(this.r, this.g, this.b);
}

/// A named set of headroom-scale colors. [rgbFor] maps a remaining-percent value
/// (0..100) onto a smooth gradient across spent -> low -> tightening -> healthy.
class Palette {
  final String name;
  final Rgb healthy; // >= 50% free
  final Rgb tight; // ~25-50%
  final Rgb low; // > 0, tight
  final Rgb spent; // 0
  final Rgb accent; // wordmark, route arrow

  const Palette({
    required this.name,
    required this.healthy,
    required this.tight,
    required this.low,
    required this.spent,
    required this.accent,
  });

  Rgb rgbFor(double remaining) {
    final r = remaining.clamp(0, 100).toDouble();
    if (r < 25) return _lerp(spent, low, r / 25);
    if (r < 50) return _lerp(low, tight, (r - 25) / 25);
    return _lerp(tight, healthy, (r - 50) / 50);
  }

  static Rgb _lerp(Rgb a, Rgb b, double t) {
    int c(int x, int y) => (x + (y - x) * t).round();
    return Rgb(c(a.r, b.r), c(a.g, b.g), c(a.b, b.b));
  }
}

const kDefaultPalette = Palette(
  name: 'default',
  healthy: Rgb(0x3C, 0xB4, 0x4B),
  tight: Rgb(0xD2, 0x96, 0x14),
  low: Rgb(0xDB, 0x6D, 0x28),
  spent: Rgb(0xDC, 0x32, 0x2F),
  accent: Rgb(0x58, 0xA6, 0xFF),
);

/// The palettes people already rice their terminals with. Matching an existing
/// setup matters more than inventing colors: a dashboard that is meant to stay
/// open all day should look like it belongs on the desktop it sits on.
const _gruvbox = Palette(
  name: 'gruvbox',
  healthy: Rgb(0xB8, 0xBB, 0x26),
  tight: Rgb(0xFA, 0xBD, 0x2F),
  low: Rgb(0xFE, 0x80, 0x19),
  spent: Rgb(0xFB, 0x49, 0x34),
  accent: Rgb(0x83, 0xA5, 0x98),
);

const _nord = Palette(
  name: 'nord',
  healthy: Rgb(0xA3, 0xBE, 0x8C),
  tight: Rgb(0xEB, 0xCB, 0x8B),
  low: Rgb(0xD0, 0x87, 0x70),
  spent: Rgb(0xBF, 0x61, 0x6A),
  accent: Rgb(0x88, 0xC0, 0xD0),
);

const _dracula = Palette(
  name: 'dracula',
  healthy: Rgb(0x50, 0xFA, 0x7B),
  tight: Rgb(0xF1, 0xFA, 0x8C),
  low: Rgb(0xFF, 0xB8, 0x6C),
  spent: Rgb(0xFF, 0x55, 0x55),
  accent: Rgb(0x8B, 0xE9, 0xFD),
);

const _catppuccin = Palette(
  name: 'catppuccin',
  healthy: Rgb(0xA6, 0xE3, 0xA1),
  tight: Rgb(0xF9, 0xE2, 0xAF),
  low: Rgb(0xFA, 0xB3, 0x87),
  spent: Rgb(0xD2, 0x0F, 0x39),
  accent: Rgb(0x89, 0xB4, 0xFA),
);

const _tokyoNight = Palette(
  name: 'tokyonight',
  healthy: Rgb(0x9E, 0xCE, 0x6A),
  tight: Rgb(0xE0, 0xAF, 0x68),
  low: Rgb(0xFF, 0x9E, 0x64),
  spent: Rgb(0xDB, 0x4B, 0x4B),
  accent: Rgb(0x7A, 0xA2, 0xF7),
);

const _builtins = {
  'default': kDefaultPalette,
  'gruvbox': _gruvbox,
  'nord': _nord,
  'dracula': _dracula,
  'catppuccin': _catppuccin,
  'tokyonight': _tokyoNight,
};

const _followedTerminalThemes = {'light', 'dark'};

const _retiredThemes = {'green', 'matrix', 'synthwave', 'rainbow'};

/// How `top` should apply a theme spec.
class TopPaletteChoice {
  final Palette palette;

  /// True when the user asked for a 24-bit palette.
  final bool applyTruecolor;

  /// One-line note for a retired or unnecessary theme name.
  final String? notice;

  const TopPaletteChoice(this.palette, this.applyTruecolor, this.notice);
}

/// Resolves [spec] for `top`. An empty spec follows the terminal theme.
TopPaletteChoice resolveTopPalette(String? spec) {
  if (spec == null || spec.trim().isEmpty) {
    return const TopPaletteChoice(kDefaultPalette, false, null);
  }
  final s = spec.trim().toLowerCase();
  if (_followedTerminalThemes.contains(s)) {
    return TopPaletteChoice(
      kDefaultPalette,
      false,
      'top follows your terminal theme; --theme $s is no longer needed',
    );
  }
  if (_retiredThemes.contains(s)) {
    return TopPaletteChoice(
      kDefaultPalette,
      false,
      'theme "$s" was retired; top follows your terminal theme',
    );
  }
  final builtin = _builtins[s];
  if (builtin != null) return TopPaletteChoice(builtin, true, null);
  if (s.startsWith('custom:')) {
    final parsed = _parseCustom(s.substring('custom:'.length));
    if (parsed != null) return TopPaletteChoice(parsed, true, null);
  }
  return const TopPaletteChoice(kDefaultPalette, false, null);
}

/// The names of the built-in palettes, for help text.
List<String> get paletteNames => _builtins.keys.toList();

/// Resolves a palette from a [spec]: a built-in name, or a custom one-liner
/// `custom:HEALTHY-TIGHT-LOW-SPENT[-ACCENT]` of 6-digit hex colors (most free to
/// least, then an optional accent). Unknown or malformed specs fall back to the
/// default, so a typo never breaks rendering.
Palette paletteFromSpec(String? spec) {
  if (spec == null || spec.trim().isEmpty) return kDefaultPalette;
  final s = spec.trim().toLowerCase();
  final builtin = _builtins[s];
  if (builtin != null) return builtin;
  if (s.startsWith('custom:')) {
    final parsed = _parseCustom(s.substring('custom:'.length));
    if (parsed != null) return parsed;
  }
  return kDefaultPalette;
}

Palette? _parseCustom(String body) {
  final parts = body.split('-');
  if (parts.length < 4) return null;
  final colors = <Rgb>[];
  for (final p in parts) {
    final c = _hex(p);
    if (c == null) return null;
    colors.add(c);
  }
  return Palette(
    name: 'custom',
    healthy: colors[0],
    tight: colors[1],
    low: colors[2],
    spent: colors[3],
    accent: colors.length > 4 ? colors[4] : kDefaultPalette.accent,
  );
}

Rgb? _hex(String h) {
  final s = h.startsWith('#') ? h.substring(1) : h;
  if (s.length != 6) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null) return null;
  return Rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
}
