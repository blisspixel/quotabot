import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/settings_dialog.dart';

Future<void> selectSettingsCategory(
  WidgetTester tester,
  SettingsCategory category,
) async {
  final chip = find.byKey(ValueKey('settings-category-${category.name}'));
  if (chip.evaluate().isNotEmpty) {
    await tester.tap(chip);
  } else {
    await tester.tap(find.byKey(const ValueKey('settings-category')));
    await tester.pumpAndSettle();
    final option = find.text(category.label).last;
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
  }
  await tester.pumpAndSettle();
}
