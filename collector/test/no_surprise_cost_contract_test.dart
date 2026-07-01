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
      final findings = <String>[];

      for (final file in _runtimeFiles(root)) {
        final text = file.readAsStringSync();
        for (final blocked in _blockedInferenceSurfaces.entries) {
          if (text.contains(blocked.key)) {
            findings.add(
              '${_relativePath(root, file)} contains ${blocked.value} '
              '(${blocked.key})',
            );
          }
        }
      }

      expect(
        findings,
        isEmpty,
        reason: 'quotabot must stay quota-metadata-only. Model, chat, image, '
            'video, and other generation calls belong outside runtime code '
            'unless a future design explicitly adds a separately reviewed '
            'paid-spend feature.',
      );
    });

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

Iterable<File> _runtimeFiles(Directory root) sync* {
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
    for (final entry in directory.listSync(recursive: true)) {
      if (entry is! File) continue;
      if (_isIgnoredRuntimePath(entry.path)) continue;
      if (extensions.any(entry.path.endsWith)) yield entry;
    }
  }
}

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
