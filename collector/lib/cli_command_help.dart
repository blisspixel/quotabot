/// Focused help for CLI commands that do not have their own printer.
///
/// `suggest`, `models`, `update`, `theme`, `claude-status`, and `mcp` keep
/// the printers already next to those commands. Every other name in
/// [knownCliCommands] is here, or is named in [commandsWithGlobalHelp].
library;

import 'palette.dart';
import 'simulation.dart';
import 'top.dart';

/// Commands `quotabot help` accepts. Empty means the default status view.
const knownCliCommands = <String>{
  'calibration',
  'check',
  'claude-status',
  'doctor',
  'explain',
  'hide',
  'hidden',
  'json',
  'login',
  'logout',
  'manual',
  'mcp',
  'models',
  'report',
  'stats',
  'status',
  'suggest',
  'theme',
  'top',
  'unhide',
  'update',
  'verify',
  'version',
  'watch',
};

/// Commands whose help is the global index on purpose. Empty unless a command
/// truly has no options of its own.
const commandsWithGlobalHelp = <String>{};

/// Lines for [command], or null when that command uses a dedicated printer
/// or the global index.
List<String>? focusedCommandHelp(String? command) {
  if (command == null || commandsWithGlobalHelp.contains(command)) return null;
  final sorts = TopSort.values.map((mode) => mode.cliName).join(', ');
  final palettes = paletteNames.join(', ');
  final states = simulationStates.join(', ');
  return switch (command) {
    'top' => _top(sorts, palettes, states),
    'doctor' => _doctor(states),
    'status' => _status(states),
    'json' => _json(states),
    'check' => _check(states),
    'verify' => _verify(states),
    'version' => _version(),
    'login' => _login(),
    'logout' => _logout(),
    'hide' => _hide(),
    'unhide' => _unhide(),
    'hidden' => _hidden(),
    'watch' => _watch(states),
    'explain' => _explain(),
    'report' => _report(states),
    'stats' => _stats(states),
    'calibration' => _calibration(states),
    'manual' => _manual(),
    _ => null,
  };
}

List<String> _top(String sorts, String palettes, String states) => [
      'quotabot top',
      '',
      'Live quota table. Refreshes in place on a terminal. A pipe or a dumb',
      'terminal prints one plain frame and exits.',
      '',
      'USAGE',
      '  quotabot top [options]',
      '',
      'OPTIONS',
      '  --interval=N       seconds between refreshes (2..3600).',
      '                     Out of range values are clamped. A non-integer is',
      '                     a usage error. Default is adaptive.',
      '                     Does not bypass a provider cooldown.',
      '  --sort=NAME        starting order: $sorts.',
      '                     Also QUOTABOT_SORT. The s key cycles the order.',
      '  --theme=NAME       24-bit palette: $palettes,',
      '                     or custom:HEX-HEX-HEX-HEX[-HEX] for an optional accent.',
      '                     No theme follows the terminal.',
      '                     Also QUOTABOT_THEME. light, dark, and retired names do not recolor.',
      '  --truecolor        force 24-bit gradient meters.',
      ..._quotaOptions(states, json: false),
      '',
      'KEYS',
      '  q or Ctrl-C   quit',
      '  r             refresh now',
      '  s             cycle sort',
      '  j, k, up, down  move the cursor',
      '  x or h        hide the selected provider (same list as quotabot hide)',
      '  u             restore a provider hidden this session',
      '  c             copy the recommended route',
      '  m             inspect models for the selected local runtime',
      '',
      'The built-in palette names above are the set this build ships.',
    ];

List<String> _doctor(String states) => [
      'quotabot doctor',
      '',
      'Every provider, its windows, and its resets, plus sign-in readiness.',
      'Human output matches status. JSON adds read_state on each provider,',
      'and next_step when recovery has one. It also adds a stored Claude',
      'session projection when one exists.',
      'That projection is local evidence. It is not a quota read and it does',
      'not change the route.',
      '',
      'USAGE',
      '  quotabot doctor [options]',
      '',
      'OPTIONS',
      ..._quotaOptions(states),
    ];

