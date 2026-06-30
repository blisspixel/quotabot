import 'package:quotabot_collector/profiles.dart';

import 'prefs.dart';

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
  routingPolicy: profile.routingPolicy,
  theme: profile.theme,
  sort: sort.name,
);

QuotaProfile profileWithoutUiPrefs(QuotaProfile profile) => QuotaProfile(
  name: profile.name,
  providers: profile.providers,
  accounts: profile.accounts,
  routingPolicy: profile.routingPolicy,
  theme: profile.theme,
  sort: profile.sort,
);
