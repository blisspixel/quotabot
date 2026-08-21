import 'package:quotabot_collector/identifiers.dart';
import 'package:test/test.dart';

void main() {
  test('provider selectors are canonical, bounded, and never fail open', () {
    expect(parseExactProviderSelector(null), (value: null, error: null));
    expect(parseExactProviderSelector('Claude').value, 'claude');
    expect(parseExactProviderSelector(' Claude ').error, isNotNull);
    expect(parseExactProviderSelector('').error, isNotNull);
    expect(parseExactProviderSelector('   ').error, isNotNull);
    expect(
      parseExactProviderSelector('a' * maxExactProviderSelectorCharacters)
          .value,
      'a' * maxExactProviderSelectorCharacters,
    );
    expect(
      parseExactProviderSelector(
        'a' * (maxExactProviderSelectorCharacters + 1),
      ).error,
      isNotNull,
    );
    expect(parseExactProviderSelector('../claude').error, isNotNull);
  });

  test('account selectors preserve every printable character through 512', () {
    expect(parseExactAccountSelector(null), (value: null, error: null));
    expect(parseExactAccountSelector('work account').value, 'work account');
    expect(parseExactAccountSelector(' work account ').error, isNotNull);
    for (final length in [121, 240, 241, 256, 257, 512]) {
      final account = 'a' * length;
      expect(
        parseExactAccountSelector(account).value,
        account,
        reason: 'length $length must remain exact',
      );
    }
    expect(parseExactAccountSelector('').error, isNotNull);
    expect(parseExactAccountSelector('   ').error, isNotNull);
    expect(parseExactAccountSelector('a\u0007b').error, isNotNull);
    expect(parseExactAccountSelector('a\u007fb').error, isNotNull);
    expect(parseExactAccountSelector('a\u0085b').error, isNotNull);
    expect(parseExactAccountSelector('a' * 513).error, isNotNull);
  });

  test('idempotency keys are exact from 8 through 120 characters', () {
    for (final length in [8, 120]) {
      final key = 'k' * length;
      expect(parseIdempotencyKey(key).value, key);
    }
    expect(parseIdempotencyKey(null), (value: null, error: null));
    expect(parseIdempotencyKey('k' * 7).error, isNotNull);
    expect(parseIdempotencyKey('k' * 121).error, isNotNull);
    expect(parseIdempotencyKey(' eight__ ').error, isNotNull);
    expect(parseIdempotencyKey('not.valid').error, isNotNull);
  });
}
