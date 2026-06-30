import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'util.dart';

const profileSchema = 'quotabot.profile.v1';
const defaultProfileName = 'default';

enum ProfileRoutingPolicy {
  balanced,
  subscriptionsFirst,
  localOnly;

  static ProfileRoutingPolicy parse(Object? value) {
    final s = value?.toString();
    return ProfileRoutingPolicy.values.firstWhere(
      (p) => p.name == s,
      orElse: () => ProfileRoutingPolicy.balanced,
    );
  }
}

class QuotaProfile {
  final String name;
  final Set<String> providers;
  final Map<String, Set<String>> accounts;
  final Set<String> hiddenProviders;
  final ProfileRoutingPolicy routingPolicy;
  final String? theme;
  final String? sort;

  const QuotaProfile({
    required this.name,
    this.providers = const {},
    this.accounts = const {},
    this.hiddenProviders = const {},
    this.routingPolicy = ProfileRoutingPolicy.balanced,
    this.theme,
    this.sort,
  });

  factory QuotaProfile.defaultProfile() =>
      const QuotaProfile(name: defaultProfileName);

  bool allows(ProviderQuota quota) {
    final provider = normalizeProviderId(quota.provider) ?? quota.provider;
    final hidden = _providerSet(hiddenProviders);
    if (hidden.contains(provider)) return false;
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
    final normalizedHidden = _providerSet(hiddenProviders);
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
      'routing_policy': routingPolicy.name,
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
      hiddenProviders: _providerSet(_stringSet(json['hidden'])),
      routingPolicy: ProfileRoutingPolicy.parse(json['routing_policy']),
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
    hiddenProviders: _providerSet(profile.hiddenProviders),
    routingPolicy: profile.routingPolicy,
    theme: profile.theme,
    sort: profile.sort,
  );
  final file = profileFile(normalized, dir: dir);
  final tmp = File('${file.path}.$pid.tmp');
  tmp.writeAsStringSync(jsonEncode(safe.toJson()));
  tmp.renameSync(file.path);
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
  if (normalized == defaultProfileName) {
    final f = profileFile(normalized, dir: dir);
    if (!f.existsSync()) return QuotaProfile.defaultProfile();
  }
  try {
    final f = profileFile(normalized, dir: dir);
    if (!f.existsSync() || f.lengthSync() > _maxProfileBytes) return null;
    return QuotaProfile.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  } catch (_) {
    return null;
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

String? normalizeProfileName(String? name) {
  final s = name?.trim().toLowerCase();
  if (s == null || s.isEmpty || s.length > 64) return null;
  if (s == '.' || s == '..') return null;
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(s)) return null;
  return s;
}

String? normalizeProviderId(String? provider) {
  final s = provider?.trim().toLowerCase();
  if (s == null || s.isEmpty || s.length > 64) return null;
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(s)) return null;
  return s;
}

const _maxProfileBytes = 256 * 1024;

Set<String> _providerSet(Set<String> values) =>
    values.map(normalizeProviderId).nonNulls.toSet();

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

String? _nonEmptyString(Object? value) {
  final s = value?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

List<String> _sorted(Set<String> values) => values.toList()..sort();

List<String> _sortedKeys(Map<String, Object?> values) =>
    values.keys.toList()..sort();
