import 'provider_ids.dart';

const maxExactProviderSelectorCharacters = 64;
const maxExactAccountSelectorCharacters = 512;
const minIdempotencyKeyCharacters = 8;
const maxIdempotencyKeyCharacters = 120;

typedef ExactIdentifierParse = ({String? value, String? error});

final _providerSelectorPattern = RegExp(r'^[a-z0-9][a-z0-9._-]*$');
final _idempotencyKeyPattern = RegExp(r'^[A-Za-z0-9_-]{8,120}$');

ExactIdentifierParse parseExactProviderSelector(Object? raw) {
  if (raw == null) return (value: null, error: null);
  if (raw is! String) {
    return (value: null, error: 'provider must be a string');
  }
  final value = raw.toLowerCase();
  if (value.isEmpty ||
      raw != raw.trim() ||
      value.length > maxExactProviderSelectorCharacters ||
      !_providerSelectorPattern.hasMatch(value)) {
    return (
      value: null,
      error: 'provider must be a non-empty provider id of at most '
          '$maxExactProviderSelectorCharacters characters',
    );
  }
  return (value: canonicalizeProviderId(value), error: null);
}

ExactIdentifierParse parseExactAccountSelector(Object? raw) {
  if (raw == null) return (value: null, error: null);
  if (raw is! String) {
    return (value: null, error: 'account must be a string');
  }
  final value = raw;
  if (value.isEmpty ||
      raw != raw.trim() ||
      value.length > maxExactAccountSelectorCharacters ||
      value.runes.any(
        (character) =>
            character <= 0x1f || (character >= 0x7f && character <= 0x9f),
      )) {
    return (
      value: null,
      error: 'account must be a non-empty printable account identity of at '
          'most $maxExactAccountSelectorCharacters characters',
    );
  }
  return (value: value, error: null);
}

ExactIdentifierParse parseIdempotencyKey(Object? raw) {
  if (raw == null) return (value: null, error: null);
  if (raw is! String || !_idempotencyKeyPattern.hasMatch(raw)) {
    return (
      value: null,
      error: 'idempotency_key must contain 8 to '
          '$maxIdempotencyKeyCharacters ASCII letters, numbers, underscores, '
          'or hyphens',
    );
  }
  return (value: raw, error: null);
}
