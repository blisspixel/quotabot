/// Pure renderer for the `quotabot top` live dashboard.
///
/// [renderTopFrame] turns a snapshot into the content lines of one frame and
/// nothing else: no clock read, no terminal control codes, no I/O. The watch
/// loop in `bin/collect.dart` owns the cursor, the alternate screen, the
/// synchronized-output wrapper, and the refresh timing; keeping all of that out
/// of here means the entire layout, color logic, and binding-window collapse are
/// unit tested directly against fixtures (the repo's pure-core rule).
library;

import 'dart:convert';

import 'analysis.dart';
import 'ansi.dart';
import 'models.dart';
import 'palette.dart';

/// Builds the OSC 52 terminal escape that asks the terminal to copy [text] to
/// the system clipboard. This needs no external process or platform clipboard
/// dependency: the terminal itself does the copy, on the many terminals that
/// support OSC 52. The watch loop writes the result to stdout. Pure.
String osc52Copy(String text) =>
    '\x1B]52;c;${base64.encode(utf8.encode(text))}\x07';

/// Moves a selection [index] within a list of [length] by [delta], clamping to
/// the valid range; an empty list has no selection (-1). Pure, so the keyboard
/// navigation in the live view is unit tested without a terminal.
int moveSelection(int index, int delta, int length) {
  if (length <= 0) return -1;
  final i = index.clamp(0, length - 1);
  return (i + delta).clamp(0, length - 1);
}

/// The orderings the interactive `top` view can cycle through with the `s` key.
/// [defaultOrder] keeps providers in collection order (the historical default);
/// the others float the most relevant provider to the top of its group by a
/// routing metric. The reorder is a pure, tested function ([sortProvidersForTop]);
/// the watch loop only holds which mode is active.
enum TopSort {
  defaultOrder('default'),
  headroom('headroom'),
  burn('burn'),
  strand('strand risk'),
  reset('reset');

  const TopSort(this.label);

  /// Short name shown in the footer keymap.
  final String label;

  /// The single token a user types for `--sort=` (every mode is one word).
  String get cliName => this == defaultOrder ? 'default' : name;

  /// The next mode in the cycle, wrapping around. Drives the `s` key.
  TopSort get next => values[(index + 1) % values.length];

  /// Parses a `--sort=` value (name or label, case-insensitive); null when
  /// unrecognized so the caller can report a usage error.
  static TopSort? parse(String s) {
    final k = s.trim().toLowerCase();
    for (final m in values) {
      if (m.name.toLowerCase() == k || m.label == k) return m;
    }
    if (k == 'fleet' || k == 'none') return defaultOrder;
    if (k == 'risk') return strand;
    return null;
  }
}

/// Reorders [providers] for display under [sort], reading each provider's routing
/// metrics from [suggestion]. The render still groups cloud above local; this
/// only sets the order within each group.
///
/// Stable and total: providers the sort cannot rank (no metric yet, or a local
/// runtime under a cloud-only metric) keep their original relative order and sink
/// below the ranked ones, so a fleet with no burn history never reshuffles into
/// nonsense. Pure: no clock or I/O, [now] is supplied by the caller.
List<ProviderQuota> sortProvidersForTop(
  List<ProviderQuota> providers,
  RouteSuggestion suggestion,
  int now,
  TopSort sort,
) {
  if (sort == TopSort.defaultOrder) return List.of(providers);
  final cand = {for (final c in suggestion.ranked) c.provider: c};

  // (value, rankable). Lower value sorts first; unrankable rows sink and hold
  // their original order. Signs are chosen so each mode's "most urgent" leads.
  (double, bool) keyFor(ProviderQuota q) {
    switch (sort) {
      case TopSort.headroom:
        final h = providerHeadroom(q, now);
        return (-(h ?? 0), h != null); // most free first
      case TopSort.burn:
        final b = cand[q.provider]?.burnPerHour;
        return (-(b ?? 0), b != null && b > 0); // fastest burn first
      case TopSort.strand:
        final p = cand[q.provider]?.strandProbability;
        return (-(p ?? 0), p != null); // most likely to strand first
      case TopSort.reset:
        final r = bindingWindow(q, now)?.resetsAt;
        return ((r ?? 0).toDouble(), r != null); // soonest reset first
      case TopSort.defaultOrder:
        return (0, false);
    }
  }

  final decorated = [
    for (var i = 0; i < providers.length; i++)
      (i, providers[i], keyFor(providers[i])),
  ];
  decorated.sort((a, b) {
    final ka = a.$3, kb = b.$3;
    if (ka.$2 != kb.$2) return ka.$2 ? -1 : 1; // ranked rows before unranked
    if (ka.$2) {
      final c = ka.$1.compareTo(kb.$1);
      if (c != 0) return c;
    }
    return a.$1.compareTo(b.$1); // original index keeps the sort stable
  });
  return [for (final d in decorated) d.$2];
}

