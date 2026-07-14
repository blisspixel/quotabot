/// Small pure display formatters for the desktop dashboard: reset and age
/// labels, clock time, the "as of" line, and the notification id hash. Extracted
/// from main.dart so the widgets and the dashboard state share one copy.
library;

/// A stable non-negative 31-bit id for a notification [key], so re-notifying the
/// same provider/window replaces the prior notification instead of stacking.
int notificationId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Compact "3h12m" / "2d4h" reset label.
String resetLabel(int? resetsAt, int now) {
  if (resetsAt == null) return '';
  final s = resetsAt - now;
  if (s <= 0) return 'now';
  // Near-term: a precise countdown is what you act on ("59m", "3h58m").
  if (s < 18 * 3600) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h${m}m';
  }
  // Far-out (a weekly cap, say): an absolute day and time reads far clearer than
  // a "2d7h" countdown - "Mon 5:00 PM", with the date added beyond a week out.
  final dt = DateTime.fromMillisecondsSinceEpoch(resetsAt * 1000);
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final wd = days[dt.weekday - 1];
  // Join the day and clock time with a non-breaking space so the whole reset
  // renders as one unit in a narrow right-hand column. When the row runs out of
  // width it then breaks cleanly after the label ("37% free" over "Fri 11:14
  // PM") instead of dropping a lone "PM" onto the next line.
  const nb = ' ';
  final time = formatClockTime(dt).replaceAll(' ', nb);
  return s < 7 * 86400 ? '$wd$nb$time' : '$wd$nb${dt.month}/${dt.day}$nb$time';
}

/// When a spent window becomes usable again, phrased for a spent card: a
/// near-term countdown reads "in 59m", a far-out reset reads as its absolute day
/// and time ("Mon 5:00 PM").
String backLabel(int? resetsAt, int now) {
  if (resetsAt == null) return '';
  final s = resetsAt - now;
  if (s <= 0) return 'now';
  final label = resetLabel(resetsAt, now);
  return s < 18 * 3600 ? 'in $label' : label;
}

/// The snapshot's capture time as an absolute clock ("as of 8:38 AM"), with a
/// short date appended once it is no longer today so a stale snapshot cannot
/// masquerade as fresh.
String asOfLabel(DateTime t) {
  final now = DateTime.now();
  final clock = formatClockTime(t);
  final sameDay =
      now.year == t.year && now.month == t.month && now.day == t.day;
  if (sameDay) return 'as of $clock';
  return 'as of $clock ${t.month}/${t.day}';
}

/// 12-hour clock time, e.g. "5:00 PM".
String formatClockTime(DateTime t) {
  final h = t.hour;
  final min = t.minute.toString().padLeft(2, '0');
  final ampm = h >= 12 ? 'PM' : 'AM';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$min $ampm';
}

/// Short age of a cached snapshot, e.g. "12m", "3h", "2d".
String ageLabel(int asOf, int now) {
  final s = now - asOf;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}