List<String> _status(String states) => [
      'quotabot status',
      '',
      'Every provider, its windows, and its resets. This is also the default',
      'when no command is given. Human output includes the route line.',
      '',
      'USAGE',
      '  quotabot status [options]',
      '  quotabot [options]',
      '',
      'OPTIONS',
      ..._quotaOptions(states),
    ];

List<String> _json(String states) => [
      'quotabot json',
      '',
      'Full snapshot as quotabot.v1 JSON.',
      '',
      'USAGE',
      '  quotabot json [options]',
      '',
      'OPTIONS',
      ..._quotaOptions(states),
    ];

List<String> _check(String states) => [
      'quotabot check',
      '',
      'One provider from the current view: whether it is usable, and when it',
      'resets. A failed live read prints its error. Stale headroom stays',
      'last-known evidence and is not treated as available.',
      '',
      'USAGE',
      '  quotabot check <provider> [options]',
      '',
      'OPTIONS',
      '  --account=VALUE    exact returned account',
      ..._quotaOptions(states),
    ];

List<String> _version() => [
      'quotabot version',
      '',
      'Print the CLI version and exit. This does not read quota.',
      '',
      'USAGE',
      '  quotabot version',
      '  quotabot --version',
      '  quotabot -v',
      '',
      'Unknown flags and extra arguments are a usage error.',
      '--version and -v also print the version when they are the only flags.',
    ];

List<String> _verify(String states) => [
      'quotabot verify',
      '',
      'Honesty check for the current snapshot. Exit 65 when a check fails.',
      'Recovery writes bounded local metadata for one exact account. It does',
      'not call a model.',
      '',
      'USAGE',
      '  quotabot verify [options]',
      '',
      'OPTIONS',
      '  --require-live     fail unless every selected provider read is fresh',
      '  --recover-drift=PROVIDER --account=EXACT --yes',
      '                     replace one exact drift baseline',
      '  --recover-analytics=PROVIDER --account=EXACT --tier=history|buckets',
      '                     inspect one quarantine. Add --yes to archive first,',
      '                     then exact-merge provable history or restart that tier empty',
      '  --account=VALUE    exact current account from unfiltered quotabot --json',
      ..._quotaOptions(states),
    ];

List<String> _login() => [
      'quotabot login',
      '',
      'Named sign-in for one provider. The grant quotabot stores is its own.',
      'Host credential files are not modified. A browser or device prompt is',
      'the provider consent step, not proof that quota was read.',
      '',
      'USAGE',
      '  quotabot login <grok|antigravity|claude|codex>',
      '',
      'OPTIONS',
      '  --color, --no-color',
    ];

List<String> _logout() => [
      'quotabot logout',
      '',
      'Remove the quotabot-owned grant for one provider.',
      '',
      'USAGE',
      '  quotabot logout <grok|antigravity|claude|codex>',
      '',
      'OPTIONS',
      '  --color, --no-color',
    ];

List<String> _hide() => [
      'quotabot hide',
      '',
      'Keep a provider off the default view until unhide. The list is local.',
      'The name must be a known provider or a saved manual entry. An unknown',
      'name exits 64 and prints the known list.',
      '',
      'USAGE',
      '  quotabot hide <provider>',
      '',
      'OPTIONS',
      '  --json',
      '  --color, --no-color',
    ];

List<String> _unhide() => [
      'quotabot unhide',
      '',
      'Show a previously hidden provider again. A known provider that is not',
      'hidden is left unchanged.',
      '',
      'USAGE',
      '  quotabot unhide <provider>',
      '',
      'OPTIONS',
      '  --json',
      '  --color, --no-color',
    ];

List<String> _hidden() => [
      'quotabot hidden',
      '',
      'List providers kept off the default view, including leftovers still',
      'stored in desktop prefs.',
      '',
      'USAGE',
      '  quotabot hidden',
      '',
      'OPTIONS',
      '  --json',
      '  --color, --no-color',
    ];

