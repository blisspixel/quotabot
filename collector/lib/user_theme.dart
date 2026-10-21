/// Pure theme-file parser and contrast checker.
///
/// No HTTP, disk, or process calls. Callers pass file text in and get a theme
/// or a one-line refusal back. Disk and git live in `user_theme_store.dart`.
library;

import 'dart:convert';
import 'dart:math' as math;

/// Hard cap for one theme file. Larger bodies are refused before parsing.
const maxThemeFileBytes = 16 * 1024;

/// Euclidean distance in 8-bit sRGB. Success and error closer than this are
/// refused: a shift of about 48 in one channel, or the same amount shared
/// across channels, is the smallest gap that still reads as two status hues.
const successErrorChannelDistance = 48.0;

const contrastBodyMin = 4.5;
const contrastChartMin = 3.0;

final RegExp themeSlugPattern = RegExp(r'^[a-z0-9_][a-z0-9._+-]*$');

final RegExp _hexColor = RegExp(r'^#[0-9a-fA-F]{6}$');

const _requiredColors = [
  'bg',
  'surface',
  'text',
  'muted',
  'accent',
  'success',
  'warning',
  'error',
  'info',
  'selection',
];

const _knownTopKeys = {
  'name',
  'slug',
  'variant',
  'author',
  'source',
  'license',
};

/// An opaque sRGB color. Channels are 0..255.
class ThemeRgb {
  final int r;
  final int g;
  final int b;

  const ThemeRgb(this.r, this.g, this.b);

  String get hex {
    String channel(int value) => value.toRadixString(16).padLeft(2, '0');
    return '#${channel(r)}${channel(g)}${channel(b)}'.toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeRgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}

/// A theme that passed the schema and contrast checks.
class UserTheme {
  final String name;
  final String slug;
  final String variant;
  final String author;
  final String source;
  final String license;
  final ThemeRgb bg;
  final ThemeRgb surface;
  final ThemeRgb text;
  final ThemeRgb muted;
  final ThemeRgb accent;
  final ThemeRgb success;
  final ThemeRgb warning;
  final ThemeRgb caution;
  final ThemeRgb error;
  final ThemeRgb info;
  final ThemeRgb selection;
  final List<ThemeRgb> chart;
  final ThemeRgb border;
  final ThemeRgb tileBorder;
  final ThemeRgb gaugeTrack;
  final List<String> repairs;
  final List<String> ignoredKeys;

  const UserTheme({
    required this.name,
    required this.slug,
    required this.variant,
    required this.author,
    required this.source,
    required this.license,
    required this.bg,
    required this.surface,
    required this.text,
    required this.muted,
    required this.accent,
    required this.success,
    required this.warning,
    required this.caution,
    required this.error,
    required this.info,
    required this.selection,
    required this.chart,
    required this.border,
    required this.tileBorder,
    required this.gaugeTrack,
    this.repairs = const [],
    this.ignoredKeys = const [],
  });

  bool get isLight => variant == 'light';
}

/// Result of parsing one theme body. [refusal] is a single line and [theme]
/// is null when the file must not replace the current theme.
class ThemeParseResult {
  final UserTheme? theme;
  final String? slug;
  final String? refusal;
  final String report;

  const ThemeParseResult({
    this.theme,
    this.slug,
    this.refusal,
    this.report = '',
  });

