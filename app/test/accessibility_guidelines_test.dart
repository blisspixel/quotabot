import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/profiles.dart';

const desktopTapTargetGuideline = MinimumTapTargetGuideline(
  size: Size(28, 28),
  link:
      'https://learn.microsoft.com/windows/apps/design/input/guidelines-for-targeting',
);

void main() {
  for (final theme in [appThemeLight, appThemeDark, appThemeHacker]) {
    for (final compact in [false, true]) {
      final surface = compact ? 'compact' : 'expanded';

      testWidgets('$surface $theme dashboard meets accessibility guidelines', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(700, 1800);
        appThemeSpec.value = theme;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(() => appThemeSpec.value = appThemeSystem);

        try {
          final prefs = Prefs(
            compact: compact,
            enableNotifications: false,
            setupDone: true,
          );
          await tester.pumpWidget(
            QuotaBotApp.test(
              prefs: prefs,
              testHome: Dashboard.test(
                prefs: prefs,
                testProfiles: [
                  QuotaProfile(name: defaultProfileName, theme: theme),
                ],
              ),
            ),
          );
          await tester.pumpAndSettle();

          await _expectAccessibilityGuidelines(tester);

          if (!compact) {
            await tester.tap(find.byTooltip('Quota analytics'));
            await tester.pumpAndSettle();
            await _expectAccessibilityGuidelines(tester);
          }
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}

Future<void> _expectAccessibilityGuidelines(WidgetTester tester) async {
  for (final guideline in [
    labeledTapTargetGuideline,
    desktopTapTargetGuideline,
    textContrastGuideline,
  ]) {
    await expectLater(tester, meetsGuideline(guideline));
  }
}
