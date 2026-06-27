import 'dart:math' as math;
import 'package:flutter/material.dart';

/// The Quota app mark: a small radial gauge that fills clockwise from the top in
/// proportion to [value] (0..1, how much of the overall pool is left) and is
/// drawn in [fillColor] (the green/amber/red status color). A faint full ring in
/// [trackColor] shows the total, and a centre dot keeps it reading as a dial.
/// Abstract and radial, so it never reads as a letter, and recolors for
/// light/dark via the colors passed in.
class AppGauge extends StatelessWidget {
  final double size;
  final double value; // 0..1 fraction of the pool remaining
  final Color fillColor;
  final Color trackColor;
  const AppGauge({
    super.key,
    this.size = 16,
    required this.value,
    required this.fillColor,
    required this.trackColor,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _AppGaugePainter(value, fillColor, trackColor)),
  );
}

class _AppGaugePainter extends CustomPainter {
  final double value;
  final Color fillColor;
  final Color trackColor;
  _AppGaugePainter(this.value, this.fillColor, this.trackColor);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final r = s * 0.34;
    final sw = s * 0.16;
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);

    // Faint full-ring track = total capacity.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw
        ..color = trackColor,
    );

    // Coloured fill arc, clockwise from the top, proportional to what's left.
    if (v > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        2 * math.pi * v,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw
          ..strokeCap = StrokeCap.round
          ..color = fillColor,
      );
    }

    // Centre dot, in the status color, so empty still reads (red dot).
    canvas.drawCircle(c, s * 0.105, Paint()..color = fillColor);
  }

  @override
  bool shouldRepaint(covariant _AppGaugePainter old) =>
      old.value != value ||
      old.fillColor != fillColor ||
      old.trackColor != trackColor;
}

/// Vector provider logos drawn with CustomPainter so they stay crisp at any
/// size and recolor cleanly for light/dark. Monochrome marks take [color];
/// brand-colored marks (Claude, Google) ignore it.
class ProviderLogo extends StatelessWidget {
  final String provider;
  final double size;
  final Color color; // foreground for monochrome marks
  const ProviderLogo(
    this.provider, {
    super.key,
    this.size = 22,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final painter = switch (provider) {
      'codex' => _OpenAIKnot(color),
      'claude' => _ClaudeBurst(),
      'grok' => _GrokX(color),
      'antigravity' => _AntigravityG(),
      'kiro' => _KiroK(color),
      'cursor' => _CursorC(color),
      'windsurf' => _WindsurfW(color),
      'ollama' => _OllamaLlama(color),
      'lmstudio' => _LmStudioMark(),
      _ => _Fallback(color),
    };
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: painter),
    );
  }
}

/// OpenAI-style interlocking knot, approximated by three rotated stroked
/// rounded-hexagon loops - reads as the hexafoil mark, single color.
class _OpenAIKnot extends CustomPainter {
  final Color color;
  _OpenAIKnot(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.40;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.10
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (var k = 0; k < 3; k++) {
      final path = Path();
      for (var i = 0; i <= 6; i++) {
        final a = (math.pi / 3) * i + k * (math.pi / 3) * (2 / 3);
        final pt = Offset(
          c.dx + r * math.cos(a),
          c.dy + r * math.sin(a) * 0.62,
        );
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(k * math.pi / 3);
      canvas.translate(-c.dx, -c.dy);
      canvas.drawPath(path, p);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _OpenAIKnot o) => o.color != color;
}

/// Anthropic/Claude radiating sunburst, in brand terracotta (works both modes).
class _ClaudeBurst extends CustomPainter {
  static const _orange = Color(0xFFD97757);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.46;
    final p = Paint()
      ..color = _orange
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.085;
    const spokes = 12;
    for (var i = 0; i < spokes; i++) {
      final a = (2 * math.pi / spokes) * i;
      final inner = r * 0.30;
      canvas.drawLine(
        Offset(c.dx + inner * math.cos(a), c.dy + inner * math.sin(a)),
        Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a)),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}

/// xAI / Grok angular slashed-X, single color.
class _GrokX extends CustomPainter {
  final Color color;
  _GrokX(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Paint()
      ..color = color
      ..strokeWidth = w * 0.11
      ..strokeCap = StrokeCap.square;
    final pad = w * 0.20;
    // Main diagonal (top-right to bottom-left).
    canvas.drawLine(Offset(w - pad, pad), Offset(pad, h - pad), p);
    // Split counter-diagonal with a gap for the xAI look.
    canvas.drawLine(Offset(pad, pad), Offset(w * 0.46, h * 0.46), p);
    canvas.drawLine(Offset(w * 0.56, h * 0.56), Offset(w - pad, h - pad), p);
  }

  @override
  bool shouldRepaint(covariant _GrokX o) => o.color != color;
}

/// Google four-color "G" for Antigravity (Google's identity, fixed palette).
class _AntigravityG extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.40;
    final sw = size.width * 0.16;
    final rect = Rect.fromCircle(center: c, radius: r);
    final segs = [
      (
        start: -20.0,
        sweep: 90.0,
        color: const Color(0xFFEA4335),
      ), // red top-right
      (
        start: 70.0,
        sweep: 90.0,
        color: const Color(0xFFFBBC05),
      ), // yellow bottom
      (start: 160.0, sweep: 90.0, color: const Color(0xFF34A853)), // green left
      (start: 250.0, sweep: 70.0, color: const Color(0xFF4285F4)), // blue top
    ];
    for (final s in segs) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw
        ..strokeCap = StrokeCap.butt
        ..color = s.color;
      canvas.drawArc(rect, _rad(s.start), _rad(s.sweep), false, p);
    }
    // The G's inner crossbar (blue).
    final bar = Paint()..color = const Color(0xFF4285F4);
    canvas.drawRect(Rect.fromLTWH(c.dx, c.dy - sw / 2, r, sw), bar);
  }

  double _rad(double deg) => deg * math.pi / 180;
  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}

