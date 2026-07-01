import 'package:flutter/widgets.dart';

/// The single source of truth for text sizes across both the main quota view
/// (`main.dart`) and the analytics screen (`fleet.dart`), so the two never drift
/// apart. Pick a role, not a raw number. These are logical sizes; the app-wide
/// [TextScaler] from the text-size preference still scales them together.
///
/// The ramp deliberately collapses the half-point near-duplicates the two
/// screens had grown independently (13 vs 13.5, 12 vs 12.5, 8.5 vs 9) onto one
/// step each, so the same kind of text is the same size on both screens.
abstract final class AppType {
  /// Emphasized stat number on the analytics screen.
  static const double stat = 18.0;

  /// The single sanctioned analytics glyph. Kept distinct on purpose.
  static const double glyph = 14.0;

  /// Largest text: provider names and section titles.
  static const double title = 13.5;

  /// Secondary headings, menu items, and control labels.
  static const double subtitle = 12.5;

  /// Default body and emphasis text.
  static const double body = 11.5;

  /// Compact body in dense rows.
  static const double bodySmall = 11.0;

  /// Captions and muted secondary lines. The most common size.
  static const double caption = 10.5;

  /// Small labels and uppercase section eyebrows.
  static const double label = 10.0;

  /// Fine print under tiles.
  static const double small = 9.5;

  /// The smallest axis and footnote labels.
  static const double micro = 9.0;
}
