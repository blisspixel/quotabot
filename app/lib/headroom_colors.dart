import 'package:flutter/material.dart';
import 'package:quotabot_collector/palette.dart';

/// Desktop headroom color on the same scale used by the terminal palette.
Color headroomColor(num remaining, {Palette palette = kDefaultPalette}) {
  final rgb = palette.rgbFor(remaining.toDouble());
  return Color.fromARGB(0xFF, rgb.r, rgb.g, rgb.b);
}
