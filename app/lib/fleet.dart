import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:window_manager/window_manager.dart';

/// Health color on the shared green-to-red scale (input is remaining free %).
Color fleetColor(num freePct) {
  if (freePct >= 50) return const Color(0xFF3FB950);
  if (freePct >= 25) return const Color(0xFFD29922);
  if (freePct > 0) return const Color(0xFFDB6D28);
  return const Color(0xFFF85149);
}

/// One provider reduced to the few numbers the fleet charts need.
class _Node {
  final String label;
  final double free; // remaining headroom percent, 0..100
  final int? resetsAt;
  final Insights? insights;
  _Node(this.label, this.free, this.resetsAt, this.insights);
  double get used => (100 - free).clamp(0, 100);
}

/// Full-window "mission control" view over the whole fleet at once. Pure render
/// of the snapshot the dashboard already loaded; it computes no I/O.
class FleetScreen extends StatelessWidget {
  final List<ProviderQuota> data;
  final Map<String, Insights> insights;
  final Map<String, List<List<double?>>> heatmaps;
  final bool dark;

  const FleetScreen({
    super.key,
    required this.data,
    required this.insights,
    required this.heatmaps,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    final bg = dark ? const Color(0xFF0C0E12) : const Color(0xFFF4F5F7);
    final panel = dark ? const Color(0xFF14171D) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF111317);
    final muted = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
    final line = dark ? const Color(0xFF262B33) : const Color(0xFFE3E5EA);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nodes = <_Node>[];
    for (final q in data) {
      if (q.isLocal) continue;
      final h = providerHeadroom(q, now);
      if (h == null) continue;
      final b = bindingWindow(q, now);
      nodes.add(_Node(q.displayName, h, b?.resetsAt, insights[q.provider]));
    }
    nodes.sort((a, b) => a.free.compareTo(b.free)); // tightest first

    final avgFree = nodes.isEmpty
        ? null
        : nodes.map((n) => n.free).reduce((a, b) => a + b) / nodes.length;
    final fleetGrid = _aggregateHeatmap();
    final portfolio = portfolioInsight(insights);

    return Scaffold(
      backgroundColor: bg,
      body: Column(
        children: [
          _bar(context, fg, muted, line, panel),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _summary(nodes, avgFree, portfolio, fg, muted, panel, line),
                  const SizedBox(height: 14),
                  _card(
                    panel,
                    line,
                    'CONSTELLATION',
                    'remaining headroom across the fleet',
                    muted,
                    fg,
                    SizedBox(
                      height: 300,
                      child: nodes.length < 3
                          ? _empty('needs 3+ live providers', muted)
                          : CustomPaint(
                              painter: _RadarPainter(nodes, avgFree ?? 0, dark),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (_, c) {
                      final wide = c.maxWidth > 560;
                      final ranking = _card(
                        panel,
                        line,
                        'HEADROOM',
                        'free now, tightest first',
                        muted,
                        fg,
                        SizedBox(
                          height: math.max(120, nodes.length * 30.0),
                          child: nodes.isEmpty
                              ? _empty('no live data', muted)
                              : CustomPaint(
                                  painter: _RankPainter(nodes, dark, fg, muted),
                                ),
                        ),
                      );
                      final donut = _card(
                        panel,
                        line,
                        'CONSUMPTION',
                        'share of quota spent',
                        muted,
                        fg,
                        SizedBox(
                          height: 220,
                          child: nodes.every((n) => n.used <= 0.5)
                              ? _empty('nothing spent yet', muted)
                              : CustomPaint(
                                  painter: _DonutPainter(
                                    nodes,
                                    dark,
                                    fg,
                                    muted,
                                  ),
                                ),
                        ),
                      );
                      if (!wide) {
                        return Column(
                          children: [
                            ranking,
                            const SizedBox(height: 14),
                            donut,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: ranking),
                          const SizedBox(width: 14),
                          Expanded(flex: 2, child: donut),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  _card(
                    panel,
                    line,
                    'DISTRIBUTION',
                    'typical free range (p10 / p50 / p90) from history',
                    muted,
                    fg,
                    SizedBox(
                      height: math.max(110, _withStats(nodes).length * 30.0),
                      child: _withStats(nodes).isEmpty
                          ? _empty('history is still warming up', muted)
                          : CustomPaint(
                              painter: _DistPainter(
                                _withStats(nodes),
                                dark,
                                fg,
                                muted,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _card(
                    panel,
                    line,
                    'BEST TIME TO RUN',
                    'fleet headroom by weekday x hour (local)',
                    muted,
                    fg,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 150,
                          child: fleetGrid == null
                              ? _empty('history is still warming up', muted)
                              : CustomPaint(
                                  painter: _FleetHeatmapPainter(
                                    fleetGrid,
                                    dark,
                                    muted,
                                  ),
                                ),
                        ),
                        const SizedBox(height: 6),
                        _legend(muted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_Node> _withStats(List<_Node> nodes) => [
    for (final n in nodes)
      if ((n.insights?.samples ?? 0) > 0) n,
  ];

  /// Cell-wise average of every provider's 7x24 heatmap, null where no data.
  List<List<double?>>? _aggregateHeatmap() {
    final sum = List.generate(7, (_) => List<double>.filled(24, 0));
    final cnt = List.generate(7, (_) => List<int>.filled(24, 0));
    var any = false;
    for (final grid in heatmaps.values) {
      if (grid.length != 7) continue;
      for (var d = 0; d < 7; d++) {
        for (var h = 0; h < 24; h++) {
          final v = grid[d][h];
          if (v != null) {
            sum[d][h] += v;
            cnt[d][h]++;
            any = true;
          }
        }
      }
    }
    if (!any) return null;
    return List.generate(
      7,
      (d) => List.generate(
        24,
        (h) => cnt[d][h] == 0 ? null : sum[d][h] / cnt[d][h],
      ),
    );
  }

  // ---- chrome ----------------------------------------------------------

  Widget _bar(
    BuildContext context,
    Color fg,
    Color muted,
    Color line,
    Color panel,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        decoration: BoxDecoration(
          color: panel,
          border: Border(bottom: BorderSide(color: line)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.hub_rounded, size: 16, color: fleetColor(60)),
            const SizedBox(width: 8),
            Text(
              'FLEET ANALYTICS',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: fg,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Close',
              icon: Icon(Icons.close_rounded, size: 18, color: muted),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(
    List<_Node> nodes,
    double? avgFree,
    PortfolioInsight pf,
    Color fg,
    Color muted,
    Color panel,
    Color line,
  ) {
    final live = nodes.length;
    final tight = nodes.isEmpty ? null : nodes.first;
    final spent = nodes.where((n) => n.free <= 0.5).length;
    final busiest = pf.mostUsed;
    return Row(
      children: [
        _stat(
          '$live',
          'live providers',
          fleetColor(60),
          fg,
          muted,
          panel,
          line,
        ),
        const SizedBox(width: 10),
        _stat(
          avgFree == null ? '--' : '${avgFree.round()}%',
          'pool free',
          avgFree == null ? muted : fleetColor(avgFree),
          fg,
          muted,
          panel,
          line,
        ),
        const SizedBox(width: 10),
        _stat(
          tight == null ? '--' : '${tight.free.round()}%',
          tight == null ? 'tightest' : 'tightest: ${tight.label}',
          tight == null ? muted : fleetColor(tight.free),
          fg,
          muted,
          panel,
          line,
        ),
        const SizedBox(width: 10),
        _stat(
          busiest == null ? '--' : '${busiest.peakUsed.round()}%',
          busiest == null ? 'busiest' : 'busiest: ${busiest.provider}',
          spent > 0 ? const Color(0xFFF85149) : fg,
          fg,
          muted,
          panel,
          line,
        ),
      ],
    );
  }

  Widget _stat(
    String value,
    String label,
    Color accent,
    Color fg,
    Color muted,
    Color panel,
    Color line,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: accent,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(
    Color panel,
    Color line,
    String title,
    String subtitle,
    Color muted,
    Color fg,
    Widget child,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: fg,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _empty(String text, Color muted) => Center(
    child: Text(text, style: TextStyle(fontSize: 11, color: muted)),
  );

  Widget _legend(Color muted) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text('spent', style: TextStyle(fontSize: 9.5, color: muted)),
      const SizedBox(width: 6),
      for (final c in const [
        Color(0xFFF85149),
        Color(0xFFDB6D28),
        Color(0xFFD29922),
        Color(0xFF3FB950),
      ])
        Container(width: 16, height: 8, color: c),
      const SizedBox(width: 6),
      Text('free', style: TextStyle(fontSize: 9.5, color: muted)),
    ],
  );
}

// ---- painters ----------------------------------------------------------

/// Radial polygon ("constellation"): one spoke per provider, the filled polygon
/// traces remaining headroom, concentric rings mark 25/50/75/100 percent.
class _RadarPainter extends CustomPainter {
  final List<_Node> nodes;
  final double avgFree;
  final bool dark;
  _RadarPainter(this.nodes, this.avgFree, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 46;
    final n = nodes.length;
    final grid = dark ? const Color(0xFF2A2F38) : const Color(0xFFDADDE3);
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = grid;

    // Concentric rings.
    for (final frac in const [0.25, 0.5, 0.75, 1.0]) {
      final path = Path();
      for (var i = 0; i <= n; i++) {
        final a = -math.pi / 2 + (2 * math.pi * i / n);
        final p = center + Offset(math.cos(a), math.sin(a)) * (radius * frac);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, gridPaint);
    }

    // Spokes + labels.
    final label = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + (2 * math.pi * i / n);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center, center + dir * radius, gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: nodes[i].label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: label,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = center + dir * (radius + 16);
      tp.paint(canvas, Offset(lp.dx - tp.width / 2, lp.dy - tp.height / 2));
    }

    // Headroom polygon.
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + (2 * math.pi * i / n);
      final frac = (nodes[i].free / 100).clamp(0.0, 1.0);
      pts.add(center + Offset(math.cos(a), math.sin(a)) * (radius * frac));
    }
    final poly = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 1; i < pts.length; i++) {
      poly.lineTo(pts[i].dx, pts[i].dy);
    }
    poly.close();
    final tint = fleetColor(avgFree);
    canvas.drawPath(poly, Paint()..color = tint.withValues(alpha: 0.16));
    canvas.drawPath(
      poly,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = tint.withValues(alpha: 0.85),
    );
    for (var i = 0; i < pts.length; i++) {
      canvas.drawCircle(
        pts[i],
        3.5,
        Paint()..color = fleetColor(nodes[i].free),
      );
    }

    // Center reading.
    final ctp = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: '${avgFree.round()}',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: tint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          TextSpan(
            text: '%',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: tint,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    ctp.paint(
      canvas,
      Offset(center.dx - ctp.width / 2, center.dy - ctp.height / 2),
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.nodes != nodes;
}

/// Horizontal ranking bars: free headroom per provider, tightest first.
class _RankPainter extends CustomPainter {
  final List<_Node> nodes;
  final bool dark;
  final Color fg;
  final Color muted;
  _RankPainter(this.nodes, this.dark, this.fg, this.muted);

  @override
  void paint(Canvas canvas, Size size) {
    final track = dark ? const Color(0xFF22262E) : const Color(0xFFEDEEF1);
    final rowH = size.height / nodes.length;
    const labelW = 78.0;
    const valW = 44.0;
    final barL = labelW + 6;
    final barW = size.width - barL - valW;
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final cy = i * rowH + rowH / 2;
      final bh = math.min(14.0, rowH - 8);
      _text(
        canvas,
        n.label,
        Offset(0, cy),
        labelW,
        fg,
        11,
        FontWeight.w600,
        right: false,
        vCenter: true,
      );
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(barL + barW / 2, cy),
          width: barW,
          height: bh,
        ),
        const Radius.circular(3),
      );
      canvas.drawRRect(r, Paint()..color = track);
      final w = (n.free / 100).clamp(0.0, 1.0) * barW;
      if (w > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(barL, cy - bh / 2, w, bh),
            const Radius.circular(3),
          ),
          Paint()..color = fleetColor(n.free),
        );
      }
      _text(
        canvas,
        '${n.free.round()}%',
        Offset(size.width - valW, cy),
        valW,
        fg,
        11,
        FontWeight.w700,
        right: true,
        vCenter: true,
      );
    }
  }

  void _text(
    Canvas canvas,
    String s,
    Offset at,
    double width,
    Color color,
    double size,
    FontWeight weight, {
    required bool right,
    required bool vCenter,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: right ? TextAlign.right : TextAlign.left,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: width);
    final dx = right ? at.dx + (width - tp.width) : at.dx;
    final dy = vCenter ? at.dy - tp.height / 2 : at.dy;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_RankPainter old) => old.nodes != nodes;
}

/// Donut of consumption share: how spend concentrates across providers.
class _DonutPainter extends CustomPainter {
  final List<_Node> nodes;
  final bool dark;
  final Color fg;
  final Color muted;
  _DonutPainter(this.nodes, this.dark, this.fg, this.muted);

  static const _palette = [
    Color(0xFF58A6FF),
    Color(0xFFBC8CFF),
    Color(0xFF3FB950),
    Color(0xFFD29922),
    Color(0xFFDB6D28),
    Color(0xFFF85149),
    Color(0xFF39C5CF),
    Color(0xFFE685B5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final spenders = [
      for (final n in nodes)
        if (n.used > 0.5) n,
    ];
    final total = spenders.fold<double>(0, (a, n) => a + n.used);
    if (total <= 0) return;
    final center = Offset(size.height / 2 + 4, size.height / 2);
    final outer = size.height / 2 - 6;
    final inner = outer * 0.58;
    var start = -math.pi / 2;
    for (var i = 0; i < spenders.length; i++) {
      final sweep = 2 * math.pi * (spenders[i].used / total);
      final paint = Paint()..color = _palette[i % _palette.length];
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: outer),
        start,
        sweep - 0.02,
        true,
        paint,
      );
      start += sweep;
    }
    // Punch the hole.
    canvas.drawCircle(
      center,
      inner,
      Paint()..color = dark ? const Color(0xFF14171D) : Colors.white,
    );

    // Legend to the right of the donut.
    final lx = center.dx + outer + 14;
    var ly = center.dy - (spenders.length * 9.0);
    for (var i = 0; i < spenders.length; i++) {
      final c = _palette[i % _palette.length];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(lx, ly + 2, 9, 9),
          const Radius.circular(2),
        ),
        Paint()..color = c,
      );
      final pct = (spenders[i].used / total * 100).round();
      final tp = TextPainter(
        text: TextSpan(
          children: [
            TextSpan(
              text: '${spenders[i].label}  ',
              style: TextStyle(fontSize: 10.5, color: fg),
            ),
            TextSpan(
              text: '$pct%',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: muted,
              ),
            ),
          ],
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: math.max(40, size.width - lx - 4));
      tp.paint(canvas, Offset(lx + 14, ly));
      ly += 18;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.nodes != nodes;
}

/// Floating distribution bars: the p10..p90 free range with a p50 tick, so you
/// see how steady (narrow) or swingy (wide) each provider runs.
class _DistPainter extends CustomPainter {
  final List<_Node> nodes;
  final bool dark;
  final Color fg;
  final Color muted;
  _DistPainter(this.nodes, this.dark, this.fg, this.muted);

  @override
  void paint(Canvas canvas, Size size) {
    final track = dark ? const Color(0xFF22262E) : const Color(0xFFEDEEF1);
    final rowH = size.height / nodes.length;
    const labelW = 78.0;
    final scaleL = labelW + 6;
    final scaleW = size.width - scaleL - 8;
    double x(double pct) => scaleL + (pct / 100).clamp(0.0, 1.0) * scaleW;

    // Faint 0/50/100 guides.
    final guide = Paint()
      ..color = track
      ..strokeWidth = 1;
    for (final g in const [0.0, 50.0, 100.0]) {
      canvas.drawLine(Offset(x(g), 0), Offset(x(g), size.height), guide);
    }

    for (var i = 0; i < nodes.length; i++) {
      final ins = nodes[i].insights!;
      final p10 = ins.p10, p50 = ins.p50, p90 = ins.p90;
      final cy = i * rowH + rowH / 2;
      _label(canvas, nodes[i].label, cy, labelW);
      if (p10 == null || p90 == null) continue;
      final bh = math.min(12.0, rowH - 10);
      final left = x(p10), right = x(p90);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, cy - bh / 2, right, cy + bh / 2),
          const Radius.circular(3),
        ),
        Paint()
          ..color = fleetColor(((p10) + (p90)) / 2).withValues(alpha: 0.55),
      );
      if (p50 != null) {
        canvas.drawRect(
          Rect.fromLTWH(x(p50) - 1, cy - bh / 2 - 2, 2, bh + 4),
          Paint()..color = fg,
        );
      }
    }
  }

  void _label(Canvas canvas, String s, double cy, double width) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: width);
    tp.paint(canvas, Offset(0, cy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_DistPainter old) => old.nodes != nodes;
}

/// Fleet 7x24 heatmap with weekday labels: aggregate best-time-to-run.
class _FleetHeatmapPainter extends CustomPainter {
  final List<List<double?>> grid;
  final bool dark;
  final Color muted;
  _FleetHeatmapPainter(this.grid, this.dark, this.muted);

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void paint(Canvas canvas, Size size) {
    const cols = 24, rows = 7;
    const labelW = 30.0;
    const axisH = 14.0;
    final gw = size.width - labelW;
    final gh = size.height - axisH;
    final cw = gw / cols, ch = gh / rows;
    final empty = dark ? const Color(0xFF20242B) : const Color(0xFFEDEEF1);
    for (var r = 0; r < rows; r++) {
      final tp = TextPainter(
        text: TextSpan(
          text: _days[r],
          style: TextStyle(fontSize: 9, color: muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, r * ch + ch / 2 - tp.height / 2));
      for (var c = 0; c < cols; c++) {
        final v = grid[r][c];
        canvas.drawRect(
          Rect.fromLTWH(labelW + c * cw, r * ch, cw - 0.6, ch - 0.6),
          Paint()..color = v == null ? empty : fleetColor(v),
        );
      }
    }
    for (final h in const [0, 6, 12, 18]) {
      final tp = TextPainter(
        text: TextSpan(
          text: h == 0
              ? '12a'
              : (h == 12 ? '12p' : (h < 12 ? '${h}a' : '${h - 12}p')),
          style: TextStyle(fontSize: 8.5, color: muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(labelW + h * cw, gh + 2));
    }
  }

  @override
  bool shouldRepaint(_FleetHeatmapPainter old) => old.grid != grid;
}
