import 'dart:convert';
import 'dart:io';

const String desktopReadinessSchema = 'quotabot.desktop-readiness.v1';
const String desktopReadinessEnvironmentVariable =
    'QUOTABOT_DESKTOP_READINESS_FILE';

/// Publishes an opt-in integration signal after the native window and tray have
/// both finished initializing. Normal application runs do not create a file.
class DesktopReadinessProbe {
  DesktopReadinessProbe({required String? outputPath, required this.platform})
    : _outputPath = _normalizedPath(outputPath);

  factory DesktopReadinessProbe.fromEnvironment() => DesktopReadinessProbe(
    outputPath: Platform.environment[desktopReadinessEnvironmentVariable],
    platform: Platform.operatingSystem,
  );

  final String? _outputPath;
  final String platform;
  bool _windowReady = false;
  bool? _trayReady;
  bool _published = false;

  bool get enabled => _outputPath != null;

  void recordWindowReady() {
    _windowReady = true;
    _publishIfComplete();
  }

  void recordTrayReady(bool ready) {
    _trayReady = ready;
    _publishIfComplete();
  }

  void _publishIfComplete() {
    final outputPath = _outputPath;
    final trayReady = _trayReady;
    if (outputPath == null ||
        _published ||
        !_windowReady ||
        trayReady == null) {
      return;
    }

    final target = File(outputPath);
    File? pending;
    try {
      target.parent.createSync(recursive: true);
      pending = File(
        '$outputPath.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
      );
      final payload = <String, Object>{
        'schema': desktopReadinessSchema,
        'window_ready': true,
        'tray_ready': trayReady,
        'platform': platform,
      };
      pending.writeAsStringSync('${jsonEncode(payload)}\n', flush: true);
      if (target.existsSync()) {
        target.deleteSync();
      }
      pending.renameSync(outputPath);
      _published = true;
    } on FileSystemException {
      try {
        if (pending?.existsSync() ?? false) {
          pending!.deleteSync();
        }
      } on FileSystemException {
        // A readiness probe must never interfere with normal app startup.
      }
    }
  }

  static String? _normalizedPath(String? path) {
    final normalized = path?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
