import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:test/test.dart';

void main() {
  const now = 1782000000;

  test('sanitized provider-shape fixtures parse through the pure parsers', () {
    final codex = codexWindows(_fixtureMap('codex_rate_limits.json'));
    expect(codex.map((w) => w.label), ['5h', 'weekly']);
    expect(codex[1].usedPercent, 73);

    final claude = claudeWindows(_fixtureMap('claude_usage.json'));
    expect(claude.map((w) => w.label), ['5h', 'weekly', 'opus']);
    expect(claude.first.resetsAt, isNotNull);

    final antigravity = antigravityWindows(
      _fixtureMap('antigravity_quota.json'),
      now,
    );
    expect(antigravity, hasLength(2));
    expect(antigravity.any((w) => w.usedPercent! > 50), isTrue);

    final cursor = cursorWindows(_fixtureMap('cursor_state.json'), now);
    expect(cursor.single.label, 'monthly');
    expect(cursor.single.usedPercent, closeTo(86.75, 0.01));

    final windsurf = windsurfWindows(_fixtureMap('windsurf_state.json'), now);
    expect(windsurf.map((w) => w.label), ['daily', 'weekly']);

    final kiro = kiroWindows(_fixtureMap('kiro_usage_state.json'), now);
    expect(kiro.single.label, 'credits');
    expect(kiro.single.usedPercent, 82);

    final grok = grokWindow(_fixtureBytes('grok_message_bytes.json'), now);
    expect(grok, isNotNull);
    expect(grok!.usedPercent, 6);
    expect(grok.resetsAt, 1782086400);

    final lmstudio = lmStudioNativeFromJson(
      _fixtureMap('lmstudio_native.json'),
    );
    expect(lmstudio!.installed, hasLength(2));
    expect(lmstudio.loaded.single.name, 'llama-3.1-8b');

    final ollama = ollamaModelsFromJson(_fixtureMap('ollama_tags.json'));
    expect(ollama.single.name, 'qwen2.5-coder:7b');
    expect(ollama.single.param, '7B');
  });
}

Map<String, dynamic> _fixtureMap(String name) =>
    jsonDecode(_fixture(name).readAsStringSync()) as Map<String, dynamic>;

Uint8List _fixtureBytes(String name) {
  final values =
      (jsonDecode(_fixture(name).readAsStringSync()) as List).cast<int>();
  return Uint8List.fromList(values);
}

File _fixture(String name) => File('test/fixtures/provider_shapes/$name');
