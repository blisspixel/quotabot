import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/top.dart';
import 'package:quotabot_collector/util.dart';

/// quotabot CLI. Run `quotabot help` for the full command list. Every read is a
/// local metadata lookup, not a model call, so it costs no usage tokens.

const _version = '0.4.0';

late AnsiStyle style;

/// Honors NO_COLOR and CLICOLOR=0, an explicit --color/--no-color, then falls
/// back to whether stdout is an interactive terminal.
bool _useColor(Set<String> flags) {
  if (flags.contains('--no-color')) return false;
  if (flags.contains('--color')) return true;
  if (Platform.environment.containsKey('NO_COLOR')) return false;
  if (Platform.environment['CLICOLOR'] == '0') return false;
  return stdout.hasTerminal;
}

String _jsonPretty(Object? o) => const JsonEncoder.withIndent('  ').convert(o);

/// Runs [task] while showing a spinner on stderr, but only when stderr is a
/// terminal, so piped or scripted output stays clean. The spinner line is
/// erased before the result is printed.
Future<T> _withSpinner<T>(String label, Future<T> Function() task) async {
  if (!stderr.hasTerminal) return task();
  const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  var i = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
    stderr.write('\r${style.cyan(frames[i++ % frames.length])} $label ');
  });
  try {
    return await task();
  } finally {
    timer.cancel();
    stderr.write('\r\x1B[K'); // carriage return + clear to end of line
  }
}

/// Collects every provider's quota behind the spinner.
Future<List<ProviderQuota>> _read() =>
    _withSpinner('reading quota', collectAll);

Map<String, dynamic> _snapshot(List<ProviderQuota> results) => {
      'schema': 'quotabot.v1',
      'generated_at': nowEpoch(),
      'providers': results.map((r) => r.toJson()).toList(),
    };
Future<void> main(List<String> args) async {
  final flags = args.where((a) => a.startsWith('-')).toSet();
  final pos = args.where((a) => !a.startsWith('-')).toList();
  final cmd = pos.isEmpty ? '' : pos.first;
  final wantsJson = flags.contains('--json');
  style = AnsiStyle(_useColor(flags));

  if (cmd == 'help' || flags.contains('--help') || flags.contains('-h')) {
    _printHelp();
    return;
  }
  if (cmd == 'version' || flags.contains('--version') || flags.contains('-v')) {
    stdout.writeln('quotabot $_version');
    return;
  }

  switch (cmd) {
    case 'login':
      await _login(pos.length > 1 ? pos[1] : '');
      return;
    case 'logout':
      _logout(pos.length > 1 ? pos[1] : '');
      return;
    case 'check':
      if (pos.length < 2) {
        stderr.writeln('usage: quotabot check <provider>');
        exitCode = 64;
        return;
      }
      await _check(pos[1], wantsJson);
      return;
    case 'suggest':
      final results = await _read();
      final riskZ = _doubleOption(flags, 'risk', 0).clamp(0.0, 5.0).toDouble();
      final s = _suggestFor(results, nowEpoch(), riskZ: riskZ);
      wantsJson ? print(_jsonPretty(s.toJson())) : _printSuggest(s);
      return;
    case 'stats':
      await _runStats(pos.skip(1).toList(), wantsJson);
      return;
    case 'top':
      await _runTop(flags);
      return;
    case 'models':
      final results = await _read();
      final now = nowEpoch();
      final reqs = _modelRequirements(flags);
      if (wantsJson) {
        print(_jsonPretty(modelRegistryJson(results, now,
            catalog: kModelCatalog, requirements: reqs)));
      } else {
        _printModels(buildModelRegistry(results, now,
            catalog: kModelCatalog, requirements: reqs));
      }
      return;
    case 'calibration':
      await _runCalibration(wantsJson);
      return;
  }

  // Snapshot and the default status table share one collect.
  final results = await _read();
  if (cmd == 'json' || (cmd.isEmpty && wantsJson)) {
    print(_jsonPretty(_snapshot(results)));
    return;
  }
  if (cmd.isEmpty || cmd == 'status' || cmd == 'doctor') {
    wantsJson ? print(_jsonPretty(_snapshot(results))) : _printDoctor(results);
    return;
  }

  stderr.writeln('${style.red('unknown command')}: $cmd');
  stderr.writeln('run "quotabot help" for the command list');
  exitCode = 64;
}