/// One painted run of text with a known visible width. [paint] is applied only
/// when color is on; it never changes the visible length, so layout math can
/// work in plain characters and still produce correct colored output.
class _Cell {
  final String text;
  final String Function(AnsiStyle, String)? paint;
  const _Cell(this.text, [this.paint]);
}

/// Joins [cells] into a line exactly [width] visible columns wide: truncating
/// when the cells overflow (so a frame never wraps and corrupts the redraw) and
/// padding with spaces when they fall short (so stale text from a previous,
/// longer frame is fully overwritten).
String _line(List<_Cell> cells, int width, AnsiStyle s) {
  final out = StringBuffer();
  var used = 0;
  for (final c in cells) {
    if (used >= width) break;
    var t = c.text;
    if (used + t.length > width) t = t.substring(0, width - used);
    if (t.isEmpty) continue;
    used += t.length;
    out.write(c.paint == null ? t : c.paint!(s, t));
  }
  if (used < width) out.write(' ' * (width - used));
  return out.toString();
}

/// A left side and a right side separated by stretch space, for the header and
/// footer. The right side is dropped before the left if the line is too narrow.
String _justify(List<_Cell> left, List<_Cell> right, int width, AnsiStyle s) {
  int vis(List<_Cell> cells) => cells.fold(0, (n, c) => n + c.text.length);
  final lw = vis(left);
  final rw = vis(right);
  if (lw + 1 + rw > width) return _line(left, width, s);
  return _line([
    ...left,
    _Cell(' ' * (width - lw - rw)),
    ...right,
  ], width, s);
}

const _nameW =
    12; // one wider than the longest provider name, so labels never touch
const _labelW = 8;
const _barMax = 40;

/// The width of the bar for this frame, shared by every row so they align.
/// When [reserveForecast] is set a column is held back for the forward-looking
/// note, so the meters shrink to make room only when there is a forecast to show
/// (a fleet with no burn history keeps full-width bars).
int _barWidth(int width, {bool reserveForecast = false}) {
  // indent(2) name label gaps(3) bar "100% free"(10) gap(2) reset(~13).
  final overhead =
      2 + _nameW + _labelW + 3 + 10 + 2 + 13 + (reserveForecast ? 13 : 0);
  return (width - overhead).clamp(6, _barMax);
}

/// A compact forward-looking note for a provider's binding window, derived from
/// its routing candidate: the strand probability (chance the window is spent
/// before it resets) when that is material, otherwise a time-to-empty estimate
/// when the provider is visibly burning. Null when there is no burn signal - no
/// history yet, or headroom is steady - so quotabot never invents a forecast.
/// [sev] grades urgency for color: 2 likely to strand, 1 watch, 0 informational.
({String text, int sev})? _forecast(RouteCandidate? c) {
  if (c == null) return null;
  final f = classifyForecast(
    strandProbability: c.strandProbability,
    burnPerHour: c.burnPerHour,
    headroom: c.headroom,
  );
  if (f == null) return null;
  final text = switch (f.kind) {
    ForecastKind.strand => 'strand ${(f.strandProbability! * 100).round()}%',
    ForecastKind.timeToEmpty => _runwayTerse(f.hoursToEmpty!),
  };
  return (text: text, sev: f.severity);
}

