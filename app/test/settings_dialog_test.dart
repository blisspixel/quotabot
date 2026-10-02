import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/settings_dialog.dart';

import 'support/settings_navigation.dart';

Widget _dialog({double scale = 1, VoidCallback? onClose}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.windows),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SettingsDialog(
      onClose: onClose ?? () {},
      providers: const Column(
        children: [Text('Provider visibility'), SizedBox(height: 1200)],
      ),
      display: const Text('Display preferences'),
      alerts: const Text('Alert preferences'),
      updates: const Text('Update controls'),
    ),
  ),
);

void main() {
  testWidgets('keyboard traversal can activate a category', (tester) async {
    await tester.pumpWidget(_dialog());
    ChoiceChip? focused;
    for (var attempt = 0; attempt < 8; attempt++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<ChoiceChip>();
      if (focused?.key == const ValueKey('settings-category-display')) break;
    }
    expect(focused?.key, const ValueKey('settings-category-display'));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Display preferences'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected category survives compact navigation after resize', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_dialog());
    await selectSettingsCategory(tester, SettingsCategory.updates);
    tester.view.physicalSize = const Size(260, 360);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<SettingsCategory>>(
            find.byKey(const ValueKey('settings-category')),
          )
          .initialValue,
      SettingsCategory.updates,
    );
    expect(find.text('Update controls'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'each category opens its controls without invoking another action',
    (tester) async {
      var closed = 0;
      await tester.pumpWidget(_dialog(onClose: () => closed++));
      expect(find.byType(Scrollbar), findsOneWidget);
      expect(
        tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility,
        isTrue,
      );
      expect(find.text('Provider visibility'), findsOneWidget);
      expect(find.text('Update controls'), findsNothing);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      expect(scroll.offset, greaterThan(0));
      for (final category in SettingsCategory.values.skip(1)) {
        await selectSettingsCategory(tester, category);
        expect(
          tester
              .widget<ChoiceChip>(
                find.byKey(ValueKey('settings-category-${category.name}')),
              )
              .selected,
          isTrue,
        );
        expect(scroll.offset, 0);
      }
      expect(find.text('Update controls'), findsOneWidget);
      expect(find.byType(Scrollbar), findsOneWidget);
      expect(closed, 0);
      await tester.tap(find.byTooltip('Close settings'));
      expect(closed, 1);
    },
  );

  for (final size in [const Size(260, 360), const Size(320, 520)]) {
    testWidgets('compact categories and Close stay reachable at $size and 2x', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var closed = false;
      await tester.pumpWidget(_dialog(scale: 2, onClose: () => closed = true));
      expect(find.byKey(const ValueKey('settings-category')), findsOneWidget);
      await selectSettingsCategory(tester, SettingsCategory.updates);
      expect(find.text('Update controls'), findsOneWidget);
      await selectSettingsCategory(tester, SettingsCategory.providers);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      await selectSettingsCategory(tester, SettingsCategory.alerts);
      expect(find.text('Alert preferences'), findsOneWidget);
      await tester.tap(find.byTooltip('Close settings'));
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
