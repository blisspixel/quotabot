import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_filters.dart';
import 'package:test/test.dart';

void main() {
  test('parseProviderExclusions accepts strings and string lists', () {
    final parsed = parseProviderExclusions([
      'codex, claude',
      'ollama',
      '',
    ]);

    expect(parsed.ok, isTrue);
    expect(parsed.providers, {'codex', 'claude', 'ollama'});
  });

  test('parseProviderExclusions rejects malformed provider ids', () {
    final parsed = parseProviderExclusions('../bad');

    expect(parsed.ok, isFalse);
    expect(parsed.error, 'invalid exclude provider: ../bad');
    expect(parsed.invalidProvider, '../bad');
  });

  test('filterExcludedProviders removes normalized provider ids', () {
    final providers = [
      ProviderQuota(
        provider: 'Codex',
        displayName: 'Codex',
        account: 'a',
        asOf: 1,
        windows: const [],
      ),
      ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'a',
        asOf: 1,
        windows: const [],
      ),
    ];

    final filtered = filterExcludedProviders(providers, {'codex'});

    expect(filtered.map((provider) => provider.provider), ['claude']);
  });
}
