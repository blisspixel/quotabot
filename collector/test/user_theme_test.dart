import 'dart:io';

import 'package:quotabot_collector/builtin_themes.dart';
import 'package:quotabot_collector/user_theme.dart';
import 'package:quotabot_collector/user_theme_store.dart';
import 'package:test/test.dart';

void main() {
  test('built-in theme files match the canonical constants', () {
    final files = {
      'dark': builtinDarkThemeSource,
      'light': builtinLightThemeSource,
      'green-screen': builtinGreenScreenThemeSource,
    };
    for (final entry in files.entries) {
      final file = _themeFile('${entry.key}.toml');
      expect(_norm(file.readAsStringSync()), _norm(entry.value));
      expect(builtinThemeSources[entry.key], entry.value);
    }
    expect(
      builtinGreenScreenThemeSource.toUpperCase(),
      isNot(contains('39FF14')),
    );
    expect(builtinGreenScreenThemeSource, contains('#0E1511'));
    expect(builtinGreenScreenThemeSource, contains('#82AB89'));
    expect(builtinGreenScreenThemeSource, contains('#8FD19E'));
    expect(builtinGreenScreenThemeSource, contains('#24402D'));
  });

  test('every built-in theme meets the contrast contract', () {
    for (final entry in builtinThemeSources.entries) {
      final parsed = parseUserTheme(entry.value, fallbackSlug: entry.key);
      expect(parsed.ok, isTrue, reason: '${entry.key}: ${parsed.refusal}');
      final theme = parsed.theme!;
      expect(theme.chart, hasLength(6));
      _expectBody(theme.text, theme, 'text');
      _expectBody(theme.muted, theme, 'muted');
      for (final role in [
        theme.accent,
        theme.success,
        theme.warning,
        theme.caution,
        theme.error,
        theme.info,
      ]) {
        expect(
          contrastRatio(role, theme.bg) + 1e-9,
          greaterThanOrEqualTo(contrastBodyMin),
          reason: '${theme.slug} ${role.hex} on bg',
        );
        expect(
          contrastRatio(role, theme.surface) + 1e-9,
          greaterThanOrEqualTo(contrastBodyMin),
          reason: '${theme.slug} status on surface',
        );
      }
      for (final chart in theme.chart) {
        expect(forbiddenChartColor(chart), isFalse, reason: chart.hex);
        expect(
          contrastRatio(chart, theme.surface) + 1e-9,
          greaterThanOrEqualTo(contrastChartMin),
        );
      }
      expect(
        channelDistance(theme.success, theme.error),
        greaterThanOrEqualTo(successErrorChannelDistance),
      );
    }
  });

  test('light warning and green-screen muted repairs are recorded', () {
    final light = parseUserTheme(builtinLightThemeSource);
    expect(light.ok, isTrue);
    expect(light.theme!.warning.hex, isNot('#9A6700'));
    expect(light.report, contains('repaired warning'));
    expect(builtinLightThemeSource, contains('#9A6700'));

    final screen = parseUserTheme(builtinGreenScreenThemeSource);
    expect(screen.ok, isTrue);
    expect(screen.theme!.muted.hex, isNot('#82AB89'));
    expect(screen.report, contains('repaired muted'));
  });

  test('refuses a non-hex color in one line and keeps no theme', () {
    final parsed = parseUserTheme(_theme(colors: {'text': 'not-a-color'}));
    expect(parsed.theme, isNull);
    expect(parsed.refusal, 'Theme "Forest" not loaded: text is not #rrggbb.');
    expect(parsed.refusal, isNot(contains('\n')));
  });

  test('refuses body text that still misses 4.5:1 on bg', () {
    final parsed = parseUserTheme(
      _theme(
        colors: {
          'bg': '#FFFFFF',
          'surface': '#000000',
          'selection': '#FFFFFF',
          'text': '#000000',
          'muted': '#111111',
        },
      ),
    );
    expect(parsed.theme, isNull);
    expect(parsed.refusal, contains('text is'));
    expect(parsed.refusal, contains('on bg (needs 4.5)'));
    expect(parsed.refusal, isNot(contains('\n')));
  });

  test('refuses success and error that are too similar', () {
    final parsed = parseUserTheme(
      _theme(colors: {'success': '#3FB950', 'error': '#3FBA50'}),
    );
    expect(parsed.ok, isFalse);
    expect(parsed.refusal, contains('success and error are too similar'));
    expect(
      channelDistance(
        const ThemeRgb(0x3F, 0xB9, 0x50),
        const ThemeRgb(0x3F, 0xBA, 0x50),
      ),
      lessThan(successErrorChannelDistance),
    );
  });

  test('one file can carry an unknown key and a chart substitution', () {
    final parsed = parseUserTheme(
      _theme(
        extraTop: 'glow = "soft"',
        colors: {'chart-1': '#BC8CFF', 'chart-2': '#E685B5'},
      ),
    );
    expect(parsed.ok, isTrue, reason: parsed.refusal);
    expect(parsed.report, contains('ignored keys: glow'));
    expect(parsed.report, contains('replaced chart-1'));
    expect(parsed.report, contains('replaced chart-2'));
    expect(forbiddenChartColor(parsed.theme!.chart[0]), isFalse);
    expect(forbiddenChartColor(parsed.theme!.chart[1]), isFalse);
  });

  test('derives caution when the key is absent', () {
    final source = _theme().replaceAll(
      RegExp(r'\ncaution = "#[0-9A-Fa-f]{6}"'),
      '',
    );
    expect(source, isNot(contains('caution')));
    final parsed = parseUserTheme(source);
    expect(parsed.ok, isTrue, reason: parsed.refusal);
    expect(parsed.report, contains('derived caution'));
  });

  test(
    'store loads, ignores, installs, and removes inside a temp directory',
    () async {
      final root = await Directory.systemTemp.createTemp('quotabot-themes-');
      addTearDown(() async {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = UserThemeStore(root);
      File('${root.path}/forest.toml').writeAsStringSync(_theme());
      File('${root.path}/style.css').writeAsStringSync('body { color: red; }');
      var linked = false;
      try {
        Link(
          '${root.path}/linked.toml',
        ).createSync(File('${root.path}/forest.toml').path);
        linked = true;
      } catch (_) {}
      File('${root.path}/bad.toml').writeAsStringSync(
        _theme(name: 'Bad', slug: 'bad_theme', colors: {'text': 'green'}),
      );
      File(
        '${root.path}/huge.toml',
      ).writeAsStringSync('x' * (maxThemeFileBytes + 1));

      final loaded = store.readAll();
      final byName = {for (final item in loaded) item.filename: item.result};
      expect(byName['forest.toml']!.ok, isTrue);
      expect(byName['style.css']!.theme, isNull);
      expect(byName['style.css']!.refusal, isNull);
      expect(byName['style.css']!.report, contains('ignored file: style.css'));
      expect(byName['bad.toml']!.refusal, contains('not #rrggbb'));
      expect(byName['bad.toml']!.refusal, isNot(contains('\n')));
      expect(byName['huge.toml']!.refusal, contains('16 KB'));
      if (linked) {
        expect(byName['linked.toml']!.refusal, contains('symlink'));
      }

      final installed = await UserThemeStore(
        root,
        gitClone: (url, destination) async {
          expect(url, 'https://example.com/quotabot-lagoon-theme.git');
          File('${destination.path}/readme.md').writeAsStringSync('nope');
          File('${destination.path}/theme.css').writeAsStringSync('x');
          Directory('${destination.path}/nested').createSync();
          File(
            '${destination.path}/nested/lagoon.toml',
          ).writeAsStringSync(_theme(name: 'Lagoon', slug: 'lagoon'));
        },
      ).installFromGit('https://example.com/quotabot-lagoon-theme.git');
      expect(installed.ok, isTrue, reason: installed.message);
      expect(installed.slugs, ['lagoon']);
      expect(installed.message, contains('lagoon'));
      expect(installed.report, contains('ignored'));
      expect(File('${root.path}/lagoon.toml').existsSync(), isTrue);

      final removed = store.remove('lagoon');
      expect(removed.ok, isTrue);
      expect(File('${root.path}/lagoon.toml').existsSync(), isFalse);
      final missing = store.remove('lagoon');
      expect(missing.ok, isFalse);
      expect(missing.message, contains('not removed'));
      expect(store.remove('../dark').ok, isFalse);

      final blocked = await store.installFromGit('file:///tmp/theme');
      expect(blocked.ok, isFalse);
      expect(blocked.message, 'Theme install failed: git url is not allowed.');
    },
  );
}

void _expectBody(ThemeRgb color, UserTheme theme, String role) {
  for (final background in [theme.bg, theme.surface, theme.selection]) {
    expect(
      contrastRatio(color, background) + 1e-9,
      greaterThanOrEqualTo(contrastBodyMin),
      reason: '${theme.slug} $role ${color.hex} on ${background.hex}',
    );
  }
}

String _theme({
  String name = 'Forest',
  String slug = 'forest',
  String variant = 'dark',
  String extraTop = '',
  Map<String, String> colors = const {},
}) {
  final values = {
    'bg': '#14161A',
    'surface': '#1C1F25',
    'text': '#FFFFFF',
    'muted': '#8A91A0',
    'accent': '#58A6FF',
    'success': '#3FB950',
    'warning': '#D29922',
    'caution': '#DB6D28',
    'error': '#F85149',
    'info': '#58A6FF',
    'selection': '#1E2A3A',
  };
  values.addAll(colors);
  return [
    'name = "$name"',
    'slug = "$slug"',
    'variant = "$variant"',
    if (extraTop.isNotEmpty) extraTop,
    '',
    '[colors]',
    for (final entry in values.entries) '${entry.key} = "${entry.value}"',
    '',
  ].join('\n');
}

File _themeFile(String name) {
  final candidates = [File('app/themes/$name'), File('../app/themes/$name')];
  for (final file in candidates) {
    if (file.existsSync()) return file;
  }
  throw StateError('missing $name from ${Directory.current.path}');
}

String _norm(String value) => value.replaceAll('\r\n', '\n').trimRight();
