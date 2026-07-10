import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_readiness.dart';

void main() {
  late Directory temporaryDirectory;
  late File readinessFile;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'quotabot-desktop-readiness-',
    );
    readinessFile = File('${temporaryDirectory.path}/readiness.json');
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  test('publishes immutable progress and the complete readiness result', () {
    final probe = DesktopReadinessProbe(
      outputPath: readinessFile.path,
      platform: 'test',
    );

    expect(probe.enabled, isTrue);
    probe.recordWindowReady();
    expect(readinessFile.existsSync(), isFalse);
    final windowProgress = File('${readinessFile.path}.window.json');
    expect(jsonDecode(windowProgress.readAsStringSync()), <String, Object?>{
      'schema': desktopReadinessSchema,
      'window_ready': true,
      'tray_ready': null,
      'platform': 'test',
    });

    probe.recordTrayReady(true);
    expect(jsonDecode(readinessFile.readAsStringSync()), <String, Object>{
      'schema': desktopReadinessSchema,
      'window_ready': true,
      'tray_ready': true,
      'platform': 'test',
    });
  });

  test('publishes a failed tray result without blocking startup', () {
    final probe = DesktopReadinessProbe(
      outputPath: readinessFile.path,
      platform: 'test',
    );

    probe.recordTrayReady(false);
    expect(readinessFile.existsSync(), isFalse);
    final trayProgress = File('${readinessFile.path}.tray.json');
    expect(jsonDecode(trayProgress.readAsStringSync()), <String, Object>{
      'schema': desktopReadinessSchema,
      'window_ready': false,
      'tray_ready': false,
      'platform': 'test',
    });
    probe.recordWindowReady();

    final payload = jsonDecode(readinessFile.readAsStringSync());
    expect(payload['window_ready'], isTrue);
    expect(payload['tray_ready'], isFalse);
  });

  test('publishes the first complete result only once', () {
    final probe = DesktopReadinessProbe(
      outputPath: readinessFile.path,
      platform: 'test',
    );

    probe.recordWindowReady();
    probe.recordTrayReady(false);
    probe.recordTrayReady(true);

    final payload = jsonDecode(readinessFile.readAsStringSync());
    expect(payload['tray_ready'], isFalse);
  });

  test('does nothing when the probe is disabled', () {
    final probe = DesktopReadinessProbe(outputPath: '  ', platform: 'test');

    probe.recordWindowReady();
    probe.recordTrayReady(true);

    expect(probe.enabled, isFalse);
    expect(temporaryDirectory.listSync(), isEmpty);
  });

  test('filesystem failures never interfere with app readiness', () {
    final blockingFile = File('${temporaryDirectory.path}/not-a-directory')
      ..writeAsStringSync('occupied');
    final probe = DesktopReadinessProbe(
      outputPath: '${blockingFile.path}/readiness.json',
      platform: 'test',
    );

    expect(probe.recordWindowReady, returnsNormally);
    expect(() => probe.recordTrayReady(true), returnsNormally);
    expect(blockingFile.readAsStringSync(), 'occupied');
  });
}
