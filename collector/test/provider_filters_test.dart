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

  test('parseProviderCostPenalties accepts strings and objects', () {
    final fromString = parseProviderCostPenalties('codex:1.5, Claude=2');
    expect(fromString.ok, isTrue);
    expect(fromString.penalties, {'codex': 1.5, 'claude': 2.0});

    final fromObject = parseProviderCostPenalties({'Grok': '0.25'});
    expect(fromObject.ok, isTrue);
    expect(fromObject.penalties, {'grok': 0.25});
  });

  test('parseProviderCostPenalties rejects unsafe keys and bad values', () {
    final badProvider = parseProviderCostPenalties('../bad:1');
    expect(badProvider.ok, isFalse);
    expect(badProvider.error, 'invalid cost-penalty provider: ../bad');

    final badValue = parseProviderCostPenalties('codex:-1');
    expect(badValue.ok, isFalse);
    expect(badValue.error, 'cost penalty for codex must be between 0 and 100');

    final badShape = parseProviderCostPenalties('codex');
    expect(badShape.ok, isFalse);
    expect(badShape.error, 'invalid cost penalty: codex');
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