/// The compact runway wording for the width-constrained dashboard column.
String _runwayTerse(double hours) => hours >= 24
    ? '~${(hours / 24).round()}d left'
    : hours >= 1
        ? '~${hours.round()}h left'
        : '~${(hours * 60).round()}m left';

/// Paints a forecast note by urgency: red when a strand is likely, orange when
/// it bears watching, dim for a calm time-to-empty estimate.
String _forecastPaint(AnsiStyle s, int sev, String t) =>
    sev == 2 ? s.red(t) : (sev == 1 ? s.orange(t) : s.dim(t));

/// Paints [t] in the palette's headroom color for [remaining] on a truecolor
/// terminal, falling back to the standard named headroom color otherwise.
String _healthPaint(AnsiStyle s, Palette p, double remaining, String t) {
  if (!s.truecolor) return s.health(remaining, t);
  final c = p.rgbFor(remaining);
  return s.rgb(c.r, c.g, c.b, t);
}

/// Paints [t] bold, and in the palette accent on a truecolor terminal. Used for
/// the wordmark and the route arrow.
String _accent(AnsiStyle s, Palette p, String t) {
  final bolded = s.bold(t);
  return s.truecolor
      ? s.rgb(p.accent.r, p.accent.g, p.accent.b, bolded)
      : bolded;
}

/// A horizontal meter: filled to the used fraction. On a truecolor terminal the
/// fill is a palette gradient (cells nearer the used frontier run toward the
/// spent color, so the bar visibly "heats up" toward exhaustion); otherwise it
/// falls back to a single headroom-colored fill. htop-style, btop-grade gradient.
List<_Cell> _bar(
    double usedPct, double remaining, int barW, AnsiStyle s, Palette p) {
  final filled = ((usedPct.clamp(0, 100) / 100) * barW).round().clamp(0, barW);
  final cells = <_Cell>[_Cell('[', (s, t) => s.dim(t))];
  if (s.truecolor) {
    for (var i = 0; i < filled; i++) {
      final cellRemaining = 100.0 * (1 - (i + 1) / barW);
      cells.add(_Cell('█', (s, t) => _healthPaint(s, p, cellRemaining, t)));
    }
  } else {
    cells.add(_Cell('█' * filled, (s, t) => s.health(remaining, t)));
  }
  cells.add(_Cell('░' * (barW - filled), (s, t) => s.dim(t)));
  cells.add(_Cell(']', (s, t) => s.dim(t)));
  return cells;
}

/// "3d12h" / "2h14m" / "now" countdown from [now] to [resetsAt].
String _eta(int resetsAt, int now) {
  var s = resetsAt - now;
  if (s <= 0) return 'now';
  final d = s ~/ 86400;
  s %= 86400;
  final h = s ~/ 3600;
  if (d > 0) return '${d}d${h}h';
  return '${h}h${(s % 3600) ~/ 60}m';
}

/// The leading columns of a data row: indent, provider name (only on the first
/// window of a provider), then the window label.
List<_Cell> _rowHead(String name, String label, {bool selected = false}) => [
      _Cell(selected ? '> ' : '  ', (s, t) => s.bold(t)),
      _Cell(name.padRight(_nameW), (s, t) => s.bold(t)),
      _Cell(label.padRight(_labelW), (s, t) => s.dim(t)),
    ];

