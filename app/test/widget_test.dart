import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/profile_ui.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota _provider(
  String id,
  String account, {
  String kind = 'subscription',
}) => ProviderQuota(
  provider: id,
  displayName: id,
  account: account,
  kind: kind,
  asOf: 1782046566,
);

void main() {
  test('QuotaWindow derives percent from used/limit', () {
    final w = QuotaWindow(label: '5h', used: 25, limit: 100);
    expect(w.percent, 25);
    expect(w.exhausted, isFalse);
  });

  test('QuotaWindow flags an exhausted window', () {
    final w = QuotaWindow(label: 'weekly', usedPercent: 100);
    expect(w.exhausted, isTrue);
  });

  test('ProviderQuota round-trips through JSON', () {
    final q = ProviderQuota(
      provider: 'codex',
      displayName: 'Codex',
      account: 'pro',
      plan: 'pro',
      asOf: 1782046566,
      windows: [QuotaWindow(label: '5h', usedPercent: 7, resetsAt: 1782050000)],
    );
    final back = ProviderQuota.fromJson(q.toJson());
    expect(back.provider, 'codex');
    expect(back.windows.single.usedPercent, 7);
    expect(back.windows.single.resetsAt, 1782050000);
  });

  group('Prefs', () {
    test('round-trips through JSON including window position', () {
      const p = Prefs(
        hidden: {'grok', 'codex'},
        compact: true,
        cadence: Cadence.h1,
        alwaysOnTop: true,
        showInTaskbar: false,
        enableNotifications: false,
        sort: ProviderSort.mostUsed,
        activeProfile: 'work',
        webhookUrl: 'http://127.0.0.1:9000/quota',
        webhookAllowExternal: true,
        windowX: 100,
        windowY: 200,
      );
      final back = Prefs.fromJson(p.toJson());
      expect(back.hidden, {'grok', 'codex'});
      expect(back.compact, isTrue);
      expect(back.cadence, Cadence.h1);
      expect(back.alwaysOnTop, isTrue);
      expect(back.showInTaskbar, isFalse);
      expect(back.enableNotifications, isFalse);
      expect(back.sort, ProviderSort.mostUsed);
      expect(back.activeProfile, 'work');
      expect(back.showAccounts, isFalse);
      expect(back.webhookUrl, 'http://127.0.0.1:9000/quota');
      expect(back.webhookAllowExternal, isTrue);
      expect(back.windowX, 100);
      expect(back.windowY, 200);
    });

    test('defaults are sane and tolerant of bad input', () {
      final p = Prefs.fromJson({'cadence': 'nonsense'});
      expect(p.hidden, isEmpty);
      expect(p.compact, isFalse);
      expect(p.cadence, Cadence.smart);
      expect(p.alwaysOnTop, isFalse);
      expect(p.showInTaskbar, isTrue);
      expect(p.enableNotifications, isTrue);
      expect(p.sort, ProviderSort.defaultOrder);
      expect(p.activeProfile, 'default');
      expect(p.showAccounts, isFalse);
      expect(p.webhookUrl, isNull);
      expect(p.webhookAllowExternal, isFalse);
      expect(p.windowX, isNull);
    });

    test('copyWith can clear the stored window position', () {
      const p = Prefs(windowX: 100, windowY: 200);
      final back = p.copyWith(clearWindowPosition: true);
      expect(back.windowX, isNull);
      expect(back.windowY, isNull);
    });
  });

  group('profile UI preferences', () {
    test('labels default and named profiles for compact UI', () {
      expect(profileLabel(QuotaProfile.defaultProfile()), 'Default');
      expect(
        profileLabel(const QuotaProfile(name: 'work-project')),
        'Work Project',
      );
    });

    test('maps profile sort strings to app sort values safely', () {
      expect(
        sortFromProfile(const QuotaProfile(name: 'work', sort: 'mostUsed')),
        ProviderSort.mostUsed,
      );
      expect(
        sortFromProfile(const QuotaProfile(name: 'work', sort: 'unknown')),
        ProviderSort.defaultOrder,
      );
    });

    test(
      'updates and strips UI preferences without changing routing filters',
      () {
        final profile = profileWithUiPrefs(
          const QuotaProfile(
            name: 'work',
            providers: {'codex'},
            accounts: {
              'codex': {'work@example.com'},
            },
            routingPolicy: ProfileRoutingPolicy.subscriptionsFirst,
          ),
          hiddenProviders: {'grok'},
          sort: ProviderSort.alphabetical,
        );

        expect(profile.providers, {'codex'});
        expect(profile.accounts['codex'], {'work@example.com'});
        expect(profile.hiddenProviders, {'grok'});
        expect(profile.routingPolicy, ProfileRoutingPolicy.subscriptionsFirst);
        expect(profile.sort, ProviderSort.alphabetical.name);

        final routing = profileWithoutUiPrefs(profile);
        expect(routing.providers, {'codex'});
        expect(routing.accounts['codex'], {'work@example.com'});
        expect(routing.hiddenProviders, isEmpty);
        expect(routing.routingPolicy, ProfileRoutingPolicy.subscriptionsFirst);
      },
    );

    test(
      'builds provider options from live data and saved profile filters',
      () {
        final options = profileProviderOptions(
          [
            _provider('codex', 'default'),
            _provider('grok', 'work@example.com'),
          ],
          profiles: [
            const QuotaProfile(
              name: 'archived',
              providers: {'cursor'},
              accounts: {
                'cursor': {'old@example.com'},
              },
            ),
          ],
        );

        expect(options.map((o) => o.provider), ['codex', 'cursor', 'grok']);
        expect(options[0].accounts, isEmpty);
        expect(options[1].accounts, ['old@example.com']);
        expect(options[2].accounts, ['work@example.com']);
      },
    );

    test('builds compact profile filters from editor selection', () {
      final options = [
        const ProfileProviderOption(
          provider: 'codex',
          displayName: 'Codex',
          accounts: [],
        ),
        const ProfileProviderOption(
          provider: 'grok',
          displayName: 'Grok',
          accounts: ['home@example.com', 'work@example.com'],
        ),
      ];

      final all = profileFromSelection(
        name: 'all',
        options: options,
        selectedProviders: {'codex', 'grok'},
        selectedAccounts: {
          'grok': {'home@example.com', 'work@example.com'},
        },
        hiddenProviders: const {},
        routingPolicy: ProfileRoutingPolicy.balanced,
        sort: ProviderSort.defaultOrder,
      );
      expect(all.providers, isEmpty);
      expect(all.accounts, isEmpty);

      final work = profileFromSelection(
        name: 'work',
        options: options,
        selectedProviders: {'grok'},
        selectedAccounts: {
          'grok': {'work@example.com'},
        },
        hiddenProviders: {'cursor'},
        routingPolicy: ProfileRoutingPolicy.subscriptionsFirst,
        sort: ProviderSort.mostAvailable,
        theme: 'dark',
      );
      expect(work.providers, {'grok'});
      expect(work.accounts['grok'], {'work@example.com'});
      expect(work.hiddenProviders, {'cursor'});
      expect(work.routingPolicy, ProfileRoutingPolicy.subscriptionsFirst);
      expect(work.sort, ProviderSort.mostAvailable.name);
      expect(work.theme, 'dark');
    });
  });

  group('provider display grouping', () {
    test('uses provider and account as the stable display key', () {
      expect(
        quotaDisplayKey(_provider('grok', 'work@example.com')),
        'grok|work@example.com',
      );
      expect(quotaDisplayKey(_provider('grok', 'default')), 'grok');
      expect(quotaDisplayKey(_provider('grok', 'unknown')), 'grok');
    });

    test('targets one account when hiding a multi-account provider', () {
      final work = _provider('antigravity', 'work@example.com');
      final home = _provider('antigravity', 'home@example.com');
      final counts = {'antigravity': 2};

      expect(quotaHideTarget(work, counts), 'antigravity|work@example.com');
      expect(
        hiddenTargetsQuota({'antigravity|work@example.com'}, work),
        isTrue,
      );
      expect(
        hiddenTargetsQuota({'antigravity|work@example.com'}, home),
        isFalse,
      );
      expect(hiddenTargetsQuota({'antigravity'}, home), isTrue);
    });

    test('keeps a flat group for the common single-account case', () {
      final groups = groupProvidersForDisplay([
        _provider('codex', 'you@example.com'),
        _provider('claude', 'you@example.com'),
        _provider('ollama', 'installed', kind: 'local'),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.account, isNull);
      expect(groups.single.quotas.map((q) => q.provider).toList(), [
        'codex',
        'claude',
        'ollama',
      ]);
    });

    test(
      'groups distinct accounts while preserving provider order per group',
      () {
        final groups = groupProvidersForDisplay([
          _provider('codex', 'work@example.com'),
          _provider('antigravity', 'home@example.com'),
          _provider('grok', 'work@example.com'),
          _provider('ollama', 'installed', kind: 'local'),
        ]);

        expect(groups.map((g) => g.account).toList(), [
          'work@example.com',
          'home@example.com',
          null,
        ]);
        expect(groups.first.quotas.map((q) => q.provider).toList(), [
          'codex',
          'grok',
        ]);
        expect(groups[1].quotas.single.provider, 'antigravity');
        expect(groups.last.quotas.single.provider, 'ollama');
      },
    );
  });
}
