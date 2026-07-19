import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'provider_ids.dart';
import 'util.dart';

const profileSchema = 'quotabot.profile.v1';
const defaultProfileName = 'default';

enum ProfileRoutingPolicy {
  balanced,

  /// Deprecated wire alias for [balanced]. Kept so older profile files remain
  /// readable; new writes always serialize the canonical policy.
  subscriptionsFirst,
  localOnly;

  static ProfileRoutingPolicy parse(Object? value) {
    final s = value?.toString();
    if (s == ProfileRoutingPolicy.subscriptionsFirst.name) {
      return ProfileRoutingPolicy.balanced;
    }
    return ProfileRoutingPolicy.values.firstWhere(
      (p) => p.name == s,
      orElse: () => ProfileRoutingPolicy.balanced,
    );
  }

  ProfileRoutingPolicy get canonical =>
      this == ProfileRoutingPolicy.subscriptionsFirst
          ? ProfileRoutingPolicy.balanced
          : this;
}

class QuotaProfile {
  final String name;
  final Set<String> providers;
  final Map<String, Set<String>> accounts;
  final Set<String> hiddenProviders;
  final ProfileRoutingPolicy routingPolicy;

  /// The user's provider preference for routing, most-preferred first. Applied
  /// only among already-viable candidates (see [preferredViableCandidate]); it
  /// never overrides availability or the spend envelope. Empty means no
  /// preference.
  final List<String> preferenceOrder;
  final String? theme;
  final String? sort;

  const QuotaProfile({
    required this.name,
    this.providers = const {},
    this.accounts = const {},
    this.hiddenProviders = const {},
    this.routingPolicy = ProfileRoutingPolicy.balanced,
    this.preferenceOrder = const [],
    this.theme,
    this.sort,
  });

  factory QuotaProfile.defaultProfile() =>
      const QuotaProfile(name: defaultProfileName);

  bool allows(ProviderQuota quota) {
    final provider = normalizeProviderId(quota.provider) ?? quota.provider;
    if (hiddenTargetsQuota(hiddenProviders, quota)) {
      return false;
    }
    final allowedProviders = _providerSet(providers);
    if (allowedProviders.isNotEmpty && !allowedProviders.contains(provider)) {
      return false;
    }
    final allowedAccounts = _accountMap(accounts)[provider];
    if (allowedAccounts != null &&
        allowedAccounts.isNotEmpty &&
        !allowedAccounts.contains(quota.account)) {
      return false;
    }
    if (routingPolicy == ProfileRoutingPolicy.localOnly && !quota.isLocal) {
      return false;
    }
    return true;
  }

  List<ProviderQuota> filter(List<ProviderQuota> quotas) =>
      quotas.where(allows).toList();

  Map<String, dynamic> toJson() {
    final normalizedProviders = _providerSet(providers);
    final normalizedAccounts = _accountMap(accounts);
    final normalizedHidden = _hiddenSet(hiddenProviders);
    final normalizedPreference = _preferenceList(preferenceOrder);
    return {
      'schema': profileSchema,
      'name': normalizeProfileName(name) ?? name,
      if (normalizedProviders.isNotEmpty)
        'providers': _sorted(normalizedProviders),
      if (normalizedAccounts.isNotEmpty)
        'accounts': {
          for (final entry in _sortedKeys(normalizedAccounts))
            entry: _sorted(normalizedAccounts[entry] ?? const {}),
        },
      if (normalizedHidden.isNotEmpty) 'hidden': _sorted(normalizedHidden),
      'routing_policy': routingPolicy.canonical.name,
      // Order matters (most-preferred first), so this is a list, not a sorted
      // set like the filter fields above.
      if (normalizedPreference.isNotEmpty)
        'preference_order': normalizedPreference,
      if (theme != null) 'theme': theme,
      if (sort != null) 'sort': sort,
    };
  }

  factory QuotaProfile.fromJson(Map<String, dynamic> json) {
    final name = normalizeProfileName(json['name']?.toString());
    if (name == null) throw const FormatException('invalid profile name');
    final accounts = <String, Set<String>>{};
    final rawAccounts = json['accounts'];
    if (rawAccounts is Map) {
      for (final entry in rawAccounts.entries) {
        final provider = normalizeProviderId(entry.key?.toString());
        if (provider == null) continue;
        final values = _stringSet(entry.value);
        if (values.isNotEmpty) accounts[provider] = values;
      }
    }
    return QuotaProfile(
      name: name,
      providers: _providerSet(_stringSet(json['providers'])),
      accounts: accounts,
      hiddenProviders: _hiddenSet(_stringSet(json['hidden'])),
      routingPolicy: ProfileRoutingPolicy.parse(json['routing_policy']),
      preferenceOrder:
          _preferenceList(_stringListInOrder(json['preference_order'])),
      theme: _nonEmptyString(json['theme']),
      sort: _nonEmptyString(json['sort']),
    );
  }
}