/// The rows for one cloud (metered) provider, honoring the binding-window
/// collapse: when the most constrained window is spent, the whole provider
/// collapses to a single "<label> spent" line instead of showing a misleading
/// healthy shorter window.
List<String> _providerRows(ProviderQuota q, int now, int width, AnsiStyle s,
    Palette p, int barW, ({String text, int sev})? forecast,
    {bool selected = false}) {
  final cachedTag = q.stale ? const _Cell(' (cached)') : const _Cell('');

  if (!q.ok) {
    return [
      _line([
        ..._rowHead(q.displayName, '', selected: selected),
        _Cell(q.error?.isNotEmpty == true ? q.error! : 'read failed',
            (s, t) => s.red(t)),
      ], width, s),
    ];
  }
  if (q.windows.isEmpty) {
    return [
      _line([
        ..._rowHead(q.displayName, '', selected: selected),
        _Cell('no live data', (s, t) => s.dim(t)),
        if (q.stale) _Cell(' (cached)', (s, t) => s.dim(t)),
      ], width, s),
    ];
  }

  final binding = bindingWindow(q, now);
  final headroom = providerHeadroom(q, now) ?? 100;
  if (binding != null && headroom <= 0.5) {
    final reset = binding.resetsAt == null
        ? ''
        : 'resets ${_eta(binding.resetsAt!, now)}';
    return [
      _line([
        ..._rowHead(q.displayName, binding.label, selected: selected),
        _Cell('spent', (s, t) => s.red(t)),
        _Cell('   $reset', (s, t) => s.dim(t)),
        _Cell(cachedTag.text, (s, t) => s.dim(t)),
      ], width, s),
    ];
  }

  final lines = <String>[];
  var first = true;
  for (final w in q.windows) {
    final rolled = w.resetsAt != null && w.resetsAt! < now;
    final used = rolled ? 0.0 : (w.percent ?? 0).clamp(0, 100).toDouble();
    final remaining = 100 - used;
    final reset = w.resetsAt == null ? '' : 'resets ${_eta(w.resetsAt!, now)}';
    final showForecast = forecast != null && w.label == binding?.label;
    lines.add(_line([
      ..._rowHead(first ? q.displayName : '', w.label,
          selected: first && selected),
      ..._bar(used, remaining, barW, s, p),
      _Cell(' '),
      _Cell('${remaining.round().toString().padLeft(3)}% free',
          (s, t) => _healthPaint(s, p, remaining, t)),
      _Cell('  '),
      _Cell(reset, (s, t) => s.dim(t)),
      if (showForecast) ...[
        const _Cell('  '),
        _Cell(forecast.text, (s, t) => _forecastPaint(s, forecast.sev, t)),
      ],
      if (first) _Cell(cachedTag.text, (s, t) => s.dim(t)),
    ], width, s));
    first = false;
  }
  return lines;
}

/// The rows for one local runtime: a headline (what is loaded, always-on) and any
/// detail lines (VRAM, context, disk) the adapter provides, indented under it -
/// the same detail the desktop app shows.
List<String> _localRows(ProviderQuota q, int width, AnsiStyle s,
    {bool selected = false}) {
  final status = q.status?.isNotEmpty == true ? q.status! : 'ready';
  final lines = <String>[
    _line([
      ..._rowHead(q.displayName, 'local', selected: selected),
      _Cell(status, (s, t) => q.active ? s.cyan(t) : s.dim(t)),
      _Cell('  '),
      _Cell('[always on]', (s, t) => s.dim(t)),
    ], width, s),
  ];
  for (final d in q.details) {
    lines.add(_line([
      const _Cell('  '),
      _Cell(' ' * (_nameW + _labelW)),
      _Cell(d, (s, t) => s.dim(t)),
    ], width, s));
  }
  return lines;
}

/// Average remaining headroom across cloud providers that have live numbers, for
/// the header pool gauge. Null when nothing metered is readable.
double? _poolHeadroom(List<ProviderQuota> providers, int now) {
  var sum = 0.0;
  var n = 0;
  for (final q in providers) {
    if (q.isLocal) continue;
    final h = providerHeadroom(q, now);
    if (h != null) {
      sum += h;
      n++;
    }
  }
  return n == 0 ? null : sum / n;
}