  bool get ok => theme != null && refusal == null;
}

bool isThemeSlug(String value) =>
    value.length <= 64 && themeSlugPattern.hasMatch(value);

/// Repository directory name used by `theme install`.
/// `quotabot-<name>-theme` becomes `<name>`. Other names stay as the last
/// path segment with a trailing `.git` removed.
String themeSlugFromRepositoryName(String url) {
  var tail = url.trim();
  while (tail.endsWith('/')) {
    tail = tail.substring(0, tail.length - 1);
  }
  final slash = math.max(tail.lastIndexOf('/'), tail.lastIndexOf(':'));
  if (slash >= 0 && slash + 1 < tail.length) {
    tail = tail.substring(slash + 1);
  }
  if (tail.toLowerCase().endsWith('.git')) {
    tail = tail.substring(0, tail.length - 4);
  }
  final match = RegExp(
    r'^quotabot-(.+)-theme$',
    caseSensitive: false,
  ).firstMatch(tail);
  final name = (match?.group(1) ?? tail).toLowerCase();
  return isThemeSlug(name) ? name : '';
}

double _channel(int value) {
  final s = value / 255.0;
  if (s <= 0.04045) return s / 12.92;
  return math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

/// WCAG relative luminance.
double relativeLuminance(ThemeRgb color) =>
    0.2126 * _channel(color.r) +
    0.7152 * _channel(color.g) +
    0.0722 * _channel(color.b);

/// WCAG contrast ratio, 1..21.
double contrastRatio(ThemeRgb a, ThemeRgb b) {
  final left = relativeLuminance(a);
  final right = relativeLuminance(b);
  final lighter = math.max(left, right);
  final darker = math.min(left, right);
  return (lighter + 0.05) / (darker + 0.05);
}

double channelDistance(ThemeRgb a, ThemeRgb b) {
  final dr = (a.r - b.r).toDouble();
  final dg = (a.g - b.g).toDouble();
  final db = (a.b - b.b).toDouble();
  return math.sqrt(dr * dr + dg * dg + db * db);
}

ThemeRgb mixRgb(ThemeRgb a, ThemeRgb b, double t) {
  int channel(int from, int to) =>
      (from + (to - from) * t).round().clamp(0, 255);
  return ThemeRgb(channel(a.r, b.r), channel(a.g, b.g), channel(a.b, b.b));
}

/// Scales every channel toward white (`t > 0`) or black (`t < 0`).
/// One factor keeps the hue as far as a straight RGB scale allows.
ThemeRgb scaleRgb(ThemeRgb color, double t) {
  final clamped = t.clamp(-1.0, 1.0);
  int channel(int value) {
    if (clamped >= 0) {
      return (value + (255 - value) * clamped).round().clamp(0, 255);
    }
    return (value * (1 + clamped)).round().clamp(0, 255);
  }

  return ThemeRgb(channel(color.r), channel(color.g), channel(color.b));
}

bool _meets(ThemeRgb foreground, List<ThemeRgb> backgrounds, double minimum) =>
    backgrounds.every(
      (background) => contrastRatio(foreground, background) + 1e-9 >= minimum,
    );

/// One repair attempt: a binary search for the smallest RGB scale that clears
/// [minimum] on every background. The returned color is the best effort when
/// even full white or black cannot get there.
ThemeRgb repairForeground(
  ThemeRgb foreground,
  List<ThemeRgb> backgrounds,
  double minimum,
) {
  if (backgrounds.isEmpty || _meets(foreground, backgrounds, minimum)) {
    return foreground;
  }
  final worst = backgrounds.reduce(
    (a, b) =>
        contrastRatio(foreground, a) <= contrastRatio(foreground, b) ? a : b,
  );
  final lightened = scaleRgb(foreground, 1);
  final darkened = scaleRgb(foreground, -1);
  final lighten =
      contrastRatio(lightened, worst) >= contrastRatio(darkened, worst);
  var low = 0.0;
  var high = 1.0;
  var best = foreground;
  var bestScore = backgrounds
      .map((background) => contrastRatio(foreground, background))
      .reduce(math.min);
  for (var step = 0; step < 18; step++) {
    final mid = (low + high) / 2;
    final candidate = scaleRgb(foreground, lighten ? mid : -mid);
    final score = backgrounds
        .map((background) => contrastRatio(candidate, background))
        .reduce(math.min);
    if (score + 1e-9 >= minimum) {
      best = candidate;
      high = mid;
    } else {
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
      low = mid;
    }
  }
  return best;
}

const _lightChart = [
  ThemeRgb(0x1F, 0x4E, 0x8C),
  ThemeRgb(0x0E, 0x6A, 0x74),
  ThemeRgb(0x3D, 0x5A, 0x73),
  ThemeRgb(0x24, 0x5C, 0x86),
  ThemeRgb(0x4A, 0x62, 0x74),
  ThemeRgb(0x2A, 0x6F, 0x97),
];

const _darkChart = [
  ThemeRgb(0x79, 0xB8, 0xFF),
  ThemeRgb(0x5F, 0xB3, 0xC8),
  ThemeRgb(0x8F, 0xB4, 0xC9),
  ThemeRgb(0x9A, 0xA7, 0xB8),
  ThemeRgb(0x6E, 0x8C, 0xA0),
  ThemeRgb(0x3D, 0x9A, 0x9A),
];

/// Blues, teals, and neutral greys. Not purple, pink, or status red/green/amber.
List<ThemeRgb> defaultChartColors(ThemeRgb surface) {
  final source = relativeLuminance(surface) >= 0.5 ? _lightChart : _darkChart;
  return [
    for (final color in source)
      repairForeground(color, [surface], contrastChartMin),
  ];
}

/// True for hues the chart must not use as categories: purple, pink, and the
/// status red, green, and amber families. Teal stays allowed.
bool forbiddenChartColor(ThemeRgb color) {
  final r = color.r;
  final g = color.g;
  final b = color.b;
  if (r > 170 && b > 120 && g + 40 < r && g + 20 < b) return true;
  if (b > 140 && r > 100 && g + 30 < b && g + 20 < r && b >= r - 10) {
    return true;
  }
  if (r > 160 && r > g + 50 && r > b + 40 && g < 140) return true;
  if (g > 140 && g > r + 40 && g > b + 30) return true;
  if (r > 160 &&
      g > 110 &&
      b < 90 &&
      r > b + 80 &&
      g > b + 40 &&
      (r - g).abs() < 80) {
    return true;
  }
  return false;
}

String _oneLine(String value) =>
    value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

ThemeParseResult _refuse(
  String? name,
  String? slug,
  String reason,
  String report,
) {
  final label = _oneLine(name ?? '').isEmpty ? null : _oneLine(name!);
  final lead = label == null ? 'Theme not loaded' : 'Theme "$label" not loaded';
  return ThemeParseResult(
    slug: slug,
    refusal: '$lead: ${_oneLine(reason)}',
    report: report,
  );
}

class _ParsedFields {
  final Map<String, String> top = {};
  final Map<String, String> colors = {};
  final List<String> ignored = [];
}

_ParsedFields? _scan(String source, List<String> errors) {
  final fields = _ParsedFields();
  var section = '';
  final lines = source.split(RegExp(r'\r?\n'));
  for (final raw in lines) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) continue;
    final comment = _unquotedHash(line);
    if (comment >= 0) line = line.substring(0, comment).trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[')) {
      if (!line.endsWith(']')) {
        errors.add('invalid section');
        return null;
      }
      section = line.substring(1, line.length - 1).trim().toLowerCase();
      if (section != 'colors') {
        fields.ignored.add(section);
      }
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0) {
      errors.add('invalid line');
      return null;
    }
    final key = line.substring(0, eq).trim().toLowerCase();
    final value = _parseString(line.substring(eq + 1).trim());
    if (value == null) {
      errors.add('$key is not a string');
      return null;
    }
    if (section.isEmpty) {
      if (_knownTopKeys.contains(key)) {
        fields.top[key] = value;
      } else {
        fields.ignored.add(key);
      }
    } else if (section == 'colors') {
      fields.colors[key] = value;
    } else {
      fields.ignored.add('$section.$key');
    }
  }
  return fields;
}

