import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/first_run.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota _quota({
  required String provider,
  required String name,
  bool ok = true,
  bool local = false,
  String? error,
  List<QuotaWindow> windows = const [],
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return ProviderQuota(
    provider: provider,
    displayName: name,
    account: 'default',
    asOf: now,
    ok: ok,
    kind: local ? ProviderQuotaKind.local : ProviderQuotaKind.subscription,
    error: error,
    windows: windows,
    sourceClass: local
        ? ProviderSourceClass.localRuntime
        : ProviderSourceClass.authoritativeLive,
  );
}

void main() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  test('live quota is selected by default and needs no setup', () {
    final entries = firstRunEntries([
      _quota(
        provider: 'claude',
        name: 'Claude',
        windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
      ),
    ], now);
    final claude = entries.firstWhere((entry) => entry.id == 'claude');
    expect(claude.presence, FirstRunPresence.live);
    expect(claude.defaultSelected, isTrue);
    expect(claude.needsSetup, isFalse);
    expect(claude.statusLabel, 'live');
  });

  test('installed but empty rows are found and selected', () {
    final entries = firstRunEntries([
      _quota(
        provider: 'cursor',
        name: 'Cursor',
        ok: false,
        error: 'no quota data found in local state',
      ),
    ], now);
    final cursor = entries.firstWhere((entry) => entry.id == 'cursor');
    expect(cursor.presence, FirstRunPresence.found);
    expect(cursor.defaultSelected, isTrue);
    expect(cursor.needsSetup, isTrue);
  });

  test('invalid usage still counts as a signed-in tool they have', () {
    final entries = firstRunEntries([
      _quota(
        provider: 'claude',
        name: 'Claude',
        ok: false,
        error: 'invalid Claude usage response',
      ),
    ], now);
    final claude = entries.firstWhere((entry) => entry.id == 'claude');
    expect(claude.presence, FirstRunPresence.found);
    expect(claude.defaultSelected, isTrue);
    expect(claude.statusLabel, 'signed in');
  });

  test('not installed rows stay unchecked', () {
    final entries = firstRunEntries([
      _quota(
        provider: 'antigravity',
        name: 'Antigravity',
        ok: false,
        error: 'Antigravity not installed',
      ),
    ], now);
    final antigravity = entries.firstWhere(
      (entry) => entry.id == 'antigravity',
    );
    expect(antigravity.presence, FirstRunPresence.missing);
    expect(antigravity.defaultSelected, isFalse);
  });

  test('hidden set is every catalog id the user did not check', () {
    expect(
      firstRunHiddenProviders({'claude', 'grok'}),
      isNot(contains('claude')),
    );
    expect(firstRunHiddenProviders({'claude', 'grok'}), contains('cursor'));
    expect(
      firstRunHiddenProviders({'claude', 'grok'}),
      contains('antigravity'),
    );
  });

  testWidgets('wizard shows found tools then checkboxes then setup', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final nowTick = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final snapshot = [
      _quota(
        provider: 'claude',
        name: 'Claude',
        windows: [QuotaWindow(label: 'weekly', usedPercent: 12)],
      ),
      _quota(
        provider: 'cursor',
        name: 'Cursor',
        ok: false,
        error: 'no quota data found in local state',
      ),
      _quota(
        provider: 'antigravity',
        name: 'Antigravity',
        ok: false,
        error: 'Antigravity not installed',
      ),
    ];
    FirstRunResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: [AppChromeTheme.forSpec(Brightness.dark, appThemeDark)],
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showFirstRunWizard(
                context: context,
                entries: () => firstRunEntries(snapshot, nowTick),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('What we found'), findsOneWidget);
    expect(find.text('Claude'), findsWidgets);
    expect(find.text('live'), findsOneWidget);
    expect(find.text('found on this machine'), findsOneWidget);
    expect(find.text('not seen yet'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('What do you use?'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsWidgets);

    final claudeBox = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Claude'),
    );
    final cursorBox = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Cursor'),
    );
    final antigravityBox = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Antigravity'),
    );
    expect(claudeBox.value, isTrue);
    expect(cursorBox.value, isTrue);
    expect(antigravityBox.value, isFalse);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Cursor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Set these up'), findsNothing);
    expect(result?.skipped, isFalse);
    expect(result?.selected, contains('claude'));
    expect(result?.selected, isNot(contains('cursor')));
    expect(result?.selected, isNot(contains('antigravity')));
  });

  testWidgets('wizard offers setup only for checked tools that are not live', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final nowTick = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final snapshot = [
      _quota(
        provider: 'claude',
        name: 'Claude',
        windows: [QuotaWindow(label: 'weekly', usedPercent: 12)],
      ),
      _quota(
        provider: 'cursor',
        name: 'Cursor',
        ok: false,
        error: 'no quota data found in local state',
      ),
    ];
    FirstRunResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: [AppChromeTheme.forSpec(Brightness.dark, appThemeDark)],
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showFirstRunWizard(
                context: context,
                entries: () => firstRunEntries(snapshot, nowTick),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Set these up'), findsOneWidget);
    expect(find.text('Cursor'), findsWidgets);
    expect(
      find.text('Open the app once and sign in, then come back.'),
      findsOneWidget,
    );
    expect(find.text('Claude'), findsNothing);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result?.skipped, isFalse);
    expect(result?.selected, contains('claude'));
    expect(result?.selected, contains('cursor'));
  });
}
