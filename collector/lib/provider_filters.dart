import 'models.dart';
import 'profiles.dart';

final class ProviderExclusionParseResult {
  const ProviderExclusionParseResult._({
    required this.providers,
    this.error,
    this.invalidProvider,
  });

  const ProviderExclusionParseResult.ok(Set<String> providers)
      : this._(providers: providers);

  const ProviderExclusionParseResult.error(
    String error, {
    String? invalidProvider,
  }) : this._(
          providers: const {},
          error: error,
          invalidProvider: invalidProvider,
        );

  final Set<String> providers;
  final String? error;
  final String? invalidProvider;

  bool get ok => error == null;
}

ProviderExclusionParseResult parseProviderExclusions(Object? value) {
  if (value == null) return const ProviderExclusionParseResult.ok({});

  final Iterable<Object?> raw;
  if (value is String) {
    raw = [value];
  } else if (value is Iterable) {
    raw = value;
  } else {
    return const ProviderExclusionParseResult.error(
      'exclude must be a string or list of provider ids',
    );
  }

  final providers = <String>{};
  for (final item in raw) {
    if (item is! String) {
      return ProviderExclusionParseResult.error(
        'invalid exclude provider: $item',
        invalidProvider: '$item',
      );
    }
    for (final part in item.split(',')) {
      if (part.trim().isEmpty) continue;
      final provider = normalizeProviderId(part);
      if (provider == null) {
        return ProviderExclusionParseResult.error(
          'invalid exclude provider: $part',
          invalidProvider: part,
        );
      }
      providers.add(provider);
    }
  }
  return ProviderExclusionParseResult.ok(providers);
}

List<ProviderQuota> filterExcludedProviders(
  List<ProviderQuota> providers,
  Set<String> excluded,
) {
  if (excluded.isEmpty) return providers;
  return [
    for (final provider in providers)
      if (!excluded.contains(
        normalizeProviderId(provider.provider) ?? provider.provider,
      ))
        provider,
  ];
}
