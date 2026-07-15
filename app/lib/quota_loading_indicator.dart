import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The startup loader: a quota-gauge arc that sweeps while the first snapshot is
/// collected, instead of a stock spinner. Honors reduced-motion by holding a
/// static arc. Self-contained; takes only a size and its two colors.
class QuotaLoadingIndicator extends StatefulWidget {
  final double size;
  final Color color;
  final Color trackColor;

  const QuotaLoadingIndicator({
    super.key,
    this.size = 30,
    required this.color,
    required this.trackColor,
  });

  @override
  State<QuotaLoadingIndicator> createState() => _QuotaLoadingIndicatorState();
}

class _QuotaLoadingIndicatorState extends State<QuotaLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce == _reduceMotion) return;
    _reduceMotion = reduce;
    if (_reduceMotion) {
      _controller.stop();
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget paint(double phase) => SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _QuotaLoadingPainter(
          phase: phase,
          color: widget.color,
          trackColor: widget.trackColor,
        ),
      ),
    );

    return Semantics(
      label: 'Loading quota data',
      child: _reduceMotion
          ? paint(0.64)
          : AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => paint(_controller.value),
            ),
    );
  }
}

class _QuotaLoadingPainter extends CustomPainter {
  final double phase;
  final Color color;
  final Color trackColor;

  const _QuotaLoadingPainter({
    required this.phase,
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final center = size.center(Offset.zero);
    final radius = s * 0.34;
    final stroke = s * 0.14;
    final start = -math.pi / 2 + phase * math.pi * 2;
    final sweep = math.pi * 1.45;
    final pulse = 0.88 + 0.12 * math.sin(phase * math.pi * 2);
    final animatedColor = Color.lerp(trackColor, color, pulse) ?? color;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = trackColor,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = animatedColor,
    );

    final dotAngle = start + sweep;
    canvas.drawCircle(
      Offset(
        center.dx + radius * math.cos(dotAngle),
        center.dy + radius * math.sin(dotAngle),
      ),
      s * 0.095,
      Paint()..color = color,
    );
    canvas.drawCircle(center, s * 0.07, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _QuotaLoadingPainter old) =>
      old.phase != phase || old.color != color || old.trackColor != trackColor;
}
