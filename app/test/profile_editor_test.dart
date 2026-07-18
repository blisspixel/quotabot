import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/profile_editor.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/collector.dart';

ProviderQuota _provider(String id, String name, String account) =>
    ProviderQuota(
      provider: id,
      displayName: name,
      account: account,
      asOf: 1782046566,
    );

const _workProfile = QuotaProfile(
  name: 'work',
  providers: {'grok'},
  accounts: {
    'grok': {'work@example.com'},
  },
  hiddenProviders: {'codex'},
  routingPolicy: ProfileRoutingPolicy.subscriptionsFirst,
  theme: appThemeDark,
  sort: 'mostUsed',
);

final _profiles = [QuotaProfile.defaultProfile(), _workProfile];

final _providers = [
  _provider('codex', 'Codex', 'default'),
  _provider('grok', 'Grok', 'home@example.com'),
  _provider('grok', 'Grok', 'work@example.com'),
];

Future<ValueNotifier<ProfileEditorResult?>> _openEditor(
  WidgetTester tester, {
  List<QuotaProfile>? profiles,
  List<ProviderQuota>? providers,
  String activeProfile = defaultProfileName,
  ProviderSort currentSort = ProviderSort.defaultOrder,
  Set<String> currentHidden = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final result = ValueNotifier<ProfileEditorResult?>(null);
  addTearDown(result.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result.value = await showDialog<ProfileEditorResult>(
              context: context,
              builder: (_) => ProfileEditorDialog(
                profiles: profiles ?? _profiles,
                providers: providers ?? _providers,
                activeProfile: activeProfile,
                currentSort: currentSort,
                currentHidden: currentHidden,
              ),
            );
          },
          child: const Text('Open editor'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
  return result;
}

TextButton _button(WidgetTester tester, String label) =>
    tester.widget(find.widgetWithText(TextButton, label));

Future<void> _choose(WidgetTester tester, String current, String choice) async {
  await tester.tap(find.text(current).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(choice).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('default profile is visible but immutable', (tester) async {
    final result = await _openEditor(tester);

    expect(find.text('Profiles'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Grok'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    expect(_button(tester, 'Save').onPressed, isNull);

    final name = tester.widget<TextField>(find.byType(TextField));
    expect(name.enabled, isFalse);
    expect(name.controller!.text, defaultProfileName);

    final providerTiles = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(providerTiles, isNotEmpty);
    expect(providerTiles.every((tile) => tile.onChanged == null), isTrue);
    expect(
      tester
          .widget<DropdownButtonFormField<ProfileRoutingPolicy>>(
            find.byKey(const ValueKey('routing:default')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('theme:default')),
          )
          .onChanged,
      isNull,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result.value, isNull);
  });

  testWidgets('new profile validates names and saves a precise selection', (
    tester,
  ) async {
    final result = await _openEditor(tester);

    await _choose(tester, 'Default', 'New profile');
    expect(_button(tester, 'Save').onPressed, isNull);

    final name = find.byType(TextField);
    await tester.enterText(name, 'bad name!');
    await tester.pump();
    expect(
      find.text('Use letters, numbers, dots, dashes, or underscores'),
      findsOneWidget,
    );

    await tester.enterText(name, defaultProfileName);
    await tester.pump();
    expect(find.text('Default already exists'), findsOneWidget);

    await tester.enterText(name, _workProfile.name);
    await tester.pump();
    expect(find.text('Profile already exists'), findsOneWidget);

    await tester.enterText(name, 'research-team');
    await tester.pump();
    expect(_button(tester, 'Save').onPressed, isNotNull);

    await _choose(tester, 'Balanced', 'Subscriptions first');
    await _choose(tester, 'System', 'Hacker');

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Codex'));
    await tester.pump();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'home@example.com'));
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result.value?.action, ProfileEditorAction.save);
    final saved = result.value?.profile;
    expect(saved?.name, 'research-team');
    expect(saved?.providers, {'grok'});
    expect(saved?.accounts, {
      'grok': {'work@example.com'},
    });
    expect(saved?.routingPolicy, ProfileRoutingPolicy.subscriptionsFirst);
    expect(saved?.theme, appThemeHacker);
    expect(saved?.sort, ProviderSort.defaultOrder.name);
  });

  testWidgets('new profile focuses its name and submits with keyboard done', (
    tester,
  ) async {
    final result = await _openEditor(tester);

    await _choose(tester, 'Default', 'New profile');
    final nameField = find.byType(TextField);
    final editable = find.descendant(
      of: nameField,
      matching: find.byType(EditableText),
    );
    expect(
      FocusManager.instance.primaryFocus,
      tester.widget<EditableText>(editable).focusNode,
    );

    await tester.enterText(nameField, 'keyboard-profile');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result.value?.action, ProfileEditorAction.save);
    expect(result.value?.profile?.name, 'keyboard-profile');
  });

  testWidgets('account selection removes and restores its provider', (
    tester,
  ) async {
    final result = await _openEditor(tester);
    await _choose(tester, 'Default', 'New profile');
    await tester.enterText(find.byType(TextField), 'account-scope');
    await tester.pump();

    await tester.tap(find.widgetWithText(CheckboxListTile, 'home@example.com'));
    await tester.pump();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'home@example.com'),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.widgetWithText(CheckboxListTile, 'home@example.com'));
    await tester.pump();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'home@example.com'),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.widgetWithText(CheckboxListTile, 'home@example.com'));
    await tester.pump();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'work@example.com'));
    await tester.pump();

    final grokOff = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Grok'),
    );
    expect(grokOff.value, isFalse);
    expect(find.text('home@example.com'), findsNothing);
    expect(find.text('work@example.com'), findsNothing);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Codex'));
    await tester.pump();
    expect(find.text('Select at least one provider'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );
    expect(_button(tester, 'Save').onPressed, isNull);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Codex'));
    await tester.pump();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Grok'));
    await tester.pump();
    expect(find.text('home@example.com'), findsOneWidget);
    expect(find.text('work@example.com'), findsOneWidget);
    for (final account in ['home@example.com', 'work@example.com']) {
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, account),
            )
            .value,
        isTrue,
      );
    }

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result.value?.profile?.providers, isEmpty);
    expect(result.value?.profile?.accounts, isEmpty);
  });

  testWidgets('editing the active profile preserves live UI preferences', (
    tester,
  ) async {
    final result = await _openEditor(
      tester,
      activeProfile: _workProfile.name,
      currentSort: ProviderSort.alphabetical,
      currentHidden: {'nvidia'},
    );

    expect(find.text('Delete'), findsOneWidget);
    expect(_button(tester, 'Save').onPressed, isNotNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    await _choose(tester, 'Subscriptions first', 'Local only');
    await _choose(tester, 'Dark', 'Light');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = result.value?.profile;
    expect(saved?.name, _workProfile.name);
    expect(saved?.providers, {'grok'});
    expect(saved?.accounts, {
      'grok': {'work@example.com'},
    });
    expect(saved?.hiddenProviders, {'nvidia'});
    expect(saved?.routingPolicy, ProfileRoutingPolicy.localOnly);
    expect(saved?.theme, appThemeLight);
    expect(saved?.sort, ProviderSort.alphabetical.name);
  });

  testWidgets('editing a profile preserves its routing preference order', (
    tester,
  ) async {
    const ordered = QuotaProfile(
      name: 'ordered',
      providers: {'codex', 'grok'},
      routingPolicy: ProfileRoutingPolicy.subscriptionsFirst,
      preferenceOrder: ['grok', 'codex'],
      theme: appThemeDark,
    );
    final result = await _openEditor(
      tester,
      profiles: [QuotaProfile.defaultProfile(), ordered],
      activeProfile: ordered.name,
    );

    await _choose(tester, 'Dark', 'Light');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result.value?.profile?.theme, appThemeLight);
    expect(result.value?.profile?.preferenceOrder, ['grok', 'codex']);
  });

  testWidgets('switching profiles loads that profile stored UI preferences', (
    tester,
  ) async {
    final result = await _openEditor(tester);

    await _choose(tester, 'Default', 'Work');
    expect(find.text('Subscriptions first'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Codex'),
          )
          .value,
      isFalse,
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result.value?.profile?.hiddenProviders, {'codex'});
    expect(result.value?.profile?.sort, ProviderSort.mostUsed.name);
  });

  testWidgets('delete returns the selected profile name', (tester) async {
    final result = await _openEditor(tester, activeProfile: _workProfile.name);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(result.value?.action, ProfileEditorAction.delete);
    expect(result.value?.deleteName, _workProfile.name);
    expect(result.value?.profile, isNull);
  });

  testWidgets('empty provider state remains actionable', (tester) async {
    final result = await _openEditor(
      tester,
      profiles: [QuotaProfile.defaultProfile()],
      providers: const [],
    );

    await _choose(tester, 'Default', 'New profile');
    expect(find.text('No providers detected yet.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'offline');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result.value?.profile?.name, 'offline');
    expect(result.value?.profile?.providers, isEmpty);
  });
}
