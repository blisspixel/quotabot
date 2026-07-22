import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

const double _fallbackCoordinateLimit = 20000;
const double _headerHeight = 48;
const double _minimumVisibleHeaderWidth = 96;
const double _minimumVisibleHeaderHeight = 32;
const Size _preferredAnalyticsWindowSize = Size(340, 760);
const double _expandedFallbackHeight = 120;

typedef AnalyticsWindowGeometry = ({Size size, Offset? position});
typedef QuotaWindowGeometry = ({Size size, Offset? position, bool overflowing});
typedef CompactWindowGeometry = ({Size size, Offset? position});

/// Width requested by the compact strip before display-work-area clamping.
///
/// Duplicate provider accounts need enough room to keep the selected account
/// visible. Large text receives a wider identity budget rather than removing
/// the routing answer from the smallest product surface.
double compactDesiredWindowWidth({
  required int providerCount,
  required bool needsAccountIdentity,
  required bool largeText,
  bool shotsMode = false,
}) {
  final count = providerCount.clamp(1, shotsMode ? 16 : 8);
  final maximum = shotsMode ? 680.0 : 560.0;
  final base = count * 46 + 240.0;
  final identityFloor = needsAccountIdentity
      ? largeText
            ? 520.0
            : 360.0
      : 0.0;
  return math.max(base, identityFloor).clamp(200.0, maximum).toDouble();
}

/// Fits the compact strip inside the work area that currently owns the window.
///
/// Collapsing can make the strip wider than the expanded card. Clamp both axes
/// and shift the existing position just enough to keep the whole strip visible.
CompactWindowGeometry compactWindowGeometry({
  required Size desiredSize,
  required Size currentSize,
  required Offset? currentPosition,
  required List<Rect> workAreas,
}) {
  final desiredWidth = desiredSize.width.isFinite && desiredSize.width > 0
      ? desiredSize.width
      : _preferredAnalyticsWindowSize.width;
  final desiredHeight = desiredSize.height.isFinite && desiredSize.height > 0
      ? desiredSize.height
      : _headerHeight;
  final usable = workAreas.where(_usableWorkArea).toList();
  if (usable.isEmpty) {
    return (
      size: Size(desiredWidth, desiredHeight),
      position: _validPosition(currentPosition) ? currentPosition : null,
    );
  }

  final target = _workAreaForWindow(
    currentPosition: currentPosition,
    currentSize: currentSize,
    workAreas: usable,
  );
  final size = Size(
    math.min(desiredWidth, target.width),
    math.min(desiredHeight, target.height),
  );
  final position = _validPosition(currentPosition)
      ? Offset(
          _fitAxis(currentPosition!.dx, target.left, target.right, size.width),
          _fitAxis(currentPosition.dy, target.top, target.bottom, size.height),
        )
      : null;
  return (size: size, position: position);
}

/// Hugs the rendered quota content while keeping the whole window inside the
/// current display work area.
///
/// The rendered height wins over the estimator because provider status and
/// recovery copy can wrap or add rows that estimates cannot predict. The
/// estimator remains the first-frame fallback. Content above the display cap
/// gets a bounded viewport with an explicit scroll affordance.
QuotaWindowGeometry quotaWindowGeometry({
  required double width,
  required double estimatedContentHeight,
  required double? renderedContentHeight,
  required Size currentSize,
  required Offset? currentPosition,
  required List<Rect> workAreas,
  double fallbackMaximumHeight = 900,
}) {
  final renderedHeightIsUsable =
      renderedContentHeight != null &&
      renderedContentHeight.isFinite &&
      renderedContentHeight > 80;
  final estimatedHeightIsUsable =
      estimatedContentHeight.isFinite && estimatedContentHeight > 0;
  final contentHeight = renderedHeightIsUsable
      ? renderedContentHeight
      : estimatedHeightIsUsable
      ? estimatedContentHeight
      : _expandedFallbackHeight;
  final usable = workAreas.where(_usableWorkArea).toList();
  final fallbackCap =
      fallbackMaximumHeight.isFinite && fallbackMaximumHeight > 0
      ? math.max(fallbackMaximumHeight, _expandedFallbackHeight)
      : _preferredAnalyticsWindowSize.height;

  Rect? target;
  var maximumHeight = fallbackCap;
  if (usable.isNotEmpty) {
    target = _workAreaForWindow(
      currentPosition: currentPosition,
      currentSize: currentSize,
      workAreas: usable,
    );
    maximumHeight = target.height;
  }

  final safeWidth = width.isFinite && width > 0
      ? target == null
            ? width
            : math.min(width, target.width)
      : _preferredAnalyticsWindowSize.width;
  final minimumHeight = math.min(_expandedFallbackHeight, maximumHeight);
  final size = Size(
    safeWidth,
    contentHeight.clamp(minimumHeight, maximumHeight).toDouble(),
  );
  final position = target != null && _validPosition(currentPosition)
      ? Offset(
          _fitAxis(currentPosition!.dx, target.left, target.right, size.width),
          _fitAxis(currentPosition.dy, target.top, target.bottom, size.height),
        )
      : restoredWindowPosition(
          savedPosition: currentPosition,
          windowSize: size,
          workAreas: usable,
        );
  return (
    size: size,
    position: position,
    overflowing: contentHeight > maximumHeight + 1,
  );
}

