/// Color palettes for the live `quotabot top` view.
///
/// A palette is just the four headroom-scale colors (healthy -> tightening ->
/// low -> spent) plus an accent, an interpolation between them giving the smooth
/// gradient meters. Built-ins cover the default, a phosphor "green" CRT look, a
/// muted "dark", a "light" terminal palette, and a "synthwave" for fun. A custom
/// palette is a one-liner, so anyone can make their own without touching code.
///
/// Palettes only change the 24-bit (truecolor) rendering; on 256/16-color
/// terminals the view falls back to the standard named headroom colors, so a
/// custom palette never produces unreadable output.
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

const _green = Palette(
  name: 'green',
  healthy: Rgb(0x39, 0xFF, 0x14), // phosphor
  tight: Rgb(0x00, 0xCC, 0x5A),
  low: Rgb(0x00, 0x99, 0x46),
  spent: Rgb(0x00, 0x5A, 0x32),
  accent: Rgb(0x7C, 0xFF, 0x9E),
);

const _dark = Palette(
  name: 'dark',
  healthy: Rgb(0x2E, 0xA0, 0x43),
  tight: Rgb(0x9E, 0x86, 0x28),
  low: Rgb(0xAA, 0x5A, 0x28),
  spent: Rgb(0xB4, 0x46, 0x46),
  accent: Rgb(0x58, 0x8C, 0xC8),
);

const _light = Palette(
  name: 'light',
  healthy: Rgb(0x23, 0x86, 0x36),
  tight: Rgb(0x9A, 0x67, 0x00),
  low: Rgb(0xB4, 0x50, 0x14),
  spent: Rgb(0xC8, 0x28, 0x28),
  accent: Rgb(0x28, 0x5A, 0xC8),
);

const _synthwave = Palette(
  name: 'synthwave',
  healthy: Rgb(0x00, 0xF5, 0xC8), // aqua
  tight: Rgb(0xFF, 0xC8, 0x00), // gold
  low: Rgb(0xFF, 0x6E, 0x3C), // orange
  spent: Rgb(0xFF, 0x3C, 0x78), // hot pink
  accent: Rgb(0xC8, 0x78, 0xFF), // purple
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
  accent: Rgb(0xBD, 0x93, 0xF9),
);

const _catppuccin = Palette(
  name: 'catppuccin',
  healthy: Rgb(0xA6, 0xE3, 0xA1),
  tight: Rgb(0xF9, 0xE2, 0xAF),
  low: Rgb(0xFA, 0xB3, 0x87),
  spent: Rgb(0xF3, 0x8B, 0xA8),
  accent: Rgb(0xCB, 0xA6, 0xF7),
);

const _tokyoNight = Palette(
  name: 'tokyonight',
  healthy: Rgb(0x9E, 0xCE, 0x6A),
  tight: Rgb(0xE0, 0xAF, 0x68),
  low: Rgb(0xFF, 0x9E, 0x64),
  spent: Rgb(0xF7, 0x76, 0x8E),
  accent: Rgb(0x7A, 0xA2, 0xF7),
);

/// Monochrome phosphor, for the CRT look. Every step is a brighter green, so the
/// meter reads as glow intensity rather than hue.
const _matrix = Palette(
  name: 'matrix',
  healthy: Rgb(0x39, 0xFF, 0x6A),
  tight: Rgb(0x24, 0xC0, 0x4C),
  low: Rgb(0x15, 0x84, 0x33),
  spent: Rgb(0x0B, 0x4A, 0x1E),
  accent: Rgb(0x8C, 0xFF, 0xB0),
);

/// Full-spectrum, for people who want the meter to be the wallpaper.
const _rainbow = Palette(
  name: 'rainbow',
  healthy: Rgb(0x4C, 0xC9, 0xF0),
  tight: Rgb(0x72, 0xEF, 0x36),
  low: Rgb(0xFF, 0xD1, 0x00),
  spent: Rgb(0xF7, 0x25, 0x85),
  accent: Rgb(0xB5, 0x17, 0xFF),
);

const _builtins = {
  'default': kDefaultPalette,
  'green': _green,
  'dark': _dark,
  'light': _light,
  'synthwave': _synthwave,
  'gruvbox': _gruvbox,
  'nord': _nord,
  'dracula': _dracula,
  'catppuccin': _catppuccin,
  'tokyonight': _tokyoNight,
  'matrix': _matrix,
  'rainbow': _rainbow,
};

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
