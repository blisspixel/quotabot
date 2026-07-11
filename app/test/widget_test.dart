import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/chrome_controls.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/profile_ui.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota _provider(
  String id,
  String account, {
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
}) => ProviderQuota(
  provider: id,
  displayName: id,
  account: account,
  kind: kind,
  asOf: 1782046566,
);

ProviderQuota _quota(
  String id,
  String name,
  String account, {
  double used = 20,
}) => ProviderQuota(
  provider: id,
  displayName: name,
  account: account,
  asOf: 1782046566,
  windows: [QuotaWindow(label: '5h', usedPercent: used)],
);

void main() {
  testWidgets('startup loader uses the quota gauge instead of stock spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QuotaLoadingIndicator(
          color: Color(0xFF3FB950),
          trackColor: Color(0xFF12391F),
        ),
      ),
    );

    expect(find.byType(QuotaLoadingIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('Loading quota data'), findsOneWidget);
  });

  testWidgets(
    'desktop chrome icon button exposes tooltip and semantics label',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppChromeIconButton(
                icon: Icons.open_in_full_rounded,
                color: Colors.black,
                onTap: () {},
                tooltip: 'Expand',
              ),
            ),
          ),
        ),
      );

      expect(find.byTooltip('Expand'), findsOneWidget);
      expect(find.bySemanticsLabel('Expand'), findsOneWidget);
    },
  );

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

  test('provider setup copy matches live and status-only sources', () {
    final codex = providerSetupText('codex');
    expect(codex, contains('ChatGPT usage endpoint'));
    expect(codex, contains('this-machine session snapshots'));
    expect(codex, contains('No quotabot login needed'));

    final nvidia = providerSetupText('nvidia');
    expect(nvidia, contains('NVIDIA_API_KEY'));
    expect(nvidia, contains('nvapi'));
    expect(nvidia, contains('/v1/models'));
    expect(nvidia, contains('without a numeric balance'));
  });

  test(
    'visible provider rows keep status-only and actionable setup states',
    () {
      final statusOnly = ProviderQuota(
        provider: 'nvidia',
        displayName: 'NVIDIA NIM',
        account: 'default',
        asOf: 1782046566,
        ok: true,
        status: 'free trial available; balance unknown',
        windows: const [],
      );
      final missingKey = ProviderQuota(
        provider: 'nvidia',
        displayName: 'NVIDIA NIM',
        account: 'default',
        asOf: 1782046566,
        ok: false,
        error: 'NVIDIA NIM not configured; set NVIDIA_API_KEY or nvapi',
        windows: const [],
      );
      final invalidKey = ProviderQuota(
        provider: 'nvidia',
        displayName: 'NVIDIA NIM',
        account: 'default',
        asOf: 1782046566,
        ok: false,
        error: 'NVIDIA key present but /models failed (invalid or network)',
        windows: const [],
      );
      final passiveMissing = ProviderQuota(
        provider: 'cursor',
        displayName: 'Cursor',
        account: 'default',
        asOf: 1782046566,
        ok: false,
        error: 'not installed',
        windows: const [],
      );

      final hiddenPassive = visibleProviderRows([
        statusOnly,
        missingKey,
        invalidKey,
        passiveMissing,
      ], const {});
      expect(hiddenPassive, contains(statusOnly));
      expect(hiddenPassive, contains(invalidKey));
      expect(hiddenPassive, isNot(contains(missingKey)));
      expect(hiddenPassive, isNot(contains(passiveMissing)));
      expect(providerSetupRows([missingKey, passiveMissing]), [
        missingKey,
        passiveMissing,
      ]);
      expect(providerSetupRows([missingKey, invalidKey]), [missingKey]);

      final detectedPassive = visibleProviderRows(
        [statusOnly, missingKey, invalidKey, passiveMissing],
        {'cursor', 'nvidia'},
      );
      expect(detectedPassive, contains(missingKey));
      expect(detectedPassive, contains(passiveMissing));
    },
  );

  test('refresh failure messages are sanitized', () {
    final timeout = refreshFailureMessage(
      TimeoutException('secret path C:\\Users\\name\\token.json'),
      hasPreviousData: true,
    );
    final failure = refreshFailureMessage(
      StateError('secret-token'),
      hasPreviousData: true,
    );
    final initial = refreshFailureMessage(
      TimeoutException('secret-token'),
      hasPreviousData: false,
    );

    expect(timeout, 'Refresh timed out; showing previous data');
    expect(failure, 'Refresh failed; showing previous data');
    expect(initial, 'Refresh timed out; retrying automatically');
    expect(timeout, isNot(contains('secret')));
    expect(failure, isNot(contains('secret')));
    expect(initial, isNot(contains('secret')));
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
    test('normalizes app theme preferences safely', () {
      expect(normalizeAppTheme(' Hacker '), appThemeHacker);
      expect(normalizeAppTheme('dark'), appThemeDark);
      expect(normalizeAppTheme('unknown'), appThemeSystem);
      expect(storedAppTheme(appThemeSystem), isNull);
      expect(storedAppTheme(appThemeHacker), appThemeHacker);
      expect(themeModeForAppTheme(appThemeHacker), ThemeMode.dark);
      expect(
        AppChromeTheme.forSpec(Brightness.dark, appThemeHacker).accent,
        const Color(0xFF39FF14),
      );
    });

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

      final hacker = profileFromSelection(
        name: 'hacker',
        options: options,
        selectedProviders: {'codex', 'grok'},
        selectedAccounts: const {},
        hiddenProviders: const {},
        routingPolicy: ProfileRoutingPolicy.balanced,
        sort: ProviderSort.defaultOrder,
        theme: 'hacker',
      );
      expect(hacker.theme, appThemeHacker);
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

    test('hides single-account labels from the main display', () {
      final quota = _provider('codex', 'you@example.com');

      expect(quotaShouldShowAccountLabel(quota, {'codex': 1}), isFalse);
    });

    test('shows account labels when a provider has multiple accounts', () {
      final quota = _provider('antigravity', 'work@example.com');

      expect(quotaShouldShowAccountLabel(quota, {'antigravity': 2}), isTrue);
    });

    test('keeps a flat list when every provider has a single account', () {
      // Different providers signed in with different emails is the common case,
      // not multi-account, so it must not group by email.
      final groups = groupProvidersForDisplay([
        _provider('codex', 'work@example.com'),
        _provider('antigravity', 'home@example.com'),
        _provider('grok', 'work@example.com'),
        _provider('ollama', 'installed', kind: ProviderQuotaKind.local),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.account, isNull);
      expect(groups.single.quotas.map((q) => q.provider).toList(), [
        'codex',
        'antigravity',
        'grok',
        'ollama',
      ]);
    });

    test(
      'groups by account only when a provider is signed into more than one',
      () {
        // Claude is signed into both work and home, a real work/personal split,
        // so the fleet groups by account; codex rides along in its account.
        final groups = groupProvidersForDisplay([
          _provider('claude', 'work@example.com'),
          _provider('codex', 'work@example.com'),
          _provider('claude', 'home@example.com'),
          _provider('ollama', 'installed', kind: ProviderQuotaKind.local),
        ]);

        expect(groups.map((g) => g.account).toList(), [
          'work@example.com',
          'home@example.com',
          null,
        ]);
        expect(groups.first.quotas.map((q) => q.provider).toList(), [
          'claude',
          'codex',
        ]);
        expect(groups[1].quotas.single.provider, 'claude');
        expect(groups.last.quotas.single.provider, 'ollama');
      },
    );
  });

  group('desktop route signal', () {
    test('shows burn-aware confidence without a lone account label', () {
      const now = 1782046566;
      final claude = _quota('claude', 'Claude', 'solo@example.com');
      final suggestion = suggestRoute(
        [claude],
        now,
        burnStatsByProvider: {
          quotaIdentityKey('claude', 'solo@example.com'): const BurnStat(
            perHour: 20,
            sePerHour: 4,
            samples: 8,
          ),
        },
      );

      final line = desktopRouteSignalLine(
        suggestion,
        [claude],
        now,
        showAccounts: true,
      );

      expect(line, contains('Next: Claude'));
      expect(line, contains('authoritative'));
      expect(line, contains('80% free'));
      expect(line, contains('60% after burn'));
      expect(line, contains('medium confidence (67%)'));
      expect(line, isNot(contains('solo@example.com')));
    });

    test('uses account labels only to disambiguate duplicate providers', () {
      const now = 1782046566;
      final work = _quota('codex', 'Codex', 'work@example.com');
      final home = _quota('codex', 'Codex', 'home@example.com', used: 60);
      final suggestion = suggestRoute([work, home], now);

      final line = desktopRouteSignalLine(
        suggestion,
        [work, home],
        now,
        showAccounts: true,
      );

      expect(line, contains('Next: Codex (work@example.com)'));
      expect(line, contains('authoritative'));
    });

    test('names machine fallback provenance without a duplicate scope tag', () {
      const now = 1782046566;
      final codex = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'default',
        asOf: now,
        sourceClass: ProviderSourceClass.thisMachineFallback,
        perMachine: true,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 20)],
      );

      final line = desktopRouteSignalLine(suggestRoute([codex], now), [
        codex,
      ], now);

      expect(line, contains('this-machine fallback'));
      expect(line, isNot(contains('(this machine)')));
    });

    test('labels a local route without repeating local runtime', () {
      const now = 1782046566;
      final ollama = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'local',
        asOf: now,
        kind: ProviderQuotaKind.local,
      );

      final line = desktopRouteSignalLine(
        suggestRoute([ollama], now, preferLocal: true),
        [ollama],
        now,
      );

      expect(line, startsWith('Next: Ollama | local runtime | fallback'));
      expect(line, isNot(contains('local runtime | local fallback')));
    });
  });

  group('desktop provider trust line', () {
    test('labels live quota plans and capture age', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        _quota('claude', 'Claude', 'pro'),
        now,
      );

      expect(line, 'live | authoritative | quota plan | captured 0s ago');
    });

    test('labels cached manual quota without plan identity noise', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        ProviderQuota(
          provider: 'custom-ai',
          displayName: 'Custom AI',
          account: 'work',
          source: providerQuotaManualSource,
          asOf: now - 3600,
          stale: true,
          windows: [QuotaWindow(label: 'monthly', usedPercent: 40)],
        ),
        now,
      );

      expect(line, 'cached | manual | captured 1h ago');
    });

    test('labels provider drift separately from ordinary cached data', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        _quota(
          'claude',
          'Claude',
          'pro',
        ).withProviderDrift('5h usage fell with no reset', now - 30),
        now,
      );

      expect(
        line,
        'provider drift | authoritative | quota plan | captured 0s ago',
      );
    });

    test('labels an active local runtime once', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: '2 models',
          kind: ProviderQuotaKind.local,
          active: true,
          perMachine: true,
          asOf: now,
        ),
        now,
      );

      expect(line, 'in use | local runtime | captured 0s ago');
    });

    test('labels an idle local runtime without claiming it is active', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: '2 models',
          kind: ProviderQuotaKind.local,
          perMachine: true,
          asOf: now,
        ),
        now,
      );

      expect(line, 'available | local runtime | captured 0s ago');
    });

    test('labels status-only metadata without claiming live quota', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        ProviderQuota(
          provider: 'nvidia',
          displayName: 'NVIDIA NIM',
          account: 'default',
          asOf: now,
          status: 'free trial available; balance unknown',
        ),
        now,
      );

      expect(line, 'metadata | status only | captured 0s ago');
    });

    test('labels this-machine fallback without repeated scope', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        ProviderQuota(
          provider: 'antigravity',
          displayName: 'Antigravity',
          account: 'user@example.com',
          asOf: now,
          status: 'local fallback data',
          perMachine: true,
        ),
        now,
      );

      expect(line, 'metadata | this-machine fallback | captured 0s ago');
    });

    test('labels passive local evidence without repeating machine scope', () {
      const now = 1782046566;
      final line = desktopProviderTrustLine(
        ProviderQuota(
          provider: 'cursor',
          displayName: 'Cursor',
          account: 'user@example.com',
          asOf: now,
          perMachine: true,
          windows: [QuotaWindow(label: 'monthly', usedPercent: 20)],
        ),
        now,
      );

      expect(line, 'live | passive local | metered plan | captured 0s ago');
    });
  });
}
