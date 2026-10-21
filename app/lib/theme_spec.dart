import 'package:flutter/material.dart';
import 'package:quotabot_collector/builtin_themes.dart';
import 'package:quotabot_collector/user_theme.dart';

const appThemeSystem = 'system';
const appThemeLight = 'light';
const appThemeDark = 'dark';
const appThemeHacker = 'hacker';
const appThemeGreenScreen = 'green-screen';

final Map<String, UserTheme> _themesBySlug = {};
bool _builtinsReady = false;

/// Parses the built-in theme constants. Safe to call before the asset bundle
/// is ready, which is what widget tests need.
void ensureBuiltinThemes() {
  if (_builtinsReady) return;
  for (final entry in builtinThemeSources.entries) {
    final parsed = parseUserTheme(entry.value, fallbackSlug: entry.key);
    final theme = parsed.theme;
    if (theme != null) _themesBySlug[theme.slug] = theme;
  }
  _builtinsReady = true;
}

/// Replaces non-built-in themes. Built-in slugs stay on the packaged files.
void replaceUserThemes(Iterable<UserTheme> themes) {
  ensureBuiltinThemes();
  final builtin = builtinThemeSources.keys.toSet();
  _themesBySlug.removeWhere((slug, _) => !builtin.contains(slug));
  for (final theme in themes) {
    if (builtin.contains(theme.slug)) continue;
    _themesBySlug[theme.slug] = theme;
  }
}

UserTheme? lookupTheme(String slug) {
  ensureBuiltinThemes();
  final key = slug.trim().toLowerCase();
  if (key == appThemeHacker) return _themesBySlug[appThemeGreenScreen];
  return _themesBySlug[key];
}

List<UserTheme> installedUserThemes() {
  ensureBuiltinThemes();
  final builtin = builtinThemeSources.keys.toSet();
  return [
    for (final theme in _themesBySlug.values)
      if (!builtin.contains(theme.slug)) theme,
  ];
}

/// Loads `themes/<slug>.toml` from the asset bundle over the constants.
Future<void> loadBundledThemeAssets(
  Future<String> Function(String asset) load,
) async {
  ensureBuiltinThemes();
  for (final slug in builtinThemeSources.keys) {
    try {
      final text = await load('themes/$slug.toml');
      final parsed = parseUserTheme(text, fallbackSlug: slug);
      final theme = parsed.theme;
      if (theme != null) _themesBySlug[slug] = theme;
    } catch (_) {}
  }
}

/// Unset or invalid values open in Dark. Explicit system, light, dark, hacker,
/// and any well-formed slug are preserved.
String normalizeAppTheme(String? raw) {
  final value = raw?.trim().toLowerCase();
  if (value == null || value.isEmpty) return appThemeDark;
  return switch (value) {
    appThemeSystem || appThemeLight || appThemeDark || appThemeHacker => value,
    _ => isThemeSlug(value) ? value : appThemeDark,
  };
}

/// Stored preference. Explicit system is the string `system`, so a later read
/// can tell it apart from a theme key that was never written.
String storedAppTheme(String raw) => normalizeAppTheme(raw);

/// [persisted] is true when the profile file exists. An omitted theme on that
/// file is the legacy system choice. A missing file is first run and is dark.
String themeSpecForProfile(String? raw, {required bool persisted}) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return persisted ? appThemeSystem : appThemeDark;
  }
  return normalizeAppTheme(trimmed);
}

bool themeSpecAvailable(String spec) {
  final value = spec.trim().toLowerCase();
  if (value == appThemeSystem ||
      value == appThemeLight ||
      value == appThemeDark ||
      value == appThemeHacker ||
      value == appThemeGreenScreen) {
    return true;
  }
  return lookupTheme(value) != null;
}

String themeDisplayName(String spec) {
  final value = spec.trim().toLowerCase();
  return switch (value) {
    appThemeSystem => 'System',
    appThemeLight => 'Light',
    appThemeDark => 'Dark',
    appThemeHacker || appThemeGreenScreen => 'Green Screen',
    _ => lookupTheme(value)?.name ?? 'Dark',
  };
}

/// One-line notice. The current theme is unchanged.
String themeRefusalNotice(String refusal, String currentSpec) {
  final line = refusal.replaceAll(RegExp(r'\s+'), ' ').trim();
  return '$line Using ${themeDisplayName(currentSpec)}.';
}

ThemeMode themeModeForAppTheme(String raw) {
  final value = raw.trim().toLowerCase();
  if (value == appThemeLight) return ThemeMode.light;
  if (value == appThemeSystem) return ThemeMode.system;
  if (value == appThemeDark || value == appThemeHacker) return ThemeMode.dark;
  final theme = lookupTheme(value);
  if (theme != null && theme.isLight) return ThemeMode.light;
  return ThemeMode.dark;
}

@immutable
class AppChromeTheme extends ThemeExtension<AppChromeTheme> {
  final Color scaffold;
  final Color card;
  final Color border;
  final Color tileBorder;
  final Color foreground;
  final Color muted;
  final Color gaugeTrack;
  final Color accent;
  final Color success;
  final Color warning;
  final Color caution;
  final Color error;
  final Color info;
  final Color selection;
  final List<Color> chart;

