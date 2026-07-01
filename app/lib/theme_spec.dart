import 'package:flutter/material.dart';

const appThemeSystem = 'system';
const appThemeLight = 'light';
const appThemeDark = 'dark';
const appThemeHacker = 'hacker';

String normalizeAppTheme(String? raw) {
  final value = raw?.trim().toLowerCase();
  return switch (value) {
    appThemeLight => appThemeLight,
    appThemeDark => appThemeDark,
    appThemeHacker => appThemeHacker,
    _ => appThemeSystem,
  };
}

String? storedAppTheme(String raw) {
  final normalized = normalizeAppTheme(raw);
  return normalized == appThemeSystem ? null : normalized;
}

ThemeMode themeModeForAppTheme(String raw) {
  return switch (normalizeAppTheme(raw)) {
    appThemeLight => ThemeMode.light,
    appThemeDark || appThemeHacker => ThemeMode.dark,
    _ => ThemeMode.system,
  };
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

  const AppChromeTheme({
    required this.scaffold,
    required this.card,
    required this.border,
    required this.tileBorder,
    required this.foreground,
    required this.muted,
    required this.gaugeTrack,
    required this.accent,
  });

  factory AppChromeTheme.forSpec(Brightness brightness, String spec) {
    if (normalizeAppTheme(spec) == appThemeHacker) {
      return const AppChromeTheme(
        scaffold: Color(0xFF020603),
        card: Color(0xFF071109),
        border: Color(0xFF1F6B35),
        tileBorder: Color(0xFF164D28),
        foreground: Color(0xFFE9FFE8),
        muted: Color(0xFF8CDB9A),
        gaugeTrack: Color(0xFF12391F),
        accent: Color(0xFF39FF14),
      );
    }
    final dark = brightness == Brightness.dark;
    return AppChromeTheme(
      scaffold: dark ? const Color(0xFF14161A) : const Color(0xFFF4F5F7),
      card: dark ? const Color(0xFF1C1F25) : Colors.white,
      border: dark ? const Color(0xFF2A2E36) : const Color(0xFFE2E4E8),
      tileBorder: dark ? const Color(0xFF272B33) : const Color(0xFFEDEEF1),
      foreground: dark ? Colors.white : const Color(0xFF111317),
      muted: dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280),
      gaugeTrack: dark ? const Color(0xFF333842) : const Color(0xFFD8DBE0),
      accent: dark ? const Color(0xFF58A6FF) : const Color(0xFF285AC8),
    );
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
    );
  }

  @override
  AppChromeTheme lerp(ThemeExtension<AppChromeTheme>? other, double t) {
    if (other is! AppChromeTheme) return this;
    Color blend(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return AppChromeTheme(
      scaffold: blend(scaffold, other.scaffold),
      card: blend(card, other.card),
      border: blend(border, other.border),
      tileBorder: blend(tileBorder, other.tileBorder),
      foreground: blend(foreground, other.foreground),
      muted: blend(muted, other.muted),
      gaugeTrack: blend(gaugeTrack, other.gaugeTrack),
      accent: blend(accent, other.accent),
    );
  }
}