List<ProviderQuota> applyProfile(
  List<ProviderQuota> quotas,
  QuotaProfile profile,
) =>
    profile.filter(quotas);

Directory profilesDir({Directory? root}) {
  if (root != null) {
    if (!root.existsSync()) root.createSync(recursive: true);
    restrictOwnerOnlyDirectory(root);
    return root;
  }
  return quotabotDir('profiles');
}

File profileFile(String name, {Directory? dir}) {
  final normalized = normalizeProfileName(name);
  if (normalized == null) throw ArgumentError.value(name, 'name');
  return File('${profilesDir(root: dir).path}/$normalized.json');
}

void saveProfile(QuotaProfile profile, {Directory? dir}) {
  final normalized = normalizeProfileName(profile.name);
  if (normalized == null) throw ArgumentError.value(profile.name, 'name');
  final safe = QuotaProfile(
    name: normalized,
    providers: _providerSet(profile.providers),
    accounts: _accountMap(profile.accounts),
    hiddenProviders: _hiddenSet(profile.hiddenProviders),
    routingPolicy: profile.routingPolicy,
    preferenceOrder: _preferenceList(profile.preferenceOrder),
    theme: profile.theme,
    sort: profile.sort,
  );
  final file = profileFile(normalized, dir: dir);
  // Profile JSON carries account emails and hidden provider/account targets,
  // so it is owner-only like every other local metadata file: lock the tmp
  // before the secret lands, then re-lock the final file after the rename.
  final tmp = File('${file.path}.$pid.tmp');
  if (!tmp.existsSync()) tmp.createSync(recursive: true);
  restrictOwnerOnlyFile(tmp);
  tmp.writeAsStringSync(jsonEncode(safe.toJson()));
  tmp.renameSync(file.path);
  restrictOwnerOnlyFile(file);
}

