import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:quotabot_collector/adapters/grok.dart';
import 'package:quotabot_collector/adapters/lemonade.dart';
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

  test('historical Grok gRPC fixture remains a legacy parser regression', () {
    final raw = jsonDecode(File('test/fixtures/legacy/grok_message_bytes.json')
        .readAsStringSync()) as List<dynamic>;
    final bytes = Uint8List.fromList(raw.cast<int>());
    final window = grokWindow(bytes, now)!;
    expect(window.usedPercent, 73);
    expect(window.resetsAt, 1783379179);
    expect(grokCategoryDetails(bytes),
        ['Category split of this weekly pool: 66%, 5%, 2%']);
  });
}

void _assertFixtureParses(ProviderAdapterRegistration entry, int now) {
  switch (entry.fixtureKind) {
    case ProviderFixtureKind.codexUsage:
      final windows = codexUsageWindows(_fixtureMap(entry.fixtureFile));
      expect(windows.map((w) => w.label), ['5h', 'weekly']);
      expect(windows[1].usedPercent, 73);
    case ProviderFixtureKind.claudeUsage:
      final data = _fixtureMap(entry.fixtureFile);
      final windows = claudeWindows(data);
      expect(windows.map((w) => w.label), ['5h', 'weekly']);
      expect(windows.first.resetsAt, isNotNull);
      final models = claudeModelQuotas(data);
      expect(models.map((m) => m.model), ['Opus']);
      expect(models.single.usedPercent, 12);
    case ProviderFixtureKind.antigravityQuota:
      // The Cloud Code endpoint reports each model's binding limit; quotabot
      // surfaces the account's most-constrained one as a single weekly window.
      final windows = antigravityWindows(_fixtureMap(entry.fixtureFile), now);
      expect(windows, hasLength(1));
      expect(windows.single.label, 'weekly');
      expect(windows.single.usedPercent! > 50, isTrue);
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
    case ProviderFixtureKind.grokBilling:
      // Synthetic shape from the pinned official client. Purchased balances
      // and product usage cannot replace the included pool's percentage.
      final window = grokBillingWindowFromJson(_fixtureMap(entry.fixtureFile));
      expect(window, isNotNull);
      expect(window!.usedPercent, 73);
      expect(window.label, 'weekly');
      expect(window.resetsAt, 1789171200);
    case ProviderFixtureKind.lmStudioNativeModels:
      final models = lmStudioNativeFromJson(_fixtureMap(entry.fixtureFile));
      expect(models!.installed, hasLength(2));
      expect(models.loaded.single.name, 'llama-3.1-8b');
      // v0 declares tool use in its capability array and vision through the
      // model type, so both reach the capability gates.
      expect(models.loaded.single.tools, isTrue);
      expect(models.loaded.single.vision, isFalse);
      final vlm = models.installed.firstWhere((m) => m.name == 'mistral-7b');
      expect(vlm.tools, isFalse);
      expect(vlm.vision, isTrue);
      // Both are generative types, so neither is removed from routing.
      expect(models.installed.map((m) => m.embedding), everyElement(isFalse));
    case ProviderFixtureKind.ollamaTags:
      final models = ollamaModelsFromJson(_fixtureMap(entry.fixtureFile));
      expect(models.single.name, 'qwen2.5-coder:7b');
      expect(models.single.param, '7B');
      // The model list carries the content digest used to cache capabilities,
      // but declares no capability of its own; `/api/show` does that.
      expect(models.single.digest, isNotNull);
      expect(models.single.tools, isNull);
      expect(models.single.vision, isNull);
    case ProviderFixtureKind.lemonadeModels:
      final models = lemonadeModelsFromJson(_fixtureMap(entry.fixtureFile));
      expect(models, hasLength(3));
      expect(models!.first.name, 'llama-3.2-3b-instruct');
      expect(models.first.context, 32768);
      expect(models.first.tools, isTrue);
      expect(models.last.cloud, isTrue);
    case ProviderFixtureKind.nvidiaModels:
      final fixture = _fixtureMap(entry.fixtureFile);
      expect(fixture['object'], 'list');
      expect(fixture['data'], isA<List<dynamic>>());
  }
}

Map<String, dynamic> _fixtureMap(String name) =>
    jsonDecode(_fixture(name).readAsStringSync()) as Map<String, dynamic>;

File _fixture(String name) => File('$kProviderFixtureRoot/$name');