int _unquotedHash(String line) {
  var quote = '';
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote.isEmpty && char == '#') return i;
    if (quote.isEmpty && (char == '"' || char == "'")) {
      quote = char;
      continue;
    }
    if (quote.isNotEmpty && char == '\\') {
      i++;
      continue;
    }
    if (char == quote) quote = '';
  }
  return -1;
}

String? _parseString(String raw) {
  if (raw.length < 2) return null;
  final quote = raw[0];
  if (quote != '"' && quote != "'") return null;
  if (!raw.endsWith(quote)) return null;
  final body = raw.substring(1, raw.length - 1);
  final out = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final char = body[i];
    if (char == quote) return null;
    if (char == '\\') {
      if (i + 1 >= body.length) return null;
      final next = body[++i];
      if (next == quote || next == '\\') {
        out.write(next);
      } else if (next == 'n') {
        return null;
      } else {
        return null;
      }
      continue;
    }
    if (char == '\n' || char == '\r') return null;
    out.write(char);
  }
  return out.toString();
}

ThemeRgb? _parseHex(String raw) {
  final value = raw.trim();
  if (!_hexColor.hasMatch(value)) return null;
  return ThemeRgb(
    int.parse(value.substring(1, 3), radix: 16),
    int.parse(value.substring(3, 5), radix: 16),
    int.parse(value.substring(5, 7), radix: 16),
  );
}