/// Builds the content lines of one `top` frame. [clock] is supplied by the
/// caller (the only time-of-day text), [width] is the terminal width, and
/// [color] turns ANSI styling on or off.
List<String> renderTopFrame({
  required List<ProviderQuota> providers,
  required RouteSuggestion suggestion,
  required int now,
  required int width,
  required bool color,
  required String clock,
  ColorDepth depth = ColorDepth.none,
  Palette palette = kDefaultPalette,
  String updated = '',
  String sort = '',
  String? selected,
  int hidden = 0,
  String copied = '',
}) {
  final w = width < 24 ? 24 : width;
  final s = AnsiStyle(color, depth: depth);
  final p = palette;
  final lines = <String>[];

  final pool = _poolHeadroom(providers, now);
  final poolText = pool == null ? 'pool   ? ' : 'pool ${pool.round()}% free';
  lines.add(_justify(
    [_Cell('quotabot', (s, t) => _accent(s, p, t))],
    [
      _Cell(poolText,
          (s, t) => pool == null ? s.dim(t) : _healthPaint(s, p, pool, t)),
      const _Cell('   '),
      _Cell(clock, (s, t) => s.dim(t)),
    ],
    w,
    s,
  ));
  lines.add(_line([_Cell('─' * w, (s, t) => s.dim(t))], w, s));

  final cloud = providers.where((q) => !q.isLocal).toList();
  final local = providers.where((q) => q.isLocal).toList();
  if (cloud.isEmpty && local.isEmpty) {
    lines.add(_line([
      const _Cell('  '),
      _Cell('no providers detected - open a provider app or run a login',
          (s, t) => s.dim(t)),
    ], w, s));
  }
  // A forward-looking note per provider, from its routing candidate. The bar
  // only yields width when at least one provider has a forecast to show.
  final byProvider = {for (final c in suggestion.ranked) c.provider: c};
  final forecasts = <String, ({String text, int sev})?>{
    for (final q in cloud) q.provider: _forecast(byProvider[q.provider]),
  };
  final barW =
      _barWidth(w, reserveForecast: forecasts.values.any((f) => f != null));
  for (final q in cloud) {
    lines.addAll(_providerRows(q, now, w, s, p, barW, forecasts[q.provider],
        selected: q.provider == selected));
  }
  for (final q in local) {
    lines.addAll(_localRows(q, w, s, selected: q.provider == selected));
  }

  lines.add(_line([_Cell('─' * w, (s, t) => s.dim(t))], w, s));
  final r = suggestion.recommended;
  lines.add(_line([
    const _Cell('  '),
    _Cell('route ', (s, t) => s.dim(t)),
    if (r == null)
      _Cell('waiting', (s, t) => s.dim(t))
    else ...[
      _Cell('-> ', (s, t) => _accent(s, p, t)),
      _Cell(r.provider, (s, t) => s.bold(t)),
      if (r.isLocal) _Cell(' (local fallback)', (s, t) => s.dim(t)),
    ],
    _Cell('   '),
    _Cell(suggestion.reason, (s, t) => s.dim(t)),
  ], w, s));
  lines.add(_line([
    const _Cell('  '),
    _Cell('q', (s, t) => s.bold(t)),
    _Cell(' quit  ', (s, t) => s.dim(t)),
    _Cell('r', (s, t) => s.bold(t)),
    _Cell(' refresh  ', (s, t) => s.dim(t)),
    if (sort.isNotEmpty) ...[
      _Cell('s', (s, t) => s.bold(t)),
      _Cell(' sort:$sort  ', (s, t) => s.dim(t)),
    ],
    _Cell('j/k', (s, t) => s.bold(t)),
    _Cell(' move  ', (s, t) => s.dim(t)),
    _Cell('x', (s, t) => s.bold(t)),
    _Cell(' hide  ', (s, t) => s.dim(t)),
    if (hidden > 0) ...[
      _Cell('u', (s, t) => s.bold(t)),
      _Cell(' show($hidden)  ', (s, t) => s.dim(t)),
    ],
    _Cell('c', (s, t) => s.bold(t)),
    _Cell(' copy  ', (s, t) => s.dim(t)),
    if (copied.isNotEmpty)
      _Cell('copied $copied  ', (s, t) => _accent(s, p, t)),
    if (updated.isNotEmpty) _Cell('$updated  ', (s, t) => s.dim(t)),
    _Cell('0 usage tokens', (s, t) => s.dim(t)),
  ], w, s));

  return lines;
}
