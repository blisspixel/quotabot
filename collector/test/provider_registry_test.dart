import 'dart:io';

import 'package:quotabot_collector/provider_adapters.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:test/test.dart';

void main() {
  group('provider adapter registry', () {
    test('covers every built-in adapter exactly once', () {
      final ids = kProviderAdapterRegistry.map((entry) => entry.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(
        ids,
        containsAll([
          antigravityProviderId,
          claudeProviderId,
          codexProviderId,
          cursorProviderId,
          grokProviderId,
          kiroProviderId,
          lemonadeProviderId,
          lmStudioProviderId,
          ollamaProviderId,
          windsurfProviderId,
        ]),
      );
    });

    test('requires one committed provider-shape fixture per adapter', () {
      final fixtureFiles = Directory(kProviderFixtureRoot)
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toSet();
      final registryFiles =
          kProviderAdapterRegistry.map((entry) => entry.fixtureFile).toSet();

      expect(registryFiles, hasLength(kProviderAdapterRegistry.length));
      expect(fixtureFiles, registryFiles);
      for (final entry in kProviderAdapterRegistry) {
        expect(File('$kProviderFixtureRoot/${entry.fixtureFile}').existsSync(),
            isTrue,
            reason: entry.id);
      }
    });

    test('uses stable provider ids and display names', () {
      for (final entry in kProviderAdapterRegistry) {
        expect(entry.id, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
        expect(entry.displayName.trim(), isNotEmpty);
        expect(entry.fixtureFile, endsWith('.json'));
      }
    });

    test('looks up ids case-insensitively and exposes local runtime class', () {
      final ollama = providerAdapterById(' OLLAMA ');
      expect(ollama, isNotNull);
      expect(ollama!.localRuntime, isTrue);
      expect(ollama.cached, isFalse);

      final claude = providerAdapterById(claudeProviderId);
      expect(claude, isNotNull);
      expect(claude!.localRuntime, isFalse);
      expect(claude.cached, isTrue);

      expect(providerAdapterById('missing'), isNull);
    });
  });
}
