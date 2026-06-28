import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/palette.dart';
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

  test('a truecolor terminal draws a 24-bit gradient meter', () {
    final out = renderTopFrame(
      providers: [
        _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 60)]),
      ],
      suggestion: suggestRoute(const [], _now),
      now: _now,
      width: 80,
      color: true,
      clock: '12:00:00',
      depth: ColorDepth.truecolor,
    ).join();
    expect(out, contains('\x1B[38;2;')); // 24-bit foreground sequence
  });

  test('a palette recolors the truecolor frame (accent shows)', () {
    final providers = [
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 60)]),
    ];
    final synth = renderTopFrame(
      providers: providers,
      suggestion: suggestRoute(providers, _now),
      now: _now,
      width: 80,
      color: true,
      clock: '12:00:00',
      depth: ColorDepth.truecolor,
      palette: paletteFromSpec('synthwave'),
    ).join();
    // synthwave accent is purple 200;120;255, used for the wordmark.
    expect(synth, contains('\x1B[38;2;200;120;255m'));
    final def = renderTopFrame(
      providers: providers,
      suggestion: suggestRoute(providers, _now),
      now: _now,
      width: 80,
      color: true,
      clock: '12:00:00',
      depth: ColorDepth.truecolor,
    ).join();
    expect(def, isNot(contains('\x1B[38;2;200;120;255m')));
  });

  test('without truecolor the gradient sequence is not used', () {
    final out = renderTopFrame(
      providers: [
        _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 60)]),
      ],
      suggestion: suggestRoute(const [], _now),
      now: _now,
      width: 80,
      color: true,
      clock: '12:00:00',
      depth: ColorDepth.ansi16,
    ).join();
    expect(out, isNot(contains('\x1B[38;2;')));
  });

  group('detectColorDepth', () {
    test('NO_COLOR forces none even on a terminal', () {
      expect(
        detectColorDepth({'NO_COLOR': '1'}, hasTerminal: true),
        ColorDepth.none,
      );
    });
    test('no terminal is none', () {
      expect(detectColorDepth({}, hasTerminal: false), ColorDepth.none);
    });
    test('COLORTERM=truecolor is truecolor', () {
      expect(
        detectColorDepth({'COLORTERM': 'truecolor'}, hasTerminal: true),
        ColorDepth.truecolor,
      );
    });
    test('a 256-color TERM is ansi256, else ansi16', () {
      expect(
        detectColorDepth({'TERM': 'xterm-256color'}, hasTerminal: true),
        ColorDepth.ansi256,
      );
      expect(
        detectColorDepth({'TERM': 'xterm'}, hasTerminal: true),
        ColorDepth.ansi16,
      );
    });
    test('Windows Terminal and known terminal programs get truecolor', () {
      expect(
        detectColorDepth({'WT_SESSION': 'abc'}, hasTerminal: true),
        ColorDepth.truecolor,
      );
      expect(
        detectColorDepth({'TERM_PROGRAM': 'vscode'}, hasTerminal: true),
        ColorDepth.truecolor,
      );
    });
  });

  test('the updated label appears in the footer', () {
    final out = renderTopFrame(
      providers: [
        _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
      ],
      suggestion: suggestRoute(const [], _now),
      now: _now,
      width: 80,
      color: false,
      clock: '12:00:00',
      updated: 'updated 5s ago',
    ).join();
    expect(_plain(out), contains('updated 5s ago'));
  });

  test('local runtime detail lines render under the headline', () {
    final q = ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: 'local',
      asOf: _now,
      kind: 'local',
      status: 'qwen loaded',
      active: true,
      details: const ['4 GB VRAM . 32K ctx', '3 installed . 18 GB on disk'],
    );
    final lines = _frame([q]);
    expect(lines.any((l) => _plain(l).contains('VRAM')), isTrue);
    expect(lines.any((l) => _plain(l).contains('on disk')), isTrue);
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
