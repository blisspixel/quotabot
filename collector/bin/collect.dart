import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/util.dart';

/// Usage:
///   quotabot                 Print a readable status table (default)
///   quotabot doctor          Same as above
///   quotabot suggest         Recommend which provider to route work to next
///   quotabot suggest --json  Routing recommendation as JSON (for scripts/agents)
///   quotabot stats [name]    Historical analytics from local 90-day buckets
///   quotabot stats --json    Analytics as JSON
///   quotabot login <name>    Connect grok or antigravity
///   quotabot logout <name>   Disconnect a provider
///   quotabot --json          Print raw JSON (for scripts)
///
/// The reads are metadata lookups, not model calls, so they cost no usage
/// tokens. login/logout manage quotabot's own OAuth grant so a provider stays
/// live without reopening its app.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'login') {
    await _login(args.length > 1 ? args[1] : '');
    return;
  }
  if (args.isNotEmpty && args.first == 'logout') {
    _logout(args.length > 1 ? args[1] : '');
    return;
  }

  // Historical analytics from the long-term buckets.
  if (args.isNotEmpty && args.first == 'stats') {
    final positional = args.skip(1).where((a) => !a.startsWith('-')).toList();
    final only = positional.isEmpty ? null : positional.first.toLowerCase();
    final now = nowEpoch();
    // Discover which providers have history, optionally filtered to one.
    final results = await collectAll();
    final providers = {
      ...results.where((q) => !q.isLocal).map((q) => q.provider),
    }.where((p) => only == null || p == only).toList()
      ..sort();
    final tz = DateTime.now().timeZoneOffset;
    final byProvider = {for (final q in results) q.provider: q};
    final report = <String, dynamic>{};
    for (final p in providers) {
      final ins = Insights.from(loadBuckets(p), now, tzOffset: tz);
      final pace = _paceFor(byProvider[p], ins, now);
      report[p] = {...ins.toJson(), if (pace != null) 'pace': pace.toJson()};
    }
    if (args.contains('--json')) {
      print(const JsonEncoder.withIndent('  ').convert(report));
    } else {
      _printStats(providers, byProvider, now, tz);
    }
    return;
  }

  // Routing recommendation: which provider to use next.
  if (args.isNotEmpty && args.first == 'suggest') {
    final results = await collectAll();
    final suggestion = suggestRoute(results, nowEpoch());
    if (args.contains('--json')) {
      print(const JsonEncoder.withIndent('  ').convert(suggestion.toJson()));
    } else {
      _printSuggest(suggestion);
    }
    return;
  }

  // Bare invocation or explicit doctor -> human friendly table
  if (args.isEmpty || args.contains('doctor')) {
    final results = await collectAll();
    _printDoctor(results);
    return;
  }

  // --json or anything else -> raw JSON for scripting / power users
  final results = await collectAll();
  if (args.contains('doctor')) {
    _printDoctor(results);
    return;
  }
  print(
    const JsonEncoder.withIndent('  ').convert({
      'schema': 'quotabot.v1',
      'generated_at': nowEpoch(),
      'providers': results.map((r) => r.toJson()).toList(),
    }),
  );
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
        stderr.writeln('Antigravity login is not configured: $e');
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

void _printDoctor(List<ProviderQuota> results) {
  final now = nowEpoch();
  print('quotabot doctor  (all checks are metadata reads, 0 usage tokens)\n');
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
    print('  ${namePart.padRight(28)} ${state.padRight(12)} $detail');
    for (final d in q.details) {
      print('  ${' '.padRight(28)} ${' '.padRight(12)} $d');
    }
    final hint = _doctorHint(q, state);
    if (hint != null)
      print('  ${' '.padRight(28)} ${' '.padRight(12)} -> $hint');
  }

  // Close the loop: tell the user where to route work next.
  final suggestion = suggestRoute(results, now);
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

/// Prints a routing recommendation: where to send the next request and why,
/// with the ranked alternatives below it.
void _printSuggest(RouteSuggestion s) {
  print('quotabot suggest  (which subscription to use next, 0 usage tokens)\n');
  final r = s.recommended;
  if (r == null) {
    print('  no provider to route to right now');
  } else {
    final tag = r.isLocal ? ' (local fallback)' : '';
    print('  -> ${r.provider}$tag');
  }
  print('  ${s.reason}\n');

  if (s.ranked.isEmpty) return;
  print('  candidates (best first):');
  for (final c in s.ranked) {
    if (c.isLocal) {
      // Local runtimes have no quota; show them as the always-on fallback.
      print('    ${c.provider.padRight(12)} local fallback  [always on]');
      continue;
    }
    final head = c.headroom == null
        ? '   ? '
        : '${c.headroom!.round().toString().padLeft(3)}%';
    final kind = c.stale ? 'cached' : 'live';
    final state = c.available ? '' : '  spent';
    print('    ${c.provider.padRight(12)} $head free  [$kind]$state');
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
