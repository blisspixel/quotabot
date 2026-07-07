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
    // Defense in depth: cell text must never carry raw control bytes, so a
    // provider-sourced string cannot inject escape sequences or skew the
    // width math. quotabot's own styling is applied by paint(), never here.
    var t = stripTerminalControl(c.text);
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

// Row column costs, used to decide what fits before anything is drawn:
// indent(2) name label = the row head; brackets+space(3) "100% free"(10)
// around the bar; then the optional trailing columns.
const _rowCore = 2 + _nameW + _labelW + 3 + 10;
const _resetCost = 2 + 13; // "  resets 4d12h"
const _forecastCost = 13; // "  strand 76%" / "  ~4h left"
const _minReadableBar = 10;

/// Which trailing columns fit at [width], decided once per frame so every row
/// drops the same columns and stays aligned. Under width pressure whole
/// columns yield, forecast first and the reset countdown second, so the view
/// narrows the story instead of clipping words mid-letter.
({bool reset, bool forecast}) topColumnsFor(int width,
    {required bool hasForecast}) {
  final reset = width >= _rowCore + _minReadableBar + _resetCost;
  final forecast = hasForecast &&
      width >= _rowCore + _minReadableBar + _resetCost + _forecastCost;
  return (reset: reset, forecast: forecast);
}

