import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/window_geometry.dart';

void main() {
  const windowSize = Size(340, 760);

  test(
    'preserves a reachable saved position on a negative-coordinate display',
    () {
      const saved = Offset(-1500, 120);

      final restored = restoredWindowPosition(
        savedPosition: saved,
        windowSize: windowSize,
        workAreas: const [
          Rect.fromLTWH(-1920, 0, 1920, 1040),
          Rect.fromLTWH(0, 0, 1920, 1040),
        ],
      );

      expect(restored, saved);
    },
  );

  test('moves a window from a removed monitor onto the nearest work area', () {
    final restored = restoredWindowPosition(
      savedPosition: const Offset(4100, 200),
      windowSize: windowSize,
      workAreas: const [Rect.fromLTWH(0, 0, 1920, 1040)],
    );

    expect(restored, const Offset(1580, 200));
  });

  test('reconciles stale logical coordinates after display scale changes', () {
    final restored = restoredWindowPosition(
      savedPosition: const Offset(2100, 900),
      windowSize: const Size(340, 500),
      workAreas: const [Rect.fromLTWH(0, 0, 1280, 680)],
    );

    expect(restored, const Offset(940, 180));
  });

  test('requires a usable portion of the title region to remain visible', () {
    final restored = restoredWindowPosition(
      savedPosition: const Offset(1840, 20),
      windowSize: windowSize,
      workAreas: const [Rect.fromLTWH(0, 0, 1920, 1040)],
    );

    expect(restored, const Offset(1580, 20));
  });

  test('rejects invalid positions and bounds the no-display fallback', () {
    expect(
      restoredWindowPosition(
        savedPosition: const Offset(double.nan, 0),
        windowSize: windowSize,
        workAreas: const [],
      ),
      isNull,
    );
    expect(
      restoredWindowPosition(
        savedPosition: const Offset(40000, 0),
        windowSize: windowSize,
        workAreas: const [],
      ),
      isNull,
    );
    expect(
      restoredWindowPosition(
        savedPosition: const Offset(-800, 50),
        windowSize: windowSize,
        workAreas: const [],
      ),
      const Offset(-800, 50),
    );
  });
}
