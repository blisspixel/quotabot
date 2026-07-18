import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

const double _fallbackCoordinateLimit = 20000;
const double _headerHeight = 48;
const double _minimumVisibleHeaderWidth = 96;
const double _minimumVisibleHeaderHeight = 32;

/// Returns logical work areas for every currently attached display.
///
/// Native display discovery is optional at runtime. An empty result lets the
/// caller retain the existing bounded fallback instead of blocking startup.
Future<List<Rect>> desktopWorkAreas() async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    return [
      for (final display in displays)
        Rect.fromLTWH(
          display.visiblePosition?.dx ?? 0,
          display.visiblePosition?.dy ?? 0,
          (display.visibleSize ?? display.size).width,
          (display.visibleSize ?? display.size).height,
        ),
    ].where(_usableWorkArea).toList();
  } catch (_) {
    return const [];
  }
}

/// Reconciles a saved logical window position with the attached displays.
///
/// A position with a reachable title region is preserved, including negative
/// coordinates and windows intentionally spanning monitors. A position left on
/// a removed or rescaled display is moved fully into the nearest work area.
/// Null means the caller should use the platform's centered fallback.
Offset? restoredWindowPosition({
  required Offset? savedPosition,
  required Size windowSize,
  required List<Rect> workAreas,
}) {
  if (savedPosition == null ||
      !savedPosition.dx.isFinite ||
      !savedPosition.dy.isFinite ||
      !windowSize.width.isFinite ||
      !windowSize.height.isFinite ||
      windowSize.width <= 0 ||
      windowSize.height <= 0) {
    return null;
  }

  final usable = workAreas.where(_usableWorkArea).toList();
  if (usable.isEmpty) {
    final x = savedPosition.dx;
    final y = savedPosition.dy;
    return x > -_fallbackCoordinateLimit &&
            y > -_fallbackCoordinateLimit &&
            x < _fallbackCoordinateLimit &&
            y < _fallbackCoordinateLimit
        ? savedPosition
        : null;
  }

  final header = Rect.fromLTWH(
    savedPosition.dx,
    savedPosition.dy,
    windowSize.width,
    math.min(_headerHeight, windowSize.height),
  );
  final requiredWidth = math.min(_minimumVisibleHeaderWidth, header.width);
  final requiredHeight = math.min(_minimumVisibleHeaderHeight, header.height);
  for (final area in usable) {
    final visible = header.intersect(area);
    if (visible.width >= requiredWidth && visible.height >= requiredHeight) {
      return savedPosition;
    }
  }

  var target = usable.first;
  var targetDistance = _distanceSquaredToRect(savedPosition, target);
  for (final area in usable.skip(1)) {
    final distance = _distanceSquaredToRect(savedPosition, area);
    if (distance < targetDistance) {
      target = area;
      targetDistance = distance;
    }
  }

  return Offset(
    _fitAxis(savedPosition.dx, target.left, target.right, windowSize.width),
    _fitAxis(savedPosition.dy, target.top, target.bottom, windowSize.height),
  );
}

bool _usableWorkArea(Rect area) =>
    area.left.isFinite &&
    area.top.isFinite &&
    area.width.isFinite &&
    area.height.isFinite &&
    area.width > 0 &&
    area.height > 0;

double _distanceSquaredToRect(Offset point, Rect rect) {
  final dx = point.dx < rect.left
      ? rect.left - point.dx
      : point.dx > rect.right
      ? point.dx - rect.right
      : 0.0;
  final dy = point.dy < rect.top
      ? rect.top - point.dy
      : point.dy > rect.bottom
      ? point.dy - rect.bottom
      : 0.0;
  return dx * dx + dy * dy;
}

double _fitAxis(double value, double start, double end, double extent) {
  final lastFullyVisible = end - extent;
  if (lastFullyVisible <= start) return start;
  return value.clamp(start, lastFullyVisible).toDouble();
}
