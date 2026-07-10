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
    if (_windowReady) {
      return;
    }
    _windowReady = true;
    _publishProgress('window');
    _publishIfComplete();
  }

  void recordTrayReady(bool ready) {
    if (_trayReady != null) {
      return;
    }
    _trayReady = ready;
    _publishProgress('tray');
    _publishIfComplete();
  }

  void _publishProgress(String component) {
    final outputPath = _outputPath;
    if (outputPath == null) {
      return;
    }
    _publishState('$outputPath.$component.json');
  }

  void _publishIfComplete() {
    final outputPath = _outputPath;
    if (outputPath == null ||
        _published ||
        !_windowReady ||
        _trayReady == null) {
      return;
    }
    _published = _publishState(outputPath);
  }

  bool _publishState(String path) {
    final target = File(path);
    File? pending;
    try {
      if (target.existsSync()) {
        return false;
      }
      target.parent.createSync(recursive: true);
      pending = File('$path.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
      final payload = <String, Object?>{
        'schema': desktopReadinessSchema,
        'window_ready': _windowReady,
        'tray_ready': _trayReady,
        'platform': platform,
      };
      pending.writeAsStringSync('${jsonEncode(payload)}\n', flush: true);
      pending.renameSync(path);
      return true;
    } on FileSystemException {
      try {
        if (pending?.existsSync() ?? false) {
          pending!.deleteSync();
        }
      } on FileSystemException {
        // A readiness probe must never interfere with normal app startup.
      }
      return false;
    }
  }

  static String? _normalizedPath(String? path) {
    final normalized = path?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
