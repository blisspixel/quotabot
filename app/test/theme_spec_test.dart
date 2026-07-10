import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/theme_spec.dart';

void main() {
  test('system themes expose complete light and dark color roles', () {
    final light = AppChromeTheme.forSpec(Brightness.light, appThemeSystem);
    final dark = AppChromeTheme.forSpec(Brightness.dark, appThemeSystem);

    expect(light.scaffold, const Color(0xFFF4F5F7));
    expect(light.card, Colors.white);
    expect(light.foreground, const Color(0xFF111317));
    expect(dark.scaffold, const Color(0xFF14161A));
    expect(dark.card, const Color(0xFF1C1F25));
    expect(dark.foreground, Colors.white);
    expect(light.accent, isNot(dark.accent));
  });

  test('copyWith changes only the requested semantic colors', () {
    final base = AppChromeTheme.forSpec(Brightness.dark, appThemeSystem);
    final changed = base.copyWith(
      scaffold: Colors.red,
      card: Colors.orange,
      border: Colors.yellow,
      tileBorder: Colors.green,
      foreground: Colors.blue,
      muted: Colors.indigo,
      gaugeTrack: Colors.purple,
      accent: Colors.pink,
    );

    expect(changed.scaffold, Colors.red);
    expect(changed.card, Colors.orange);
    expect(changed.border, Colors.yellow);
    expect(changed.tileBorder, Colors.green);
    expect(changed.foreground, Colors.blue);
    expect(changed.muted, Colors.indigo);
    expect(changed.gaugeTrack, Colors.purple);
    expect(changed.accent, Colors.pink);
    expect(base.copyWith().accent, base.accent);
  });

  test('lerp blends every role and rejects a missing extension', () {
    final light = AppChromeTheme.forSpec(Brightness.light, appThemeSystem);
    final dark = AppChromeTheme.forSpec(Brightness.dark, appThemeSystem);
    final midpoint = light.lerp(dark, 0.5);

    expect(midpoint.scaffold, Color.lerp(light.scaffold, dark.scaffold, 0.5));
    expect(midpoint.card, Color.lerp(light.card, dark.card, 0.5));
    expect(midpoint.border, Color.lerp(light.border, dark.border, 0.5));
    expect(
      midpoint.tileBorder,
      Color.lerp(light.tileBorder, dark.tileBorder, 0.5),
    );
    expect(
      midpoint.foreground,
      Color.lerp(light.foreground, dark.foreground, 0.5),
    );
    expect(midpoint.muted, Color.lerp(light.muted, dark.muted, 0.5));
    expect(
      midpoint.gaugeTrack,
      Color.lerp(light.gaugeTrack, dark.gaugeTrack, 0.5),
    );
    expect(midpoint.accent, Color.lerp(light.accent, dark.accent, 0.5));
    expect(light.lerp(null, 0.5), same(light));
  });

  testWidgets('of reads an installed extension and falls back to brightness', (
    tester,
  ) async {
    const custom = AppChromeTheme(
      scaffold: Colors.red,
      card: Colors.red,
      border: Colors.red,
      tileBorder: Colors.red,
      foreground: Colors.red,
      muted: Colors.red,
      gaugeTrack: Colors.red,
      accent: Colors.red,
    );
    late AppChromeTheme installed;
    late AppChromeTheme fallback;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [custom]),
        home: Builder(
          builder: (context) {
            installed = AppChromeTheme.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(installed, same(custom));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            fallback = AppChromeTheme.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fallback.scaffold, const Color(0xFF14161A));
  });
}