/// The width of the bar for this frame, shared by every row so they align.
/// The forecast column is reserved only when a forecast exists and fits, and
/// [tagWidth] reserves room for the widest trailing cached/account tag in the
/// fleet, so a fleet with no burn history and no annotations keeps full-width
/// meters while an annotated fleet shrinks its meters instead of clipping.
int _barWidth(int width,
    {required ({bool reset, bool forecast}) columns, int tagWidth = 0}) {
  final overhead = _rowCore +
      (columns.reset ? _resetCost : 0) +
      (columns.forecast ? _forecastCost : 0) +
      tagWidth;
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

/// A compact age for the cached tag: "5m", "8h", "2d". Under a minute reads
/// "now" so a just-served cache is not dramatized.
String _ageTerse(int seconds) {
  if (seconds < 60) return 'now';
  if (seconds < 5400) return '${(seconds / 60).round()}m';
  if (seconds < 129600) return '${(seconds / 3600).round()}h';
  return '${(seconds / 86400).round()}d';
}

/// The cached tag for a stale snapshot, carrying its age so "how old is this
/// number" never needs a second command: " (cached 8h)".
String _cachedTag(ProviderQuota q, int now) {
  if (!q.stale) return '';
  final age = q.asOf > 0 && now > q.asOf ? ' ${_ageTerse(now - q.asOf)}' : '';
  return ' (cached$age)';
}

/// The leading columns of a data row: cursor, provider name (only on the first
/// window of a provider), then the window label. The selected provider's name
/// takes the palette accent so the cursor row reads at a glance.
List<_Cell> _rowHead(String name, String label,
        {bool selected = false, Palette? palette}) =>
    [
      _Cell(selected ? '> ' : '  ', (s, t) => s.bold(t)),
      _Cell(
          name.padRight(_nameW),
          selected && palette != null
              ? (s, t) => _accent(s, palette, t)
              : (s, t) => s.bold(t)),
      _Cell(label.padRight(_labelW), (s, t) => s.dim(t)),
    ];

/// The rows for one cloud (metered) provider, honoring the binding-window
/// collapse: when the most constrained window is spent, the whole provider
/// collapses to a single "<label> spent" line instead of showing a misleading
/// healthy shorter window. [columns] carries the frame-wide decision of which
/// trailing columns fit; [accountTag] labels this row's account when the fleet
/// holds more than one account of the same provider.
List<String> _providerRows(ProviderQuota q, int now, int width, AnsiStyle s,
    Palette p, int barW, ({String text, int sev})? forecast,
    {bool selected = false,
    ({bool reset, bool forecast}) columns = (reset: true, forecast: true),
    String accountTag = ''}) {
  final cachedTag = _cachedTag(q, now);

  if (!q.ok) {
    return [
      _line([
        ..._rowHead(q.displayName, '', selected: selected, palette: p),
        _Cell(q.error?.isNotEmpty == true ? q.error! : 'read failed',
            (s, t) => s.red(t)),
        _Cell(accountTag, (s, t) => s.dim(t)),
      ], width, s),
    ];
  }
  if (q.windows.isEmpty) {
    final status = q.status?.isNotEmpty == true ? q.status! : 'no live data';
    return [
      _line([
        ..._rowHead(q.displayName, '', selected: selected, palette: p),
        _Cell(status, (s, t) => s.dim(t)),
        _Cell(cachedTag, (s, t) => s.dim(t)),
        _Cell(accountTag, (s, t) => s.dim(t)),
      ], width, s),
    ];
  }

  final binding = bindingWindow(q, now);
  final headroom = providerHeadroom(q, now) ?? 100;
  if (binding != null && headroom <= 0.5) {
    final reset = !columns.reset || binding.resetsAt == null
        ? ''
        : 'resets ${_eta(binding.resetsAt!, now)}';
    return [
      _line([
        ..._rowHead(q.displayName, binding.label,
            selected: selected, palette: p),
        _Cell('spent', (s, t) => s.red(t)),
        if (reset.isNotEmpty) _Cell('   $reset', (s, t) => s.dim(t)),
        _Cell(cachedTag, (s, t) => s.dim(t)),
        _Cell(accountTag, (s, t) => s.dim(t)),
      ], width, s),
    ];
  }

  final lines = <String>[];
  var first = true;
  for (final w in q.windows) {
    final used = windowUsedPercent(w, now);
    final remaining = 100 - used;
    final reset = w.resetsAt == null ? '' : 'resets ${_eta(w.resetsAt!, now)}';
    final showForecast =
        columns.forecast && forecast != null && w.label == binding?.label;
    lines.add(_line([
      ..._rowHead(first ? q.displayName : '', w.label,
          selected: first && selected, palette: p),
      ..._bar(used, remaining, barW, s, p),
      _Cell(' '),
      _Cell('${remaining.round().toString().padLeft(3)}% free',
          (s, t) => _healthPaint(s, p, remaining, t)),
      // The reset column is padded to its reserved width so the forecast and
      // cached/account tags line up vertically across every row.
      if (columns.reset) ...[
        const _Cell('  '),
        _Cell(reset.padRight(_resetCost - 2), (s, t) => s.dim(t)),
      ],
      if (showForecast) ...[
        const _Cell('  '),
        _Cell(forecast.text, (s, t) => _forecastPaint(s, forecast.sev, t)),
      ],
      if (first) _Cell(cachedTag, (s, t) => s.dim(t)),
      if (first) _Cell(accountTag, (s, t) => s.dim(t)),
    ], width, s));
    first = false;
  }
  return lines;
}

/// The rows for one local runtime: a headline (what is loaded, always-on) and any
/// detail lines (VRAM, context, disk) the adapter provides, indented under it -
/// the same detail the desktop app shows. The "[always on]" tag yields on
/// narrow terminals so the status itself never clips.
List<String> _localRows(ProviderQuota q, int width, AnsiStyle s, Palette p,
    {bool selected = false}) {
  final status = q.status?.isNotEmpty == true ? q.status! : 'ready';
  // The tag renders only when the whole row fits, so a long model list on a
  // narrow terminal keeps its status text intact instead of clipping the tag.
  const head = 2 + _nameW + _labelW;
  const tag = '[always on]';
  final showAlwaysOn = head + status.length + 2 + tag.length <= width;
  final lines = <String>[
    _line([
      ..._rowHead(q.displayName, 'local', selected: selected, palette: p),
      _Cell(status, (s, t) => q.active ? s.cyan(t) : s.dim(t)),
      if (showAlwaysOn) ...[
        const _Cell('  '),
        _Cell(tag, (s, t) => s.dim(t)),
      ],
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

/// One footer chunk with its yield order under width pressure. Chunks with a
/// higher [drop] value disappear first; -1 never drops. Whole chunks yield so
/// a narrow footer never shows a clipped, unusable key hint.
class _Seg {
  final List<_Cell> cells;
  final int drop;
  const _Seg(this.cells, this.drop);
}

/// Fits [segs] into [width] by removing whole segments in drop order.
List<_Cell> _fitSegments(List<_Seg> segs, int width) {
  final kept = List.of(segs);
  int vis() =>
      kept.fold(0, (n, g) => n + g.cells.fold(0, (m, c) => m + c.text.length));
  while (vis() > width) {
    _Seg? worst;
    for (final g in kept) {
      if (g.drop < 0) continue;
      if (worst == null || g.drop > worst.drop) worst = g;
    }
    if (worst == null) break;
    kept.remove(worst);
  }
  return [for (final g in kept) ...g.cells];
}

/// Trims [reason] to fit [available] columns, cutting at a word boundary and
/// ending with an ellipsis, so the route line never clips mid-word at the
/// frame edge.
String _fitReason(String reason, int available) {
  if (reason.length <= available) return reason;
  if (available <= 3) return '';
  var cut = reason.substring(0, available - 3);
  final space = cut.lastIndexOf(' ');
  if (space > available ~/ 2) cut = cut.substring(0, space);
  return '${cut.trimRight()}...';
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
  String? selectedAccount,
  int hidden = 0,
  String copied = '',
}) {
  final w = width < 24 ? 24 : width;
  final s = AnsiStyle(color, depth: depth);
  final p = palette;
  final lines = <String>[];

  final pool = _poolHeadroom(providers, now);
  final poolText = pool == null ? 'pool --' : 'pool ${pool.round()}% free';
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
      _Cell('no providers detected - open app; login supports Grok/Antigravity',
          (s, t) => s.dim(t)),
    ], w, s));
  }
  // A forward-looking note per provider, from its routing candidate. The bar
  // only yields width when at least one provider has a forecast to show.
  final byProvider = {for (final c in suggestion.ranked) c.provider: c};
  final forecasts = <String, ({String text, int sev})?>{
    for (final q in cloud) q.provider: _forecast(byProvider[q.provider]),
  };
  final columns =
      topColumnsFor(w, hasForecast: forecasts.values.any((f) => f != null));
  // Multi-account fleets label each duplicate provider's row with its account,
  // so two Grok rows are never ambiguous; single-account fleets stay unlabeled.
  final providerCounts = <String, int>{};
  for (final q in cloud) {
    providerCounts[q.provider] = (providerCounts[q.provider] ?? 0) + 1;
  }
  String accountTagFor(ProviderQuota q) =>
      (providerCounts[q.provider] ?? 0) > 1 &&
              hasSpecificQuotaAccount(q.account)
          ? ' @${q.account}'
          : '';
  // Reserve room for the widest trailing annotation so tags never clip.
  var tagWidth = 0;
  for (final q in cloud) {
    final t = _cachedTag(q, now).length + accountTagFor(q).length;
    if (t > tagWidth) tagWidth = t;
  }
  final barW = _barWidth(w, columns: columns, tagWidth: tagWidth);
  // A selection names a provider and, in multi-account fleets, the account,
  // so two rows of the same provider never both carry the cursor.
  bool isSelected(ProviderQuota q) =>
      q.provider == selected &&
      (selectedAccount == null || q.account == selectedAccount);
  for (final q in cloud) {
    lines.addAll(_providerRows(q, now, w, s, p, barW, forecasts[q.provider],
        selected: isSelected(q),
        columns: columns,
        accountTag: accountTagFor(q)));
  }
  for (final q in local) {
    lines.addAll(_localRows(q, w, s, p, selected: isSelected(q)));
  }

  lines.add(_line([_Cell('─' * w, (s, t) => s.dim(t))], w, s));
  final r = suggestion.recommended;
  // The route line already names the pick, so a reason that repeats it as
  // "Use <provider> - " is trimmed to just the explanation, and a long reason
  // yields at a word boundary instead of clipping at the frame edge.
  final routeHead = <_Cell>[
    const _Cell('  '),
    _Cell('route ', (s, t) => s.dim(t)),
    if (r == null)
      _Cell('waiting', (s, t) => s.dim(t))
    else ...[
      _Cell('-> ', (s, t) => _accent(s, p, t)),
      _Cell(r.provider, (s, t) => s.bold(t)),
      if (r.isLocal) _Cell(' (local fallback)', (s, t) => s.dim(t)),
    ],
    const _Cell('   '),
  ];
  var reason = suggestion.reason;
  if (r != null && reason.startsWith('Use ${r.provider} - ')) {
    reason = reason.substring('Use ${r.provider} - '.length);
  }
  final routeHeadWidth = routeHead.fold(0, (n, c) => n + c.text.length);
  lines.add(_line([
    ...routeHead,
    _Cell(_fitReason(reason, w - routeHeadWidth), (s, t) => s.dim(t)),
  ], w, s));
  lines.add(_line(
    _fitSegments([
      _Seg([
        const _Cell('  '),
        _Cell('q', (s, t) => s.bold(t)),
        _Cell(' quit  ', (s, t) => s.dim(t)),
        _Cell('r', (s, t) => s.bold(t)),
        _Cell(' refresh  ', (s, t) => s.dim(t)),
      ], -1),
      if (sort.isNotEmpty)
        _Seg([
          _Cell('s', (s, t) => s.bold(t)),
          _Cell(' sort:$sort  ', (s, t) => s.dim(t)),
        ], 6),
      _Seg([
        _Cell('j/k', (s, t) => s.bold(t)),
        _Cell(' move  ', (s, t) => s.dim(t)),
      ], 8),
      _Seg([
        _Cell('x', (s, t) => s.bold(t)),
        _Cell(' hide  ', (s, t) => s.dim(t)),
      ], 7),
      if (hidden > 0)
        _Seg([
          _Cell('u', (s, t) => s.bold(t)),
          _Cell(' show($hidden)  ', (s, t) => s.dim(t)),
        ], 4),
      _Seg([
        _Cell('c', (s, t) => s.bold(t)),
        _Cell(' copy  ', (s, t) => s.dim(t)),
      ], 5),
      if (copied.isNotEmpty)
        _Seg([
          _Cell('copied $copied  ', (s, t) => _accent(s, p, t)),
        ], 3),
      if (updated.isNotEmpty)
        _Seg([
          _Cell('$updated  ', (s, t) => s.dim(t)),
        ], 9),
      _Seg([
        _Cell('0 usage tokens', (s, t) => s.dim(t)),
      ], 10),
    ], w),
    w,
    s,
  ));

  return lines;
}
