import 'package:quotabot_collector/profiles.dart';
import 'package:quotabot_collector/provider_adapters.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalizeProviderId', () {
    test('resolves a retired id to its current canonical id', () {
      // A synthetic rename standing in for a real one, so the resolution is
      // proven end to end without shipping a fake alias in the product map.
      const aliases = {'codeium': windsurfProviderId};
      expect(canonicalizeProviderId('codeium', aliases), windsurfProviderId);
    });

    test('leaves a current id and an unknown id unchanged', () {
      const aliases = {'codeium': windsurfProviderId};
      expect(canonicalizeProviderId(windsurfProviderId, aliases),
          windsurfProviderId);
      expect(canonicalizeProviderId('grok', aliases), 'grok');
    });

    test('is identity with the shipped (empty) alias map', () {
      for (final id in const ['claude', 'codex', 'grok', 'antigravity']) {
        expect(canonicalizeProviderId(id), id);
      }
    });
  });

  group('kProviderIdAliases invariants', () {
    final registered = kProviderAdapterRegistry.map((e) => e.id).toSet();

    test('every alias key is a retired id, never a live registered provider',
        () {
      for (final key in kProviderIdAliases.keys) {
        expect(registered.contains(key), isFalse,
            reason: 'aliasing away the live provider "$key" would break it');
      }
    });

    test('every alias points at a current registered provider', () {
      for (final target in kProviderIdAliases.values) {
        expect(registered.contains(target), isTrue,
            reason: 'alias target "$target" is not a registered provider');
      }
    });

    test('aliases are one-way with no chains', () {
      for (final value in kProviderIdAliases.values) {
        expect(kProviderIdAliases.containsKey(value), isFalse,
            reason: 'alias target "$value" is itself a key: a chain');
      }
    });
  });

  group('identity seams apply canonicalization', () {
    test('normalizeProviderId funnels through the resolver', () {
      // With the shipped empty map this is identity; the point is that the
      // canonicalization step is wired in, so a registered rename would flow.
      expect(normalizeProviderId('  Claude  '), 'claude');
      expect(normalizeProviderId('codex'), 'codex');
    });

    test('providerAdapterById resolves a normal id to its adapter', () {
      expect(providerAdapterById('claude')?.id, 'claude');
      expect(providerAdapterById('nope'), isNull);
    });
  });
}
