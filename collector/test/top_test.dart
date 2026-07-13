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
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
  String? status,
  bool active = false,
  String? source,
  bool perMachine = false,
  String account = 'a',
  int asOf = _now,
  List<String> details = const [],
  int resetCreditsAvailable = 0,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: account,
      asOf: asOf,
      windows: windows,
      stale: stale,
      ok: ok,
      error: error,
      kind: kind,
      status: status,
      active: active,
      source: source,
      perMachine: perMachine,
      details: details,
      resetCreditsAvailable: resetCreditsAvailable,
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

  test('a spent short window still shows the healthy longer window', () {
    final lines = _frame([
      _q('codex', [
        QuotaWindow(label: '5h', usedPercent: 100, resetsAt: _now + 3600),
        QuotaWindow(
            label: 'weekly', usedPercent: 42, resetsAt: _now + 5 * 86400),
      ]),
    ]);
    // The 5h collapses to a spent line...
    final spent = lines.firstWhere((l) => _plain(l).contains('spent'));
    expect(_plain(spent), contains('codex'));
    expect(_plain(spent), contains('5h'));
    // ...but the weekly cap the user faces after 3h stays visible.
    final weekly = lines.where((l) => _plain(l).contains('weekly')).toList();
    expect(weekly, hasLength(1));
    expect(_plain(weekly.first), contains('58% free'));
    expect(_plain(weekly.first), contains('resets'));
  });

  test('rounded-one-percent headroom renders as spent, not free', () {
    final lines = _frame([
      _q('claude', [
        QuotaWindow(label: '5h', usedPercent: 98.6, resetsAt: _now + 3600),
      ]),
    ]);
    final row = _plain(lines.firstWhere((l) => _plain(l).contains('claude')));
    expect(row, contains('spent'));
    expect(row, isNot(contains('1% free')));
  });

  test('a spent card surfaces the reset escape hatch, not only a wait', () {
    // A spent Codex window whose account holds redeemable resets must show that
    // way out instead of only "resets in Xh".
    final lines = _frame([
      _q(
          'codex',
          [
            QuotaWindow(
                label: 'weekly', usedPercent: 100, resetsAt: _now + 3600),
          ],
          resetCreditsAvailable: 2),
    ], width: 100);
    expect(lines.any((l) => _plain(l).contains('spent')), isTrue);
    expect(lines.any((l) => _plain(l).contains('resets available')), isTrue);
  });

  test('the reset escape hatch renders in green, not dim', () {
    final lines = _frame([
      _q(
          'codex',
          [
            QuotaWindow(
                label: 'weekly', usedPercent: 100, resetsAt: _now + 3600),
          ],
          resetCreditsAvailable: 2),
    ], width: 100, color: true);
    final resetLine =
        lines.firstWhere((l) => _plain(l).contains('resets available'));
    // The green SGR code (32) marks it prominent rather than the dim (2) that
    // ordinary detail lines use.
    expect(resetLine, contains('\x1B[32m'));
  });

  test('a local runtime shows its status and local trust scope', () {
    final lines = _frame([
      _q('ollama', const [],
          kind: ProviderQuotaKind.local,
          status: '3 models, llama3 loaded',
          active: true,
          perMachine: true),
    ], width: 100);
    final row = lines.firstWhere((l) => _plain(l).contains('ollama'));
    expect(_plain(row), contains('local'));
    expect(_plain(row), contains('llama3'));
    expect(_plain(row), contains('(in use, local runtime, loaded)'));
    expect(_plain(row), isNot(contains('this machine')));
  });

  test('an idle local runtime uses available without repeating local', () {
    final lines = _frame([
      _q(
        'lemonade',
        const [],
        kind: ProviderQuotaKind.local,
        status: '1 installed, idle',
      ),
    ], width: 100);
    final row =
        _plain(lines.firstWhere((line) => _plain(line).contains('lemonade')));

    expect(row, contains('(available, local runtime, cold)'));
    expect(row, isNot(contains('(local, local runtime')));
  });

  test('a failed local runtime shows the error and trust state', () {
    final lines = _frame([
      _q('ollama', const [],
          kind: ProviderQuotaKind.local,
          ok: false,
          error: 'runtime offline',
          perMachine: true),
    ], width: 100);
    final row = _plain(lines.firstWhere((l) => _plain(l).contains('ollama')));
    expect(row, contains('runtime offline'));
    expect(row, contains('(error, local runtime, cold)'));
    expect(row, isNot(contains('this machine')));
  });

  test('a failed read says so instead of faking a bar', () {
    final lines =
        _frame([_q('grok', const [], ok: false, error: 'token expired')]);
    final row = lines.firstWhere((l) => _plain(l).contains('grok'));
    expect(_plain(row), contains('token expired'));
    expect(_plain(row), contains('(error, authoritative, quota plan)'));
    expect(row, isNot(contains('█')));
  });

  test('a stale provider is tagged cached with spend class', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)],
          stale: true),
    ], width: 90);
    expect(
      lines.any(
        (l) => _plain(l).contains('(cached, authoritative, quota plan)'),
      ),
      isTrue,
    );
    expect(_plain(lines.join('\n')), contains('80% last'));
    expect(_plain(lines.join('\n')), isNot(contains('80% free')));
  });

  test('provider drift is distinct from an ordinary cached read', () {
    final trusted = _q(
      'claude',
      [QuotaWindow(label: 'weekly', usedPercent: 20)],
      asOf: _now - 2 * 60 * 60,
    );
    final lines = _frame(
      [trusted.withProviderDrift('weekly reset moved earlier', _now - 30)],
      width: 100,
    );

    expect(
      lines.any((line) => _plain(line)
          .contains('(provider drift 2h, authoritative, quota plan)')),
      isTrue,
    );
    expect(_plain(lines.join('\n')), contains('80% last'));
    expect(_plain(lines.join('\n')), isNot(contains('80% free')));
  });

  test('legacy no-window quarantine stays labeled provider drift', () {
    final legacy = _q(
      'claude',
      [QuotaWindow(label: 'weekly', usedPercent: 20)],
      asOf: _now - 2 * 60 * 60,
    ).withSuspect('legacy concern').asProviderDriftQuarantine(
          'unresolved legacy provider drift: legacy concern',
          _now - 30,
        );
    final lines = _frame([legacy], width: 100);

    expect(
      lines.any((line) => _plain(line)
          .contains('(provider drift 2h, authoritative, quota plan)')),
      isTrue,
    );
    expect(_plain(lines.join('\n')), isNot(contains('(error,')));
  });

  test('top rows label all six normalized provider source classes', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
      _q(
        'codex',
        [QuotaWindow(label: 'weekly', usedPercent: 25)],
        perMachine: true,
      ),
      _q(
        'cursor',
        [QuotaWindow(label: 'monthly', usedPercent: 30)],
        perMachine: true,
      ),
      _q(
        'ollama',
        const [],
        kind: ProviderQuotaKind.local,
        status: 'llama3 loaded',
        active: true,
        perMachine: true,
      ),
      _q('nvidia', const [], status: 'free trial available; balance unknown'),
      _q(
        'manual-ai',
        [QuotaWindow(label: 'monthly', usedPercent: 45)],
        source: providerQuotaManualSource,
      ),
    ], width: 140);

    expect(
      lines.any(
        (l) => _plain(l).contains('(live, authoritative, quota plan)'),
      ),
      isTrue,
    );
    expect(
      lines.any(
        (l) => _plain(l).contains('(live, this-machine fallback, quota plan)'),
      ),
      isTrue,
    );
    expect(
      lines.any(
        (l) => _plain(l).contains('(live, passive local, metered plan)'),
      ),
      isTrue,
    );
    expect(
      lines.any(
        (l) => _plain(l).contains('(in use, local runtime, loaded)'),
      ),
      isTrue,
    );
    expect(
      lines.any((l) => _plain(l).contains('(metadata, status only)')),
      isTrue,
    );
    expect(lines.any((l) => _plain(l).contains('(live, manual)')), isTrue);
    final plain = _plain(lines.join('\n'));
    expect(plain, isNot(contains('local runtime, loaded, this machine')));
    expect(plain, isNot(contains('passive local, metered plan, this machine')));
  });

  test('an authoritative metadata snapshot keeps its normalized provenance',
      () {
    final lines = _frame([
      _q('claude', const [], status: 'quota endpoint unavailable'),
    ], width: 100);
    final row = _plain(lines.firstWhere((l) => _plain(l).contains('claude')));
    expect(row, contains('(metadata, authoritative)'));
    expect(row, isNot(contains('quota plan')));
  });

  test('long status rows drop trust tags before clipping them', () {
    final lines = _frame([
      _q('claude', const [],
          status: 'quota endpoint unavailable while browser is signed out'),
    ], width: 50);
    final row = _plain(lines.firstWhere((l) => _plain(l).contains('claude')));
    expect(row, isNot(contains('(metadata')));
    expect(row, isNot(contains('(met')));
    expect(row.length, 50);
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
      kind: ProviderQuotaKind.local,
      status: 'qwen loaded',
      active: true,
      details: const ['4 GB VRAM . 32K ctx', '3 installed . 18 GB on disk'],
    );
    final lines = _frame([q]);
    expect(lines.any((l) => _plain(l).contains('VRAM')), isTrue);
    expect(lines.any((l) => _plain(l).contains('on disk')), isTrue);
  });

  group('forward-looking forecast', () {
    test('a burning provider shows a strand forecast on its binding window',
        () {
      final providers = [
        _q('codex', [
          QuotaWindow(label: '5h', usedPercent: 70, resetsAt: _now + 3600),
        ]),
      ];
      // 30% free, burning 40%/hr (se 5) for an hour: a near-certain strand.
      final suggestion = suggestRoute(providers, _now, burnStatsByProvider: {
        'codex': const BurnStat(perHour: 40, sePerHour: 5, samples: 10),
      });
      final lines = renderTopFrame(
        providers: providers,
        suggestion: suggestion,
        now: _now,
        width: 100,
        color: false,
        clock: '12:00:00',
      );
      final row = lines.firstWhere((l) => _plain(l).contains('codex'));
      expect(_plain(row), contains('strand'));
    });

    test('shows time-to-empty when burning but a strand cannot be computed',
        () {
      final providers = [
        _q('codex', [QuotaWindow(label: '5h', usedPercent: 20)]), // 80% free
      ];
      // Burn but no standard error and no reset, so strand is null: fall back to
      // a plain time-to-empty (80% / 10%/hr = ~8h).
      final suggestion = suggestRoute(providers, _now, burnStatsByProvider: {
        'codex': const BurnStat(perHour: 10, samples: 3),
      });
      final lines = renderTopFrame(
        providers: providers,
        suggestion: suggestion,
        now: _now,
        width: 100,
        color: false,
        clock: '12:00:00',
      );
      final row = lines.firstWhere((l) => _plain(l).contains('codex'));
      expect(_plain(row), contains('left'));
    });

    test('no forecast is invented without burn history', () {
      final lines = _frame([
        _q('codex', [
          QuotaWindow(label: '5h', usedPercent: 70, resetsAt: _now + 3600),
        ]),
      ], width: 100);
      expect(lines.any((l) => _plain(l).contains('strand')), isFalse);
      expect(lines.any((l) => _plain(l).contains('left')), isFalse);
    });

    test('multi-account forecasts stay on the matching account row', () {
      final providers = [
        _q(
          'codex',
          [QuotaWindow(label: '5h', usedPercent: 70, resetsAt: _now + 3600)],
          account: 'work@example.com',
        ),
        _q(
          'codex',
          [QuotaWindow(label: '5h', usedPercent: 70, resetsAt: _now + 3600)],
          account: 'home@example.com',
        ),
      ];
      final suggestion = suggestRoute(providers, _now, burnStatsByProvider: {
        quotaIdentityKey('codex', 'work@example.com'):
            const BurnStat(perHour: 40, sePerHour: 5, samples: 10),
      });
      final lines = renderTopFrame(
        providers: providers,
        suggestion: suggestion,
        now: _now,
        width: 120,
        color: false,
        clock: '12:00:00',
      ).map(_plain).toList();
      final workRow = lines.firstWhere((l) => l.contains('@work@example.com'));
      final homeRow = lines.firstWhere((l) => l.contains('@home@example.com'));
      expect(workRow, contains('strand'));
      expect(homeRow, isNot(contains('strand')));
    });

    test('mixed forecast rows keep trust tags aligned', () {
      final providers = [
        _q(
          'codex',
          [QuotaWindow(label: '5h', usedPercent: 70, resetsAt: _now + 3600)],
          account: 'aa@example.com',
        ),
        _q(
          'codex',
          [QuotaWindow(label: '5h', usedPercent: 70, resetsAt: _now + 3600)],
          account: 'bb@example.com',
        ),
      ];
      final suggestion = suggestRoute(providers, _now, burnStatsByProvider: {
        quotaIdentityKey('codex', 'aa@example.com'):
            const BurnStat(perHour: 40, sePerHour: 5, samples: 10),
      });
      final lines = renderTopFrame(
        providers: providers,
        suggestion: suggestion,
        now: _now,
        width: 120,
        color: false,
        clock: '12:00:00',
      ).map(_plain).toList();
      final forecastRow =
          lines.firstWhere((l) => l.contains('@aa@example.com'));
      final quietRow = lines.firstWhere((l) => l.contains('@bb@example.com'));
      expect(forecastRow, contains('strand'));
      expect(quietRow, isNot(contains('strand')));
      expect(forecastRow.indexOf('(live'), quietRow.indexOf('(live'));
    });
  });

  group('width degradation', () {
    List<ProviderQuota> burning() => [
          _q('codex', [
            QuotaWindow(label: '5h', usedPercent: 70, resetsAt: _now + 3600),
          ]),
        ];
    RouteSuggestion sug(List<ProviderQuota> ps) =>
        suggestRoute(ps, _now, burnStatsByProvider: {
          'codex': const BurnStat(perHour: 40, sePerHour: 5, samples: 10),
        });
    List<String> at(int width) {
      final ps = burning();
      return renderTopFrame(
        providers: ps,
        suggestion: sug(ps),
        now: _now,
        width: width,
        color: false,
        clock: '12:00:00',
      );
    }

    String rowAt(int width) =>
        _plain(at(width).firstWhere((l) => _plain(l).contains('codex')));

    test('a wide frame shows bar, reset, and forecast', () {
      final row = rowAt(100);
      expect(row, contains('resets'));
      expect(row, contains('strand'));
    });

    test('a narrow frame drops the forecast column before the reset', () {
      final row = rowAt(64);
      expect(row, contains('resets'));
      expect(row, isNot(contains('strand')));
      expect(row, isNot(contains('stra')), reason: 'no mid-word clipping');
    });

    test('cloud trust tags yield whole before clipping on narrow frames', () {
      final lines = _frame([
        _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
      ], width: 54)
          .map(_plain)
          .toList();
      final row = lines.firstWhere((l) => l.contains('claude'));
      expect(row, isNot(contains('(live')));
      expect(row, isNot(contains('quota p')));
    });

    test('a very narrow frame drops the reset countdown too', () {
      final row = rowAt(50);
      expect(row, isNot(contains('resets')));
      expect(row, contains('% free'));
    });

    test('the footer yields whole key hints, never clipped ones', () {
      final ps = burning();
      final footer = _plain(renderTopFrame(
        providers: ps,
        suggestion: sug(ps),
        now: _now,
        width: 46,
        color: false,
        clock: '12:00:00',
        updated: 'updated 3s ago',
        sort: 'default',
        hidden: 2,
        copied: 'claude',
      ).last);
      expect(footer, contains('q quit'));
      expect(footer, contains('r refresh'));
      // Dropped segments disappear entirely; nothing is cut mid-hint.
      expect(footer, isNot(contains('updated')));
      expect(footer, isNot(contains('usage tokens')));
      expect(_plain(footer).length, 46);
    });
  });

  test('a stale snapshot is tagged with the age of its cache', () {
    final q = ProviderQuota(
      provider: 'codex',
      displayName: 'codex',
      account: 'a',
      asOf: _now - 8 * 3600,
      stale: true,
      windows: [QuotaWindow(label: '5h', usedPercent: 44)],
    );
    final lines = _frame([q], width: 90);
    expect(
      lines.any(
        (l) => _plain(l).contains('(cached 8h, authoritative, quota plan)'),
      ),
      isTrue,
    );
    expect(_plain(lines.join('\n')), contains('56% last'));
  });

  test('the pool gauge ignores stale cached cloud headroom', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)],
          stale: true),
      _q('codex', [QuotaWindow(label: 'weekly', usedPercent: 60)]),
    ], width: 90);
    expect(_plain(lines.first), contains('pool 40% free'));
  });

  test('the route line drops the reason\'s redundant "Use <provider>"', () {
    final lines = _frame([
      _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
    ], width: 100);
    final route = _plain(lines.firstWhere((l) => _plain(l).contains('route')));
    expect(route, contains('-> claude'));
    expect(route, isNot(contains('Use claude')));
  });

  test('a long route reason yields at a word boundary with an ellipsis', () {
    final providers = [
      _q('ollama', const [], kind: ProviderQuotaKind.local, status: 'ready'),
      _q('codex', [QuotaWindow(label: '5h', usedPercent: 99)]),
    ];
    final lines = _frame(providers, width: 56);
    final route = _plain(lines.firstWhere((l) => _plain(l).contains('route')));
    expect(route.trimRight(), endsWith('...'));
    expect(route.length, 56);
  });

  test('duplicate-provider rows are labeled with their accounts', () {
    ProviderQuota grok(String account, double used) => ProviderQuota(
          provider: 'grok',
          displayName: 'Grok',
          account: account,
          asOf: _now,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    final lines = _frame(
      [grok('work@example.com', 57), grok('home@example.com', 22)],
      width: 110,
    );
    expect(lines.any((l) => _plain(l).contains('@work@example.com')), isTrue);
    expect(lines.any((l) => _plain(l).contains('@home@example.com')), isTrue);
    final route = _plain(lines.firstWhere((l) => _plain(l).contains('route')));
    expect(route, contains('-> grok @home@example.com'));
    final narrow = _frame(
      [grok('work@example.com', 57), grok('home@example.com', 22)],
      width: 76,
    );
    expect(
      narrow.any((l) => _plain(l).contains('@work@example.com')),
      isTrue,
    );
    // A single-account provider stays unlabeled.
    final single = _frame([grok('work@example.com', 57)], width: 110);
    expect(single.any((l) => _plain(l).contains('@work@example.com')), isFalse);
  });

  test('spent duplicate rows keep trust tags when no bar is rendered', () {
    ProviderQuota grok(String account, double used) => ProviderQuota(
          provider: 'grok',
          displayName: 'Grok',
          account: account,
          asOf: _now,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    final lines = _frame(
      [grok('work@example.com', 100), grok('home@example.com', 75)],
      width: 86,
    );
    final spentRow = _plain(lines.firstWhere((l) => l.contains('spent')));
    expect(spentRow, contains('(live, authoritative, quota plan)'));
    expect(spentRow, contains('@work@example.com'));
  });

  test('status-only duplicate rows keep account labels when reset is absent',
      () {
    ProviderQuota grok(String account, String status) => ProviderQuota(
          provider: 'grok',
          displayName: 'Grok',
          account: account,
          asOf: _now,
          status: status,
          windows: const [],
        );
    final lines = _frame(
      [
        grok('work@example.com', 'balance unknown'),
        grok('home@example.com', 'balance unknown'),
      ],
      width: 68,
    );
    expect(
      lines.any((l) => _plain(l).contains('@work@example.com')),
      isTrue,
    );
    expect(
      lines.any((l) => _plain(l).contains('@home@example.com')),
      isTrue,
    );
  });

  test('the route account tag yields whole before clipping', () {
    ProviderQuota grok(String account, double used) => ProviderQuota(
          provider: 'grok',
          displayName: 'Grok',
          account: account,
          asOf: _now,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    final lines = _frame(
      [
        grok('very-long-work-account@example.com', 22),
        grok('home@example.com', 57)
      ],
      width: 58,
    );
    final route = _plain(lines.firstWhere((l) => l.contains('route')));
    expect(route, isNot(contains('@very-long')));
    expect(route, isNot(contains('@very')));
    expect(route.length, 58);
  });

  test('selection in a multi-account fleet marks only the matching account',
      () {
    ProviderQuota grok(String account) => ProviderQuota(
          provider: 'grok',
          displayName: 'Grok',
          account: account,
          asOf: _now,
          windows: [QuotaWindow(label: 'weekly', usedPercent: 40)],
        );
    final providers = [grok('work@example.com'), grok('home@example.com')];
    final lines = renderTopFrame(
      providers: providers,
      suggestion: suggestRoute(providers, _now),
      now: _now,
      width: 110,
      color: false,
      clock: '12:00:00',
      selected: 'grok',
      selectedAccount: 'home@example.com',
    );
    final cursors = lines.where((l) => _plain(l).startsWith('> ')).toList();
    expect(cursors, hasLength(1));
    expect(_plain(cursors.single), contains('@home@example.com'));
  });

  test('the local trust tag yields before a long local status clips', () {
    final q = _q('ollama', const [],
        kind: ProviderQuotaKind.local,
        status: 'qwen2.5-coder 7B Q4_K_M loaded',
        active: true,
        perMachine: true);
    final wide = _frame([q], width: 110);
    final narrow = _frame([q], width: 60);
    expect(
      wide.any((l) => _plain(l).contains('(in use, local runtime, loaded)')),
      isTrue,
    );
    final row =
        _plain(narrow.firstWhere((l) => _plain(l).contains('qwen2.5-coder')));
    expect(row, isNot(contains('local runtime')));
    expect(row, isNot(contains('local run')), reason: 'no clipped tag');
    expect(row, contains('loaded'));
  });

  test('an empty fleet still renders a usable frame', () {
    final lines = _frame(const [], width: 60);
    expect(
        lines.any((l) => _plain(l).contains('no providers detected')), isTrue);
    expect(
      lines.any((l) => _plain(l).contains('login supports Grok')),
      isTrue,
    );
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

  test('a sub-24-column terminal never overflows its width', () {
    final lines = _frame([
      _q('antigravity', [QuotaWindow(label: 'weekly', usedPercent: 50)]),
    ], width: 20);
    for (final line in lines) {
      expect(_plain(line).length, 20, reason: line);
    }
  });

  group('sortProvidersForTop', () {
    // Three clouds with distinct headroom and resets, plus a local runtime.
    List<ProviderQuota> fleet() => [
          _q('claude', [
            QuotaWindow(
                label: 'weekly', usedPercent: 30, resetsAt: _now + 3000),
          ]), // 70% free
          _q('codex', [
            QuotaWindow(label: '5h', usedPercent: 90, resetsAt: _now + 1000),
          ]), // 10% free, soonest reset
          _q('grok', [
            QuotaWindow(label: '5h', usedPercent: 60, resetsAt: _now + 5000),
          ]), // 40% free, latest reset
          _q('ollama', const [],
              kind: ProviderQuotaKind.local, status: 'ready'),
        ];

    List<String> order(List<ProviderQuota> ps) =>
        [for (final q in ps) q.provider];

    test('default order leaves the fleet untouched', () {
      final ps = fleet();
      final out = sortProvidersForTop(
          ps, suggestRoute(ps, _now), _now, TopSort.defaultOrder);
      expect(order(out), ['claude', 'codex', 'grok', 'ollama']);
    });

    test('headroom puts the most free cloud first and sinks the local', () {
      final ps = fleet();
      final out = sortProvidersForTop(
          ps, suggestRoute(ps, _now), _now, TopSort.headroom);
      expect(order(out), ['claude', 'grok', 'codex', 'ollama']);
    });

    test('reset puts the soonest-resetting window first', () {
      final ps = fleet();
      final out =
          sortProvidersForTop(ps, suggestRoute(ps, _now), _now, TopSort.reset);
      expect(order(out).take(3).toList(), ['codex', 'claude', 'grok']);
    });

    test('burn floats the fastest-burning provider up, others hold order', () {
      final ps = fleet();
      final sug = suggestRoute(ps, _now, burnStatsByProvider: const {
        'grok': BurnStat(perHour: 30, sePerHour: 5, samples: 8),
        'claude': BurnStat(perHour: 5, sePerHour: 2, samples: 8),
      });
      final out = sortProvidersForTop(ps, sug, _now, TopSort.burn);
      // grok burns fastest, then claude; codex (no burn) and the local sink,
      // keeping their original relative order.
      expect(order(out), ['grok', 'claude', 'codex', 'ollama']);
    });

    test('burn sort uses account-scoped stats for duplicate providers', () {
      final ps = [
        _q('codex', [QuotaWindow(label: '5h', usedPercent: 30)],
            account: 'home@example.com'),
        _q('codex', [QuotaWindow(label: '5h', usedPercent: 30)],
            account: 'work@example.com'),
      ];
      final sug = suggestRoute(ps, _now, burnStatsByProvider: {
        quotaIdentityKey('codex', 'work@example.com'):
            const BurnStat(perHour: 30, sePerHour: 5, samples: 8),
      });
      final out = sortProvidersForTop(ps, sug, _now, TopSort.burn);
      expect([for (final q in out) q.account],
          ['work@example.com', 'home@example.com']);
    });

    test('an unrankable sort keeps the fleet stable (no burn history)', () {
      final ps = fleet();
      final out =
          sortProvidersForTop(ps, suggestRoute(ps, _now), _now, TopSort.burn);
      expect(order(out), ['claude', 'codex', 'grok', 'ollama']);
    });

    test('stale cached providers do not lead headroom sort', () {
      final ps = [
        _q(
            'grok',
            [
              QuotaWindow(label: 'weekly', usedPercent: 1),
            ],
            stale: true),
        _q('claude', [
          QuotaWindow(label: 'weekly', usedPercent: 30),
        ]),
      ];
      final out = sortProvidersForTop(
          ps, suggestRoute(ps, _now), _now, TopSort.headroom);
      expect(order(out), ['claude', 'grok']);
    });

    test('the footer shows the active sort label', () {
      final ps = fleet();
      final lines = renderTopFrame(
        providers: ps,
        suggestion: suggestRoute(ps, _now),
        now: _now,
        width: 100,
        color: false,
        clock: '12:00:00',
        sort: TopSort.headroom.label,
      );
      expect(lines.any((l) => _plain(l).contains('sort:headroom')), isTrue);
    });
  });

  group('TopSort', () {
    test('next cycles through every mode and wraps to the start', () {
      final seen = <TopSort>[];
      var m = TopSort.defaultOrder;
      for (var i = 0; i < TopSort.values.length; i++) {
        seen.add(m);
        m = m.next;
      }
      expect(seen.toSet(), TopSort.values.toSet());
      expect(m, TopSort.defaultOrder);
    });

    test('parse accepts names, labels, and aliases; rejects junk', () {
      expect(TopSort.parse('headroom'), TopSort.headroom);
      expect(TopSort.parse('strand risk'), TopSort.strand);
      expect(TopSort.parse('risk'), TopSort.strand);
      expect(TopSort.parse('FLEET'), TopSort.defaultOrder);
      expect(TopSort.parse('nope'), isNull);
    });
  });

  group('interactive top', () {
    test('osc52Copy wraps base64 in the OSC 52 clipboard escape', () {
      // "claude" -> base64 "Y2xhdWRl".
      expect(osc52Copy('claude'), '\x1B]52;c;Y2xhdWRl\x07');
    });

    test('moveSelection clamps within range and handles an empty list', () {
      expect(moveSelection(0, 1, 3), 1);
      expect(moveSelection(2, 1, 3), 2); // clamped at the end
      expect(moveSelection(0, -1, 3), 0); // clamped at the start
      expect(moveSelection(5, 0, 3), 2); // an out-of-range start is clamped
      expect(moveSelection(0, 1, 0), -1); // nothing to select
    });

    test('the selected provider row is marked with a cursor', () {
      final providers = [
        _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
        _q('codex', [QuotaWindow(label: '5h', usedPercent: 40)]),
      ];
      final lines = renderTopFrame(
        providers: providers,
        suggestion: suggestRoute(providers, _now),
        now: _now,
        width: 80,
        color: false,
        clock: '12:00:00',
        selected: 'codex',
      );
      final claude = lines.firstWhere((l) => _plain(l).contains('claude'));
      final codex = lines.firstWhere((l) => _plain(l).contains('codex'));
      expect(_plain(codex).startsWith('> '), isTrue);
      expect(_plain(claude).startsWith('> '), isFalse);
    });

    test('the footer surfaces the hidden count and a copy confirmation', () {
      final providers = [
        _q('claude', [QuotaWindow(label: 'weekly', usedPercent: 20)]),
      ];
      final footer = renderTopFrame(
        providers: providers,
        suggestion: suggestRoute(providers, _now),
        now: _now,
        width: 120,
        color: false,
        clock: '12:00:00',
        hidden: 2,
        copied: 'grok',
      ).last;
      expect(_plain(footer), contains('show(2)'));
      expect(_plain(footer), contains('copied grok'));
      expect(_plain(footer), contains('x'));
    });
  });
}
