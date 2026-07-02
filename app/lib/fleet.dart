import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/litellm_metrics.dart';
import 'package:quotabot_collector/models.dart';

import 'profile_ui.dart' show quotaDisplayKey;
import 'theme_spec.dart';
import 'typography.dart';

/// Health color on the shared green-to-red scale (input is remaining free %).
Color fleetColor(num freePct) {
  if (freePct >= 50) return const Color(0xFF3FB950);
  if (freePct >= 25) return const Color(0xFFD29922);
  if (freePct > 0) return const Color(0xFFDB6D28);
  return const Color(0xFFF85149);
}

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

/// Analytics over the whole fleet, switchable by time range. Rendered as a
/// body inside the main dashboard, under the same header and menu as the
/// quota view, so switching views never changes the window chrome. The Now
/// view is a live read; the 7d/90d views recompute from the raw history
/// buckets.
class FleetScreen extends StatefulWidget {
  final List<ProviderQuota> data;
  final Map<String, List<HeadroomBucket>> buckets;
  final RoutedRequestSummary? routedRequests;
  final bool dark;
  final FleetRange initialRange;

  const FleetScreen({
    super.key,
    required this.data,
    required this.buckets,
    required this.dark,
    this.routedRequests,
    this.initialRange = FleetRange.now,
  });

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  late FleetRange _range = widget.initialRange;

  bool get dark => widget.dark;

  /// The history buckets for [q], keyed the way the dashboard stores them
  /// (provider|account when the account is specific), with a plain provider-id
  /// fallback for callers that key by provider only.
  List<HeadroomBucket> _bucketsFor(ProviderQuota q) =>
      widget.buckets[quotaDisplayKey(q)] ??
      widget.buckets[q.provider] ??
      const <HeadroomBucket>[];

