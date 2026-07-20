import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/profiles.dart';

import 'prefs.dart';
import 'theme_spec.dart';

const genericAccountLabels = {'default', 'unknown', 'installed', 'cli'};

bool quotaHasSpecificAccount(ProviderQuota q) =>
    q.account.trim().isNotEmpty &&
    !genericAccountLabels.contains(q.account.trim().toLowerCase());

String quotaDisplayKey(ProviderQuota q) =>
    quotaHasSpecificAccount(q) ? '${q.provider}|${q.account}' : q.provider;

String quotaHideTarget(ProviderQuota quota, Map<String, int> providerCounts) =>
    (providerCounts[quota.provider] ?? 0) > 1 && quotaHasSpecificAccount(quota)
    ? quotaHiddenTarget(quota)
    : quota.provider;

bool quotaShouldShowAccountLabel(
  ProviderQuota quota,
  Map<String, int> providerCounts,
) =>
    quotaHasSpecificAccount(quota) && (providerCounts[quota.provider] ?? 0) > 1;

ProviderSort sortFromProfile(QuotaProfile profile) =>
    ProviderSort.values.firstWhere(
      (sort) => sort.name == profile.sort,
      orElse: () => ProviderSort.defaultOrder,
    );

String profileLabel(QuotaProfile profile) {
  if (profile.name == defaultProfileName) return 'Default';
  return profile.name
      .split(RegExp(r'[._-]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

QuotaProfile profileWithUiPrefs(
  QuotaProfile profile, {
  required Set<String> hiddenProviders,
  required ProviderSort sort,
}) => QuotaProfile(
  name: profile.name,
  providers: profile.providers,
  accounts: profile.accounts,
  hiddenProviders: hiddenProviders,
  routingPolicy: profile.routingPolicy.canonical,
  // Routing preference is not a UI pref; it survives a UI-pref update.
  preferenceOrder: profile.preferenceOrder,
  theme: profile.theme,
  sort: sort.name,
);

QuotaProfile profileWithoutUiPrefs(QuotaProfile profile) => QuotaProfile(
  name: profile.name,
  providers: profile.providers,
  accounts: profile.accounts,
  routingPolicy: profile.routingPolicy.canonical,
  // Stripping UI prefs (theme, sort) must not drop a routing preference.
  preferenceOrder: profile.preferenceOrder,
  theme: profile.theme,
  sort: profile.sort,
);

class ProfileProviderOption {
  final String provider;
  final String displayName;
  final List<String> accounts;

  const ProfileProviderOption({
    required this.provider,
    required this.displayName,
    required this.accounts,
  });
}

List<ProfileProviderOption> profileProviderOptions(
  List<ProviderQuota> quotas, {
  List<QuotaProfile> profiles = const [],
}) {
  final labels = <String, String>{};
  final accounts = <String, Set<String>>{};
  for (final q in quotas) {
    labels.putIfAbsent(q.provider, () => q.displayName);
    // Claude and Codex moved from human plan/response labels to opaque,
    // credential-derived identities. Never offer an obsolete profile label as
    // though it were a currently detected credential.
    if (quotaHasSpecificAccount(q) &&
        !isLegacyCredentialProfileAccountFilter(q.provider, q.account)) {
      accounts.putIfAbsent(q.provider, () => <String>{}).add(q.account);
    }
  }
  for (final profile in profiles) {
    for (final provider in profile.providers) {
      labels.putIfAbsent(provider, () => provider);
    }
    for (final entry in profile.accounts.entries) {
      labels.putIfAbsent(entry.key, () => entry.key);
      accounts
          .putIfAbsent(entry.key, () => <String>{})
          .addAll(
            entry.value.where(
              (account) =>
                  !isLegacyCredentialProfileAccountFilter(entry.key, account),
            ),
          );
    }
  }
  final ids = labels.keys.toList()
    ..sort((a, b) => labels[a]!.compareTo(labels[b]!));
  return [
    for (final id in ids)
      ProfileProviderOption(
        provider: id,
        displayName: labels[id]!,
        accounts: (accounts[id]?.toList() ?? <String>[])..sort(),
      ),
  ];
}

QuotaProfile profileFromSelection({
  required String name,
  required List<ProfileProviderOption> options,
  required Set<String> selectedProviders,
  required Map<String, Set<String>> selectedAccounts,
  required Set<String> hiddenProviders,
  required ProfileRoutingPolicy routingPolicy,
  required ProviderSort sort,
  List<String> preferenceOrder = const [],
  String? theme,
}) {
  final allProviders = options.map((option) => option.provider).toSet();
  final providers =
      selectedProviders.containsAll(allProviders) &&
          selectedProviders.length == allProviders.length
      ? <String>{}
      : selectedProviders;
  final accounts = <String, Set<String>>{};
  for (final option in options) {
    if (!selectedProviders.contains(option.provider)) continue;
    final chosen = selectedAccounts[option.provider] ?? const <String>{};
    if (option.accounts.isNotEmpty &&
        chosen.isNotEmpty &&
        chosen.length < option.accounts.length) {
      accounts[option.provider] = chosen;
    }
  }
  return QuotaProfile(
    name: name,
    providers: providers,
    accounts: accounts,
    hiddenProviders: hiddenProviders,
    routingPolicy: routingPolicy.canonical,
    preferenceOrder: preferenceOrder,
    theme: theme == null ? null : storedAppTheme(theme),
    sort: sort.name,
  );
}