List<String> _watch(String states) => [
      'quotabot watch',
      '',
      'Print a quotabot.alert.v1 line when a binding window crosses into red,',
      'and name a better route when one exists. Amber is used for a',
      'projected-waste alert from --waste-threshold. Metadata only.',
      '',
      'USAGE',
      '  quotabot watch [options]',
      '',
      'OPTIONS',
      '  --interval=N             seconds between checks (2..86400).',
      '                           Out of range values are clamped. A non-integer',
      '                           is a usage error.',
      '  --once                   emit the current crossings and exit',
      '  --waste-threshold=N      also alert when at least N percent of paid',
      '                           quota is projected to expire unused (0..100)',
      '  --webhook=URL            POST each alert. Loopback unless --allow-external',
      '  --allow-external         permit a non-loopback webhook',
      ..._quotaOptions(states),
    ];

List<String> _explain() => [
      'quotabot explain',
      '',
      'Dry-run manifest of the local files and network hosts a quota read may',
      'touch. It does not contact providers and does not read secret file',
      'contents. With neither flag, both reads and network hosts are shown.',
      'Passing only one flag limits the manifest to that side.',
      '',
      'USAGE',
      '  quotabot explain [--reads] [--network] [options]',
      '',
      'OPTIONS',
      '  --reads              local metadata paths',
      '  --network            provider endpoints those reads would contact',
      '  --profile=NAME       local named profile',
      '  --exclude=A,B        skip these providers after the profile filter',
      '  --json               quotabot explain manifest JSON',
      '  --color, --no-color',
    ];

List<String> _report(String states) => [
      'quotabot report',
      '',
      'Markdown report of the current snapshot.',
      '',
      'USAGE',
      '  quotabot report [options]',
      '',
      'OPTIONS',
      '  --include-accounts   include account labels',
      ..._quotaOptions(states),
    ];

List<String> _stats(String states) => [
      'quotabot stats',
      '',
      'Local analytics for recorded quota history. An optional provider limits',
      'the report. Tier flags are inputs to the fit estimate. They do not',
      'change routing.',
      '',
      'USAGE',
      '  quotabot stats [provider] [options]',
      '',
      'OPTIONS',
      '  --tier-plan=PROVIDER:PERCENT[:PRICE]',
      '                       explicit plan cap and optional price',
      '  --current-price=N    price input for tier fit',
      '  --tier-risk=P        risk input for tier fit, 0..1',
      ..._quotaOptions(states),
    ];

List<String> _calibration(String states) => [
      'quotabot calibration',
      '',
      'Collect the current snapshot, then grade the stored burn forecast',
      'against later history. JSON is quotabot.calibration.v1. A fitted',
      'lookback is reported only. Routing uses it when suggest is run with',
      '--tuned-burn.',
      '',
      'USAGE',
      '  quotabot calibration [options]',
      '',
      'OPTIONS',
      ..._quotaOptions(states),
    ];

List<String> _manual() => [
      'quotabot manual',
      '',
      'Self-reported quota for a provider with no measured plan. Manual rows',
      'are not included-quota evidence and cannot satisfy quota or stretch',
      'routing.',
      '',
      'USAGE',
      '  quotabot manual [list]',
      '  quotabot manual set <provider> [options]',
      '  quotabot manual remove <provider>',
      '',
      'OPTIONS',
      '  --account=VALUE',
      '  --display-name=VALUE',
      '  --plan=VALUE',
      '  --window=VALUE',
      '  --used=N',
      '  --limit=N',
      '  --reset=VALUE',
      '  --json',
      '  --color, --no-color',
    ];

List<String> _quotaOptions(String states, {bool json = true}) => [
      '  --profile=NAME       local named profile',
      '  --exclude=A,B        skip these providers after the profile filter',
      '  --mock-provider=NAME --state=STATE',
      '                       deterministic snapshot ($states)',
      '  --fresh              bypass recent Claude sharing; backoff still applies',
      '  --verbose            show collection progress',
      if (json)
        '  --json               machine-readable output where this command has it',
      '  --color, --no-color  force or disable color. NO_COLOR and CLICOLOR=0 also apply',
    ];