/// Grows a content-hugged quota window into a useful Analytics viewport and
/// keeps the resulting bounds inside the current display's work area.
///
/// Existing user-expanded dimensions are preserved when they fit. When native
/// work-area discovery is unavailable, height uses [fallbackMaximumHeight] and
/// the caller retains any sane current position.
AnalyticsWindowGeometry analyticsWindowGeometry({
  required Size currentSize,
  required Offset? currentPosition,
  required List<Rect> workAreas,
  double fallbackMaximumHeight = 900,
}) {
  final currentWidth = currentSize.width.isFinite && currentSize.width > 0
      ? currentSize.width
      : _preferredAnalyticsWindowSize.width;
  final currentHeight = currentSize.height.isFinite && currentSize.height > 0
      ? currentSize.height
      : _expandedFallbackHeight;
  final usable = workAreas.where(_usableWorkArea).toList();
  if (usable.isNotEmpty) {
    final target = _workAreaForWindow(
      currentPosition: currentPosition,
      currentSize: Size(currentWidth, currentHeight),
      workAreas: usable,
    );
    final size = Size(
      math.min(
        math.max(currentWidth, _preferredAnalyticsWindowSize.width),
        target.width,
      ),
      math.min(
        math.max(currentHeight, _preferredAnalyticsWindowSize.height),
        target.height,
      ),
    );
    final position = _validPosition(currentPosition)
        ? Offset(
            _fitAxis(
              currentPosition!.dx,
              target.left,
              target.right,
              size.width,
            ),
            _fitAxis(
              currentPosition.dy,
              target.top,
              target.bottom,
              size.height,
            ),
          )
        : null;
    return (size: size, position: position);
  }

  final heightCap = fallbackMaximumHeight.isFinite && fallbackMaximumHeight > 0
      ? math.max(fallbackMaximumHeight, _expandedFallbackHeight)
      : _preferredAnalyticsWindowSize.height;
  final size = Size(
    math.max(currentWidth, _preferredAnalyticsWindowSize.width),
    math.min(
      math.max(currentHeight, _preferredAnalyticsWindowSize.height),
      heightCap,
    ),
  );
  return (
    size: size,
    position: restoredWindowPosition(
      savedPosition: currentPosition,
      windowSize: size,
      workAreas: const [],
    ),
  );
}

/// Returns total content height only when the scroll view proves that content
/// exceeds its viewport. A zero extent means a previously enlarged viewport is
/// not content evidence and must not defeat content-hugging window estimates.
double? measuredOverflowContentHeight({
  required double viewportHeight,
  required double maxScrollExtent,
}) {
  if (!viewportHeight.isFinite ||
      viewportHeight <= 0 ||
      !maxScrollExtent.isFinite ||
      maxScrollExtent <= 1) {
    return null;
  }
  return viewportHeight + maxScrollExtent;
}

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

Rect _workAreaForWindow({
  required Offset? currentPosition,
  required Size currentSize,
  required List<Rect> workAreas,
}) {
  if (!_validPosition(currentPosition)) return workAreas.first;

  final current = Rect.fromLTWH(
    currentPosition!.dx,
    currentPosition.dy,
    currentSize.width,
    currentSize.height,
  );
  var target = workAreas.first;
  var largestOverlap = -1.0;
  for (final area in workAreas) {
    final intersection = current.intersect(area);
    final overlap =
        math.max(0.0, intersection.width) * math.max(0.0, intersection.height);
    if (overlap > largestOverlap) {
      target = area;
      largestOverlap = overlap;
    }
  }
  if (largestOverlap > 0) return target;

  var targetDistance = _distanceSquaredToRect(currentPosition, target);
  for (final area in workAreas.skip(1)) {
    final distance = _distanceSquaredToRect(currentPosition, area);
    if (distance < targetDistance) {
      target = area;
      targetDistance = distance;
    }
  }
  return target;
}

bool _validPosition(Offset? position) =>
    position != null && position.dx.isFinite && position.dy.isFinite;

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
