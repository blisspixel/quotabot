import 'dart:io';

import 'package:quotabot_collector/catalog_audit.dart';
import 'package:test/test.dart';

const _blockedInferenceSurfaces = <String, String>{
  '/v1/images/generations': 'image generation endpoint',
  '/v1/images/edits': 'image editing endpoint',
  '/v1/chat/completions': 'chat inference endpoint',
  '/v1/responses': 'responses inference endpoint',
  '/v1/completions': 'legacy completions inference endpoint',
  'api.x.ai/v1/images': 'xAI image inference endpoint',
  'api.x.ai/v1/chat/completions': 'xAI chat inference endpoint',
  'api.openai.com/v1/images': 'OpenAI image inference endpoint',
  'api.openai.com/v1/chat/completions': 'OpenAI chat inference endpoint',
  'api.openai.com/v1/responses': 'OpenAI responses inference endpoint',
  'api.anthropic.com/v1/messages': 'Anthropic messages inference endpoint',
  ':generateContent': 'Gemini content-generation endpoint',
  'client.image.sample(': 'xAI SDK image generation call',
  '.images.generate(': 'image generation SDK call',
  '.chat.completions.create(': 'chat completion SDK call',
};

void main() {
  group('no-surprise-cost contract', () {
    test('runtime sources do not call paid model or image inference endpoints',
        () {
      final root = Directory.current.parent;
      expect(
        _inferenceFindings(root),
        isEmpty,
        reason: 'quotabot must stay quota-metadata-only. Model, chat, image, '
            'video, and other generation calls belong outside runtime code '
            'unless a future design explicitly adds a separately reviewed '
            'paid-spend feature.',
      );
    });

    test('generated directories are pruned before listing maintained sources',
        () {
      final root =
          Directory.systemTemp.createTempSync('quotabot_source_audit_');
      addTearDown(() => root.deleteSync(recursive: true));
      const roots = [
        'collector/lib',
        'collector/bin',
        'app/lib',
        'integrations/litellm',
        'tools',
      ];
      const extensions = ['dart', 'py', 'ps1', 'sh', 'yaml', 'yml'];
      for (final sourceRoot in roots) {
        for (final extension in extensions) {
          final file = File(_join(root.path,
              '$sourceRoot/maintained/test_adapter/runtime.$extension'));
          file.createSync(recursive: true);
          file.writeAsStringSync('/v1/chat/completions');
        }
        for (final ignored in _ignoredRuntimeDirectories) {
          final file = File(_join(root.path, '$sourceRoot/$ignored/poison.py'));
          file.createSync(recursive: true);
          file.writeAsStringSync('/v1/chat/completions');
        }
      }

      final listed = <String>[];
      final findings = _inferenceFindings(root, listDirectory: (directory) {
        listed.add(directory.path);
        if (_isIgnoredRuntimeDirectory(directory.path)) {
          throw FileSystemException(
              'derived directory must not be listed', directory.path);
        }
        return _listRuntimeDirectory(directory);
      });

      expect(findings, hasLength(roots.length * extensions.length));
      for (final sourceRoot in roots) {
        for (final extension in extensions) {
          final relative = '$sourceRoot/maintained/test_adapter/runtime.'
              '$extension';
          expect(
            findings,
            contains(
                contains(relative.replaceAll('/', Platform.pathSeparator))),
          );
        }
      }
      expect(listed.where(_isIgnoredRuntimeDirectory), isEmpty);
    });

    test('maintained directory listing failures are not suppressed', () {
      final root =
          Directory.systemTemp.createTempSync('quotabot_source_audit_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(_join(root.path, 'collector/lib/maintained'))
          .createSync(recursive: true);

      expect(
        () => _inferenceFindings(root, listDirectory: (directory) {
          if (directory.path.endsWith('${Platform.pathSeparator}maintained')) {
            throw FileSystemException(
                'maintained source unavailable', directory.path);
          }
          return _listRuntimeDirectory(directory);
        }),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('runtime traversal does not follow directory links outside the tree',
        () {
      final root =
          Directory.systemTemp.createTempSync('quotabot_source_audit_');
      addTearDown(() => root.deleteSync(recursive: true));
      final outside =
          Directory.systemTemp.createTempSync('quotabot_source_audit_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final poison = File(_join(outside.path, 'poison.py'))
        ..writeAsStringSync('/v1/chat/completions');
      final maintained = Directory(_join(root.path, 'collector/lib'))
        ..createSync(recursive: true);
      Link(_join(maintained.path, 'external')).createSync(outside.path);

      expect(poison.existsSync(), isTrue);
      expect(_inferenceFindings(root), isEmpty);
    },
        skip: Platform.isWindows
            ? 'Windows directory links require native privilege support'
            : false);

    test('authenticated catalog audits stay on model-list endpoints only', () {
      final endpoints = {
        for (final source in defaultModelListSources())
          source.provider: source.endpoint.toString(),
      };

      expect(endpoints['codex'], 'https://api.openai.com/v1/models');
      expect(endpoints['grok'], 'https://api.x.ai/v1/models');
      expect(
        endpoints.values,
        everyElement(allOf(
          isNot(contains('/chat/')),
          isNot(contains('/images')),
          isNot(contains('/responses')),
          isNot(contains(':generateContent')),
        )),
      );
    });
  });
}

typedef _RuntimeDirectoryLister = Iterable<FileSystemEntity> Function(
    Directory directory);

const _ignoredRuntimeDirectories = {
  '__pycache__',
  '.dart_tool',
  '.pytest_cache',
  'build',
  'test',
};

List<String> _inferenceFindings(
  Directory root, {
  _RuntimeDirectoryLister listDirectory = _listRuntimeDirectory,
}) {
  final findings = <String>[];
  for (final file in _runtimeFiles(root, listDirectory: listDirectory)) {
    final text = file.readAsStringSync();
    for (final blocked in _blockedInferenceSurfaces.entries) {
      if (text.contains(blocked.key)) {
        findings.add('${_relativePath(root, file)} contains ${blocked.value} '
            '(${blocked.key})');
      }
    }
  }
  return findings;
}

Iterable<FileSystemEntity> _listRuntimeDirectory(Directory directory) =>
    directory.listSync(followLinks: false);

Iterable<File> _runtimeFiles(
  Directory root, {
  _RuntimeDirectoryLister listDirectory = _listRuntimeDirectory,
}) sync* {
  const sourceRoots = [
    'collector/lib',
    'collector/bin',
    'app/lib',
    'integrations/litellm',
    'tools',
  ];
  const extensions = {
    '.dart',
    '.py',
    '.ps1',
    '.sh',
    '.yaml',
    '.yml',
  };

  for (final sourceRoot in sourceRoots) {
    final directory = Directory(_join(root.path, sourceRoot));
    if (!directory.existsSync()) continue;
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
          'runtime source root must be a directory', directory.path);
    }
    for (final entry in _runtimeEntries(directory, listDirectory)) {
      if (entry is! File) continue;
      if (_isIgnoredRuntimePath(entry.path)) continue;
      if (extensions.any(entry.path.endsWith)) yield entry;
    }
  }
}

Iterable<FileSystemEntity> _runtimeEntries(
  Directory directory,
  _RuntimeDirectoryLister listDirectory,
) sync* {
  for (final entry in listDirectory(directory)) {
    if (entry is Directory) {
      if (_isIgnoredRuntimeDirectory(entry.path)) continue;
      yield* _runtimeEntries(entry, listDirectory);
    } else if (entry is File) {
      yield entry;
    }
  }
}

bool _isIgnoredRuntimeDirectory(String path) => _ignoredRuntimeDirectories
    .contains(path.replaceAll(r'\', '/').split('/').last);

bool _isIgnoredRuntimePath(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final name = normalized.split('/').last;
  return normalized.contains('/__pycache__/') ||
      normalized.contains('/.dart_tool/') ||
      normalized.contains('/build/') ||
      normalized.contains('/test/') ||
      name.startsWith('test_') ||
      name.endsWith('_test.dart');
}

String _relativePath(Directory root, File file) {
  final rootPath = root.path.endsWith(Platform.pathSeparator)
      ? root.path
      : '${root.path}${Platform.pathSeparator}';
  return file.path.startsWith(rootPath)
      ? file.path.substring(rootPath.length)
      : file.path;
}

String _join(String root, String relative) =>
    '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';
