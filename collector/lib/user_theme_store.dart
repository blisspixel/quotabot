/// File and git adapter for user themes.
///
/// Parsing and contrast stay in `user_theme.dart`. This file is the only
/// place that reads a themes directory or starts git.
library;

import 'dart:io';

import 'user_theme.dart';

/// Runs `git clone --depth 1` into [destination]. Tests pass a fake.
typedef ThemeGitClone = Future<void> Function(
    String url, Directory destination);

class ThemeCommandResult {
  final bool ok;
  final String message;
  final List<String> slugs;
  final String report;

  const ThemeCommandResult({
    required this.ok,
    required this.message,
    this.slugs = const [],
    this.report = '',
  });
}

class ThemeFileLoad {
  final String filename;
  final ThemeParseResult result;

  const ThemeFileLoad({required this.filename, required this.result});
}

/// User themes under one directory. Production uses [platformThemesDirectory].
class UserThemeStore {
  final Directory root;
  final ThemeGitClone? gitClone;

  UserThemeStore(this.root, {this.gitClone});

  /// Platform config directory: `$XDG_CONFIG_HOME/quotabot/themes`,
  /// `%LOCALAPPDATA%/quotabot/themes`, or `~/.config/quotabot/themes`.
  static Directory platformThemesDirectory() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['XDG_CONFIG_HOME'] ??
        '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path}/.config';
    return Directory('$base/quotabot/themes');
  }

  List<ThemeFileLoad> readAll() {
    if (!root.existsSync()) return const [];
    final out = <ThemeFileLoad>[];
    final entries = root.listSync(followLinks: false);
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entries) {
      final name = _baseName(entity.path);
      if (entity is Link || _isLink(entity.path)) {
        out.add(
          ThemeFileLoad(
            filename: name,
            result: ThemeParseResult(
              refusal: 'Theme not loaded: $name is a symlink.',
              report: 'ignored symlink: $name',
            ),
          ),
        );
        continue;
      }
      if (entity is! File) continue;
      if (isIgnoredThemePayload(name) ||
          !name.toLowerCase().endsWith('.toml')) {
        if (isIgnoredThemePayload(name)) {
          out.add(
            ThemeFileLoad(
              filename: name,
              result: ThemeParseResult(report: 'ignored file: $name'),
            ),
          );
        }
        continue;
      }
      out.add(_readFile(entity));
    }
    return out;
  }

  /// Shallow-clones [gitUrl] and copies only regular `*.toml` theme files.
  /// `quotabot-<name>-theme` is reported as `<name>`. Symlinks, CSS, fonts,
  /// images, and scripts are ignored and named in [ThemeCommandResult.report].
  Future<ThemeCommandResult> installFromGit(String gitUrl) async {
    final url = gitUrl.trim();
    if (!_safeGitUrl(url)) {
      return const ThemeCommandResult(
        ok: false,
        message: 'Theme install failed: git url is not allowed.',
      );
    }
    final repoName = themeSlugFromRepositoryName(url);
    Directory? staging;
    try {
      if (!root.existsSync()) root.createSync(recursive: true);
      staging = Directory(
        '${root.path}${Platform.pathSeparator}.install-${DateTime.now().microsecondsSinceEpoch}',
      );
      staging.createSync(recursive: true);
      final clone = gitClone ?? _defaultGitClone;
      await clone(url, staging);
      return _copyClonedThemes(staging, repoName);
    } catch (_) {
      return const ThemeCommandResult(
        ok: false,
        message: 'Theme install failed: git clone failed.',
      );
    } finally {
      if (staging != null && staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  ThemeCommandResult remove(String slug) {
    final normalized = slug.trim().toLowerCase();
    if (!isThemeSlug(normalized)) {
      return const ThemeCommandResult(
        ok: false,
        message: 'Theme remove failed: slug is invalid.',
      );
    }
    final file = File('${root.path}${Platform.pathSeparator}$normalized.toml');
    if (_isLink(file.path)) {
      return ThemeCommandResult(
        ok: false,
        message: 'Theme remove failed: $normalized is a symlink.',
      );
    }
    if (!file.existsSync()) {
      return ThemeCommandResult(
        ok: false,
        message: 'Theme "$normalized" not removed: no user theme file.',
      );
    }
    try {
      file.deleteSync();
    } catch (_) {
      return ThemeCommandResult(
        ok: false,
        message: 'Theme "$normalized" not removed: file is busy.',
      );
    }
    return ThemeCommandResult(
      ok: true,
      message: 'Removed theme $normalized.',
      slugs: [normalized],
    );
  }

  ThemeFileLoad _readFile(File file) {
    final name = _baseName(file.path);
    final stem = name.toLowerCase().endsWith('.toml')
        ? name.substring(0, name.length - 5).toLowerCase()
        : name.toLowerCase();
    try {
      if (file.lengthSync() > maxThemeFileBytes) {
        return ThemeFileLoad(
          filename: name,
          result: ThemeParseResult(
            slug: isThemeSlug(stem) ? stem : null,
            refusal: 'Theme not loaded: file is over 16 KB.',
          ),
        );
      }
      final text = file.readAsStringSync();
      return ThemeFileLoad(
        filename: name,
        result: parseUserTheme(text, fallbackSlug: stem),
      );
    } catch (_) {
      return ThemeFileLoad(
        filename: name,
        result: ThemeParseResult(
          slug: isThemeSlug(stem) ? stem : null,
          refusal: 'Theme not loaded: file could not be read.',
        ),
      );
    }
  }

  ThemeCommandResult _copyClonedThemes(Directory staging, String repoName) {
    final files = <File>[];
    final ignored = <String>[];
    _collectThemeFiles(staging, staging, files, ignored, 0);
    if (files.isEmpty) {
      final named = ignored.isEmpty ? 'no theme file' : ignored.join(', ');
      return ThemeCommandResult(
        ok: false,
        message: 'Theme install failed: $named.',
        report: ignored.isEmpty ? '' : 'ignored: ${ignored.join(', ')}',
      );
    }
    final installed = <String>[];
    final reports = <String>[];
    String? firstRefusal;
    for (final file in files) {
      final loaded = _readFile(file);
      final theme = loaded.result.theme;
      if (theme == null) {
        firstRefusal ??= loaded.result.refusal ?? 'Theme install failed.';
        if (loaded.result.report.isNotEmpty) reports.add(loaded.result.report);
        continue;
      }
      final slug = theme.slug;
      final destination = File(
        '${root.path}${Platform.pathSeparator}$slug.toml',
      );
      if (_isLink(destination.path)) {
        firstRefusal ??= 'Theme "$slug" not loaded: destination is a symlink.';
        continue;
      }
      destination.writeAsStringSync(file.readAsStringSync());
      installed.add(slug);
      if (loaded.result.report.isNotEmpty) reports.add(loaded.result.report);
    }
    if (ignored.isNotEmpty) reports.add('ignored: ${ignored.join(', ')}');
    if (installed.isEmpty) {
      return ThemeCommandResult(
        ok: false,
        message: _oneInstallLine(firstRefusal),
        report: reports.join('; '),
      );
    }
    final repoNote = repoName.isEmpty ? '' : ' from $repoName';
    return ThemeCommandResult(
      ok: true,
      message: 'Installed ${installed.join(', ')}$repoNote.',
      slugs: installed,
      report: reports.join('; '),
    );
  }

  void _collectThemeFiles(
    Directory rootDir,
    Directory current,
    List<File> files,
    List<String> ignored,
    int depth,
  ) {
    if (depth > 4 || files.length >= 32) return;
    final entries = current.listSync(followLinks: false);
    for (final entity in entries) {
      final name = _baseName(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is Link || _isLink(entity.path)) {
        ignored.add(name);
        continue;
      }
      if (entity is Directory) {
        _collectThemeFiles(rootDir, entity, files, ignored, depth + 1);
        continue;
      }
      if (entity is! File) continue;
      if (isIgnoredThemePayload(name)) {
        ignored.add(name);
        continue;
      }
      if (!name.toLowerCase().endsWith('.toml')) continue;
      files.add(entity);
    }
  }
}

String _oneInstallLine(String? refusal) =>
    (refusal ?? 'Theme install failed.').trim();

bool _safeGitUrl(String url) {
  if (url.isEmpty || url.startsWith('-')) return false;
  if (url.contains(' ') ||
      url.contains('\n') ||
      url.contains('\r') ||
      url.contains('\t')) {
    return false;
  }
  final scp = RegExp(r'^git@[\w.-]+:[\w./+-]+$');
  if (scp.hasMatch(url)) return true;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;
  return uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'ssh';
}

bool _isLink(String path) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link;
  } catch (_) {
    return false;
  }
}

String _baseName(String path) {
  final separator = path.lastIndexOf(Platform.pathSeparator);
  final slash = path.lastIndexOf('/');
  final index = mathMax(separator, slash);
  return index >= 0 ? path.substring(index + 1) : path;
}

int mathMax(int a, int b) => a > b ? a : b;

Future<void> _defaultGitClone(String url, Directory destination) async {
  final hooks = await Directory.systemTemp.createTemp('quotabot-theme-hooks-');
  try {
    // An empty hooks path keeps a cloned theme repo from running hooks.
    // The staging directory is deleted after the toml files are copied.
    final env = Map<String, String>.from(Platform.environment);
    env['GIT_TERMINAL_PROMPT'] = '0';
    final result = await Process.run(
      'git',
      [
        '-c',
        'core.hooksPath=${hooks.path}',
        'clone',
        '--depth',
        '1',
        '--config',
        'core.hooksPath=${hooks.path}',
        url,
        destination.path,
      ],
      environment: env,
    ).timeout(const Duration(seconds: 60));
    if (result.exitCode != 0) {
      throw const FormatException('git clone failed');
    }
  } finally {
    if (hooks.existsSync()) {
      try {
        hooks.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