  const AppChromeTheme({
    required this.scaffold,
    required this.card,
    required this.border,
    required this.tileBorder,
    required this.foreground,
    required this.muted,
    required this.gaugeTrack,
    required this.accent,
    required this.success,
    required this.warning,
    required this.caution,
    required this.error,
    required this.info,
    required this.selection,
    required this.chart,
  });

  factory AppChromeTheme.forSpec(Brightness brightness, String spec) {
    ensureBuiltinThemes();
    final value = spec.trim().toLowerCase();
    final UserTheme? theme;
    if (value == appThemeHacker || value == appThemeGreenScreen) {
      theme = _themesBySlug[appThemeGreenScreen];
    } else if (value == appThemeLight) {
      theme = _themesBySlug[appThemeLight];
    } else if (value == appThemeDark) {
      theme = _themesBySlug[appThemeDark];
    } else if (value == appThemeSystem || value.isEmpty) {
      theme = brightness == Brightness.dark
          ? _themesBySlug[appThemeDark]
          : _themesBySlug[appThemeLight];
    } else {
      theme = _themesBySlug[value] ?? _themesBySlug[appThemeDark];
    }
    final resolved = theme ?? _themesBySlug[appThemeDark];
    if (resolved == null) {
      throw StateError('built-in dark theme did not parse');
    }
    return AppChromeTheme._fromUser(resolved);
  }

  factory AppChromeTheme._fromUser(UserTheme theme) {
    Color paint(ThemeRgb rgb) => Color.fromARGB(0xFF, rgb.r, rgb.g, rgb.b);
    return AppChromeTheme(
      scaffold: paint(theme.bg),
      card: paint(theme.surface),
      border: paint(theme.border),
      tileBorder: paint(theme.tileBorder),
      foreground: paint(theme.text),
      muted: paint(theme.muted),
      gaugeTrack: paint(theme.gaugeTrack),
      accent: paint(theme.accent),
      success: paint(theme.success),
      warning: paint(theme.warning),
      caution: paint(theme.caution),
      error: paint(theme.error),
      info: paint(theme.info),
      selection: paint(theme.selection),
      chart: [for (final color in theme.chart) paint(color)],
    );
  }

  /// Remaining headroom percent (0..100) across spent, low, tight, and healthy.
  Color headroom(num remaining) {
    final value = remaining.toDouble().clamp(0, 100).toDouble();
    Color mix(Color from, Color to, double t) =>
        Color.lerp(from, to, t) ?? from;
    if (value < 25) return mix(error, caution, value / 25);
    if (value < 50) return mix(caution, warning, (value - 25) / 25);
    return mix(warning, success, (value - 50) / 50);
  }

  /// Top-edge lift for a meter fill. Dark themes lift toward text, light
  /// themes toward the card, both at 22% opacity.
  Color meterLift(Color color) {
    final source = scaffold.computeLuminance() < 0.5 ? foreground : card;
    return Color.alphaBlend(source.withValues(alpha: 0.22), color);
  }

  static AppChromeTheme of(BuildContext context) =>
      Theme.of(context).extension<AppChromeTheme>() ??
      AppChromeTheme.forSpec(Theme.of(context).brightness, appThemeSystem);

  @override
  AppChromeTheme copyWith({
    Color? scaffold,
    Color? card,
    Color? border,
    Color? tileBorder,
    Color? foreground,
    Color? muted,
    Color? gaugeTrack,
    Color? accent,
    Color? success,
    Color? warning,
    Color? caution,
    Color? error,
    Color? info,
    Color? selection,
    List<Color>? chart,
  }) {
    return AppChromeTheme(
      scaffold: scaffold ?? this.scaffold,
      card: card ?? this.card,
      border: border ?? this.border,
      tileBorder: tileBorder ?? this.tileBorder,
      foreground: foreground ?? this.foreground,
      muted: muted ?? this.muted,
      gaugeTrack: gaugeTrack ?? this.gaugeTrack,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      caution: caution ?? this.caution,
      error: error ?? this.error,
      info: info ?? this.info,
      selection: selection ?? this.selection,
      chart: chart ?? this.chart,
    );
  }

  @override
  AppChromeTheme lerp(ThemeExtension<AppChromeTheme>? other, double t) {
    if (other is! AppChromeTheme) return this;
    Color blend(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    final count = chart.length > other.chart.length
        ? chart.length
        : other.chart.length;
    return AppChromeTheme(
      scaffold: blend(scaffold, other.scaffold),
      card: blend(card, other.card),
      border: blend(border, other.border),
      tileBorder: blend(tileBorder, other.tileBorder),
      foreground: blend(foreground, other.foreground),
      muted: blend(muted, other.muted),
      gaugeTrack: blend(gaugeTrack, other.gaugeTrack),
      accent: blend(accent, other.accent),
      success: blend(success, other.success),
      warning: blend(warning, other.warning),
      caution: blend(caution, other.caution),
      error: blend(error, other.error),
      info: blend(info, other.info),
      selection: blend(selection, other.selection),
      chart: [
        for (var i = 0; i < count; i++)
          blend(
            i < chart.length ? chart[i] : chart.last,
            i < other.chart.length ? other.chart[i] : other.chart.last,
          ),
      ],
    );
  }
}
