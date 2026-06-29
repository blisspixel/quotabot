import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:window_manager/window_manager.dart';

import 'typography.dart';

/// Health color on the shared green-to-red scale (input is remaining free %).
Color fleetColor(num freePct) {
  if (freePct >= 50) return const Color(0xFF3FB950);
  if (freePct >= 25) return const Color(0xFFD29922);
  if (freePct > 0) return const Color(0xFFDB6D28);
  return const Color(0xFFF85149);
}

/// The Oracle of Pythagoras.
///
/// The cult permits exactly one emoji in this entire program, and refuses to let
/// a mere human choose it. The glyph is derived, from the fleet's own numbers,
/// through a deliberately overwrought chain of number theory. That ceremony is
/// the joke. [free] and [used] are parallel per-provider percent lists.
///
/// Returns the single sanctioned glyph and a terse, smug proof of why.
({String glyph, String proof}) pythagorasOracle(
  List<double> free,
  List<double> used,
) {
  if (free.isEmpty) {
    return (
      glyph: '\u{1F311}',
      proof: 'the void before counting (no live providers)',
    );
  }
  final n = free.length;
  final pool = free.reduce((a, b) => a + b) / n;

  if (pool <= 0.5) {
    return (
      glyph: '\u{1FAA6}',
      proof: 'Sigma(free) -> 0; the quota gods are sated',
    );
  }

  const phi = 1.6180339887498949;
  if ((pool - 100 * (phi - 1)).abs() <= 1.5) {
    return (
      glyph: '\u{1F41A}',
      proof: 'pool ~= 100(phi-1) = 61.8%; the logarithmic spiral approves',
    );
  }

  final r = free.map((f) => f.round()).where((v) => v > 0).toSet().toList()
    ..sort();
  for (var i = 0; i < r.length; i++) {
    for (var j = i + 1; j < r.length; j++) {
      for (var k = j + 1; k < r.length; k++) {
        if (r[i] * r[i] + r[j] * r[j] == r[k] * r[k]) {
          return (
            glyph: '\u{1F4D0}',
            proof:
                'a^2+b^2=c^2 walks among your quotas (${r[i]},${r[j]},${r[k]})',
          );
        }
      }
    }
  }

  final spenders = used.where((u) => u > 0.5).toList();
  if (spenders.isEmpty) {
    return (
      glyph: '\u{1F315}',
      proof: 'every window full; the monad is undisturbed',
    );
  }

  final tot = spenders.reduce((a, b) => a + b);
  var h = 0.0;
  for (final u in spenders) {
    final p = u / tot;
    h -= p * math.log(p);
  }
  final evenness = spenders.length < 2 ? 0.0 : h / math.log(spenders.length);

  if (_isPrime(n) && evenness >= 0.9) {
    return (
      glyph: '\u{1F3BC}',
      proof:
          'prime fleet ($n) in near-uniform burn (H=${evenness.toStringAsFixed(2)}): musica universalis',
    );
  }

  if (evenness <= 0.34) {
    return (
      glyph: '\u{1F5FF}',
      proof:
          'consumption entropy collapses (H=${evenness.toStringAsFixed(2)}); one node bears the load',
    );
  }

  final dr = _digitalRoot(pool.round());
  const wheel = [
    '\u{1F312}',
    '\u{1F313}',
    '\u{1F314}',
    '\u{1F316}',
    '\u{1F317}',
    '\u{1F318}',
    '\u{1F31B}',
    '\u{1F31D}',
    '\u{1F9EE}', // the abacus: 9, the indestructible digital root
  ];
  return (
    glyph: wheel[dr - 1],
    proof:
        'digital root of ${pool.round()}% is $dr; the abacus turns the wheel',
  );
}

bool _isPrime(int n) {
  if (n < 2) return false;
  for (var i = 2; i * i <= n; i++) {
    if (n % i == 0) return false;
  }
  return true;
}

/// Repeated digit sum, 1..9 (the indestructible residue mod 9).
int _digitalRoot(int n) => n <= 0 ? 9 : 1 + (n - 1) % 9;