/// The routing recommendation for [results], discounted by recent burn. Shared
/// by `suggest`, `doctor`, and the live `top` view so they never diverge.
RouteSuggestion _suggestFor(
  List<ProviderQuota> results,
  int now, {
  double riskZ = 0,
}) =>
    suggestRoute(
      results,
      now,
      burnStatsByProvider:
          recentBurnStatsByProvider(results.map((q) => q.provider), now),
      riskZ: riskZ,
    );

/// Reads a `--name=double` option from [flags], or [dflt] when absent or invalid.
double _doubleOption(Iterable<String> flags, String name, double dflt) {
  final prefix = '--$name=';
  for (final f in flags) {
    if (f.startsWith(prefix)) {
      return double.tryParse(f.substring(prefix.length)) ?? dflt;
    }
  }
  return dflt;
}

/// Parses a context size like "200k", "1m", or "200000" into tokens, or null.
int? _parseContext(String? s) {
  if (s == null) return null;
  final t = s.toLowerCase().trim();
  final mult = t.endsWith('m')
      ? 1000000
      : t.endsWith('k')
          ? 1000
          : 1;
  final digits = mult == 1 ? t : t.substring(0, t.length - 1);
  final value = double.tryParse(digits);
  return value == null ? null : (value * mult).round();
}

/// Builds the model requirement filter from CLI flags: a coarse `--task` profile
/// overlaid with explicit `--min-context`, `--require-*`, and `--tier-*` flags.
/// quotabot never sees the task itself, only this profile.
ModelRequirements _modelRequirements(Set<String> flags) {
  final explicit = ModelRequirements(
    minContextTokens: _parseContext(_stringOption(flags, 'min-context', null)),
    requireTools: flags.contains('--require-tools'),
    requireVision: flags.contains('--require-vision'),
    requireReasoning: flags.contains('--require-reasoning'),
    tierFloor: _stringOption(flags, 'tier-floor', null),
    tierCeiling: _stringOption(flags, 'tier-ceiling', null),
  );
  return taskProfile(_stringOption(flags, 'task', null)).merge(explicit);
}

/// Reads a `--name=value` string option from [flags], or [dflt] when absent.
String? _stringOption(Iterable<String> flags, String name, String? dflt) {
  final prefix = '--$name=';
  for (final f in flags) {
    if (f.startsWith(prefix)) return f.substring(prefix.length);
  }
  return dflt;
}

/// Reads an `--name=int` option from [flags], or [dflt] when absent or invalid.
int _intOption(Iterable<String> flags, String name, int dflt) {
  final prefix = '--$name=';
  for (final f in flags) {
    if (f.startsWith(prefix)) {
      return int.tryParse(f.substring(prefix.length)) ?? dflt;
    }
  }
  return dflt;
}

int _termCols() {
  try {
    return stdout.terminalColumns;
  } catch (_) {
    return 80;
  }
}

