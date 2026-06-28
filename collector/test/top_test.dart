import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/top.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _q(
  String id,
  List<QuotaWindow> windows, {
  bool stale = false,
  bool ok = true,
  String? error,
  String kind = 'subscription',
  String? status,
  bool active = false,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      windows: windows,
      stale: stale,
      ok: ok,
      error: error,
      kind: kind,
      status: status,
      active: active,
    );

/// Strips ANSI SGR codes so tests can assert on visible text and width.
String _plain(String s) => s.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

List<String> _frame(
  List<ProviderQuota> providers, {
  int width = 80,
  bool color = false,
}) {
  final suggestion = suggestRoute(providers, _now);
  return renderTopFrame(
    providers: providers,
    suggestion: suggestion,
    now: _now,
    width: width,
    color: color,
    clock: '12:00:00',
  );
}

void main() {
  test('header carries the wordmark, pool gauge, and clock', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
    ]);
    expect(_plain(lines.first), contains('quotabot'));
    expect(_plain(lines.first), contains('pool 80% free'));
    expect(_plain(lines.first), contains('12:00:00'));
  });

  test('every line is padded to exactly the terminal width', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
      _q('codex', [QuotaWindow(label: '5h', usedPercent: 95)]),
    ], width: 72);
    for (final line in lines) {
      expect(_plain(line).length, 72, reason: line);
    }
  });

  test('a healthy window renders a bar and the free percent', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
    ]);
    final row = lines.firstWhere((l) => _plain(l).contains('claude'));
    expect(_plain(row), contains('weekly'));
    expect(_plain(row), contains('80% free'));
    expect(row, contains('█')); // some filled portion for 20% used
    expect(row, contains('░')); // and some empty portion
  });

  test('a spent binding window collapses to one line', () {
    final lines = _frame([
      _q('codex', [
        QuotaWindow(label: '5h', usedPercent: 10),
        QuotaWindow(label: 'weekly', usedPercent: 100, resetsAt: _now + 3600),
      ]),
    ]);
    // Filter on the binding label, which only the provider row carries (the
    // footer also mentions codex but not the window label).
    final rows = lines.where((l) => _plain(l).contains('weekly')).toList();
    expect(rows, hasLength(1));
    expect(_plain(rows.first), contains('codex'));
    expect(_plain(rows.first), contains('spent'));
    expect(_plain(rows.first), contains('resets'));
    // The healthy 5h window must not be shown once the week is spent.
    expect(lines.any((l) => _plain(l).contains('5h')), isFalse);
  });

  test('a local runtime shows its status as an always-on fallback', () {
    final lines = _frame([
      _q('ollama', const [],
          kind: 'local', status: '3 models, llama3 loaded', active: true),
    ]);
    final row = lines.firstWhere((l) => _plain(l).contains('ollama'));
    expect(_plain(row), contains('local'));
    expect(_plain(row), contains('llama3'));
    expect(_plain(row), contains('[always on]'));
  });

  test('a failed read says so instead of faking a bar', () {
    final lines =
        _frame([_q('grok', const [], ok: false, error: 'token expired')]);
    final row = lines.firstWhere((l) => _plain(l).contains('grok'));
    expect(_plain(row), contains('token expired'));
    expect(row, isNot(contains('█')));
  });

  test('a stale provider is tagged cached', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)],
          stale: true),
    ]);
    expect(lines.any((l) => _plain(l).contains('(cached)')), isTrue);
  });

  test('the footer recommends where to route next', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
      _q('codex', [QuotaWindow(label: '5h', usedPercent: 95)]),
    ]);
    final footer = lines.firstWhere((l) => _plain(l).contains('route'));
    expect(_plain(footer), contains('claude'));
    expect(lines.any((l) => _plain(l).contains('q quit')), isTrue);
  });

  test('color mode emits ANSI codes; plain mode never does', () {
    final providers = [
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
    ];
    expect(_frame(providers, color: true).join(), contains('\x1B['));
    expect(_frame(providers, color: false).join(), isNot(contains('\x1B[')));
  });

  test('an empty fleet still renders a usable frame', () {
    final lines = _frame(const [], width: 60);
    expect(
        lines.any((l) => _plain(l).contains('no providers detected')), isTrue);
    for (final line in lines) {
      expect(_plain(line).length, 60);
    }
  });

  test('a narrow terminal never overflows its width', () {
    final lines = _frame([
      _q('antigravity', [QuotaWindow(label: 'weekly', usedPercent: 50)]),
    ], width: 30);
    for (final line in lines) {
      expect(_plain(line).length, 30, reason: line);
    }
  });
}