/// The time window the dashboard is showing.
enum FleetRange {
  now('Now', null),
  week('7d', 7),
  quarter('90d', 90);

  const FleetRange(this.label, this.days);
  final String label;
  final int? days; // null = live snapshot
}

/// One provider reduced to the numbers a chart needs.
class _Node {
  final String label;
  final double free; // remaining headroom percent, 0..100
  final int? resetsAt;
  Insights? insights; // filled per range for historical views
  _Node(this.label, this.free, this.resetsAt);
  double get used => (100 - free).clamp(0, 100);
}

/// Analytics over the whole fleet, switchable by time range. Lives in the same
/// window as the strip and scrolls like a phone. The Now view is a live read;
/// the 7d/90d views recompute from the raw history buckets.
class FleetScreen extends StatefulWidget {
  final List<ProviderQuota> data;
  final Map<String, List<HeadroomBucket>> buckets;
  final bool dark;

  const FleetScreen({
    super.key,
    required this.data,
    required this.buckets,
    required this.dark,
  });

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  FleetRange _range = FleetRange.now;

  bool get dark => widget.dark;

  @override
  Widget build(BuildContext context) {
    final bg = dark ? const Color(0xFF0C0E12) : const Color(0xFFF4F5F7);
    final panel = dark ? const Color(0xFF14171D) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF111317);
    final muted = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
    final line = dark ? const Color(0xFF262B33) : const Color(0xFFE3E5EA);
    final c = (panel: panel, fg: fg, muted: muted, line: line);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nodes = <_Node>[];
    for (final q in widget.data) {
      if (q.isLocal) continue;
      final h = providerHeadroom(q, now);
      if (h == null) continue;
      nodes.add(_Node(q.displayName, h, bindingWindow(q, now)?.resetsAt));
    }
    nodes.sort((a, b) => a.free.compareTo(b.free)); // tightest first

    final oracle = pythagorasOracle(
      [for (final n in nodes) n.free],
      [for (final n in nodes) n.used],
    );

