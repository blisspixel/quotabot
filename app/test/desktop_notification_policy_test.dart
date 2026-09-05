import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_notification_policy.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/models.dart';

const _automationPolicies = {
  'screenshots': DesktopNotificationPolicy(screenshotCapture: true),
  'readiness': DesktopNotificationPolicy(readinessProbe: true),
  'screenshots and readiness': DesktopNotificationPolicy(
    screenshotCapture: true,
    readinessProbe: true,
  ),
};

class _NotificationProbe implements DesktopNotificationClient {
  final List<String> calls = [];
  final List<String> shownTitles = [];
  final List<DesktopPendingNotification> pending = [
    const DesktopPendingNotification(
      id: 2147483000,
      payload: quotaResetReminderPayload,
    ),
  ];

  @override
  Future<List<DesktopPendingNotification>> pendingNotifications() async {
    calls.add('pending');
    return [...pending];
  }

  @override
  Future<void> cancel(int id) async {
    calls.add('cancel');
    pending.removeWhere((request) => request.id == id);
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String providerLabel,
    String? payload,
  }) async {
    calls.add('show');
    shownTitles.add(title);
  }

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required String providerLabel,
    required DateTime scheduledDate,
  }) async {
    calls.add('schedule');
    pending.add(
      DesktopPendingNotification(
        id: id,
        title: title,
        body: body,
        payload: quotaResetReminderPayload,
      ),
    );
  }
}

ProviderQuota _reminderQuota() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return ProviderQuota(
    provider: 'codex',
    displayName: 'Codex',
    account: 'notification-fixture',
    asOf: now,
    sourceClass: ProviderSourceClass.authoritativeLive,
    windows: [
      QuotaWindow(label: '5h', usedPercent: 90, resetsAt: now + 600),
      QuotaWindow(label: 'weekly', usedPercent: 90, resetsAt: now + 3600),
    ],
  );
}

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark().copyWith(
    extensions: [AppChromeTheme.forSpec(Brightness.dark, appThemeDark)],
  ),
  home: child,
);

void _desktopSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(700, 1800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _toggleNotifications(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  final toggle = find.byKey(const ValueKey('settings-notifications'));
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('settings-close')));
  await tester.pumpAndSettle();
}

void main() {
  for (final entry in _automationPolicies.entries) {
    test('${entry.key} cannot initialize platform notifications', () async {
      var registrations = 0;
      await entry.value.initialize(() async => registrations++);
      expect(registrations, 0);
    });

    for (final enabled in [true, false]) {
      testWidgets(
        '${entry.key} cannot access platform notifications with preference $enabled',
        (tester) async {
          _desktopSurface(tester);
          final notifications = _NotificationProbe();
          final quota = _reminderQuota();
          var collections = 0;
          var trayInitializations = 0;
          Prefs? saved;
          await tester.pumpWidget(
            _wrap(
              Dashboard.test(
                prefs: Prefs(
                  enableNotifications: enabled,
                  setupDone: true,
                  cadence: Cadence.h1,
                ),
                demoMode: false,
                collector: () async {
                  collections++;
                  return [quota];
                },
                notificationPolicy: entry.value,
                notificationClient: notifications,
                trayInitializer: () async => trayInitializations++,
                prefsSaver: (prefs) async => saved = prefs,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(collections, 1);
          expect(trayInitializations, 1);
          expect(notifications.calls, isEmpty);

          await _toggleNotifications(tester);
          expect(saved?.enableNotifications, !enabled);
          await tester.tap(find.byTooltip('Refresh now'));
          await tester.pumpAndSettle();
          expect(collections, 2);
          expect(notifications.calls, isEmpty);
          expect(notifications.pending.single.id, 2147483000);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  test('ordinary startup initializes platform notifications', () async {
    var registrations = 0;
    await const DesktopNotificationPolicy().initialize(() async {
      registrations++;
    });
    expect(registrations, 1);
  });

  testWidgets('ordinary notifications still reconcile, deliver and schedule', (
    tester,
  ) async {
    _desktopSurface(tester);
    final notifications = _NotificationProbe();
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          prefs: const Prefs(enableNotifications: true, setupDone: true),
          demoMode: false,
          collector: () async => [_reminderQuota()],
          notificationPolicy: const DesktopNotificationPolicy(),
          notificationClient: notifications,
          prefsSaver: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      notifications.calls,
      containsAll(['pending', 'cancel', 'show', 'schedule']),
    );
    expect(notifications.shownTitles, contains('Quota reset soon'));
    expect(notifications.pending, hasLength(1));
    expect(notifications.pending.single.id, isNot(2147483000));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
