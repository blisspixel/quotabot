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

final class ProviderCostPenaltyParseResult {
  const ProviderCostPenaltyParseResult._({
    required this.penalties,
    this.error,
    this.invalidProvider,
  });

  const ProviderCostPenaltyParseResult.ok(Map<String, double> penalties)
      : this._(penalties: penalties);

  const ProviderCostPenaltyParseResult.error(
    String error, {
    String? invalidProvider,
  }) : this._(
          penalties: const {},
          error: error,
          invalidProvider: invalidProvider,
        );

  final Map<String, double> penalties;
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

ProviderCostPenaltyParseResult parseProviderCostPenalties(Object? value) {
  if (value == null) return const ProviderCostPenaltyParseResult.ok({});

  final out = <String, double>{};

  ProviderCostPenaltyParseResult add(String rawProvider, Object? rawPenalty) {
    final provider = normalizeProviderId(rawProvider);
    if (provider == null) {
      return ProviderCostPenaltyParseResult.error(
        'invalid cost-penalty provider: $rawProvider',
        invalidProvider: rawProvider,
      );
    }
    final penalty = switch (rawPenalty) {
      num n => n.toDouble(),
      String s => double.tryParse(s.trim()),
      _ => null,
    };
    if (penalty == null || !penalty.isFinite || penalty < 0 || penalty > 100) {
      return ProviderCostPenaltyParseResult.error(
        'cost penalty for $provider must be between 0 and 100',
        invalidProvider: rawProvider,
      );
    }
    out[provider] = penalty;
    return ProviderCostPenaltyParseResult.ok(out);
  }

  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        return ProviderCostPenaltyParseResult.error(
          'cost penalties must use provider ids as keys',
          invalidProvider: '${entry.key}',
        );
      }
      final result = add(entry.key as String, entry.value);
      if (!result.ok) return result;
    }
    return ProviderCostPenaltyParseResult.ok(out);
  }

  final Iterable<Object?> raw;
  if (value is String) {
    raw = [value];
  } else if (value is Iterable) {
    raw = value;
  } else {
    return const ProviderCostPenaltyParseResult.error(
      'cost penalties must be a string, list, or object',
    );
  }

  for (final item in raw) {
    if (item is! String) {
      return ProviderCostPenaltyParseResult.error(
        'invalid cost penalty: $item',
        invalidProvider: '$item',
      );
    }
    for (final rawPart in item.split(',')) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      final split = part.contains(':') ? part.indexOf(':') : part.indexOf('=');
      if (split <= 0 || split == part.length - 1) {
        return ProviderCostPenaltyParseResult.error(
          'invalid cost penalty: $part',
          invalidProvider: part,
        );
      }
      final result = add(part.substring(0, split), part.substring(split + 1));
      if (!result.ok) return result;
    }
  }
  return ProviderCostPenaltyParseResult.ok(out);
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