String _clock() {
  final d = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// `top`: a live, htop-style dashboard that redraws in place.
///
/// On a real terminal it enters the alternate screen, hides the cursor, reads
/// keys raw (q to quit, r to refresh now), repaints countdowns every second, and
/// re-collects every `--interval` seconds (default 10, minimum 2). When stdout
/// is not a terminal (piped or dumb) it degrades to printing one plain frame and
/// exiting, so `quotabot top | cat` still yields a snapshot.
Future<void> _runTop(Set<String> flags) async {
  final color = _useColor(flags);
  final depth =
      detectColorDepth(Platform.environment, hasTerminal: stdout.hasTerminal);
  final palette = paletteFromSpec(
    _stringOption(flags, 'theme', Platform.environment['QUOTABOT_THEME']),
  );
  final interval = _intOption(flags, 'interval', 10).clamp(2, 3600);

  if (!stdout.hasTerminal) {
    final data = await collectAll();
    final now = nowEpoch();
    final lines = renderTopFrame(
      providers: data,
      suggestion: _suggestFor(data, now),
      now: now,
      width: 80,
      color: false,
      clock: _clock(),
      palette: palette,
    );
    stdout.writeln(lines.join('\n'));
    return;
  }

  var data = <ProviderQuota>[];
  var loading = true;
  final quit = Completer<void>();
  Timer? repaint;
  Timer? refresh;

  void draw() {
    final now = nowEpoch();
    final List<String> lines;
    if (loading && data.isEmpty) {
      lines = ['  ${style.bold('quotabot')}', '', '  reading quota...'];
    } else {
      lines = renderTopFrame(
        providers: data,
        suggestion: _suggestFor(data, now),
        now: now,
        width: _termCols(),
        color: color,
        clock: _clock(),
        depth: depth,
        palette: palette,
      );
    }
    final buf = StringBuffer()
      ..write('\x1B[?2026h') // begin synchronized update (no-op if unsupported)
      ..write('\x1B[H'); // cursor home
    for (final line in lines) {
      buf
        ..write(line)
        ..write('\x1B[K') // clear stale tail from a previous, longer frame
        ..write('\r\n');
    }
    buf
      ..write('\x1B[J') // clear any rows below a now-shorter frame
      ..write('\x1B[?2026l'); // end synchronized update
    stdout.write(buf.toString());
  }

  Future<void> reload() async {
    try {
      data = await collectAll();
      loading = false;
      draw();
    } catch (_) {
      // Keep the last good frame on a transient collection error.
    }
  }

  final priorEcho = stdin.echoMode;
  final priorLine = stdin.lineMode;
  stdout.write('\x1B[?1049h\x1B[?25l'); // alternate screen + hide cursor
  try {
    stdin.echoMode = false;
    stdin.lineMode = false;
  } catch (_) {
    // Some terminals disallow raw mode; keys still arrive line-buffered.
  }

  void stop() {
    if (!quit.isCompleted) quit.complete();
  }

  final keys = stdin.listen((bytes) {
    for (final b in bytes) {
      if (b == 113 || b == 81 || b == 3) return stop(); // q, Q, Ctrl-C
      if (b == 114 || b == 82) reload(); // r, R
    }
  });
  final sigint = ProcessSignal.sigint.watch().listen((_) => stop());

  draw(); // immediate "reading quota" frame
  await reload(); // first real snapshot
  repaint = Timer.periodic(const Duration(seconds: 1), (_) => draw());
  refresh = Timer.periodic(Duration(seconds: interval), (_) => reload());

  await quit.future;
  repaint.cancel();
  refresh.cancel();
  await keys.cancel();
  await sigint.cancel();
  try {
    stdin.echoMode = priorEcho;
    stdin.lineMode = priorLine;
  } catch (_) {
    // Best effort restore.
  }
  stdout.write('\x1B[?25h\x1B[?1049l'); // show cursor + leave alternate screen
}

void _printHelp() {
  String head(String s) => style.bold(s);
  stdout.writeln(
    '${style.bold('quotabot')} $_version  -  your AI subscription quota, in one place',
  );
  stdout.writeln('');
  stdout.writeln(head('USAGE'));
  stdout.writeln('  quotabot <command> [options]');
  stdout.writeln('');
  stdout.writeln(head('SEE QUOTA'));
  stdout.writeln(
    '  status, doctor      every provider, its windows and resets (default)',
  );
  stdout.writeln(
    '  top                 live dashboard, redraws in place (q quit, r refresh)',
  );
  stdout.writeln(
    '  check <provider>    whether one provider is usable now, and its reset',
  );
  stdout.writeln(
    '  models              every model you can route to now, with budget + caps',
  );
  stdout.writeln(
    '  calibration         how often quotabot\'s predictions come true (history)',
  );
  stdout.writeln(
    '  stats [provider]    90-day analytics: distribution, reliability, pace',
  );
  stdout.writeln('');
  stdout.writeln(head('ROUTE'));
  stdout
      .writeln('  suggest             which subscription to use next (ranked)');
  stdout.writeln('');
  stdout.writeln(head('CONNECT'));
  stdout.writeln(
    '  login <provider>    connect grok or antigravity (keeps it live)',
  );
  stdout.writeln('  logout <provider>   disconnect a provider');
  stdout.writeln('');
  stdout.writeln(head('OTHER'));
  stdout.writeln('  json                full snapshot as quotabot.v1 JSON');
  stdout.writeln('  help, version');
  stdout.writeln('');
  stdout.writeln(head('OPTIONS'));
  stdout.writeln(
    '  --json              machine-readable output (status/check/suggest/stats/json)',
  );
  stdout.writeln(
    '  --color, --no-color force or disable color (also honors NO_COLOR)',
  );
  stdout.writeln(
    '  --interval=N        top: seconds between refreshes (default 10, min 2)',
  );
  stdout.writeln(
    '  --theme=NAME        top: palette (${paletteNames.join(', ')}, '
    'or custom:HEX-HEX-HEX-HEX); also QUOTABOT_THEME',
  );
  stdout.writeln(
    '  --risk=Z            suggest: risk aversion (0 = mean, higher avoids '
    'uncertain caps)',
  );
  stdout.writeln(
    '  --task=LEVEL        models: simple|standard|hard (coarse capability needs)',
  );
  stdout.writeln(
    '  --min-context=N --require-tools/vision/reasoning --tier-floor/ceiling=T'
    '   models filters',
  );
  stdout.writeln('');
  stdout.writeln(
    style.dim(
        '  Every command is a local metadata read and costs no usage tokens.'),
  );
  stdout.writeln(
    style.dim(
        '  Local models (Ollama/LM Studio/Lemonade) appear once their server is'),
  );
  stdout.writeln(
    style.dim(
        '  running; LM Studio needs its local server started (lms server start).'),
  );
  stdout.writeln(
    style.dim(
        '  Agents: see AGENTS.md. MCP server: dart run bin/mcp_server.dart.'),
  );
}

Future<void> _runStats(List<String> rest, bool wantsJson) async {
  final only = rest.isEmpty ? null : rest.first.toLowerCase();
  final now = nowEpoch();
  final results = await _read();
  final providers = {
    ...results.where((q) => !q.isLocal).map((q) => q.provider),
  }.where((p) => only == null || p == only).toList()
    ..sort();
  final tz = DateTime.now().timeZoneOffset;
  final byProvider = {for (final q in results) q.provider: q};
  if (wantsJson) {
    final report = <String, dynamic>{};
    for (final p in providers) {
      final ins = Insights.from(loadBuckets(p), now, tzOffset: tz);
      final pace = _paceFor(byProvider[p], ins, now);
      report[p] = {...ins.toJson(), if (pace != null) 'pace': pace.toJson()};
    }
    print(_jsonPretty(report));
  } else {
    _printStats(providers, byProvider, now, tz);
  }
}

/// `check <provider>`: is this one usable right now, and when does it reset.
Future<void> _check(String name, bool wantsJson) async {
  final results = await _read();
  final now = nowEpoch();
  final key = name.toLowerCase();
  ProviderQuota? q;
  for (final r in results) {
    if (r.provider == key || r.displayName.toLowerCase() == key) {
      q = r;
      break;
    }
  }
  if (q == null) {
    if (wantsJson) {
      print(_jsonPretty({
        'schema': 'quotabot.v1',
        'provider': key,
        'found': false,
      }));
    } else {
      stderr.writeln('no provider named "$name"');
      stderr.writeln('known: ${results.map((r) => r.provider).join(', ')}');
    }
    exitCode = 1;
    return;
  }
  final head = providerHeadroom(q, now);
  final binding = bindingWindow(q, now);
  final available = q.isLocal ? q.ok : (head != null && head > 0.5);
  final reset = binding?.resetsAt;
  if (wantsJson) {
    print(_jsonPretty({
      'schema': 'quotabot.v1',
      'provider': q.provider,
      'account': q.account,
      'available': available,
      'headroom_percent': head,
      'resets_at': reset,
      'stale': q.stale,
    }));
    return;
  }
  final label = available ? style.green('available') : style.red('unavailable');
  final pct =
      head == null ? '' : '  ${style.health(head, '${head.round()}% free')}';
  final rs = reset == null ? '' : style.dim('  resets ${_in(reset, now)}');
  final staleTag = q.stale ? style.dim(' (cached)') : '';
  stdout.writeln('${style.bold(q.displayName)}: $label$pct$rs$staleTag');
}

Future<void> _login(String provider) async {
  switch (provider) {
    case 'grok':
      await XaiAuth().deviceLogin(
        prompt: (url, code) {
          stderr.writeln('Open this URL and confirm the code $code:\n  $url');
        },
      );
      stderr.writeln('Grok connected.');
      break;
    case 'antigravity':
      try {
        await GoogleAuth().loginLoopback(
          showUrl: (url) {
            stderr.writeln('');
            stderr.writeln(
              'Opening your browser for Google login (Antigravity)...',
            );
            stderr.writeln(
              'If the browser does not open or you see an error, manually visit this URL:',
            );
            stderr.writeln(url);
            stderr.writeln('');
          },
        );
        stderr.writeln(
          'Antigravity connected. You can now run "quotabot doctor" to verify live data.',
        );
      } catch (e) {
        stderr.writeln('Antigravity login failed: $e');
        exitCode = 64;
      }
      break;
    default:
      stderr.writeln('Usage: quotabot login <grok|antigravity>');
  }
}

void _logout(String provider) {
  if (provider != 'grok' && provider != 'antigravity') {
    stderr.writeln('Usage: quotabot logout <grok|antigravity>');
    return;
  }
  TokenStore.clear(provider);
  stderr.writeln('$provider disconnected.');
}

/// Pads a state to the column width, then colors it (so the padding stays
/// outside the ANSI codes and alignment is preserved).
String _stateStyled(String state) {
  final padded = state.padRight(12);
  switch (state) {
    case 'live':
      return style.green(padded);
    case 'in use':
    case 'local':
      return style.cyan(padded);
    case 'cached':
      return style.yellow(padded);
    case 'OUT OF QUOTA':
    case 'ERROR':
      return style.red(padded);
    default: // no live data
      return style.dim(padded);
  }
}

void _printDoctor(List<ProviderQuota> results) {
  final now = nowEpoch();
  print(
    '${style.bold('quotabot')}  ${style.dim('your quota across providers, 0 usage tokens')}\n',
  );
  for (final q in results) {
    bool exhausted = false;
    if (q.windows.isNotEmpty) {
      final minRem = providerHeadroom(q, now) ?? 100;
      exhausted = minRem <= 0.5;
    }
    final state = q.isLocal
        ? (q.active ? 'in use' : 'local')
        : !q.ok
            ? 'ERROR'
            : q.windows.isEmpty
                ? 'no live data'
                : q.stale
                    ? 'cached'
                    : exhausted
                        ? 'OUT OF QUOTA'
                        : 'live';
    final detail = q.isLocal
        ? (q.status ?? '')
        : q.windows.isEmpty
            ? (q.error ?? '')
            : q.windows.map((w) {
                final pct = w.percent?.round();
                final reset = w.resetsAt == null
                    ? ''
                    : ' (resets ${_in(w.resetsAt!, now)})';
                return '${w.label} ${pct ?? '?'}%used$reset';
              }).join(', ');
    final acct = (q.account != 'default' &&
            q.account != 'unknown' &&
            q.account != 'installed' &&
            q.account != 'cli')
        ? ' (${q.account})'
        : '';
    final namePart = '${q.displayName}$acct';
    print('  ${namePart.padRight(28)} ${_stateStyled(state)} $detail');
    for (final d in q.details) {
      print('  ${' '.padRight(28)} ${' '.padRight(12)} $d');
    }
    final hint = _doctorHint(q, state);
    if (hint != null)
      print('  ${' '.padRight(28)} ${' '.padRight(12)} -> $hint');
  }

  // Close the loop: tell the user where to route work next.
  final suggestion = _suggestFor(results, now);
  print('\nSuggested: ${suggestion.reason}');
  print('  (run "quotabot suggest" for the full ranked list)');

  // Passive detection for robustness: report installed popular agentic tools
  // even if no active subscription or full quota data (e.g. cancelled Kiro CLI).
  final detected = detectInstalledAgenticTools();
  if (detected.isNotEmpty) {
    print('\nDetected installed agentic dev coding tools (passive check):');
    for (final t in detected) {
      print(
        '  $t (local data may be available opportunistically; see DATA_SOURCES)',
      );
    }
    print(
      '  (Aider/Cline etc often use underlying provider quotas already tracked above.)',
    );
  }
}

/// `calibration`: grade quotabot's own strand predictions against the user's
/// recorded history, so "how often is it right" is a measured number, not a claim.
Future<void> _runCalibration(bool wantsJson) async {
  final results = await _read();
  final now = nowEpoch();
  final byProvider = <String, List<HeadroomBucket>>{};
  for (final q in results.where((q) => !q.isLocal)) {
    final b = loadBuckets(q.provider);
    if (b.isNotEmpty) byProvider[q.provider] = b;
  }
  final overall = calibrationAcross(byProvider, now);
  if (wantsJson) {
    print(_jsonPretty({
      'schema': 'quotabot.calibration.v1',
      'generated_at': now,
      'overall': overall.toJson(),
      'by_provider': {
        for (final e in byProvider.entries)
          e.key: calibrationFromHistory(e.value, now).toJson(),
      },
    }));
  } else {
    _printCalibration(overall, byProvider, now);
  }
}

/// Prints the calibration report: the headline accuracy, a reliability diagram
/// (predicted probability versus what actually happened), and a per-provider line.
void _printCalibration(
  CalibrationReport overall,
  Map<String, List<HeadroomBucket>> byProvider,
  int now,
) {
  print(
    'quotabot calibration  (how often quotabot\'s strand calls come true, '
    '0 usage tokens)\n',
  );
  if (overall.samples == 0) {
    print(
        '  not enough resolved history yet; leave quotabot running for a few');
    print('  hours and check back. It grades each prediction once its horizon');
    print('  has fully elapsed, so this fills in over time.');
    return;
  }
  final pct = (overall.calibration! * 100).round();
  print(
    '  ${style.bold('$pct% calibrated')} over ${overall.samples} predictions, '
    '${overall.spanDays}d of history',
  );
  print(
    style.dim(
      '  Brier ${overall.brier!.toStringAsFixed(3)} (0 = perfect), '
      '${overall.horizonHours}h horizon\n',
    ),
  );
  print(style.dim('  predicted -> actually spent   (predictions)'));
  for (final b in overall.bins) {
    final pp = (b.meanPredicted * 100).round().toString().padLeft(3);
    final oo = (b.observedFrequency * 100).round().toString().padLeft(3);
    print('    $pp%  ->  $oo%   ${style.dim('(${b.count})')}');
  }
  print('');
  for (final e in byProvider.entries) {
    final r = calibrationFromHistory(e.value, now);
    if (r.samples == 0) continue;
    print(
      '  ${e.key.padRight(12)} ${(r.calibration! * 100).round()}% '
      'calibrated  ${style.dim('(${r.samples})')}',
    );
  }
}

/// A compact context-window label: "1M", "200K".
String _ctxLabel(int tokens) => tokens >= 1000000
    ? '${(tokens / 1000000).round()}M'
    : '${(tokens / 1000).round()}K';

/// Prints the model registry: every model you can route to now, with the live
/// budget that gates it and its capability hints.
void _printModels(List<ModelEntry> reg) {
  print('quotabot models  (what you can route to now, 0 usage tokens)\n');
  if (reg.isEmpty) {
    print('  no models detected; start a local runtime or connect a provider');
    return;
  }
  for (final e in reg) {
    final m = e.model;
    final budget = e.local
        ? style.cyan('local'.padRight(9))
        : (e.headroomPercent == null
            ? style.dim('?'.padRight(9))
            : style.health(
                e.headroomPercent!,
                '${e.headroomPercent!.round()}% free'.padRight(9),
              ));
    final ctx = m.contextTokens == null
        ? ''
        : style.dim('  ${_ctxLabel(m.contextTokens!)} ctx');
    final caps = [
      if (m.tier != null) m.tier!,
      if (m.tools == true) 'tools',
      if (m.vision == true) 'vision',
      if (m.reasoning != null) 'reason',
    ].join(',');
    final capStr = caps.isEmpty ? '' : style.dim('  $caps');
    final loaded = (e.local && m.loaded) ? style.cyan('  [loaded]') : '';
    final spent = e.available ? '' : style.red('  spent');
    print(
      '  ${m.id.padRight(22)} ${e.provider.padRight(11)} '
      '$budget$ctx$capStr$loaded$spent',
    );
  }
  print(style.dim('\n  capability catalog updated $kCatalogUpdated'));
}

/// Prints a routing recommendation: where to send the next request and why,
/// with the ranked alternatives below it.
void _printSuggest(RouteSuggestion s) {
  print('quotabot suggest  (which subscription to use next, 0 usage tokens)\n');
  final r = s.recommended;
  if (r == null) {
    print('  no provider to route to right now');
  } else {
    final tag = r.isLocal ? style.dim(' (local fallback)') : '';
    print('  ${style.green('->')} ${style.bold(r.provider)}$tag');
  }
  print('  ${s.reason}\n');

  if (s.ranked.isEmpty) return;
  print('  candidates (best first):');
  for (final c in s.ranked) {
    if (c.isLocal) {
      // Local runtimes have no quota; show them as the always-on fallback.
      print(
        '    ${c.provider.padRight(12)} ${style.cyan('local fallback')}  ${style.dim('[always on]')}',
      );
      continue;
    }
    final pct = c.headroom == null
        ? '   ? '
        : '${c.headroom!.round().toString().padLeft(3)}%';
    final head = c.headroom == null ? pct : style.health(c.headroom!, pct);
    final kind = style.dim('[${c.stale ? 'cached' : 'live'}]');
    final state = c.available ? '' : style.red('  spent');
    final conf = c.confidence == null
        ? ''
        : style.dim('  conf ${(c.confidence! * 100).round()}%');
    final strand = (c.strandProbability != null && c.strandProbability! >= 0.2)
        ? style.orange('  strand ${(c.strandProbability! * 100).round()}%')
        : '';
    print('    ${c.provider.padRight(12)} $head free  $kind$conf$strand$state');
  }
}

/// Pace for a provider from its live binding window plus the recent burn rate.
Pace? _paceFor(ProviderQuota? q, Insights ins, int now) {
  if (q == null) return null;
  final binding = bindingWindow(q, now);
  final headroom = providerHeadroom(q, now);
  if (headroom == null) return null;
  return computePace(
    headroom: headroom,
    resetsAt: binding?.resetsAt,
    burnPerHour: ins.burnPerHour,
    now: now,
  );
}

/// Prints historical analytics per provider: distribution, reliability, usage
/// pattern, and a forward-looking pace read for the current window.
void _printStats(
  List<String> providers,
  Map<String, ProviderQuota> live,
  int now,
  Duration tz,
) {
  print(
    'quotabot stats  (90-day analytics from local history, 0 usage tokens)\n',
  );
  if (providers.isEmpty) {
    print('  no history yet; leave quotabot running to build it');
    return;
  }

  // Portfolio view: where you actually spend, and what you barely use.
  final insMap = {
    for (final p in providers)
      p: Insights.from(loadBuckets(p), now, tzOffset: tz),
  };
  final port = portfolioInsight(insMap);
  if (port.mostUsed != null) {
    print(
      '  Most used: ${port.mostUsed!.provider} '
      '(peaks ~${port.mostUsed!.peakUsed.round()}% used)',
    );
    final least = port.leastUsed!;
    if (least.provider != port.mostUsed!.provider) {
      print(
        '  Least used: ${least.provider} '
        '(peaks ~${least.peakUsed.round()}% used)',
      );
    }
    for (final u in port.underused) {
      print(
        '  -> you rarely use much of ${u.provider} '
        '(~${u.peakUsed.round()}% peak); a lower tier may be enough',
      );
    }
    print('');
  }

  for (final p in providers) {
    final ins = Insights.from(loadBuckets(p), now, tzOffset: tz);
    if (ins.samples == 0) {
      print('  ${p.padRight(12)} no history yet');
      continue;
    }
    final mean = ins.mean!.round();
    final rel = (ins.reliability! * 100).round();
    print(
      '  ${p.padRight(12)} avg ${mean.toString().padLeft(3)}% free'
      '   p10/p50/p90 ${_pct(ins.p10)}/${_pct(ins.p50)}/${_pct(ins.p90)}'
      '   usable $rel% of the time',
    );
    // Money read: how high usage usually climbs, how much typically goes unused.
    if (ins.typicalPeakUsed != null) {
      print(
        '  ${' '.padRight(12)} typically peaks ~${ins.typicalPeakUsed!.round()}% used,'
        ' leaves ~${ins.typicalUnused!.round()}% on the table',
      );
    }
    final extras = <String>[];
    if (_meaningfulTrend(ins)) {
      final dir = ins.trendPerDay! < 0 ? 'tightening' : 'easing';
      extras.add('$dir ${ins.trendPerDay!.abs().toStringAsFixed(1)}%/day');
    }
    if (ins.tightestHour != null) {
      extras.add(
        'tightest ${_hourLabel(ins.tightestHour!)}'
        '${ins.tightestDay != null ? ' ${_dayLabel(ins.tightestDay!)}' : ''}',
      );
    }
    extras.add('${ins.samples} samples / ${ins.spanDays}d');
    print('  ${' '.padRight(12)} ${extras.join('   ')}');
    final pace = _paceFor(live[p], ins, now);
    if (pace != null && pace.burnPerHour >= 0.2) {
      print('  ${' '.padRight(12)} pace: ${pace.verdict}');
    }
  }
}

/// True when a trend is both confident and large enough to be worth showing.
/// A perfectly flat series fits with R-squared 1 but a ~0 slope, which should
/// not read as "easing".
bool _meaningfulTrend(Insights ins) =>
    ins.trendPerDay != null &&
    (ins.trendConfidence ?? 0) >= 0.3 &&
    ins.trendPerDay!.abs() >= 0.15;

String _dayLabel(int day) =>
    const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][day % 7];

String _pct(double? v) => v == null ? '?' : '${v.round()}%';

String _hourLabel(int hour24) {
  final ampm = hour24 >= 12 ? 'pm' : 'am';
  final h = hour24 % 12 == 0 ? 12 : hour24 % 12;
  return '$h$ampm';
}

/// A next-step suggestion for a provider row, or null when none applies.
/// Turns the status table into a guided setup: cached providers that support a
/// login are pointed at it; providers with no data are pointed at their app.
String? _doctorHint(ProviderQuota q, String state) {
  const canLogin = {'grok', 'antigravity'};
  if (state == 'cached' && canLogin.contains(q.provider)) {
    return 'run: quotabot login ${q.provider}  (keeps it live without reopening the app)';
  }
  if (state == 'no live data' && !q.isLocal) {
    return 'open the ${q.displayName} app once so it writes local state, then re-run';
  }
  return null;
}

String _in(int resetsAt, int now) {
  var s = resetsAt - now;
  if (s <= 0) return 'now';
  final d = s ~/ 86400;
  s %= 86400;
  final h = s ~/ 3600;
  if (d > 0) return '${d}d${h}h';
  return '${h}h${(s % 3600) ~/ 60}m';
}
