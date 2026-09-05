/// Keeps explicit desktop automation from registering or changing the user's
/// platform notifications, which can live outside an isolated profile folder.
class DesktopNotificationPolicy {
  const DesktopNotificationPolicy({
    bool screenshotCapture = false,
    bool readinessProbe = false,
  }) : allowPlatformAccess = !screenshotCapture && !readinessProbe;

  final bool allowPlatformAccess;

  Future<void> initialize(Future<void> Function() initializePlatform) async {
    if (!allowPlatformAccess) return;
    await initializePlatform();
  }
}