  @override
  Widget build(BuildContext context) {
    final chrome = AppChromeTheme.of(context);
    final c = (
      panel: chrome.card,
      fg: chrome.foreground,
      muted: chrome.muted,
      line: chrome.tileBorder,
    );

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nodes = <_Node>[];
    for (final q in widget.data) {
      if (q.isLocal) continue;
      final h = providerHeadroom(q, now);
      if (h == null) continue;
      nodes.add(_Node(q.displayName, h, bindingWindow(q, now)?.resetsAt));
    }
    nodes.sort((a, b) => a.free.compareTo(b.free)); // tightest first

    return Column(
      children: [
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
    );
  }

  // ---- live (Now) ------------------------------------------------------

  double? _averageHeadroom(List<_Node> nodes) {
    if (nodes.isEmpty) return null;
    return nodes.map((n) => n.free).reduce((a, b) => a + b) / nodes.length;
  }

  Widget _liveView(
    List<_Node> nodes,
    int now,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    if (nodes.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(c, 'HEADROOM', 'free now', _empty('no live data', c.muted)),
          _routedRequestsCard(now, c),
        ],
      );
    }
    final pool = _averageHeadroom(nodes)!;
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
          'share of total usage',
          SizedBox(
            height: 150,
            child: nodes.every((n) => n.used <= 0.5)
                ? _empty('nothing spent yet', c.muted)
                : CustomPaint(
                    painter: _DonutPainter(nodes, dark, c.fg, c.muted),
                  ),
          ),
        ),
        _routedRequestsCard(now, c),
        _missingNote(now, c),
      ],
    );
  }

  Widget _routedRequestsCard(
    int now,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    final summary = widget.routedRequests;
    if (summary == null || !summary.hasData) return const SizedBox.shrink();
    final topServed = summary.topServedModels
        .map((model) => '${model.model} (${model.count})')
        .join(', ');
    final top = topServed.isEmpty
        ? 'no served-model breakdown'
        : 'top served: $topServed';
    final last = summary.lastAt == null
        ? 'last request unknown'
        : 'last request ${_age(summary.lastAt!, now)} ago';
    final spend = _spendLine(summary);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: _card(
        c,
        'ROUTED REQUESTS',
        'LiteLLM proxy, local JSONL',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _routeMetric(
                    '${summary.totalRequests}',
                    '${summary.routedRequests} routed',
                    const Color(0xFF58A6FF),
                    c,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _routeMetric(
                    _compactInt(summary.totalTokens),
                    'tokens',
                    const Color(0xFF3FB950),
                    c,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _routeMetric(
                    _money(summary.cost),
                    'tracked cost',
                    const Color(0xFFD29922),
                    c,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              spend,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.3,
                color: summary.paidApiRequests > 0
                    ? const Color(0xFFD29922)
                    : c.muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$top | $last',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.3,
                color: c.muted,
              ),
            ),
          ],
        ),
      ),
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
    final fleetBuckets = <HeadroomBucket>[];
    final rawInsights = <String, Insights>{};
    final insightKeys = <_Node, String>{};
    var maxSamples = 0;
    var maxSpan = 0;
    for (final q in widget.data) {
      if (q.isLocal) continue;
      final all = _bucketsFor(q);
      final win = [
        for (final b in all)
          if (b.start >= cutoff) b,
      ];
      if (win.isEmpty) continue;
      fleetBuckets.addAll(win);
      final ins = Insights.from(win, now, tzOffset: tz);
      if (ins.samples == 0) continue;
      final node = _Node(q.displayName, ins.p50 ?? 0, null)..insights = ins;
      final insightKey = rawInsights.length.toString();
      rawInsights[insightKey] = ins;
      insightKeys[node] = insightKey;
      stats.add(node);
      grids.add(smoothedWeekHourHeatmap(win, tzOffset: tz));
      maxSamples = math.max(maxSamples, ins.samples);
      maxSpan = math.max(maxSpan, ins.spanDays);
    }
    final shrunkInsights = shrinkInsightsReliability(rawInsights);
    for (final node in stats) {
      node.insights = shrunkInsights[insightKeys[node]] ?? node.insights;
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
    final bestWindows = bestWeekHourWindows(
      fleetBuckets,
      tzOffset: tz,
      limit: 3,
    );
    int? nextReset;
    for (final quota in widget.data) {
      if (quota.isLocal) continue;
      final reset = bindingWindow(quota, now)?.resetsAt;
      if (reset == null || reset <= now) continue;
      if (nextReset == null || reset < nextReset) nextReset = reset;
    }
    final scheduleHint = weekHourScheduleHint(
      bestWindows,
      now,
      resetsAt: nextReset,
      tzOffset: tz,
    );
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
          'CALENDAR',
          'sampled days, oldest to newest',
          SizedBox(
            height: stats.length * 18.0,
            child: CustomPaint(
              painter: _CalendarPainter(
                stats,
                dark,
                c.fg,
                c.muted,
                math.min(days, kRetentionDays),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _card(
          c,
          'BEST TIME TO RUN',
          'mean free % by weekday/hour',
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
              if (bestWindows.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _bestTimeLine(bestWindows),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.25,
                    color: c.fg,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (scheduleHint != null) ...[
                const SizedBox(height: 4),
                Text(
                  'next strong slot ${scheduleHint.summary}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.25,
                    color: c.fg,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
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

  String _bestTimeLine(List<WeekHourWindow> windows) =>
      'Best: ${windows.map((window) => window.summary).join(' | ')}';

  // ---- chrome ----------------------------------------------------------

  Widget _tabs(({Color panel, Color fg, Color muted, Color line}) c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(8),
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
                          ? c.line.withValues(alpha: dark ? 0.82 : 0.58)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      r.label,
                      style: TextStyle(
                        fontSize: AppType.bodySmall,
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(11),
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
              fontWeight: FontWeight.w700,
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

  Widget _routeMetric(
    String value,
    String label,
    Color accent,
    ({Color panel, Color fg, Color muted, Color line}) c,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.stat,
            fontWeight: FontWeight.w700,
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
    );
  }

  Widget _card(
    ({Color panel, Color fg, Color muted, Color line}) c,
    String title,
    String subtitle,
    Widget child,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(11),
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

  String _compactInt(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toString();
  }

  String _money(double value) {
    if (value <= 0) return r'$0.00';
    if (value < 0.01) return '<\$0.01';
    return '\$${value.toStringAsFixed(2)}';
  }

  String _spendLine(RoutedRequestSummary summary) {
    final parts = [
      if (summary.localRequests > 0) '${summary.localRequests} local',
      if (summary.quotaPlanRequests > 0) '${summary.quotaPlanRequests} quota',
      if (summary.paidApiRequests > 0)
        '${summary.paidApiRequests} paid API (${_money(summary.paidApiCost)})',
      if (summary.unknownSpendRequests > 0)
        '${summary.unknownSpendRequests} unknown',
    ];
    return parts.isEmpty ? 'spend: no labels' : 'spend: ${parts.join(' | ')}';
  }

  String _age(int then, int now) {
    final seconds = math.max(0, now - then);
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    return '${seconds ~/ 86400}d';
  }
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

/// Compact sampled-day contribution calendar, one row per provider.
class _CalendarPainter extends CustomPainter {
  final List<_Node> nodes;
  final bool dark;
  final Color fg;
  final Color muted;
  final int maxDays;

  _CalendarPainter(this.nodes, this.dark, this.fg, this.muted, this.maxDays);

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;
    final rowH = size.height / nodes.length;
    const labelW = 70.0;
    final availableW = math.max(1.0, size.width - labelW - 8);
    for (var i = 0; i < nodes.length; i++) {
      final cy = i * rowH + rowH / 2;
      _label(canvas, nodes[i].label, cy, labelW);
      final days = nodes[i].insights!.contributionCalendar;
      if (days.isEmpty) continue;
      final count = math.min(math.max(1, maxDays), days.length);
      final visible = days.sublist(days.length - count);
      final gap = count > 45 ? 0.8 : 1.2;
      final cellW = ((availableW - gap * (count - 1)) / count).clamp(2.0, 8.0);
      final cellH = math.min(10.0, math.max(3.0, rowH - 6));
      final startX = labelW + 6;
      for (var d = 0; d < visible.length; d++) {
        final day = visible[d];
        final rect = Rect.fromLTWH(
          startX + d * (cellW + gap),
          cy - cellH / 2,
          cellW,
          cellH,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(2)),
          Paint()..color = _dayColor(day),
        );
      }
    }
  }

  Color _dayColor(ContributionDay day) {
    if (day.spent) return const Color(0xFFF85149);
    if (day.mixed) return const Color(0xFFDB6D28);
    final alpha = day.intensity <= 1 ? (dark ? 0.55 : 0.65) : 0.9;
    return fleetColor(day.meanFreePercent).withValues(alpha: alpha);
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
  bool shouldRepaint(_CalendarPainter old) =>
      old.nodes != nodes ||
      old.dark != dark ||
      old.fg != fg ||
      old.muted != muted ||
      old.maxDays != maxDays;
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
