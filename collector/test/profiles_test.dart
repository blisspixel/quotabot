import 'dart:io';

import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/profiles.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_profiles_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ProviderQuota q(
    String provider, {
    String account = 'default',
    ProviderQuotaKind kind = ProviderQuotaKind.subscription,
  }) =>
      ProviderQuota(
        provider: provider,
        displayName: provider,
        account: account,
        kind: kind,
        asOf: 123,
      );

  test('default profile is zero-config and allows every provider', () {
    final profile = QuotaProfile.defaultProfile();
    final fleet = [
      q('codex'),
      q('grok', account: 'work'),
      q('ollama', kind: ProviderQuotaKind.local)
    ];

    expect(profile.name, defaultProfileName);
    expect(applyProfile(fleet, profile), fleet);
    expect(profile.toJson()['schema'], profileSchema);
  });

  test('profile filters providers, accounts, hidden providers, and local-only',
      () {
    final fleet = [
      q('codex'),
      q('grok', account: 'work@example.com'),
      q('grok', account: 'personal@example.com'),
      q('ollama', kind: ProviderQuotaKind.local),
    ];

    final work = QuotaProfile(
      name: 'work',
      providers: {'GROK', 'ollama'},
      accounts: {
        'GROK': {'work@example.com'},
      },
    );
    expect(applyProfile(fleet, work).map((q) => q.account), [
      'work@example.com',
      'default',
    ]);

    final hidden = QuotaProfile(name: 'quiet', hiddenProviders: {'grok'});
    expect(applyProfile(fleet, hidden).map((q) => q.provider), [
      'codex',
      'ollama',
    ]);

    final hiddenAccount = QuotaProfile(
      name: 'quiet-work',
      hiddenProviders: {'grok|work@example.com'},
    );
    expect(applyProfile(fleet, hiddenAccount).map((q) => q.account), [
      'default',
      'personal@example.com',
      'default',
    ]);
    expect(hiddenAccount.toJson()['hidden'], ['grok|work@example.com']);
    expect(hiddenTargetsQuota({'grok| work@example.com '}, fleet[1]), isTrue);
    expect(hiddenTargetsQuota({'grok| work@example.com '}, fleet[2]), isFalse);
    expect(normalizeHiddenTarget('grok|bad${String.fromCharCode(7)}'), isNull);

    final local = QuotaProfile(
      name: 'offline',
      routingPolicy: ProfileRoutingPolicy.localOnly,
    );
    expect(applyProfile(fleet, local).map((q) => q.provider), ['ollama']);
  });

  test('round-trips profile JSON with normalized provider ids', () {
    final profile = QuotaProfile.fromJson({
      'schema': profileSchema,
      'name': ' Work ',
      'providers': ['Grok', 'codex', '../bad'],
      'accounts': {
        'GROK': ['work@example.com'],
        '../bad': ['ignored@example.com'],
      },
      'hidden': ['Cursor'],
      'routing_policy': 'subscriptionsFirst',
      'theme': 'forest',
      'sort': 'mostAvailable',
    });

    expect(profile.name, 'work');
    expect(profile.providers, {'codex', 'grok'});
    expect(profile.accounts, {
      'grok': {'work@example.com'},
    });
    expect(profile.hiddenProviders, {'cursor'});
    expect(profile.routingPolicy, ProfileRoutingPolicy.subscriptionsFirst);
    expect(profile.theme, 'forest');
    expect(profile.sort, 'mostAvailable');

    final back = QuotaProfile.fromJson(profile.toJson());
    expect(back.providers, profile.providers);
    expect(back.accounts, profile.accounts);
  });

  test('preference order persists, keeps order, and normalizes', () {
    final profile = QuotaProfile.fromJson({
      'schema': profileSchema,
      'name': 'work',
      // Mixed case, a blank, and a duplicate: normalized to canonical ids,
      // order preserved, first occurrence wins.
      'preference_order': ['Codex', '', 'claude', 'codex'],
    });
    expect(profile.preferenceOrder, ['codex', 'claude']);

    // Round-trips through JSON as an ordered list (not a sorted set).
    expect(profile.toJson()['preference_order'], ['codex', 'claude']);
    final back = QuotaProfile.fromJson(profile.toJson());
    expect(back.preferenceOrder, ['codex', 'claude']);
  });

  test('saveProfile preserves the preference order (not dropped on rewrite)',
      () {
    final profile = QuotaProfile(
      name: 'work',
      preferenceOrder: const ['claude', 'codex'],
    );
    saveProfile(profile, dir: temp);
    expect(
        loadProfile('work', dir: temp)!.preferenceOrder, ['claude', 'codex']);
  });

  test('a profile without a preference has an empty order and omits the key',
      () {
    final profile = QuotaProfile.fromJson({'name': 'work'});
    expect(profile.preferenceOrder, isEmpty);
    expect(profile.toJson().containsKey('preference_order'), isFalse);
  });

  test('safe profile names reject traversal and invalid filenames', () {
    expect(normalizeProfileName('Work-1'), 'work-1');
    expect(normalizeProfileName('../work'), isNull);
    expect(normalizeProfileName(''), isNull);
    expect(normalizeProfileName('.'), isNull);
    expect(normalizeProfileName('_hidden'), isNull);
    expect(() => profileFile('../work', dir: temp), throwsArgumentError);
  });

  test('profile names reject Windows reserved device names', () {
    // `nul`/`con`/`com1` (with or without an extension) resolve to a device on
    // Windows, not a file, silently discarding writes.
    for (final reserved in ['nul', 'con', 'aux', 'prn', 'com1', 'lpt9']) {
      expect(normalizeProfileName(reserved), isNull, reason: reserved);
      expect(normalizeProfileName('$reserved.json'), isNull, reason: reserved);
    }
    // A name that merely contains a reserved word is fine.
    expect(normalizeProfileName('console'), 'console');
    expect(normalizeProfileName('nul-work'), 'nul-work');
  });

  test('saves, loads, lists, and fails soft on corrupt profiles', () {
    final work = QuotaProfile(
      name: 'Work',
      providers: {'grok'},
      accounts: {
        'grok': {'work@example.com'},
      },
      hiddenProviders: {'cursor'},
      routingPolicy: ProfileRoutingPolicy.subscriptionsFirst,
    );

    saveProfile(work, dir: temp);
    File('${temp.path}/broken.json').writeAsStringSync('{not-json');

    final loaded = loadProfile('work', dir: temp);
    expect(loaded, isNotNull);
    expect(loaded!.name, 'work');
    expect(loaded.providers, {'grok'});
    expect(loaded.hiddenProviders, {'cursor'});
    expect(loaded.routingPolicy, ProfileRoutingPolicy.subscriptionsFirst);

    expect(loadProfile('missing', dir: temp), isNull);
    expect(loadProfile('default', dir: temp)!.name, defaultProfileName);
    expect(listProfiles(dir: temp).map((p) => p.name), [
      'default',
      'work',
    ]);

    deleteProfile('default', dir: temp);
    expect(loadProfile('default', dir: temp)!.name, defaultProfileName);

    deleteProfile('work', dir: temp);
    expect(loadProfile('work', dir: temp), isNull);
    expect(listProfiles(dir: temp).map((p) => p.name), ['default']);
  });

  test('a corrupt default.json still yields the zero-config default', () {
    // A torn or hand-edited default file must not make the always-available
    // default profile unusable; a non-default corrupt file still returns null.
    File('${temp.path}/default.json').writeAsStringSync('{not json');
    final loaded = loadProfile('default', dir: temp);
    expect(loaded, isNotNull);
    expect(loaded!.name, defaultProfileName);

    File('${temp.path}/broken.json').writeAsStringSync('{not json');
    expect(loadProfile('broken', dir: temp), isNull);
  });

  test('saved profile file and directory are owner-only on POSIX', () {
    // Profile JSON carries account emails; on POSIX it must not be group- or
    // world-readable. Windows uses ACLs, verified by the util layer's tests.
    if (Platform.isWindows) return;
    saveProfile(
      QuotaProfile(
        name: 'work',
        providers: {'grok'},
        accounts: {
          'grok': {'work@example.com'},
        },
      ),
      dir: temp,
    );
    final file = profileFile('work', dir: temp);
    expect(file.statSync().mode & 0x3f, 0, reason: 'no group/other bits');
    expect(temp.statSync().mode & 0x3f, 0, reason: 'directory owner-only');
  });
}
