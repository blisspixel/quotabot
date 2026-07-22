import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/window_geometry.dart';

void main() {
  const windowSize = Size(340, 760);

  test('quota window trusts rendered content over an undersized estimate', () {
    expect(
      quotaWindowGeometry(
        width: 340,
        estimatedContentHeight: 390,
        renderedContentHeight: 448,
        currentSize: const Size(340, 390),
        currentPosition: const Offset(1500, 800),
        workAreas: const [Rect.fromLTWH(0, 0, 1920, 1040)],
      ),
      (
        size: const Size(340, 448),
        position: const Offset(1500, 592),
        overflowing: false,
      ),
    );
  });

  test('quota window caps oversized content and exposes scrolling', () {
    expect(
      quotaWindowGeometry(
        width: 340,
        estimatedContentHeight: 700,
        renderedContentHeight: 1400,
        currentSize: const Size(340, 700),
        currentPosition: const Offset(300, 250),
        workAreas: const [Rect.fromLTWH(0, 0, 1280, 720)],
      ),
      (
        size: const Size(340, 720),
        position: const Offset(300, 0),
        overflowing: true,
      ),
    );
  });

  test('quota window tolerates a work area below its fallback height', () {
    expect(
      quotaWindowGeometry(
        width: 340,
        estimatedContentHeight: 430,
        renderedContentHeight: 448,
        currentSize: const Size(340, 430),
        currentPosition: const Offset(5, 10),
        workAreas: const [Rect.fromLTWH(0, 0, 320, 100)],
      ),
      (size: const Size(320, 100), position: Offset.zero, overflowing: true),
    );
  });

  test('quota window falls back to its estimate without rendered evidence', () {
    expect(
      quotaWindowGeometry(
        width: 340,
        estimatedContentHeight: 430,
        renderedContentHeight: double.nan,
        currentSize: const Size(340, 760),
        currentPosition: const Offset(50, 60),
        workAreas: const [],
        fallbackMaximumHeight: 500,
      ),
      (
        size: const Size(340, 430),
        position: const Offset(50, 60),
        overflowing: false,
      ),
    );
  });

  test('returning from Analytics restores rendered quota height', () {
    expect(
      quotaWindowGeometry(
        width: 340,
        estimatedContentHeight: 420,
        renderedContentHeight: 448,
        currentSize: const Size(340, 760),
        currentPosition: const Offset(100, 200),
        workAreas: const [Rect.fromLTWH(0, 0, 1920, 1040)],
      ),
      (
        size: const Size(340, 448),
        position: const Offset(100, 200),
        overflowing: false,
      ),
    );
  });

  test('analytics grows a short window without shrinking useful space', () {
    expect(
      analyticsWindowGeometry(
        currentSize: const Size(320, 120),
        currentPosition: const Offset(100, 80),
        workAreas: const [Rect.fromLTWH(0, 0, 1920, 1040)],
      ),
      (size: const Size(340, 760), position: const Offset(100, 80)),
    );
    expect(
      analyticsWindowGeometry(
        currentSize: const Size(520, 820),
        currentPosition: const Offset(100, 80),
        workAreas: const [Rect.fromLTWH(0, 0, 1920, 1040)],
      ),
      (size: const Size(520, 820), position: const Offset(100, 80)),
    );
  });

  test('analytics size and position stay inside a constrained work area', () {
    expect(
      analyticsWindowGeometry(
        currentSize: const Size(900, 120),
        currentPosition: const Offset(250, 420),
        workAreas: const [Rect.fromLTWH(0, 0, 640, 540)],
      ),
      (size: const Size(640, 540), position: Offset.zero),
    );
  });

  test('analytics follows the current negative-coordinate display', () {
    expect(
      analyticsWindowGeometry(
        currentSize: const Size(320, 120),
        currentPosition: const Offset(-400, 900),
        workAreas: const [
          Rect.fromLTWH(-1280, 0, 1280, 1024),
          Rect.fromLTWH(0, 0, 1920, 1040),
        ],
      ),
      (size: const Size(340, 760), position: const Offset(-400, 264)),
    );
  });

  test('analytics uses a bounded fallback when work areas are unavailable', () {
    expect(
      analyticsWindowGeometry(
        currentSize: const Size(320, 120),
        currentPosition: const Offset(100, 80),
        workAreas: const [],
        fallbackMaximumHeight: 540,
      ),
      (size: const Size(340, 540), position: const Offset(100, 80)),
    );
  });

  test('content hugging ignores a larger non-overflowing viewport', () {
    expect(
      measuredOverflowContentHeight(viewportHeight: 700, maxScrollExtent: 0),
      isNull,
    );
    expect(
      measuredOverflowContentHeight(viewportHeight: 400, maxScrollExtent: 125),
      525,
    );
  });

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