    return Scaffold(
      // Transparent so the rounded card shows on the frameless window, matching
      // the main quota view's corners instead of filling square to the edges.
      backgroundColor: Colors.transparent,
      body: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line),
        ),
        child: Column(
          children: [
            _bar(context, c, oracle),
            _tabs(c),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                child: _range == FleetRange.now
                    ? _liveView(nodes, now, c)
                    : _historyView(now, c),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- live (Now) ------------------------------------------------------

  Widget _liveView(
    List<_Node> nodes,
    int now,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    if (nodes.isEmpty) {
      return _card(c, 'HEADROOM', 'free now', _empty('no live data', c.muted));
    }
    final pool =
        nodes.map((n) => n.free).reduce((a, b) => a + b) / nodes.length;
    final freest = nodes.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _chip(
                '${pool.round()}%',
                'pool free',
                fleetColor(pool),
                c,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _chip(
                freest.label,
                'most headroom (${freest.free.round()}%)',
                fleetColor(freest.free),
                c,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _card(
          c,
          'HEADROOM',
          'free now, tightest first',
          SizedBox(
            height: nodes.length * 30.0,
            child: CustomPaint(painter: _BarsPainter(nodes, now, dark, c.fg)),
          ),
        ),
        const SizedBox(height: 10),
        _card(
          c,
          'CONSUMPTION',
          'share of total spend',
          SizedBox(
            height: 150,
            child: nodes.every((n) => n.used <= 0.5)
                ? _empty('nothing spent yet', c.muted)
                : CustomPaint(
                    painter: _DonutPainter(nodes, dark, c.fg, c.muted),
                  ),
          ),
        ),
        _missingNote(now, c),
      ],
    );
  }

  /// Providers that exist but have no live quota right now (e.g. an expired
  /// token), so they are absent from the charts above. Naming them avoids the
  /// "where did X go?" confusion.
  Widget _missingNote(
    int now,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    final missing = [
      for (final q in widget.data)
        if (!q.isLocal && providerHeadroom(q, now) == null) q.displayName,
    ];
    if (missing.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 2, right: 2),
      child: Text(
        'no live data: ${missing.join(', ')} (reopen the app or reconnect)',
        style: TextStyle(
          fontSize: AppType.caption,
          color: c.muted,
          height: 1.3,
        ),
      ),
    );
  }

  // ---- history (7d / 90d) ---------------------------------------------

  Widget _historyView(
    int now,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    final tz = DateTime.now().timeZoneOffset;
    final days = _range.days!;
    final cutoff = now - days * 86400;

    final stats = <_Node>[];
    final grids = <List<List<double?>>>[];
    var maxSamples = 0;
    var maxSpan = 0;
    for (final q in widget.data) {
      if (q.isLocal) continue;
      final all = widget.buckets[q.provider] ?? const <HeadroomBucket>[];
      final win = [
        for (final b in all)
          if (b.start >= cutoff) b,
      ];
      if (win.isEmpty) continue;
      final ins = Insights.from(win, now, tzOffset: tz);
      if (ins.samples == 0) continue;
      final node = _Node(q.displayName, ins.p50 ?? 0, null)..insights = ins;
      stats.add(node);
      grids.add(weekHourHeatmap(win, tzOffset: tz));
      maxSamples = math.max(maxSamples, ins.samples);
      maxSpan = math.max(maxSpan, ins.spanDays);
    }
    stats.sort(
      (a, b) => (a.insights!.p50 ?? 0).compareTo(b.insights!.p50 ?? 0),
    );

    if (stats.isEmpty) {
      return _card(
        c,
        'OVER $days DAYS',
        'history',
        _empty('history is still warming up', c.muted),
      );
    }

    final grid = _mergeGrids(grids);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          c,
          'DISTRIBUTION',
          'free % p10-p90, median tick',
          SizedBox(
            height: stats.length * 26.0,
            child: CustomPaint(
              painter: _DistPainter(stats, dark, c.fg, c.muted),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _card(
          c,
          'RELIABILITY & TREND',
          'usable rate, drift per day',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final n in stats) _statRow(n.label, n.insights!, c),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _card(
          c,
          'BEST TIME TO RUN',
          'mean free % by weekday x hour, local',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 120,
                child: grid == null
                    ? _empty('not enough data', c.muted)
                    : CustomPaint(
                        painter: _HeatmapPainter(grid, dark, c.muted),
                      ),
              ),
              const SizedBox(height: 6),
              _legend(c.muted),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '$maxSpan-day span, up to $maxSamples samples per provider',
            style: TextStyle(fontSize: AppType.label, color: c.muted),
          ),
        ),
      ],
    );
  }

  Widget _statRow(
    String label,
    Insights ins,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    final rel = ins.reliability;
    final trend = ins.trendPerDay;
    final r2 = ins.trendConfidence;
    String trendStr;
    Color trendCol;
    if (trend == null || trend.abs() < 0.05) {
      trendStr = 'flat';
      trendCol = c.muted;
    } else {
      final up = trend > 0;
      trendStr =
          '${up ? '▲' : '▼'} ${trend.abs().toStringAsFixed(1)}%/d'
          '${r2 == null ? '' : ' r2 ${r2.toStringAsFixed(2)}'}';
      trendCol = up ? const Color(0xFF3FB950) : const Color(0xFFDB6D28);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: FontWeight.w600,
                color: c.fg,
              ),
            ),
          ),
          Expanded(
            child: Text(
              rel == null ? '--' : 'usable ${(rel * 100).round()}%',
              style: TextStyle(
                fontSize: AppType.bodySmall,
                color: c.fg,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(
            trendStr,
            style: TextStyle(
              fontSize: AppType.bodySmall,
              fontWeight: FontWeight.w600,
              color: trendCol,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  List<List<double?>>? _mergeGrids(List<List<List<double?>>> grids) {
    final sum = List.generate(7, (_) => List<double>.filled(24, 0));
    final cnt = List.generate(7, (_) => List<int>.filled(24, 0));
    var any = false;
    for (final g in grids) {
      if (g.length != 7) continue;
      for (var d = 0; d < 7; d++) {
        for (var h = 0; h < 24; h++) {
          final v = g[d][h];
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
    ({Color panel, Color fg, Color muted, Color line}) c,
    ({String glyph, String proof}) oracle,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      child: Row(
        children: [
          // Back is a normal tap target (not inside the window-drag area, which
          // would otherwise swallow the click as a drag).
          TextButton.icon(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.arrow_back_rounded, size: 18, color: c.fg),
            label: Text(
              'Back',
              style: TextStyle(
                fontSize: AppType.subtitle,
                fontWeight: FontWeight.w600,
                color: c.fg,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 2),
          // Only the title area drags the window.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              child: Row(
                children: [
                  Text(
                    'Quota Analytics',
                    style: TextStyle(
                      fontSize: AppType.title,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                      color: c.fg,
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
          // One math-derived glyph. No label; the curious can hover.
          Tooltip(
            message: oracle.proof,
            waitDuration: const Duration(milliseconds: 400),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Opacity(
                opacity: 0.85,
                child: Text(
                  oracle.glyph,
                  style: const TextStyle(fontSize: AppType.glyph),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabs(({Color panel, Color fg, Color muted, Color line}) c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: c.line),
        ),
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            for (final r in FleetRange.values)
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _range = r),
                  child: Container(
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _range == r
                          ? (dark
                                ? const Color(0xFF24303B)
                                : const Color(0xFFE7EBF0))
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      r.label,
                      style: TextStyle(
                        fontSize: AppType.subtitle,
                        fontWeight: FontWeight.w700,
                        color: _range == r ? c.fg : c.muted,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    String value,
    String label,
    Color accent,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.stat,
              fontWeight: FontWeight.w800,
              color: accent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppType.caption, color: c.muted),
          ),
        ],
      ),
    );
  }

  Widget _card(
    ({Color panel, Color fg, Color muted, Color line}) c,
    String title,
    String subtitle,
    Widget child,
  ) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: AppType.bodySmall,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                  color: c.fg,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppType.caption, color: c.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _empty(String text, Color muted) => SizedBox(
    height: 60,
    child: Center(
      child: Text(
        text,
        style: TextStyle(fontSize: AppType.bodySmall, color: muted),
      ),
    ),
  );

  Widget _legend(Color muted) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        'spent',
        style: TextStyle(fontSize: AppType.small, color: muted),
      ),
      const SizedBox(width: 6),
      for (final col in const [
        Color(0xFFF85149),
        Color(0xFFDB6D28),
        Color(0xFFD29922),
        Color(0xFF3FB950),
      ])
        Container(width: 16, height: 8, color: col),
      const SizedBox(width: 6),
      Text(
        'free',
        style: TextStyle(fontSize: AppType.small, color: muted),
      ),
    ],
  );
}

// ---- painters ----------------------------------------------------------

/// Horizontal headroom bars: free % per provider with its reset, tightest first.
class _BarsPainter extends CustomPainter {
  final List<_Node> nodes;
  final int now;
  final bool dark;
  final Color fg;
  _BarsPainter(this.nodes, this.now, this.dark, this.fg);

  @override
  void paint(Canvas canvas, Size size) {
    final track = dark ? const Color(0xFF22262E) : const Color(0xFFEDEEF1);
    final rowH = size.height / nodes.length;
    const labelW = 70.0;
    const valW = 78.0;
    final barL = labelW + 6;
    final barW = size.width - barL - valW - 6;
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final cy = i * rowH + rowH / 2;
      final bh = math.min(13.0, rowH - 9);
      _line(canvas, n.label, 0, cy, labelW, fg, FontWeight.w600, false);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(barL, cy - bh / 2, barW, bh),
          const Radius.circular(3),
        ),
        Paint()..color = track,
      );
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
      final reset = _reset(n.resetsAt, now);
      _valueLine(canvas, '${n.free.round()}%', reset, size.width, valW, cy);
    }
  }

  void _line(
    Canvas canvas,
    String s,
    double x,
    double cy,
    double width,
    Color color,
    FontWeight weight,
    bool right,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: AppType.bodySmall,
          fontWeight: weight,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: width);
    tp.paint(canvas, Offset(x, cy - tp.height / 2));
  }

  void _valueLine(
    Canvas canvas,
    String pct,
    String reset,
    double rightEdge,
    double width,
    double cy,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: pct,
            style: TextStyle(
              fontSize: AppType.bodySmall,
              fontWeight: FontWeight.w700,
              color: fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (reset.isNotEmpty)
            TextSpan(
              text: '  $reset',
              style: TextStyle(
                fontSize: AppType.label,
                color: dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280),
              ),
            ),
        ],
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
      maxLines: 1,
    )..layout(maxWidth: width);
    tp.paint(canvas, Offset(rightEdge - tp.width, cy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.nodes != nodes;
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
    final center = Offset(size.height / 2 + 2, size.height / 2);
    final outer = size.height / 2 - 6;
    final inner = outer * 0.58;
    var start = -math.pi / 2;
    for (var i = 0; i < spenders.length; i++) {
      final sweep = 2 * math.pi * (spenders[i].used / total);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: outer),
        start,
        sweep - 0.02,
        true,
        Paint()..color = _palette[i % _palette.length],
      );
      start += sweep;
    }
    canvas.drawCircle(
      center,
      inner,
      Paint()..color = dark ? const Color(0xFF14171D) : Colors.white,
    );

    final lx = center.dx + outer + 14;
    var ly = center.dy - (spenders.length * 9.0);
    for (var i = 0; i < spenders.length; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(lx, ly + 2, 9, 9),
          const Radius.circular(2),
        ),
        Paint()..color = _palette[i % _palette.length],
      );
      final pct = (spenders[i].used / total * 100).round();
      final tp = TextPainter(
        text: TextSpan(
          children: [
            TextSpan(
              text: '${spenders[i].label}  ',
              style: TextStyle(fontSize: AppType.caption, color: fg),
            ),
            TextSpan(
              text: '$pct%',
              style: TextStyle(
                fontSize: AppType.caption,
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

/// Floating distribution bars: the p10..p90 free range with a p50 tick.
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
    const labelW = 70.0;
    final scaleL = labelW + 6;
    final scaleW = size.width - scaleL - 8;
    double x(double pct) => scaleL + (pct / 100).clamp(0.0, 1.0) * scaleW;

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
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x(p10), cy - bh / 2, x(p90), cy + bh / 2),
          const Radius.circular(3),
        ),
        Paint()..color = fleetColor((p10 + p90) / 2).withValues(alpha: 0.55),
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
        style: TextStyle(
          fontSize: AppType.bodySmall,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
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
class _HeatmapPainter extends CustomPainter {
  final List<List<double?>> grid;
  final bool dark;
  final Color muted;
  _HeatmapPainter(this.grid, this.dark, this.muted);

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
          style: TextStyle(fontSize: AppType.micro, color: muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, r * ch + ch / 2 - tp.height / 2));
      for (var col = 0; col < cols; col++) {
        final v = grid[r][col];
        canvas.drawRect(
          Rect.fromLTWH(labelW + col * cw, r * ch, cw - 0.6, ch - 0.6),
          Paint()..color = v == null ? empty : fleetColor(v),
        );
      }
    }
    for (final hh in const [0, 6, 12, 18]) {
      final tp = TextPainter(
        text: TextSpan(
          text: hh == 0
              ? '12a'
              : (hh == 12 ? '12p' : (hh < 12 ? '${hh}a' : '${hh - 12}p')),
          style: TextStyle(fontSize: AppType.micro, color: muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(labelW + hh * cw, gh + 2));
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) => old.grid != grid;
}

/// Compact reset countdown, e.g. "3h2m", "2d4h", "ready".
String _reset(int? resetsAt, int now) {
  if (resetsAt == null) return '';
  var s = resetsAt - now;
  if (s <= 0) return 'ready';
  final d = s ~/ 86400;
  s %= 86400;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (d > 0) return '${d}d${h}h';
  if (h > 0) return '${h}h${m}m';
  return '${m}m';
}