/// Simple "K" mark for Kiro (monochrome).
class _KiroK extends CustomPainter {
  final Color color;
  _KiroK(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Paint()
      ..color = color
      ..strokeWidth = w * 0.12
      ..strokeCap = StrokeCap.round;
    final pad = w * 0.18;
    // Vertical stem
    canvas.drawLine(Offset(pad, pad), Offset(pad, h - pad), p);
    // Top diagonal
    canvas.drawLine(Offset(pad, pad * 1.1), Offset(w - pad, pad), p);
    // Bottom diagonal
    canvas.drawLine(Offset(pad, h - pad * 1.1), Offset(w - pad, h - pad), p);
  }

  @override
  bool shouldRepaint(covariant _KiroK o) => o.color != color;
}

/// Simple "C" mark for Cursor (monochrome).
class _CursorC extends CustomPainter {
  final Color color;
  _CursorC(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.42;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), 0.8, 4.6, false, p);
  }

  @override
  bool shouldRepaint(covariant _CursorC o) => o.color != color;
}

/// Simple "W" for Windsurf (monochrome).
class _WindsurfW extends CustomPainter {
  final Color color;
  _WindsurfW(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Paint()
      ..color = color
      ..strokeWidth = w * 0.12
      ..strokeCap = StrokeCap.round;
    final pad = w * 0.18;
    canvas.drawLine(Offset(pad, pad), Offset(w / 2, h - pad), p);
    canvas.drawLine(Offset(w / 2, h - pad), Offset(w - pad, pad), p);
    canvas.drawLine(Offset(w / 2, pad), Offset(w / 2, h - pad), p);
  }

  @override
  bool shouldRepaint(covariant _WindsurfW o) => o.color != color;
}

/// Ollama: a minimal llama head (two upright ears over a rounded face),
/// monochrome so it recolors for light/dark like the other single-color marks.
class _OllamaLlama extends CustomPainter {
  final Color color;
  _OllamaLlama(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final solid = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final ear = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.13
      ..strokeCap = StrokeCap.round;
    // Two ears, angled slightly outward.
    canvas.drawLine(
      Offset(w * 0.37, h * 0.42),
      Offset(w * 0.32, h * 0.13),
      ear,
    );
    canvas.drawLine(
      Offset(w * 0.63, h * 0.42),
      Offset(w * 0.68, h * 0.13),
      ear,
    );
    // Rounded face/muzzle.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.31, h * 0.36, w * 0.69, h * 0.88),
        Radius.circular(w * 0.18),
      ),
      solid,
    );
  }

  @override
  bool shouldRepaint(covariant _OllamaLlama o) => o.color != color;
}

/// LM Studio: a filled rounded hexagon in the brand purple (fixed palette, like
/// the Claude and Google marks), with a small inner cut for depth.
class _LmStudioMark extends CustomPainter {
  static const _purple = Color(0xFF8B5CF6);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.44;
    Path hex(double radius) {
      final path = Path();
      for (var i = 0; i < 6; i++) {
        final a = -math.pi / 2 + i * math.pi / 3;
        final pt = Offset(
          c.dx + radius * math.cos(a),
          c.dy + radius * math.sin(a),
        );
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      return path..close();
    }

    canvas.drawPath(hex(r), Paint()..color = _purple);
    // Inner negative-space hexagon for an embossed look.
    canvas.drawPath(
      hex(r * 0.42),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.92)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}

class _Fallback extends CustomPainter {
  final Color color;
  _Fallback(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      size.width * 0.3,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}