void deleteProfile(String name, {Directory? dir}) {
  final normalized = normalizeProfileName(name);
  if (normalized == null || normalized == defaultProfileName) return;
  try {
    final file = profileFile(normalized, dir: dir);
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}

QuotaProfile? loadProfile(String name, {Directory? dir}) {
  final normalized = normalizeProfileName(name);
  if (normalized == null) return null;
  // The zero-config default must always be available: fall back to the built-in
  // default not only when its file is absent but also when it is oversize or
  // corrupt, so a single torn write cannot make the default profile unusable.
  final fallback =
      normalized == defaultProfileName ? QuotaProfile.defaultProfile() : null;
  try {
    final f = profileFile(normalized, dir: dir);
    if (!f.existsSync() || f.lengthSync() > _maxProfileBytes) return fallback;
    return QuotaProfile.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  } catch (_) {
    return fallback;
  }
}

List<QuotaProfile> listProfiles({Directory? dir}) {
  final out = <QuotaProfile>[];
  final seen = <String>{};
  final root = profilesDir(root: dir);
  if (seen.add(defaultProfileName)) out.add(QuotaProfile.defaultProfile());
  try {
    for (final entry in root.listSync()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      if (entry.lengthSync() > _maxProfileBytes) continue;
      try {
        final profile = QuotaProfile.fromJson(
          jsonDecode(entry.readAsStringSync()) as Map<String, dynamic>,
        );
        if (seen.add(profile.name)) out.add(profile);
      } catch (_) {}
    }
  } catch (_) {}
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// Windows reserved device names. As a bare filename stem (with or without an
/// extension) these resolve to a device, not a file, so a profile named `nul`
/// would silently discard its writes and mangle reads. Rejected on every OS so a
/// profile file is portable.
const _windowsReservedNames = {
  'con', 'prn', 'aux', 'nul', //
  'com1', 'com2', 'com3', 'com4', 'com5',
  'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5',
  'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

String? normalizeProfileName(String? name) {
  final s = name?.trim().toLowerCase();
  if (s == null || s.isEmpty || s.length > 64) return null;
  if (s == '.' || s == '..') return null;
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(s)) return null;
  // Check the stem before the first dot, since `nul.json` is reserved too.
  if (_windowsReservedNames.contains(s.split('.').first)) return null;
  return s;
}

String? normalizeProviderId(String? provider) {
  final s = provider?.trim().toLowerCase();
  if (s == null || s.isEmpty || s.length > 64) return null;
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(s)) return null;
  // Resolve a retired id to its current canonical id so a rename does not lose
  // the profiles, hidden-provider choices, filters, and manual entries that
  // funnel through here. Identity until a rename is registered.
  return canonicalizeProviderId(s);
}

/// True when a saved account filter predates opaque credential identities.
/// Older releases used a plan or response label for Claude and Codex accounts,
/// so those filters cannot safely match a current credential. Callers should
/// offer an edit-profile repair and keep the filter fail-closed.
bool isLegacyCredentialProfileAccountFilter(
  String provider,
  String account,
) {
  final normalizedProvider = normalizeProviderId(provider);
  final normalizedAccount = account.trim();
  return (normalizedProvider == claudeProviderId ||
          normalizedProvider == codexProviderId) &&
      normalizedAccount.isNotEmpty &&
      !isOpaqueCredentialIdentity(normalizedAccount);
}

/// Backward-compatible Claude-specific predicate.
bool isLegacyClaudeProfileAccountFilter(String provider, String account) =>
    normalizeProviderId(provider) == claudeProviderId &&
    isLegacyCredentialProfileAccountFilter(provider, account);

/// True for a pre-0.9.3 Codex plan or response-label account filter.
bool isLegacyCodexProfileAccountFilter(String provider, String account) =>
    normalizeProviderId(provider) == codexProviderId &&
    isLegacyCredentialProfileAccountFilter(provider, account);

const _maxProfileBytes = 256 * 1024;

Set<String> _providerSet(Set<String> values) =>
    values.map(normalizeProviderId).nonNulls.toSet();

String? normalizeHiddenTarget(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty || raw.length > 320) return null;
  final provider = normalizeProviderId(raw);
  if (provider != null) return provider;
  final split = raw.indexOf('|');
  if (split <= 0 || split == raw.length - 1) return null;
  final keyProvider = normalizeProviderId(raw.substring(0, split));
  final account = raw.substring(split + 1).trim();
  if (keyProvider == null || account.isEmpty || account.length > 256) {
    return null;
  }
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(account)) return null;
  return '$keyProvider|$account';
}

String quotaHiddenTarget(ProviderQuota quota) {
  final provider = normalizeProviderId(quota.provider) ?? quota.provider;
  return '$provider|${quota.account.trim()}';
}

bool hiddenTargetsQuota(Set<String> hiddenTargets, ProviderQuota quota) {
  final provider = normalizeProviderId(quota.provider) ?? quota.provider;
  final hidden = _hiddenSet(hiddenTargets);
  return hidden.contains(provider) || hidden.contains(quotaHiddenTarget(quota));
}

Set<String> _hiddenSet(Set<String> values) =>
    values.map(normalizeHiddenTarget).nonNulls.toSet();

Map<String, Set<String>> _accountMap(Map<String, Set<String>> values) {
  final out = <String, Set<String>>{};
  for (final entry in values.entries) {
    final provider = normalizeProviderId(entry.key);
    if (provider == null) continue;
    out.putIfAbsent(provider, () => <String>{}).addAll(entry.value);
  }
  return out;
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const {};
  return {
    for (final item in value)
      if (_nonEmptyString(item) case final s?) s,
  };
}

/// Parses a JSON array into a string list preserving order (unlike [_stringSet],
/// which discards it). Non-list input yields an empty list.
List<String> _stringListInOrder(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (_nonEmptyString(item) case final s?) s,
  ];
}

/// Normalizes a provider preference list: canonical provider ids where known,
/// otherwise the trimmed lowercase name, with blanks dropped and duplicates
/// removed while preserving the given order (the router honors first occurrence).
List<String> _preferenceList(Iterable<String> values) {
  final out = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    final id = normalizeProviderId(trimmed) ?? trimmed.toLowerCase();
    if (seen.add(id)) out.add(id);
  }
  return out;
}

String? _nonEmptyString(Object? value) {
  final s = value?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

List<String> _sorted(Set<String> values) => values.toList()..sort();

List<String> _sortedKeys(Map<String, Object?> values) =>
    values.keys.toList()..sort();
