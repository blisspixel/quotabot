import 'provider_ids.dart';

/// The most specific reported quota rows for one model. Equal matches remain
/// separate constraints so neither quota usage nor admission loses a veto.
List<T> bestModelQuotaMatches<T>(
  Iterable<T> rows, {
  required String provider,
  required String modelId,
  String? displayName,
  required String Function(T row) modelLabel,
}) {
  final modelKeys = modelQuotaIdentityKeys(modelId, displayName);
  final best = <T>[];
  var bestScore = 0;
  for (final row in rows) {
    final score = _matchScore(
      modelQuotaIdentityKey(modelLabel(row)),
      modelKeys,
      provider: provider,
    );
    if (score > bestScore) {
      best
        ..clear()
        ..add(row);
      bestScore = score;
    } else if (score > 0 && score == bestScore) {
      best.add(row);
    }
  }
  return best;
}

int _matchScore(String quotaKey, Set<String> modelKeys,
    {required String provider}) {
  if (modelKeys.contains(quotaKey)) return 3;
  if (modelKeys.any((modelKey) => quotaKey.startsWith(modelKey))) return 2;
  if (_isProviderFamilyQuotaKey(quotaKey) &&
      modelKeys.any((modelKey) => modelKey.startsWith(quotaKey))) {
    return 1;
  }
  if (provider == claudeProviderId &&
      claudeScopedQuotaFamilies.any(
        (family) =>
            quotaKey == family &&
            modelKeys.any((modelKey) => modelKey.contains(family)),
      )) {
    return 1;
  }
  return 0;
}

const Set<String> claudeScopedQuotaFamilies = {
  'fable',
  'opus',
  'sonnet',
  'haiku',
};

Set<String> modelQuotaIdentityKeys(String id, String? displayName) => {
      modelQuotaIdentityKey(id),
      if (displayName != null) modelQuotaIdentityKey(displayName),
    };

String modelQuotaIdentityKey(String label) =>
    label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

bool _isProviderFamilyQuotaKey(String key) =>
    key == 'gemini' || key == 'claude' || key == 'gptoss';