/// Parses one TOML-like theme. Unknown keys are ignored and named in [report].
/// A non-hex color, a slug that fails the pattern, or body text that still
/// misses 4.5:1 on bg after one repair is refused.
ThemeParseResult parseUserTheme(String source, {String? fallbackSlug}) {
  final slugHint = fallbackSlug?.trim().toLowerCase();
  if (utf8.encode(source).length > maxThemeFileBytes) {
    return _refuse(null, slugHint, 'file is over 16 KB.', '');
  }
  final errors = <String>[];
  final scanned = _scan(source, errors);
  if (scanned == null) {
    return _refuse(null, slugHint, errors.join(', '), '');
  }
  final ignored = List<String>.of(scanned.ignored);
  final reportIgnored =
      ignored.isEmpty ? '' : 'ignored keys: ${ignored.join(', ')}';
  final name = _oneLine(scanned.top['name'] ?? '');
  final slug = (scanned.top['slug'] ?? slugHint ?? '').trim().toLowerCase();
  final variant = (scanned.top['variant'] ?? '').trim().toLowerCase();
  if (name.isEmpty) {
    return _refuse(
      null,
      slug.isEmpty ? slugHint : slug,
      'name is missing.',
      reportIgnored,
    );
  }
  if (!isThemeSlug(slug)) {
    return _refuse(name, slugHint, 'slug is invalid.', reportIgnored);
  }
  if (variant != 'dark' && variant != 'light') {
    return _refuse(name, slug, 'variant must be dark or light.', reportIgnored);
  }

  final parsed = <String, ThemeRgb>{};
  for (final key in _requiredColors) {
    final raw = scanned.colors[key];
    if (raw == null) {
      return _refuse(name, slug, 'missing color $key.', reportIgnored);
    }
    final color = _parseHex(raw);
    if (color == null) {
      return _refuse(name, slug, '$key is not #rrggbb.', reportIgnored);
    }
    parsed[key] = color;
  }

  final knownColorKeys = {
    ..._requiredColors,
    'caution',
    for (var i = 1; i <= 6; i++) 'chart-$i',
  };
  for (final key in scanned.colors.keys) {
    if (!knownColorKeys.contains(key)) ignored.add('colors.$key');
  }

  final repairs = <String>[];
  final bg = parsed['bg']!;
  final surface = parsed['surface']!;
  final selection = parsed['selection']!;
  final textBackgrounds = [bg, surface, selection];
  final statusBackgrounds = [bg, surface];

  ThemeRgb repairText(String role, ThemeRgb color) {
    final repaired = repairForeground(color, textBackgrounds, contrastBodyMin);
    if (repaired != color) {
      repairs.add('repaired $role ${color.hex} -> ${repaired.hex}');
    }
    return repaired;
  }

  final text = repairText('text', parsed['text']!);
  final muted = repairText('muted', parsed['muted']!);
  if (contrastRatio(text, bg) + 1e-9 < contrastBodyMin) {
    final ratio = contrastRatio(text, bg);
    return _refuse(
      name,
      slug,
      'text is ${ratio.toStringAsFixed(1)}:1 on bg (needs 4.5).',
      _joinReport(reportIgnored, repairs),
    );
  }

  var caution = parsed['caution'];
  final cautionRaw = scanned.colors['caution'];
  if (cautionRaw == null) {
    caution = mixRgb(parsed['warning']!, parsed['error']!, 0.5);
    repairs.add('derived caution ${caution.hex} from warning and error');
  } else {
    final parsedCaution = _parseHex(cautionRaw);
    if (parsedCaution == null) {
      return _refuse(name, slug, 'caution is not #rrggbb.', reportIgnored);
    }
    caution = parsedCaution;
  }

  ThemeRgb repairStatus(String role, ThemeRgb color) {
    final repaired = repairForeground(
      color,
      statusBackgrounds,
      contrastBodyMin,
    );
    if (repaired != color) {
      repairs.add('repaired $role ${color.hex} -> ${repaired.hex}');
    }
    return repaired;
  }

  final accent = repairStatus('accent', parsed['accent']!);
  final success = repairStatus('success', parsed['success']!);
  final warning = repairStatus('warning', parsed['warning']!);
  final error = repairStatus('error', parsed['error']!);
  final info = repairStatus('info', parsed['info']!);
  final cautionColor = repairStatus('caution', caution);

  if (channelDistance(success, error) < successErrorChannelDistance) {
    return _refuse(
      name,
      slug,
      'success and error are too similar.',
      _joinReport(reportIgnored, repairs),
    );
  }

  final defaults = defaultChartColors(surface);
  final chart = <ThemeRgb>[];
  for (var i = 1; i <= 6; i++) {
    final key = 'chart-$i';
    final raw = scanned.colors[key];
    if (raw == null) {
      chart.add(defaults[i - 1]);
      continue;
    }
    final color = _parseHex(raw);
    if (color == null) {
      return _refuse(name, slug, '$key is not #rrggbb.', reportIgnored);
    }
    if (forbiddenChartColor(color)) {
      chart.add(defaults[i - 1]);
      repairs.add('replaced $key ${color.hex} with ${defaults[i - 1].hex}');
      continue;
    }
    final repaired = repairForeground(color, [surface], contrastChartMin);
    if (!_meets(repaired, [surface], contrastChartMin) ||
        forbiddenChartColor(repaired)) {
      chart.add(defaults[i - 1]);
      repairs.add('replaced $key ${color.hex} with ${defaults[i - 1].hex}');
    } else {
      if (repaired != color) {
        repairs.add('repaired $key ${color.hex} -> ${repaired.hex}');
      }
      chart.add(repaired);
    }
  }

  final border = repairForeground(
      mixRgb(bg, text, 0.22),
      [
        bg,
      ],
      contrastChartMin);
  final tileBorder = mixRgb(surface, text, 0.14);
  final gaugeTrack = mixRgb(surface, text, 0.18);
  final ignoredReport =
      ignored.isEmpty ? '' : 'ignored keys: ${ignored.join(', ')}';

  return ThemeParseResult(
    slug: slug,
    report: _joinReport(ignoredReport, repairs),
    theme: UserTheme(
      name: name,
      slug: slug,
      variant: variant,
      author: scanned.top['author']?.trim() ?? '',
      source: scanned.top['source']?.trim() ?? '',
      license: scanned.top['license']?.trim() ?? '',
      bg: bg,
      surface: surface,
      text: text,
      muted: muted,
      accent: accent,
      success: success,
      warning: warning,
      caution: cautionColor,
      error: error,
      info: info,
      selection: selection,
      chart: chart,
      border: border,
      tileBorder: tileBorder,
      gaugeTrack: gaugeTrack,
      repairs: repairs,
      ignoredKeys: ignored,
    ),
  );
}

String _joinReport(String ignored, List<String> repairs) {
  final parts = [if (ignored.isNotEmpty) ignored, ...repairs];
  return parts.join('; ');
}

/// Extensions the installer and directory loader must not treat as themes.
const ignoredThemeFileExtensions = {
  '.css',
  '.scss',
  '.woff',
  '.woff2',
  '.ttf',
  '.otf',
  '.eot',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.svg',
  '.ico',
  '.js',
  '.mjs',
  '.cjs',
  '.sh',
  '.ps1',
  '.bat',
  '.cmd',
  '.exe',
  '.dll',
  '.py',
  '.rb',
};

bool isIgnoredThemePayload(String name) {
  final lower = name.toLowerCase();
  for (final extension in ignoredThemeFileExtensions) {
    if (lower.endsWith(extension)) return true;
  }
  return false;
}
