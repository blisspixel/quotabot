import 'dart:io';

import 'package:quotabot_collector/models.dart';
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
          nvidiaProviderId,
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

    test('declares the complete allowed source-class contract', () {
      Set<ProviderSourceClass> classes(String id) =>
          providerAdapterById(id)!.sourceClasses;

      expect(
          classes(claudeProviderId), {ProviderSourceClass.authoritativeLive});
      expect(classes(grokProviderId), {ProviderSourceClass.authoritativeLive});
      expect(classes(codexProviderId), {
        ProviderSourceClass.authoritativeLive,
        ProviderSourceClass.thisMachineFallback,
      });
      expect(classes(antigravityProviderId), {
        ProviderSourceClass.authoritativeLive,
        ProviderSourceClass.thisMachineFallback,
      });
      for (final id in [cursorProviderId, windsurfProviderId, kiroProviderId]) {
        expect(classes(id), {ProviderSourceClass.passiveLocalEvidence});
      }
      for (final id in [
        ollamaProviderId,
        lmStudioProviderId,
        lemonadeProviderId
      ]) {
        expect(classes(id), {ProviderSourceClass.localRuntime});
      }
      expect(classes(nvidiaProviderId), {ProviderSourceClass.statusOnly});
      expect(
        kProviderAdapterRegistry
            .every((entry) => entry.sourceClasses.isNotEmpty),
        isTrue,
      );
      for (final entry in kProviderAdapterRegistry) {
        expect(entry.sourceClasses, builtInProviderSourceClasses(entry.id),
            reason: entry.id);
      }
    });

    test('rejects unregistered classes and built-in manual evidence', () {
      final claude = ProviderQuota(
        provider: claudeProviderId,
        displayName: claudeProviderName,
        account: 'default',
        asOf: 1,
        perMachine: true,
        sourceClass: ProviderSourceClass.passiveLocalEvidence,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
      );
      expect(
        registeredSourceClassViolation(
          claude,
          providerAdapterById(claudeProviderId),
        ),
        contains('not admitted for claude'),
      );

      final manual = ProviderQuota(
        provider: claudeProviderId,
        displayName: claudeProviderName,
        account: 'default',
        source: providerQuotaManualSource,
        asOf: 1,
      );
      expect(
        registeredSourceClassViolation(
          manual,
          providerAdapterById(claudeProviderId),
        ),
        isNull,
      );
      expect(
        registeredSourceClassViolation(
          manual,
          providerAdapterById(claudeProviderId),
          allowManual: false,
        ),
        contains('built-in adapters'),
      );

      final wrongIdentity = ProviderQuota(
        provider: codexProviderId,
        displayName: codexProviderName,
        account: 'default',
        asOf: 1,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
      );
      expect(
        registeredSourceClassViolation(
          wrongIdentity,
          providerAdapterById(claudeProviderId),
          allowManual: false,
        ),
        contains('does not match registered adapter claude'),
      );
    });

    test('looks up ids case-insensitively and exposes local runtime class', () {
      final ollama = providerAdapterById(' OLLAMA ');
      expect(ollama, isNotNull);
      expect(ollama!.localRuntime, isTrue);
      expect(ollama.adapterClass.quotaKind, ProviderQuotaKind.local);
      expect(ollama.cached, isFalse);

      final claude = providerAdapterById(claudeProviderId);
      expect(claude, isNotNull);
      expect(claude!.localRuntime, isFalse);
      expect(claude.adapterClass.quotaKind, ProviderQuotaKind.subscription);
      expect(claude.cached, isTrue);

      expect(providerAdapterById('missing'), isNull);
    });

    test('owns collection order and cache policy metadata', () {
      expect(kProviderAdapterRegistry.map((entry) => entry.id), [
        claudeProviderId,
        codexProviderId,
        cursorProviderId,
        windsurfProviderId,
        kiroProviderId,
        ollamaProviderId,
        lmStudioProviderId,
        lemonadeProviderId,
        nvidiaProviderId,
        grokProviderId,
        antigravityProviderId,
      ]);

      expect(
        kProviderAdapterRegistry
            .where((entry) => entry.accountScopedCache)
            .map((entry) => entry.id),
        [grokProviderId, antigravityProviderId],
      );
      expect(
        kProviderAdapterRegistry
            .where((entry) => !entry.cached)
            .map((entry) => entry.id),
        [
          ollamaProviderId,
          lmStudioProviderId,
          lemonadeProviderId,
          nvidiaProviderId
        ],
      );
      expect(
        kProviderAdapterRegistry
            .where((entry) => entry.multiAccount)
            .every((entry) => entry.currentAccounts != null),
        isTrue,
      );
    });
  });
}
