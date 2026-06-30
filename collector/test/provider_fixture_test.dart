import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:quotabot_collector/provider_adapters.dart';
import 'package:test/test.dart';

void main() {
  const now = 1782000000;

  test('sanitized provider-shape fixtures parse through the pure parsers', () {
    for (final entry in kProviderAdapterRegistry) {
      _assertFixtureParses(entry, now);
    }
  });
}

void _assertFixtureParses(ProviderAdapterRegistration entry, int now) {
  switch (entry.fixtureKind) {
    case ProviderFixtureKind.codexRateLimits:
      final windows = codexWindows(_fixtureMap(entry.fixtureFile));
      expect(windows.map((w) => w.label), ['5h', 'weekly']);
      expect(windows[1].usedPercent, 73);
    case ProviderFixtureKind.claudeUsage:
      final windows = claudeWindows(_fixtureMap(entry.fixtureFile));
      expect(windows.map((w) => w.label), ['5h', 'weekly', 'opus']);
      expect(windows.first.resetsAt, isNotNull);
    case ProviderFixtureKind.antigravityQuota:
      final windows = antigravityWindows(_fixtureMap(entry.fixtureFile), now);
      expect(windows, hasLength(2));
      expect(windows.any((w) => w.usedPercent! > 50), isTrue);
    case ProviderFixtureKind.cursorState:
      final windows = cursorWindows(_fixtureMap(entry.fixtureFile), now);
      expect(windows.single.label, 'monthly');
      expect(windows.single.usedPercent, closeTo(86.75, 0.01));
    case ProviderFixtureKind.windsurfState:
      final windows = windsurfWindows(_fixtureMap(entry.fixtureFile), now);
      expect(windows.map((w) => w.label), ['daily', 'weekly']);
    case ProviderFixtureKind.kiroUsageState:
      final windows = kiroWindows(_fixtureMap(entry.fixtureFile), now);
      expect(windows.single.label, 'credits');
      expect(windows.single.usedPercent, 82);
    case ProviderFixtureKind.grokGrpcBytes:
      final window = grokWindow(_fixtureBytes(entry.fixtureFile), now);
      expect(window, isNotNull);
      expect(window!.usedPercent, 6);
      expect(window.resetsAt, 1782086400);
    case ProviderFixtureKind.lmStudioNativeModels:
      final models = lmStudioNativeFromJson(_fixtureMap(entry.fixtureFile));
      expect(models!.installed, hasLength(2));
      expect(models.loaded.single.name, 'llama-3.1-8b');
    case ProviderFixtureKind.ollamaTags:
      final models = ollamaModelsFromJson(_fixtureMap(entry.fixtureFile));
      expect(models.single.name, 'qwen2.5-coder:7b');
      expect(models.single.param, '7B');
    case ProviderFixtureKind.lemonadeModels:
      final models = lmStudioCompatFromJson(_fixtureMap(entry.fixtureFile));
      expect(models, hasLength(2));
      expect(models!.first.name, 'llama-3.2-3b-instruct');
  }
}

Map<String, dynamic> _fixtureMap(String name) =>
    jsonDecode(_fixture(name).readAsStringSync()) as Map<String, dynamic>;

Uint8List _fixtureBytes(String name) {
  final values =
      (jsonDecode(_fixture(name).readAsStringSync()) as List).cast<int>();
  return Uint8List.fromList(values);
}

File _fixture(String name) => File('$kProviderFixtureRoot/$name');
