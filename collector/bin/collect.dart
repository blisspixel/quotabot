import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/auth/anthropic_auth.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/demo.dart' as demo;
import 'package:quotabot_collector/route_render.dart';
import 'package:quotabot_collector/top.dart';
import 'package:quotabot_collector/util.dart';
import 'package:quotabot_collector/webhook.dart';

/// quotabot CLI. Run `quotabot help` for the full command list. Every read is a
/// local metadata lookup, not a model call, so it costs no usage tokens.

const _version = '0.8.1';

/// Documented, stable CLI exit codes a shell or agent can branch on:
/// 0 success; 64 usage error (bad arguments or an unknown provider); 65 a
/// `verify` run found at least one snapshot failing its honesty checks; 69 the
/// requested provider, or the whole fleet, has no usable quota right now.
const int _exitUsage = 64;
const int _exitVerifyFailed = 65;
const int _exitUnavailable = 69;

late AnsiStyle style;
List<ProviderQuota>? _simulatedSnapshot;

bool get _usingSimulation => _simulatedSnapshot != null;

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

/// Collects every provider's quota behind the spinner, then applies an optional
/// local profile view.
Future<List<ProviderQuota>> _read([
  QuotaProfile? profile,
  Set<String> excludedProviders = const {},
]) =>
    _withSpinner(
      'reading quota',
      () => _collectProfiled(profile, excludedProviders: excludedProviders),
    );

class _VerifiedRead {
  final List<ProviderQuota> results;
  final RuntimeAccessReport runtimeAccess;

  const _VerifiedRead(this.results, this.runtimeAccess);
}

Future<_VerifiedRead> _readForVerify([
  QuotaProfile? profile,
  Set<String> excludedProviders = const {},
]) =>
    _withSpinner(
      'reading quota',
      () => _collectProfiledForVerify(
        profile,
        excludedProviders: excludedProviders,
      ),
    );

Future<List<ProviderQuota>> _collectProfiled(
  QuotaProfile? profile, {
  Set<String> excludedProviders = const {},
}) async {
  final results = _simulatedSnapshot ?? await collectAll();
  final profiled =
      profile == null ? List.of(results) : applyProfile(results, profile);
  return filterExcludedProviders(profiled, excludedProviders);
}

Future<_VerifiedRead> _collectProfiledForVerify(
  QuotaProfile? profile, {
  Set<String> excludedProviders = const {},
}) async {
  if (_simulatedSnapshot != null) {
    final profiled = profile == null
        ? List.of(_simulatedSnapshot!)
        : applyProfile(_simulatedSnapshot!, profile);
    return _VerifiedRead(
      filterExcludedProviders(profiled, excludedProviders),
      buildRuntimeAccessReport(
        generatedAt: nowEpoch(),
        includeReads: true,
        includeNetwork: true,
        providers: const [],
      ),
    );
  }
  final collected = await collectAllWithRuntimeAccess();
  final profiled = profile == null
      ? List.of(collected.providers)
      : applyProfile(collected.providers, profile);
  return _VerifiedRead(
    filterExcludedProviders(profiled, excludedProviders),
    collected.runtimeAccess,
  );
}

Map<String, dynamic> _snapshot(
  List<ProviderQuota> results, [
  QuotaProfile? profile,
]) =>
    {
      'schema': quotabotV1SchemaId,
      if (profile != null) 'profile': profile.name,
      'generated_at': nowEpoch(),
      'providers': results.map((r) => r.toJson()).toList(),
    };

Future<void> main(List<String> rawArgs) async {
  final args = _normalizeArgs(rawArgs);
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

  final profileSelection = _profileFromFlags(flags);
  if (!profileSelection.ok) {
    exitCode = _exitUsage;
    return;
  }
  final profile = profileSelection.profile;
  final simulationSelection = _simulationFromFlags(flags);
  if (!simulationSelection.ok) {
    exitCode = _exitUsage;
    return;
  }
  _simulatedSnapshot = simulationSelection.snapshot;
  var excludedProviders = const <String>{};
  if (_usesQuotaRead(cmd)) {
    final exclusionSelection = _excludedProviders(flags);
    if (!exclusionSelection.ok) {
      exitCode = _exitUsage;
      return;
    }
    excludedProviders = exclusionSelection.providers;
  }

  switch (cmd) {
    case 'login':
      await _login(pos.length > 1 ? pos[1] : '');
      return;
    case 'logout':
      _logout(pos.length > 1 ? pos[1] : '');
      return;
    case 'manual':
      await _runManual(pos.skip(1).toList(), flags, wantsJson);
      return;
    case 'check':
      if (pos.length < 2) {
        stderr.writeln('usage: quotabot check <provider>');
        exitCode = 64;
        return;
      }
      await _check(pos[1], wantsJson, profile, excludedProviders);
      return;
    case 'suggest':
      final results = await _read(profile, excludedProviders);
      final now = nowEpoch();
      final providerRoute = flags.contains('--provider-route');
      if (_hasModelProfile(flags) && !providerRoute) {
        if (_hasRouteCostPolicy(flags)) {
          stderr.writeln(
            'quotabot: --cost-penalty and --cost-weight apply to provider '
            'suggestions only; remove model filters to use them',
          );
          exitCode = _exitUsage;
          return;
        }
        final reqs = _modelRequirements(flags);
        if (!reqs.ok) {
          exitCode = _exitUsage;
          return;
        }
        final burnStats = _burnStatsFor(results, now);
        final useExpiringQuota = flags.contains('--use-expiring-quota');
        final s = suggestModel(
          results,
          now,
          catalog: kModelCatalog,
          requirements: reqs.requirements,
          useExpiringQuota: useExpiringQuota,
          expiringQuotaByProvider: useExpiringQuota
              ? expiringQuotaSignals(
                  results,
                  now,
                  burnStatsByProvider: burnStats,
                )
              : const <String, ExpiringQuotaSignal>{},
        );
        wantsJson
            ? print(_jsonPretty(s.toJson(now)))
            : _printSuggestModel(s, now);
      } else {
        if (providerRoute && flags.contains('--use-expiring-quota')) {
          stderr.writeln(
            'quotabot: --use-expiring-quota applies to model suggestions only',
          );
          exitCode = _exitUsage;
          return;
        }
        final routeReqs = providerRoute && _hasCapabilityProfile(flags)
            ? _routeRequirements(flags)
            : (requirements: null, ok: true);
        if (!routeReqs.ok) {
          exitCode = _exitUsage;
          return;
        }
        final riskZ =
            _doubleOption(flags, 'risk', 0).clamp(0.0, 5.0).toDouble();
        final costPolicy = _routeCostPolicy(flags);
        if (!costPolicy.ok) {
          exitCode = _exitUsage;
          return;
        }
        // An explicit --prefer overrides the active profile's saved preference;
        // otherwise the profile's preference (if any) applies.
        final flagPreference = _preferenceOrderFrom(flags);
        final preferenceOrder = flagPreference.isNotEmpty
            ? flagPreference
            : (profile?.preferenceOrder ?? const []);
        final s = _suggestFor(
          results,
          now,
          riskZ: riskZ,
          tunedBurn: flags.contains('--tuned-burn'),
          preferLocal: flags.contains('--local-first'),
          costPenaltyByProvider: costPolicy.penalties,
          costWeight: costPolicy.weight,
          routeRequirements: routeReqs.requirements,
          preferenceOrder: preferenceOrder,
        );
        wantsJson ? print(_jsonPretty(s.toJson())) : _printSuggest(s);
      }
      return;
    case 'stats':
      final tierFitPolicy = _tierFitPolicy(flags);
      if (!tierFitPolicy.ok) {
        exitCode = _exitUsage;
        return;
      }
      await _runStats(
        pos.skip(1).toList(),
        wantsJson,
        profile,
        excludedProviders,
        tierFitPolicy,
      );
      return;
    case 'report':
      await _runReport(wantsJson, profile, excludedProviders);
      return;
    case 'top':
      await _runTop(flags, profile, excludedProviders);
      return;
    case 'watch':
      await _runWatch(flags, profile, excludedProviders);
      return;
    case 'models':
      final results = await _read(profile, excludedProviders);
      final now = nowEpoch();
      final reqs = _modelRequirements(flags);
      if (!reqs.ok) {
        exitCode = _exitUsage;
        return;
      }
      if (wantsJson) {
        print(_jsonPretty(modelRegistryJson(results, now,
            catalog: kModelCatalog, requirements: reqs.requirements)));
      } else {
        _printModels(
          buildModelRegistry(results, now,
              catalog: kModelCatalog, requirements: reqs.requirements),
          now,
          filtersActive: !reqs.requirements.isEmpty,
        );
      }
      return;
    case 'calibration':
      await _runCalibration(wantsJson, profile, excludedProviders);
      return;
    case 'explain':
      _runExplain(flags, wantsJson, profile, excludedProviders);
      return;
    case 'verify':
      await _runVerify(wantsJson, profile, excludedProviders);
      return;
  }

  // Snapshot and the default status table share one collect.
  final results = await _read(profile, excludedProviders);
  if (cmd == 'json' || (cmd.isEmpty && wantsJson)) {
    print(_jsonPretty(_snapshot(results, profile)));
    return;
  }
  if (cmd.isEmpty || cmd == 'status' || cmd == 'doctor') {
    wantsJson
        ? print(_jsonPretty(_snapshot(results, profile)))
        : _printDoctor(results);
    return;
  }

  stderr.writeln('${style.red('unknown command')}: $cmd');
  stderr.writeln('run "quotabot help" for the command list');
  exitCode = 64;
}

bool _usesQuotaRead(String cmd) =>
    cmd.isEmpty || _quotaReadCommands.contains(cmd);

const _quotaReadCommands = {
  'calibration',
  'check',
  'doctor',
  'explain',
  'json',
  'models',
  'report',
  'stats',
  'status',
  'suggest',
  'top',
  'verify',
  'watch',
};

/// The routing recommendation for [results], discounted by recent burn. Shared
/// by `suggest`, `doctor`, and the live `top` view so they never diverge.
/// The provider preference order from `--prefer=codex,claude`, most-preferred
/// first. Names are lowercased and trimmed, blanks dropped, and order and
/// duplicates left as given (the router uses first occurrence). Empty when the
/// flag is absent, so routing keeps its score-based pick.
List<String> _preferenceOrderFrom(Set<String> flags) {
  final raw = _stringOption(flags, 'prefer', null);
  if (raw == null) return const [];
  return [
    for (final part in raw.split(','))
      if (part.trim().isNotEmpty) part.trim().toLowerCase(),
  ];
}

RouteSuggestion _suggestFor(
  List<ProviderQuota> results,
  int now, {
  double riskZ = 0,
  bool preferLocal = false,
  Map<String, double> costPenaltyByProvider = const {},
  double costWeight = kDefaultRoutingCostWeight,
  ModelRequirements? routeRequirements,
  bool tunedBurn = false,
  List<String> preferenceOrder = const [],
}) =>
    () {
      final capabilityGates = providerRouteCapabilityGates(
        results,
        now,
        catalog: kModelCatalog,
        requirements: routeRequirements,
      );
      return decide(
        results,
        now,
        context: DecisionContext(
          burnStatsByProvider: _burnStatsFor(results, now, tuned: tunedBurn),
          riskZ: riskZ,
          preferLocal: preferLocal,
          costPenaltyByProvider: costPenaltyByProvider,
          costWeight: costWeight,
          pipePenaltyByProvider: _pipePenaltyFor(results, now),
          capabilityKnownQuotaKeys: capabilityGates.knownQuotaKeys,
          capabilityAvailableQuotaKeys: capabilityGates.availableQuotaKeys,
          capabilityBudgetResetByQuotaKey:
              capabilityGates.budgetResetByQuotaKey,
          preferenceOrder: preferenceOrder,
        ),
      ).route;
    }();

Map<String, BurnStat> _burnStatsFor(
  List<ProviderQuota> results,
  int now, {
  bool tuned = false,
}) {
  if (Platform.environment['QUOTABOT_DEMO'] == '1') return demo.demoBurnStats();
  if (_usingSimulation) return const <String, BurnStat>{};
  // Opt-in: fit the burn lookback to this user's own recorded history (the value
  // best calibrated to how their quota actually behaves) instead of the shipped
  // default. Falls back to the default when the history is too thin to fit.
  int? lookback;
  if (tuned) {
    final byProvider = <String, List<HeadroomBucket>>{
      for (final q in results.where((q) => !q.isLocal))
        if (_historyBuckets(q.provider).isNotEmpty)
          q.provider: _historyBuckets(q.provider),
    };
    lookback = tuneBurnLookback(byProvider, now).burnLookbackHours;
  }
  return recentBurnStatsByQuota(results, now, lookbackHours: lookback);
}

Map<String, double> _pipePenaltyFor(List<ProviderQuota> results, int now) {
  if (Platform.environment['QUOTABOT_DEMO'] == '1' || _usingSimulation) {
    return const <String, double>{};
  }
  return loadRoutedRequestSummary().pipePenaltyByProvider(now: now);
}

List<HeadroomBucket> _historyBuckets(
  String provider, {
  String? account,
  bool fallbackToProvider = true,
}) =>
    _usingSimulation
        ? const <HeadroomBucket>[]
        : loadBuckets(
            provider,
            account: account,
            fallbackToProvider: fallbackToProvider,
          );

List<HeadroomBucket> _weeklyHistoryBuckets(
  String provider,
  int now, {
  String? account,
}) {
  final cutoff = now - 7 * 86400;
  return [
    for (final bucket in _historyBuckets(provider, account: account))
      if (bucket.start >= cutoff) bucket,
  ];
}

typedef StatsSeriesBucketLoader = List<HeadroomBucket> Function(
  String provider, {
  String? account,
  bool fallbackToProvider,
});

typedef StatsSeries = ({
  String key,
  String label,
  ProviderQuota quota,
  List<HeadroomBucket> buckets,
});

/// Builds the analytics series shown by `quotabot stats`.
///
/// Single-account providers keep their historical provider id as the output key
/// for compatibility, while duplicate provider accounts get account-qualified
/// keys and labels so their histories cannot overwrite each other.
List<StatsSeries> buildStatsSeries(
  List<ProviderQuota> results,
  String? only,
  StatsSeriesBucketLoader loadBucketsFor,
) {
  final onlyProvider = only?.toLowerCase();
  final quotas = [
    for (final q in results)
      if (!q.isLocal && (onlyProvider == null || q.provider == onlyProvider)) q,
  ]..sort((a, b) {
      final byProvider = a.provider.compareTo(b.provider);
      return byProvider == 0 ? a.account.compareTo(b.account) : byProvider;
    });
  final providerCounts = <String, int>{};
  for (final q in quotas) {
    providerCounts[q.provider] = (providerCounts[q.provider] ?? 0) + 1;
  }
  return [
    for (final q in quotas)
      _statsSeriesFor(
        q,
        providerCounts[q.provider] ?? 1,
        loadBucketsFor,
      ),
  ];
}

StatsSeries _statsSeriesFor(
  ProviderQuota quota,
  int providerCount,
  StatsSeriesBucketLoader loadBucketsFor,
) {
  final account = stripTerminalControl(quota.account);
  final duplicateProvider = providerCount > 1;
  final bucketAccount =
      hasSpecificQuotaAccount(quota.account) ? quota.account : null;
  final fallbackToProvider = !duplicateProvider;
  return (
    key: duplicateProvider ? '${quota.provider}:$account' : quota.provider,
    label: duplicateProvider ? '${quota.provider} ($account)' : quota.provider,
    quota: quota,
    buckets: loadBucketsFor(
      quota.provider,
      account: bucketAccount,
      fallbackToProvider: fallbackToProvider,
    ),
  );
}

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
  if (value == null || !value.isFinite) return null;
  // Guard the scaled value too: round() throws on a non-finite double, so an
  // overflowing --min-context (e.g. 1e309) must fall back to "no filter"
  // rather than crash the command.
  final scaled = value * mult;
  return scaled.isFinite ? scaled.round() : null;
}

/// Builds the model requirement filter from CLI flags: a coarse `--task` profile
/// overlaid with explicit `--min-context`, `--require-*`, and `--tier-*` flags.
/// quotabot never sees the task itself, only this profile.
({ModelRequirements requirements, bool ok}) _modelRequirements(
  Set<String> flags, {
  ModelBudgetPolicy defaultBudgetPolicy = ModelBudgetPolicy.any,
}) {
  final rawBudget = _stringOption(flags, 'budget', null);
  final budget = rawBudget == null
      ? defaultBudgetPolicy
      : modelBudgetPolicyFromName(rawBudget);
  if (budget == null) {
    stderr.writeln(
      'quotabot: unknown --budget value "$rawBudget" '
      '(use $modelBudgetPolicyChoices)',
    );
    return (requirements: const ModelRequirements(), ok: false);
  }
  final explicit = ModelRequirements(
    minContextTokens: _parseContext(_stringOption(flags, 'min-context', null)),
    requireTools: flags.contains('--require-tools'),
    requireVision: flags.contains('--require-vision'),
    requireReasoning: flags.contains('--require-reasoning'),
    tierFloor: _stringOption(flags, 'tier-floor', null),
    tierCeiling: _stringOption(flags, 'tier-ceiling', null),
    budgetPolicy: budget,
  );
  return (
    requirements:
        taskProfile(_stringOption(flags, 'task', null)).merge(explicit),
    ok: true,
  );
}

/// True when the user passed any model-capability flag, so `suggest` should
/// recommend a concrete model rather than a provider.
bool _hasModelProfile(Set<String> flags) {
  return _hasCapabilityProfile(flags) || flags.contains('--use-expiring-quota');
}

bool _hasCapabilityProfile(Set<String> flags) {
  const bare = {
    '--require-tools',
    '--require-vision',
    '--require-reasoning',
  };
  if (flags.any(bare.contains)) return true;
  const prefixed = [
    '--task=',
    '--min-context=',
    '--tier-floor=',
    '--tier-ceiling=',
    '--budget=',
  ];
  return flags.any((f) => prefixed.any(f.startsWith));
}

({ModelRequirements? requirements, bool ok}) _routeRequirements(
  Set<String> flags,
) {
  final parsed = _modelRequirements(flags);
  if (!parsed.ok) return (requirements: null, ok: false);
  final rawBudget = _stringOption(flags, 'budget', null);
  if (parsed.requirements.isEmpty && rawBudget == null) {
    return (requirements: null, ok: true);
  }
  final requirements = rawBudget == null
      ? const ModelRequirements(budgetPolicy: ModelBudgetPolicy.quota)
          .merge(parsed.requirements)
      : parsed.requirements;
  return (requirements: requirements, ok: true);
}

bool _hasRouteCostPolicy(Set<String> flags) => flags.any(
    (f) => f.startsWith('--cost-penalty=') || f.startsWith('--cost-weight='));

({Map<String, double> penalties, double weight, bool ok}) _routeCostPolicy(
  Set<String> flags,
) {
  final rawPenalties = _stringOption(flags, 'cost-penalty', null);
  final parsed = parseProviderCostPenalties(rawPenalties);
  if (!parsed.ok) {
    stderr.writeln('quotabot: ${parsed.error}');
    return (penalties: const {}, weight: 0, ok: false);
  }
  final rawWeight = _stringOption(flags, 'cost-weight', null);
  var weight = parsed.penalties.isEmpty ? 0.0 : 1.0;
  if (rawWeight != null) {
    final parsedWeight = double.tryParse(rawWeight.trim());
    if (parsedWeight == null ||
        !parsedWeight.isFinite ||
        parsedWeight < 0 ||
        parsedWeight > kMaxRoutingCostWeight) {
      stderr.writeln('quotabot: --cost-weight must be between 0 and 10');
      return (penalties: const {}, weight: 0, ok: false);
    }
    weight = parsedWeight;
  }
  return (penalties: parsed.penalties, weight: weight, ok: true);
}

typedef _TierFitPolicy = ({
  List<TierPlanOption> plans,
  double maxBreachProbability,
  double? currentMonthlyPrice,
  bool ok,
});

_TierFitPolicy _tierFitPolicy(Set<String> flags) {
  final rawPlans = _stringOption(flags, 'tier-plan', null);
  final rawRisk = _stringOption(flags, 'tier-risk', null);
  final rawPrice = _stringOption(flags, 'current-price', null);
  if (rawPlans == null) {
    if (rawRisk != null || rawPrice != null) {
      stderr.writeln(
        'quotabot: --tier-risk and --current-price require --tier-plan',
      );
      return (
        plans: const [],
        maxBreachProbability: 0.05,
        currentMonthlyPrice: null,
        ok: false,
      );
    }
    return (
      plans: const [],
      maxBreachProbability: 0.05,
      currentMonthlyPrice: null,
      ok: true,
    );
  }

  final plans = _parseTierPlans(rawPlans);
  if (plans == null) {
    return (
      plans: const [],
      maxBreachProbability: 0.05,
      currentMonthlyPrice: null,
      ok: false,
    );
  }
  var risk = 0.05;
  if (rawRisk != null) {
    final parsed = double.tryParse(rawRisk.trim());
    if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 1) {
      stderr.writeln('quotabot: --tier-risk must be between 0 and 1');
      return (
        plans: const [],
        maxBreachProbability: 0.05,
        currentMonthlyPrice: null,
        ok: false,
      );
    }
    risk = parsed;
  }

  double? currentPrice;
  if (rawPrice != null) {
    final parsed = double.tryParse(rawPrice.trim());
    if (parsed == null || !parsed.isFinite || parsed < 0) {
      stderr.writeln('quotabot: --current-price must be a non-negative number');
      return (
        plans: const [],
        maxBreachProbability: risk,
        currentMonthlyPrice: null,
        ok: false,
      );
    }
    currentPrice = parsed;
  }

  return (
    plans: plans,
    maxBreachProbability: risk,
    currentMonthlyPrice: currentPrice,
    ok: true,
  );
}

List<TierPlanOption>? _parseTierPlans(String raw) {
  final plans = <TierPlanOption>[];
  for (final part in raw.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final fields = trimmed.split(':');
    if (fields.length < 2 || fields.length > 3) {
      stderr.writeln(
        'quotabot: --tier-plan entries must be name:cap[:monthly_price]',
      );
      return null;
    }
    final name = fields[0].trim();
    if (!RegExp(r'^[A-Za-z0-9 ._-]{1,64}$').hasMatch(name)) {
      stderr.writeln('quotabot: invalid tier plan name: $name');
      return null;
    }
    final cap = double.tryParse(fields[1].trim());
    if (cap == null || !cap.isFinite || cap <= 0 || cap > 1000) {
      stderr.writeln(
        'quotabot: tier plan cap must be > 0 and <= 1000 percent',
      );
      return null;
    }
    double? price;
    if (fields.length == 3 && fields[2].trim().isNotEmpty) {
      price = double.tryParse(fields[2].trim());
      if (price == null || !price.isFinite || price < 0) {
        stderr.writeln(
          'quotabot: tier plan monthly price must be non-negative',
        );
        return null;
      }
    }
    plans.add(TierPlanOption(
      name: name,
      capPercentOfCurrent: cap,
      monthlyPrice: price,
    ));
  }
  if (plans.isEmpty) {
    stderr.writeln('quotabot: --tier-plan must include at least one plan');
    return null;
  }
  return plans;
}

/// Prints a concrete-model recommendation for a task profile.
void _printSuggestModel(ModelSuggestion s, int now) {
  print('quotabot suggest  (best model for your task, 0 usage tokens)\n');
  final r = s.recommended;
  if (r == null) {
    print('  no model to route to right now');
  } else {
    final provenance = _modelEntryProvenance(r, now);
    print(
      '  ${style.green('->')} ${style.bold(r.model.id)} '
      '${style.dim('on ${r.provider}')} $provenance',
    );
  }
  print('  ${s.reason}\n');
  if (s.ranked.isEmpty) return;
  print('  candidates (best first):');
  for (final e in s.ranked) {
    final m = e.model;
    final budget = e.local
        ? style.cyan('local'.padRight(9))
        : (e.headroomPercent == null
            ? style.dim('?'.padRight(9))
            : e.stale
                ? style.dim('${e.headroomPercent!.round()}% last'.padRight(9))
                : style.health(e.headroomPercent!,
                    '${e.headroomPercent!.round()}% free'.padRight(9)));
    final tier = m.tier == null ? '' : style.dim('  ${m.tier}');
    final spent = e.available
        ? ''
        : e.stale
            ? style.dim('  unavailable')
            : style.red('  spent');
    final provenance = _modelEntryProvenance(e, now);
    print(
      '    ${m.id.padRight(22)} ${e.provider.padRight(11)} '
      '$budget $provenance$tier$spent',
    );
  }
}

/// Reads a `--name=value` string option from [flags], or [dflt] when absent.
String? _stringOption(Iterable<String> flags, String name, String? dflt) {
  final prefix = '--$name=';
  for (final f in flags) {
    if (f.startsWith(prefix)) return f.substring(prefix.length);
  }
  return dflt;
}

const _valueOptions = {
  'account',
  'budget',
  'cost-penalty',
  'cost-weight',
  'current-price',
  'display-name',
  'exclude',
  'interval',
  'limit',
  'min-context',
  'mock-provider',
  'plan',
  'profile',
  'risk',
  'sort',
  'state',
  'task',
  'theme',
  'tier-ceiling',
  'tier-floor',
  'tier-plan',
  'tier-risk',
  'reset',
  'used',
  'waste-threshold',
  'webhook',
  'window',
};

List<String> _normalizeArgs(List<String> args) {
  final normalized = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--') {
      normalized.addAll(args.skip(i));
      break;
    }
    if (arg.startsWith('--') && !arg.contains('=')) {
      final name = arg.substring(2);
      if (_valueOptions.contains(name) &&
          i + 1 < args.length &&
          !args[i + 1].startsWith('-')) {
        normalized.add('$arg=${args[++i]}');
        continue;
      }
    }
    normalized.add(arg);
  }
  return normalized;
}

ProviderExclusionParseResult _excludedProviders(Set<String> flags) {
  final raw = _stringOption(flags, 'exclude', null);
  final parsed = parseProviderExclusions(raw);
  if (!parsed.ok) {
    final invalid = parsed.invalidProvider;
    if (invalid == null) {
      stderr.writeln('quotabot: ${parsed.error}');
    } else {
      stderr.writeln('quotabot: invalid --exclude provider "$invalid"');
    }
  }
  return parsed;
}

({QuotaProfile? profile, bool ok}) _profileFromFlags(Set<String> flags) {
  final requested = _stringOption(flags, 'profile', null);
  if (requested == null || requested.trim().isEmpty) {
    return (profile: null, ok: true);
  }
  final profile = loadProfile(requested);
  if (profile == null) {
    stderr.writeln('quotabot: no profile named "$requested"');
    return (profile: null, ok: false);
  }
  return (profile: profile, ok: true);
}

({List<ProviderQuota>? snapshot, bool ok}) _simulationFromFlags(
  Set<String> flags,
) {
  final requested = flags
      .any((f) => f == '--mock-provider' || f.startsWith('--mock-provider='));
  if (!requested) return (snapshot: null, ok: true);

  final provider = _stringOption(flags, 'mock-provider', null);
  if (provider == null || provider.trim().isEmpty) {
    stderr.writeln('quotabot: --mock-provider requires a provider name');
    return (snapshot: null, ok: false);
  }

  final state = _stringOption(flags, 'state', 'healthy') ?? 'healthy';
  final normalizedState = normalizeSimulationState(state);
  if (normalizedState == null) {
    stderr.writeln(
      'quotabot: unknown --state "$state" '
      '(use ${simulationStates.join(', ')})',
    );
    return (snapshot: null, ok: false);
  }

  final snapshot = simulateFleet(
    provider: provider,
    state: normalizedState,
    now: nowEpoch(),
  );
  if (snapshot == null) {
    stderr.writeln('quotabot: invalid --mock-provider "$provider"');
    return (snapshot: null, ok: false);
  }
  return (snapshot: snapshot, ok: true);
}

Future<void> _runManual(
  List<String> pos,
  Set<String> flags,
  bool wantsJson,
) async {
  final action = pos.isEmpty ? 'list' : pos.first;
  switch (action) {
    case 'list':
      final entries = loadManualQuotaEntries();
      if (wantsJson) {
        print(_jsonPretty(_manualEntriesJson(entries)));
      } else {
        _printManualEntries(entries);
      }
      return;
    case 'set':
      if (pos.length < 2) {
        stderr.writeln(
          'usage: quotabot manual set <provider> --used N --limit N --reset VALUE',
        );
        exitCode = _exitUsage;
        return;
      }
      final entry = buildManualQuotaEntry(
        provider: pos[1],
        displayName: _stringOption(flags, 'display-name', null),
        account: _stringOption(flags, 'account', null),
        plan: _stringOption(flags, 'plan', null),
        window: _stringOption(flags, 'window', null),
        used: _stringOption(flags, 'used', null),
        limit: _stringOption(flags, 'limit', null),
        reset: _stringOption(flags, 'reset', null),
        now: nowEpoch(),
      );
      if (entry == null) {
        stderr.writeln(
          'usage: quotabot manual set <provider> --used N --limit N --reset VALUE',
        );
        exitCode = _exitUsage;
        return;
      }
      setManualQuotaEntry(entry);
      if (wantsJson) {
        print(_jsonPretty({
          'schema': manualQuotaSchema,
          'entry': entry.toJson(),
        }));
      } else {
        stdout.writeln(
          'saved ${entry.provider} (${entry.account}) '
          '${_manualNumber(entry.used)}/${_manualNumber(entry.limit)} '
          '${entry.window}',
        );
      }
      return;
    case 'remove':
      if (pos.length < 2) {
        stderr.writeln('usage: quotabot manual remove <provider>');
        exitCode = _exitUsage;
        return;
      }
      final removed = removeManualQuotaEntry(
        pos[1],
        account: _stringOption(flags, 'account', 'default') ?? 'default',
      );
      if (wantsJson) {
        print(_jsonPretty({
          'schema': manualQuotaSchema,
          'removed': removed,
        }));
      } else {
        stdout.writeln(
            removed ? 'removed ${pos[1]}' : 'no manual entry for ${pos[1]}');
      }
      return;
  }
  stderr.writeln('usage: quotabot manual [list|set|remove]');
  exitCode = _exitUsage;
}

Map<String, dynamic> _manualEntriesJson(List<ManualQuotaEntry> entries) => {
      'schema': manualQuotaSchema,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    };

void _printManualEntries(List<ManualQuotaEntry> entries) {
  if (entries.isEmpty) {
    stdout.writeln('no manual quota entries');
    return;
  }
  final now = nowEpoch();
  for (final entry in entries) {
    stdout.writeln(
      '${entry.provider.padRight(14)} '
      '${entry.account.padRight(18)} '
      '${_manualNumber(entry.used)}/${_manualNumber(entry.limit)} '
      '${entry.window} '
      'resets in ${_in(entry.resetsAt, now)}',
    );
  }
}

String _manualNumber(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';

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

/// A short "updated 5s ago" / "just now" label from a last-collect epoch.
String _agoLabel(int lastCollect, int now) {
  if (lastCollect == 0) return 'updating...';
  final s = now - lastCollect;
  if (s < 2) return 'updated just now';
  if (s < 90) return 'updated ${s}s ago';
  return 'updated ${(s / 60).round()}m ago';
}

/// `top`: a live, htop-style dashboard that redraws in place.
///
/// On a real terminal it enters the alternate screen, hides the cursor, reads
/// keys raw (q to quit, r to refresh now), repaints countdowns every second, and
/// re-collects on the same adaptive cadence as the desktop app (fast near a reset
/// or a tight cap, relaxed when healthy). `--interval=N` forces a fixed cadence;
/// `--truecolor` forces 24-bit gradients. When stdout is not a terminal it prints
/// one plain frame and exits, so `quotabot top | cat` still yields a snapshot.
Future<void> _runTop(
  Set<String> flags,
  QuotaProfile? profile,
  Set<String> excludedProviders,
) async {
  final color = _useColor(flags);
  final depth = flags.contains('--truecolor')
      ? ColorDepth.truecolor
      : detectColorDepth(Platform.environment, hasTerminal: stdout.hasTerminal);
  final palette = paletteFromSpec(
    _stringOption(flags, 'theme', Platform.environment['QUOTABOT_THEME']),
  );
  // A fixed cadence only when --interval is given; otherwise adapt like the app.
  final fixedInterval = flags.any((f) => f.startsWith('--interval='))
      ? _intOption(flags, 'interval', 10).clamp(2, 3600)
      : null;

  // Initial ordering: --sort=NAME (or QUOTABOT_SORT); the `s` key cycles it live.
  var sort = TopSort.defaultOrder;
  final sortSpec =
      _stringOption(flags, 'sort', Platform.environment['QUOTABOT_SORT']);
  if (sortSpec != null && sortSpec.isNotEmpty) {
    final parsed = TopSort.parse(sortSpec);
    if (parsed == null) {
      stderr.writeln('quotabot: unknown --sort value "$sortSpec" (use '
          '${TopSort.values.map((m) => m.cliName).join(', ')})');
      exitCode = 64;
      return;
    }
    sort = parsed;
  }

  if (!stdout.hasTerminal) {
    final data =
        await _collectProfiled(profile, excludedProviders: excludedProviders);
    final now = nowEpoch();
    final suggestion = _suggestFor(data, now);
    final lines = renderTopFrame(
      providers: sortProvidersForTop(data, suggestion, now, sort),
      suggestion: suggestion,
      now: now,
      width: 80,
      color: false,
      clock: _clock(),
      palette: palette,
      sort: sort == TopSort.defaultOrder ? '' : sort.label,
    );
    stdout.writeln(lines.join('\n'));
    if (!anyProviderUsable(data, now)) exitCode = _exitUnavailable;
    return;
  }

  var data = <ProviderQuota>[];
  var loading = true;
  var lastCollect = 0;
  var failStreak = 0;
  var selected = 0; // cursor index into the visible (sorted, unhidden) list
  // Provider/account identities hidden this session with the x key. Keyed by
  // account, not bare provider, so hiding one account of a duplicated provider
  // does not also hide its other accounts (selection is per account too).
  final hidden = <String>{};
  var copied = ''; // transient confirmation shown after the copy-route key
  final quit = Completer<void>();
  Timer? repaint;
  Timer? refresh;

  // The sorted, unhidden providers plus the routing suggestion for this frame,
  // computed together so the cursor, the rows, and the route line agree.
  ({List<ProviderQuota> visible, RouteSuggestion suggestion}) frame() {
    final now = nowEpoch();
    final suggestion = _suggestFor(data, now);
    final visible = sortProvidersForTop(data, suggestion, now, sort)
        .where((q) => !hidden.contains(quotaIdentityKeyFor(q)))
        .toList();
    return (visible: visible, suggestion: suggestion);
  }

  void draw() {
    final now = nowEpoch();
    final List<String> lines;
    if (loading && data.isEmpty) {
      lines = ['  ${style.bold('quotabot')}', '', '  reading quota...'];
    } else {
      final f = frame();
      final visible = f.visible;
      if (selected >= visible.length) selected = visible.length - 1;
      if (selected < 0 && visible.isNotEmpty) selected = 0;
      lines = renderTopFrame(
        providers: visible,
        suggestion: f.suggestion,
        now: now,
        width: _termCols(),
        color: color,
        clock: _clock(),
        depth: depth,
        palette: palette,
        updated: _agoLabel(lastCollect, now),
        sort: sort.label,
        selected: (selected >= 0 && selected < visible.length)
            ? visible[selected].provider
            : null,
        selectedAccount: (selected >= 0 && selected < visible.length)
            ? visible[selected].account
            : null,
        hidden: hidden.length,
        copied: copied,
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

  // scheduleRefresh and reload reference each other, so both are late bindings.
  late final void Function() scheduleRefresh;
  late final Future<void> Function() reload;

  scheduleRefresh = () {
    final secs = fixedInterval ??
        nextRefreshSeconds(data, nowEpoch(), failStreak: failStreak);
    refresh = Timer(Duration(seconds: secs), reload);
  };

  // Re-collect, update the failure streak, redraw, and schedule the next refresh
  // on the adaptive cadence.
  reload = () async {
    try {
      final fresh =
          await _collectProfiled(profile, excludedProviders: excludedProviders);
      data = fresh;
      lastCollect = nowEpoch();
      loading = false;
      final anyLive = fresh.any((q) => q.ok && q.hasWindows && !q.stale);
      failStreak = anyLive ? 0 : failStreak + 1;
      draw();
    } catch (_) {
      // Keep the last good frame on a transient collection error.
    }
    scheduleRefresh();
  };

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

  void moveSel(int delta) {
    copied = '';
    selected = moveSelection(selected, delta, frame().visible.length);
    draw();
  }

  void hideSel() {
    copied = '';
    final visible = frame().visible;
    if (selected >= 0 && selected < visible.length) {
      hidden.add(quotaIdentityKeyFor(visible[selected]));
    }
    draw(); // draw() reclamps the cursor to the now-shorter list
  }

  void copyRoute() {
    final r = frame().suggestion.recommended;
    final route = r?.provider ?? '';
    if (route.isEmpty) {
      copied = '(no route)';
    } else {
      stdout
          .write(osc52Copy(route)); // the terminal performs the clipboard copy
      copied = route;
    }
    draw();
  }

  final keys = stdin.listen((bytes) {
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      // Arrow keys arrive as ESC [ A/B; consume the three bytes together.
      if (b == 27 && i + 2 < bytes.length && bytes[i + 1] == 91) {
        if (bytes[i + 2] == 65) moveSel(-1); // up
        if (bytes[i + 2] == 66) moveSel(1); // down
        i += 2;
        continue;
      }
      if (b == 113 || b == 81 || b == 3) return stop(); // q, Q, Ctrl-C
      if (b == 114 || b == 82) {
        copied = '';
        refresh?.cancel();
        reload(); // r, R: refresh now and reschedule
      } else if (b == 115 || b == 83) {
        copied = '';
        sort = sort.next; // s, S: cycle the ordering
        draw();
      } else if (b == 106) {
        moveSel(1); // j: down
      } else if (b == 107) {
        moveSel(-1); // k: up
      } else if (b == 120 || b == 104) {
        hideSel(); // x, h: hide the selected provider
      } else if (b == 117) {
        copied = '';
        hidden.clear(); // u: unhide all
        draw();
      } else if (b == 99) {
        copyRoute(); // c: copy the recommended route to the clipboard
      }
    }
  });
  final sigint = ProcessSignal.sigint.watch().listen((_) => stop());

  draw(); // immediate "reading quota" frame
  await reload(); // first real snapshot (also schedules the next refresh)
  repaint = Timer.periodic(const Duration(seconds: 1), (_) => draw());

  await quit.future;
  repaint.cancel();
  refresh?.cancel();
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
    '  top                 live dashboard (q quit, r refresh, s sort, j/k move, x hide, c copy route)',
  );
  stdout.writeln(
    '  watch               alert when a window goes red, naming where to route'
    ' (--webhook URL, --json, --once, --waste-threshold N)',
  );
  stdout.writeln(
    '  check <provider>    whether one provider is usable now, and its reset',
  );
  stdout.writeln(
    '  models              known model candidates, with budget + capabilities',
  );
  stdout.writeln(
    '  calibration         how often quotabot\'s predictions come true (history)',
  );
  stdout.writeln(
    '  manual              list, set, or remove self-reported quota entries',
  );
  stdout.writeln(
    '  stats [provider]    90-day analytics: distribution, best windows, pace',
  );
  stdout.writeln(
    '  report              weekly quota health markdown export',
  );
  stdout.writeln(
    '  verify              honesty checks over one live read (exit 65 on any failure)',
  );
  stdout.writeln(
    '  explain             show local reads and network hosts in the runtime trust boundary',
  );
  stdout.writeln('');
  stdout.writeln(head('ROUTE'));
  stdout.writeln(
    '  suggest             which subscription to use next (ranked); add a model'
    ' filter (e.g. --task) to get one recommended model',
  );
  stdout.writeln('');
  stdout.writeln(head('CONNECT'));
  stdout.writeln(
    '  login <provider>    connect grok, antigravity, claude, or codex '
    '(keeps it live on an idle machine)',
  );
  stdout.writeln('  logout <provider>   disconnect a provider');
  stdout.writeln(
    '  manual set NAME --used N --limit N --reset VALUE'
    '  add/update a local entry',
  );
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
    '  --profile=NAME      use a local named profile view',
  );
  stdout.writeln(
    '  --mock-provider NAME --state NAME  deterministic test snapshot '
    '(${simulationStates.join(', ')})',
  );
  stdout.writeln(
    '  --color, --no-color force or disable color (also honors NO_COLOR)',
  );
  stdout.writeln(
    '  --interval=N        top: fixed seconds between refreshes (default: adaptive)',
  );
  stdout.writeln(
    '  --sort=NAME         top: initial order (${TopSort.values.map((m) => m.cliName).join(', ')}); '
    'the s key cycles it; also QUOTABOT_SORT',
  );
  stdout.writeln(
    '  --truecolor         top: force 24-bit gradient meters',
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
    '  --tuned-burn        suggest: fit the burn lookback to your own history '
    '(see quotabot calibration)',
  );
  stdout.writeln(
    '  --local-first       suggest: prefer local runtime before subscription quota',
  );
  stdout.writeln(
    '  --prefer=A,B        suggest: provider preference among viable options '
    '(never overrides availability)',
  );
  stdout.writeln(
    '  --provider-route    suggest: keep provider output while applying model filters',
  );
  stdout.writeln(
    '  --cost-penalty=A:N  suggest: explicit relative cost penalty for provider A',
  );
  stdout.writeln(
    '  --cost-weight=N     suggest: scale explicit cost penalties (default 1 when set)',
  );
  stdout.writeln(
    '  --tier-plan=A:N[:P] stats: explicit plan cap percent and optional price',
  );
  stdout.writeln(
    '  --current-price=N --tier-risk=P  stats: tier-fit price/risk inputs',
  );
  stdout.writeln(
    '  --exclude=A,B       quota reads: ignore these providers after profile filtering',
  );
  stdout.writeln(
    '  --task=LEVEL        models/suggest: simple|standard|hard (coarse needs)',
  );
  stdout.writeln(
    '  --budget=POLICY     models/suggest: any|quota|local class filter',
  );
  stdout.writeln(
    '  --use-expiring-quota suggest: prefer qualifying included quota projected to expire unused',
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

/// `quotabot watch`: poll quota on the adaptive cadence and emit a low-quota
/// alert the first time a provider's binding window crosses into red (spent or
/// nearly so), naming where to route next. With --waste-threshold=N it also
/// emits projected-waste alerts when quota is on pace to expire unused at reset.
/// With --webhook each alert is POSTed as quotabot.alert.v1 JSON (loopback only
/// unless --allow-external). --json prints alerts as JSON lines; --once runs a
/// single pass (for cron or tests); --interval=N pins the poll rate, otherwise
/// the adaptive cadence is used.
Future<void> _runWatch(
  Set<String> flags,
  QuotaProfile? profile,
  Set<String> excludedProviders,
) async {
  final webhook = _stringOption(flags, 'webhook', null);
  final allowExternal = flags.contains('--allow-external');
  final wantsJson = flags.contains('--json');
  final once = flags.contains('--once');
  final wasteThresholdRaw = _stringOption(flags, 'waste-threshold', null);
  final wasteThreshold =
      wasteThresholdRaw == null ? null : double.tryParse(wasteThresholdRaw);
  final fixedInterval = flags.any((f) => f.startsWith('--interval='))
      ? _intOption(flags, 'interval', 60).clamp(2, 86400)
      : null;

  if (wasteThresholdRaw != null &&
      (wasteThreshold == null ||
          !wasteThreshold.isFinite ||
          wasteThreshold < 0 ||
          wasteThreshold > 100)) {
    stderr.writeln('quotabot: --waste-threshold must be between 0 and 100');
    exitCode = _exitUsage;
    return;
  }

  // Fail loudly on an external webhook host that was not explicitly allowed,
  // rather than silently dropping every POST later.
  if (webhook != null && !allowExternal && !isLoopbackUrl(webhook)) {
    stderr.writeln('quotabot: webhook host is not loopback; pass '
        '--allow-external to post to "$webhook"');
    exitCode = 64;
    return;
  }

  final client = http.Client();
  var armed = <String>{};
  var wasteArmed = <String>{};
  var failStreak = 0;
  var data = <ProviderQuota>[];

  Future<int> pass() async {
    data =
        await _collectProfiled(profile, excludedProviders: excludedProviders);
    final now = nowEpoch();
    final anyLive = data.any((q) => q.ok && q.hasWindows && !q.stale);
    failStreak = anyLive ? 0 : failStreak + 1;
    final suggestion = _suggestFor(data, now);
    final result = computeAlerts(
        snapshot: data, suggestion: suggestion, now: now, armed: armed);
    armed = result.armed;
    final fired = <QuotaAlert>[...result.fired];
    if (wasteThreshold != null) {
      final paceByProvider = <String, Pace>{};
      final tz = DateTime.now().timeZoneOffset;
      for (final q in data.where(
        (provider) => !provider.isLocal && !provider.isManual,
      )) {
        final ins = Insights.from(
          _historyBuckets(q.provider, account: q.account),
          now,
          tzOffset: tz,
        );
        final pace = _paceFor(q, ins, now);
        if (pace != null) paceByProvider[quotaIdentityKeyFor(q)] = pace;
      }
      final waste = computeProjectedWasteAlerts(
        snapshot: data,
        paceByProvider: paceByProvider,
        now: now,
        thresholdPercent: wasteThreshold,
        armed: wasteArmed,
      );
      wasteArmed = waste.armed;
      fired.addAll(waste.fired);
    }
    for (final a in fired) {
      if (wantsJson) {
        stdout.writeln(jsonEncode(a.toJson()));
      } else {
        final tag = a.severity == AlertSeverity.red
            ? style.red('[red]')
            : style.orange('[amber]');
        final fallback = a.kind == QuotaAlertKind.lowQuota && a.routeTo == null
            ? _quotaAlertFallback(suggestion.fallback, now)
            : '';
        final provenance = quotaAlertProvenance(a, data, now);
        stdout.writeln('$tag ${a.message}$fallback $provenance');
      }
      if (webhook != null) {
        final r = await postAlert(webhook, a.toJson(),
            allowExternal: allowExternal, client: client);
        if (!r.ok) {
          stderr.writeln('quotabot: webhook POST failed '
              '(${r.error ?? 'HTTP ${r.statusCode}'})');
        }
      }
    }
    return fired.length;
  }

  if (once) {
    final fired = await pass();
    // A one-shot run that fired nothing must still confirm it ran, so an empty
    // result reads as "checked, all clear" instead of a hang or a broken read.
    if (fired == 0 && !wantsJson) {
      final scope = wasteThreshold == null
          ? 'no window has crossed into red'
          : 'no window is red and no renewing quota is projected to go to waste';
      stdout.writeln('quotabot watch: all clear - $scope.');
    }
    client.close();
    return;
  }

  if (!wantsJson) {
    final wasteText = wasteThreshold == null
        ? ''
        : ' and projected waste >= ${wasteThreshold.toStringAsFixed(1)}%';
    stderr.writeln('quotabot watch: alerting on red crossings$wasteText'
        '${webhook != null ? ' -> $webhook' : ''}. Ctrl-C to stop.');
  }

  final quit = Completer<void>();
  final sigint = ProcessSignal.sigint.watch().listen((_) {
    if (!quit.isCompleted) quit.complete();
  });

  Timer? timer;
  late final Future<void> Function() loop;
  loop = () async {
    try {
      await pass();
    } catch (_) {
      // Keep watching across a transient collection error.
    }
    final secs = fixedInterval ??
        nextRefreshSeconds(data, nowEpoch(), failStreak: failStreak);
    timer = Timer(Duration(seconds: secs), loop);
  };

  await loop();
  await quit.future;
  timer?.cancel();
  await sigint.cancel();
  client.close();
}

Future<void> _runStats(
  List<String> rest,
  bool wantsJson,
  QuotaProfile? profile,
  Set<String> excludedProviders,
  _TierFitPolicy tierFitPolicy,
) async {
  final only = rest.isEmpty ? null : rest.first.toLowerCase();
  final now = nowEpoch();
  final results = await _read(profile, excludedProviders);
  final series = buildStatsSeries(results, only, _historyBuckets);
  final tz = DateTime.now().timeZoneOffset;
  final insights = shrinkInsightsReliability({
    for (final row in series)
      row.key: Insights.from(row.buckets, now, tzOffset: tz),
  });
  if (wantsJson) {
    final report = <String, dynamic>{};
    for (final row in series) {
      final ins = insights[row.key]!;
      final pace = _paceFor(row.quota, ins, now);
      final schedule = _scheduleFor(row.quota, ins, now, tz);
      final tierFit = _tierFitFor(row.buckets, tierFitPolicy);
      report[row.key] = {
        if (row.key != row.quota.provider) 'provider': row.quota.provider,
        if (row.key != row.quota.provider) 'account': row.quota.account,
        ...ins.toJson(),
        if (pace != null) 'pace': pace.toJson(),
        if (schedule != null) 'schedule_hint': schedule.toJson(),
        if (tierFit != null) 'tier_fit': tierFit.toJson(),
      };
    }
    print(_jsonPretty(report));
  } else {
    _printStats(
      series,
      now,
      tz,
      insights,
      tierFitPolicy,
    );
  }
}

Future<void> _runReport(
  bool wantsJson,
  QuotaProfile? profile,
  Set<String> excludedProviders,
) async {
  final now = nowEpoch();
  final results = await _read(profile, excludedProviders);
  final tz = DateTime.now().timeZoneOffset;
  final insights = <String, Insights>{};
  for (final provider in results.where((provider) => !provider.isLocal)) {
    insights[quotaIdentityKeyFor(provider)] = Insights.from(
      _weeklyHistoryBuckets(
        provider.provider,
        now,
        account: provider.account,
      ),
      now,
      tzOffset: tz,
    );
  }
  final shrunkInsights = shrinkInsightsReliability(insights);
  final report = buildQuotaHealthReport(
    results,
    now,
    _suggestFor(results, now),
    insightsByProvider: shrunkInsights,
    tzOffset: tz,
  );
  wantsJson
      ? print(_jsonPretty(report.toJson()))
      : stdout.write(report.toMarkdown());
}

/// `check <provider>`: is this one usable right now, and when does it reset.
Future<void> _check(
  String name,
  bool wantsJson,
  QuotaProfile? profile,
  Set<String> excludedProviders,
) async {
  final results = await _read(profile, excludedProviders);
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
        'schema': quotabotCheckV1SchemaId,
        'as_of': now,
        'provider': key,
        'found': false,
      }));
    } else if (excludedProviders.contains(key)) {
      stderr.writeln('provider "$name" is hidden by the current --exclude '
          'or profile filter; drop the filter to check it');
    } else {
      stderr.writeln('no provider named "$name"');
      stderr.writeln('known: ${results.map((r) => r.provider).join(', ')}');
    }
    exitCode = _exitUsage;
    return;
  }
  final head = providerHeadroom(q, now);
  final binding = bindingWindow(q, now);
  final availability = providerAvailability(q, now);
  final available = q.isLocal
      ? q.ok && q.sourceClassViolation == null
      : availability.available;
  // Stable exit code so a script can branch on usability without parsing output.
  exitCode = available ? 0 : _exitUnavailable;
  final reset = binding?.resetsAt;
  if (wantsJson) {
    print(_jsonPretty({
      'schema': quotabotCheckV1SchemaId,
      'as_of': now,
      'provider': q.provider,
      'account': q.account,
      'source_class': q.sourceClass.wireName,
      'available': available,
      'headroom_percent': head,
      'resets_at': reset,
      'stale': q.stale,
      if (q.driftReason != null) 'drift_reason': q.driftReason,
      if (q.driftObservedAt != null) 'drift_observed_at': q.driftObservedAt,
    }));
    return;
  }
  final label = available ? style.green('available') : style.red('unavailable');
  final pct = head == null
      ? ''
      : q.stale
          ? '  ${style.dim('last ${head.round()}% free')}'
          : '  ${style.health(head, '${head.round()}% free')}';
  final rs = reset == null ? '' : style.dim('  resets ${_in(reset, now)}');
  final staleTag = q.driftReason != null
      ? style.dim(' (provider drift)')
      : q.stale
          ? style.dim(' (cached)')
          : '';
  final sourceTag = style.dim(' (${q.sourceClass.label})');
  stdout.writeln(
      '${style.bold(q.displayName)}: $label$pct$rs$staleTag$sourceTag');
  if (q.driftReason != null) {
    stdout.writeln(
      style.red(
        '  provider drift: ${q.driftReason}; '
        '${_providerDriftEvidenceSummary(q)}',
      ),
    );
  }
}

String _providerDriftEvidenceSummary(ProviderQuota quota) => quota.hasWindows
    ? 'showing last trusted quota'
    : 'legacy evidence is quarantined; no trusted snapshot is available';

Future<void> _login(String provider) async {
  switch (provider) {
    case 'grok':
      try {
        await XaiAuth().deviceLogin(
          prompt: (url, code) {
            stderr.writeln('Open this URL and confirm the code $code:\n  $url');
          },
        );
        stderr.writeln(
            'Grok connected. Run "quotabot doctor" to verify live data.');
      } catch (e) {
        // Match the other providers: a failed device login (network error,
        // timeout, declined code) reports cleanly and exits with the usage code,
        // rather than escaping main as an unhandled exception (exit 255 + trace).
        stderr.writeln('Grok login failed: $e');
        exitCode = _exitUsage;
      }
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
    case 'claude':
      try {
        await AnthropicAuth().loginManual(
          showUrl: (url) {
            stderr.writeln('');
            stderr.writeln('Opening your browser to sign in with Anthropic...');
            stderr.writeln(
              'If the browser does not open, manually visit this URL:',
            );
            stderr.writeln(url);
            stderr.writeln('');
            stderr.write(
              'After authorizing, paste the code shown by the browser here: ',
            );
          },
          promptCode: () async => stdin.readLineSync() ?? '',
        );
        stderr.writeln(
          'Claude connected. You can now run "quotabot doctor" to verify live data.',
        );
      } catch (e) {
        stderr.writeln('Claude login failed: $e');
        exitCode = 64;
      }
      break;
    case 'codex':
      try {
        await OpenAiAuth().loginLoopback(
          showUrl: (url) {
            stderr.writeln('');
            stderr.writeln('Opening your browser to sign in with ChatGPT...');
            stderr.writeln(
              'If the browser does not open or you see an error, manually visit this URL:',
            );
            stderr.writeln(url);
            stderr.writeln('');
          },
        );
        stderr.writeln(
          'Codex connected. You can now run "quotabot doctor" to verify live data.',
        );
      } catch (e) {
        stderr.writeln('Codex login failed: $e');
        exitCode = 64;
      }
      break;
    default:
      stderr.writeln('usage: quotabot login <grok|antigravity|claude|codex>');
      exitCode = _exitUsage;
  }
}

void _logout(String provider) {
  const known = {'grok', 'antigravity', 'claude', 'codex'};
  if (!known.contains(provider)) {
    stderr.writeln('usage: quotabot logout <grok|antigravity|claude|codex>');
    exitCode = _exitUsage;
    return;
  }
  // Login persists both a provider-default grant and an account-scoped grant
  // (keyed by the email in the id token). Clearing only the default slot would
  // leave the account grant on disk, and the next collect would refresh and
  // keep using it, so disconnect must remove every slot for the provider.
  TokenStore.clear(provider);
  TokenStore.clearAccounts(provider);
  stderr.writeln('$provider disconnected.');
}

/// Pads a state to the column width, then colors it (so the padding stays
/// outside the ANSI codes and alignment is preserved).
const _stateColumnWidth = 14;

String _stateColumn(String value) => value.padRight(_stateColumnWidth);

String _stateStyled(String state) {
  final padded = _stateColumn(state);
  switch (state) {
    case 'live':
      return style.green(padded);
    case 'in use':
    case 'available':
    case 'local':
      return style.cyan(padded);
    case 'cached':
      return style.yellow(padded);
    case 'OUT OF QUOTA':
    case 'PROVIDER DRIFT':
    case 'ERROR':
      return style.red(padded);
    default: // no live data
      return style.dim(padded);
  }
}

/// The account label for a doctor row, shown only to disambiguate a provider
/// that appears under more than one real account. A single-account provider
/// gets its identity in the provenance tag instead of the row label.
String _doctorAccountSuffix(ProviderQuota q, Map<String, int> counts) =>
    (counts[q.provider] ?? 0) > 1 && _providerHasDoctorAccountIdentity(q)
        ? ' (${q.account})'
        : '';

String _providerProvenance(ProviderQuota q, int now, String state) {
  final parts = _providerProvenanceParts(q, now, state);
  return style.dim('[${parts.join(', ')}]');
}

List<String> _providerProvenanceParts(
  ProviderQuota q,
  int now,
  String state, {
  bool includeAccount = true,
}) {
  final parts = <String>[
    _providerReadStateLabel(state),
    q.sourceClass.label,
  ];
  final spendClass = _providerSpendClass(q);
  if (spendClass != null) parts.add(spendClass);
  if (includeAccount && providerHasDoctorProvenanceIdentity(q)) {
    parts.add(q.account);
  }
  final captured = routeCaptureAgeLabel(q.asOf, now);
  if (captured.isNotEmpty) parts.add(captured);
  return parts;
}

String quotaAlertProvenance(
  QuotaAlert alert,
  List<ProviderQuota> snapshot,
  int now,
) {
  final q = _findQuota(snapshot, alert.provider, alert.account);
  final parts = q == null
      ? <String>[routeCaptureAgeLabel(alert.asOf, now)]
      : _providerProvenanceParts(
          q,
          now,
          _providerAlertState(q),
          includeAccount: !_alertMessageShowsAccount(alert.account),
        );
  final route = alert.routeTo == null
      ? null
      : _findQuota(snapshot, alert.routeTo!, alert.routeAccount);
  if (route != null) {
    final routeParts = _providerProvenanceParts(
      route,
      now,
      _providerAlertState(route),
      includeAccount: !_alertMessageShowsAccount(alert.routeAccount),
    );
    parts.addAll(routeParts.map((part) => 'route $part'));
  }
  return style.dim('[${parts.where((part) => part.isNotEmpty).join(', ')}]');
}

String _quotaAlertFallback(RouteFallback fallback, int now) {
  switch (fallback.kind) {
    case RouteFallbackKind.local:
      return ' - fallback: use ${fallback.provider} locally';
    case RouteFallbackKind.soonestReset:
      final reset = fallback.resetsAt == null
          ? ''
          : ' (resets ${_in(fallback.resetsAt!, now)})';
      return ' - fallback: wait for ${fallback.provider}$reset';
    case RouteFallbackKind.passthrough:
      return ' - fallback: use the requested provider';
  }
}

String _providerAlertState(ProviderQuota q) {
  if (q.isLocal) return q.active ? 'in use' : 'available';
  return q.stale ? 'cached' : 'live';
}

bool _alertMessageShowsAccount(String? account) =>
    account != null &&
    account.contains('@') &&
    hasSpecificQuotaAccount(account);

ProviderQuota? _findQuota(
  List<ProviderQuota> snapshot,
  String provider, [
  String? account,
]) {
  if (account != null) {
    for (final q in snapshot) {
      if (q.provider == provider && q.account == account) return q;
    }
  }
  for (final q in snapshot) {
    if (q.provider == provider) return q;
  }
  return null;
}

String _providerReadStateLabel(String state) => switch (state) {
      'OUT OF QUOTA' => 'live',
      'PROVIDER DRIFT' => 'provider drift',
      'ERROR' => 'error',
      _ => state,
    };

String? _providerSpendClass(ProviderQuota q) {
  if (q.isLocal) return q.active ? 'loaded' : 'cold';
  if (q.isManual || q.sourceClass == ProviderSourceClass.statusOnly) {
    return null;
  }
  if (!q.ok && kQuotaPlanProviders.contains(q.provider)) return 'quota plan';
  if (q.windows.isEmpty) return null;
  return kQuotaPlanProviders.contains(q.provider)
      ? 'quota plan'
      : 'metered plan';
}

bool _providerHasDoctorAccountIdentity(ProviderQuota q) {
  const placeholders = {'cli', 'installed', 'simulated'};
  return !q.isLocal &&
      hasSpecificQuotaAccount(q.account) &&
      !placeholders.contains(q.account.toLowerCase());
}

bool providerHasDoctorProvenanceIdentity(ProviderQuota q) =>
    _providerHasDoctorAccountIdentity(q) &&
    (q.isManual || q.account.contains('@'));

void _printDoctor(List<ProviderQuota> results) {
  final now = nowEpoch();
  print(
    '${style.bold('quotabot')}  ${style.dim('your quota across providers, 0 usage tokens')}\n',
  );
  // Show an account label only where a provider appears under more than one
  // account, so a single-account fleet is not cluttered with emails.
  final accountCounts = <String, int>{};
  for (final q in results) {
    accountCounts[q.provider] = (accountCounts[q.provider] ?? 0) + 1;
  }
  // Size the name column to the widest row (a long account can exceed the base
  // width) so the state column stays aligned instead of jutting out.
  final nameWidth = results
      .map((q) =>
          '${q.displayName}${_doctorAccountSuffix(q, accountCounts)}'.length)
      .fold(28, (w, len) => len > w ? len : w);
  final indent = ' '.padRight(nameWidth);
  for (final q in results) {
    bool exhausted = false;
    if (q.windows.isNotEmpty) {
      final minRem = providerHeadroom(q, now) ?? 100;
      exhausted = minRem <= 0.5;
    }
    final state = q.isLocal
        ? (q.active ? 'in use' : 'available')
        : q.driftReason != null
            ? 'PROVIDER DRIFT'
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
            // A no-window row shows its status if it has one (a setup or
            // availability state), otherwise its error. A real failure sets
            // error, not status, so an ERROR row still shows the failure.
            ? (q.status ?? q.error ?? '')
            : visibleWindows(q.windows, now).map((w) {
                final pct = windowUsedPercent(w, now).round();
                final reset = w.resetsAt == null
                    ? ''
                    : ' (resets ${_in(w.resetsAt!, now)})';
                return '${w.label} $pct% used$reset';
              }).join(', ');
    final namePart =
        '${q.displayName}${_doctorAccountSuffix(q, accountCounts)}';
    final provenance = _providerProvenance(q, now, state);
    print(
      '  ${namePart.padRight(nameWidth)} ${_stateStyled(state)} '
      '$detail $provenance',
    );
    // A redeemable off-cycle reset is the most actionable thing on a tight or
    // spent provider, so it leads the detail lines in green rather than reading
    // as one more dim note.
    final resetMessage = resetAvailableMessage(q);
    if (resetMessage != null) {
      print('  $indent ${_stateColumn('')} ${style.green(resetMessage)}');
    }
    for (final d in q.details) {
      print('  $indent ${_stateColumn('')} $d');
    }
    if (q.modelQuotas.isNotEmpty) {
      // Compact human summary; the full per-model table is in `quotabot json`
      // and over MCP, so this stays one short line.
      final mostUsed = q.modelQuotas.reduce(
        (a, b) => (a.usedPercent ?? 0) >= (b.usedPercent ?? 0) ? a : b,
      );
      final u = mostUsed.usedPercent?.round() ?? 0;
      final n = q.modelQuotas.length;
      final summary = u <= 0
          ? '$n models tracked, all fresh'
          : '$n models tracked, most used: ${mostUsed.model} $u%';
      print('  $indent ${_stateColumn('models')} $summary');
    }
    if (q.driftReason != null) {
      final detected = q.driftObservedAt == null
          ? ''
          : ' ${_ago((now - q.driftObservedAt!).clamp(0, 1 << 31).toInt())}';
      print(
        '  $indent ${_stateColumn('')} '
        '${style.red('! provider drift$detected: ${q.driftReason}; '
            '${_providerDriftEvidenceSummary(q)}')}',
      );
    }
    if (q.suspect != null) {
      print(
        '  $indent ${_stateColumn('')} '
        '${style.yellow('! suspect: ${q.suspect}')}',
      );
    }
    final hint = _doctorHint(q, state);
    if (hint != null) print('  $indent ${_stateColumn('')} -> $hint');
  }

  // Close the loop: tell the user where to route work next.
  final suggestion = _suggestFor(results, now);
  print('\nSuggested: ${suggestion.reason}');
  print('  (run "quotabot suggest" for the full ranked list)');

  // Surface the calibration headline here so a skeptic sees how often quotabot's
  // predictions come true without a separate command. Shown only once enough
  // predictions have resolved; a thin history prints nothing rather than a
  // number it cannot stand behind.
  final calBuckets = <String, List<HeadroomBucket>>{};
  for (final q in results.where((q) => !q.isLocal)) {
    final b = _historyBuckets(q.provider);
    if (b.isNotEmpty) calBuckets[q.provider] = b;
  }
  final calHeadline = calibrationAcross(calBuckets, now).headline;
  if (calHeadline != null) {
    print(
      '  ${style.dim('$calHeadline (run "quotabot calibration" for detail)')}',
    );
  }
  print(
    '\n${style.cyan('Live view:')} ${style.bold('quotabot top')}  '
    '${style.dim('a refreshing dashboard (q to quit). Also: quotabot models')}',
  );

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
      '  (Aider/Cline etc. often use underlying provider quotas already tracked above.)',
    );
  }
}

/// `explain`: a dry-run manifest of provider metadata reads and network hosts.
/// It records what a normal quota read may touch for the current OS/profile
/// without contacting providers or reading secret file contents.
void _runExplain(
  Set<String> flags,
  bool wantsJson,
  QuotaProfile? profile,
  Set<String> excludedProviders,
) {
  final includeReadsFlag = flags.contains('--reads');
  final includeNetworkFlag = flags.contains('--network');
  final includeReads = includeReadsFlag || !includeNetworkFlag;
  final includeNetwork = includeNetworkFlag || !includeReadsFlag;
  final report = buildRuntimeAccessReport(
    generatedAt: nowEpoch(),
    includeReads: includeReads,
    includeNetwork: includeNetwork,
    profile: profile,
    excludedProviders: excludedProviders,
  );
  wantsJson ? print(_jsonPretty(report.toJson())) : _printExplain(report);
}

void _printExplain(RuntimeAccessReport report) {
  print(
    '${style.bold('quotabot explain')}  '
    '${style.dim('runtime trust boundary, dry-run manifest, 0 usage tokens')}\n',
  );
  print(
    '  ${style.green('metadata only')}  no prompts, source code, model outputs, '
    'or generation endpoints',
  );
  print(
    '  ${style.dim('mode')} runtime_access_manifest; provider collection was not run',
  );
  if (report.shared.isNotEmpty) {
    print('\n${style.bold('Shared local metadata')}');
    for (final record in report.shared) {
      _printAccessRecord(record);
    }
  }
  for (final provider in report.providers) {
    print(
        '\n${style.bold(provider.displayName)} ${style.dim(provider.provider)}');
    if (provider.reads.isNotEmpty) {
      print('  ${style.dim('reads')}');
      for (final record in provider.reads) {
        _printAccessRecord(record);
      }
    }
    if (provider.network.isNotEmpty) {
      print('  ${style.dim('network')}');
      for (final record in provider.network) {
        _printAccessRecord(record);
      }
    }
    for (final note in provider.notes) {
      print('  ${style.dim('note')} $note');
    }
  }
  print(
    '\n${style.dim('Machine-readable form:')} '
    '${style.bold('quotabot explain --reads --network --json')}',
  );
}

void _printAccessRecord(RuntimeAccessRecord record) {
  final token = record.credentialMaterial ? ' credential' : '';
  final method =
      record.kind == RuntimeAccessKind.network && record.method != null
          ? ' ${record.method}'
          : '';
  print(
    '    -$method ${record.target} '
    '${style.dim('[${record.dataClass}$token]')}',
  );
  print('      ${style.dim(record.purpose)}');
}

/// `verify`: mechanical honesty checks over one live read, for the 1.0
/// release-candidate provider verification matrix. Exit code 0 when every
/// snapshot passes, 65 when any check fails, so a matrix script can branch.
Future<void> _runVerify(
  bool wantsJson,
  QuotaProfile? profile,
  Set<String> excludedProviders,
) async {
  final read = await _readForVerify(profile, excludedProviders);
  final results = read.results;
  final report = buildVerificationReport(
    results,
    nowEpoch(),
    os: Platform.operatingSystem,
    filtered:
        profile != null || excludedProviders.isNotEmpty || _usingSimulation,
    runtimeAccess: read.runtimeAccess,
  );
  if (wantsJson) {
    print(_jsonPretty(report.toJson()));
  } else {
    _printVerify(report, results);
  }
  if (!report.passed) exitCode = _exitVerifyFailed;
}

String _verifyStateLabel(String state) => switch (state) {
      'out_of_quota' => 'OUT OF QUOTA',
      'error' => 'ERROR',
      'no_data' => 'no live data',
      _ => state,
    };

String _providerVerificationStateLabel(ProviderVerification verification) =>
    verification.driftReason == null
        ? _verifyStateLabel(verification.state)
        : 'PROVIDER DRIFT';

void _printVerify(VerificationReport report, List<ProviderQuota> snapshot) {
  print(
    '${style.bold('quotabot verify')}  ${style.dim('mechanical honesty checks over one live read, 0 usage tokens')}\n',
  );
  for (var i = 0; i < report.providers.length; i++) {
    final p = report.providers[i];
    final acct = (p.account != 'default' &&
            p.account != 'unknown' &&
            p.account != 'none' &&
            p.account != 'installed' &&
            p.account != 'cli')
        ? ' (${p.account})'
        : '';
    final verdict = p.passed ? style.green('PASS') : style.red('FAIL');
    final provenance =
        _verificationProvenance(p, snapshot, i, report.generatedAt);
    print(
      '  ${'${p.displayName}$acct'.padRight(28)} '
      '${_stateStyled(_providerVerificationStateLabel(p))} $verdict $provenance',
    );
    for (final c in _visibleVerifyChecks(p)) {
      final tag =
          c.status == VerifyStatus.fail ? style.red(c.id) : style.dim(c.id);
      print(
        '  ${' '.padRight(28)} ${_stateColumn('')} -> $tag: ${c.detail}',
      );
    }
  }
  print('');
  for (final c in report.fleetChecks) {
    final verdict = switch (c.status) {
      VerifyStatus.pass => style.green('PASS'),
      VerifyStatus.fail => style.red('FAIL'),
      VerifyStatus.info => style.dim('info'),
    };
    print('  fleet ${c.id.padRight(22)} $verdict  ${style.dim(c.detail)}');
  }
  final runtimeAccess = report.runtimeAccess;
  if (runtimeAccess != null) {
    final mode =
        runtimeAccess.collectionExecuted ? 'observed' : 'manifest only';
    final providerCount = runtimeAccess.providers.length;
    print(
      '  runtime access ${mode.padRight(16)} '
      '${style.dim('$providerCount provider adapter(s), no prompts/code, 0 usage tokens')}',
    );
  }
  final failed = report.failCount;
  print('');
  print(failed == 0
      ? style.green(
          '  every snapshot is reading correctly or failing with a plain reason')
      : style.red('  $failed check(s) failed; see details above'));
  final crossChecks = [
    for (final p in report.providers)
      if (p.crossCheck != null && p.state != 'undetected')
        '  ${p.displayName}: ${p.crossCheck}',
  ];
  if (crossChecks.isNotEmpty) {
    print(
        '\n${style.dim('Confirm the numbers against each provider\'s own view:')}');
    crossChecks.toSet().forEach(print);
  }
  print(
    '\n${style.dim('Record this run for the verification matrix:')} '
    '${style.bold('quotabot verify --json')}',
  );
}

Iterable<VerifyCheck> _visibleVerifyChecks(ProviderVerification p) =>
    p.checks.where((c) =>
        c.status != VerifyStatus.pass ||
        ({'error', 'no_data'}.contains(p.state) && c.id == 'read_or_reason') ||
        (p.state == 'cached' && c.id == 'stale_honesty'));

String _verificationProvenance(
  ProviderVerification verification,
  List<ProviderQuota> snapshot,
  int snapshotIndex,
  int now,
) {
  final quota = quotaForVerificationProvenance(
    snapshot,
    verification,
    snapshotIndex,
  );
  if (quota == null) {
    return style.dim('[undetected]');
  }
  return _providerProvenance(
    quota,
    now,
    _verificationProvenanceState(quota, verification.state),
  );
}

ProviderQuota? quotaForVerificationProvenance(
  List<ProviderQuota> snapshot,
  ProviderVerification verification,
  int snapshotIndex,
) {
  if (snapshotIndex < snapshot.length) {
    final q = snapshot[snapshotIndex];
    if (q.provider == verification.provider &&
        q.account == verification.account) {
      return q;
    }
    return null;
  }
  ProviderQuota? singleMatch;
  for (final q in snapshot) {
    if (q.provider == verification.provider &&
        q.account == verification.account) {
      if (singleMatch != null) return null;
      singleMatch = q;
    }
  }
  return singleMatch;
}

String _verificationProvenanceState(ProviderQuota q, String state) =>
    q.driftReason != null
        ? 'PROVIDER DRIFT'
        : switch (state) {
            'out_of_quota' => 'OUT OF QUOTA',
            'error' => 'ERROR',
            'no_data' => 'metadata',
            'local' => q.active ? 'in use' : 'available',
            _ => state,
          };

/// A compact "Ns/Nm/Nh ago" age label.
String _ago(int seconds) {
  if (seconds < 90) return '${seconds}s ago';
  if (seconds < 5400) return '${(seconds / 60).round()}m ago';
  if (seconds < 129600) return '${(seconds / 3600).round()}h ago';
  return '${(seconds / 86400).round()}d ago';
}

/// `calibration`: grade quotabot's own strand predictions against the user's
/// recorded history, so "how often is it right" is a measured number, not a claim.
Future<void> _runCalibration(
  bool wantsJson,
  QuotaProfile? profile,
  Set<String> excludedProviders,
) async {
  final results = await _read(profile, excludedProviders);
  final now = nowEpoch();
  final byProvider = <String, List<HeadroomBucket>>{};
  for (final q in results.where((q) => !q.isLocal)) {
    final b = _historyBuckets(q.provider);
    if (b.isNotEmpty) byProvider[q.provider] = b;
  }
  final overall = calibrationAcross(byProvider, now);
  final tuning = tuneBurnLookback(byProvider, now);
  if (wantsJson) {
    print(_jsonPretty({
      'schema': 'quotabot.calibration.v1',
      'generated_at': now,
      'overall': overall.toJson(),
      'tuning': tuning.toJson(),
      'by_provider': {
        for (final e in byProvider.entries)
          e.key: calibrationFromHistory(e.value, now).toJson(),
      },
    }));
  } else {
    _printCalibration(overall, byProvider, now, tuning);
  }
}

/// Prints the calibration report: the headline accuracy, a reliability diagram
/// (predicted probability versus what actually happened), and a per-provider line.
void _printCalibration(
  CalibrationReport overall,
  Map<String, List<HeadroomBucket>> byProvider,
  int now,
  TunedParameters tuning,
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
  if (tuning.tuned) {
    final improve = ((tuning.brierImprovement ?? 0) * 1000).round() / 1000;
    print('');
    print(style.dim(
      '  self-tuned: your history predicts best with a '
      '${tuning.burnLookbackHours}h burn lookback '
      '(Brier -$improve vs the ${kDefaultBurnLookbackHours}h default). '
      'Advisory; not yet applied to routing.',
    ));
  }
}

/// A compact context-window label: "1M", "200K".
String _ctxLabel(int tokens) => tokens >= 1000000
    ? '${(tokens / 1000000).round()}M'
    : '${(tokens / 1000).round()}K';

/// Prints the represented model registry with each known budget gate and its
/// capability hints.
void _printModels(
  List<ModelEntry> reg,
  int now, {
  bool filtersActive = false,
}) {
  print('quotabot models  (known candidates, 0 usage tokens)\n');
  if (reg.isEmpty) {
    // Distinguish "nothing to route to" from "your filters excluded everything",
    // so a too-strict flag does not read as a missing runtime.
    print(filtersActive
        ? '  no models match these filters; loosen them or run '
            '"quotabot models" with no filters'
        : '  no models detected; start a local runtime or connect a provider');
    return;
  }
  for (final e in reg) {
    final m = e.model;
    final budget = e.local
        ? style.cyan('local'.padRight(9))
        : (e.headroomPercent == null
            ? style.dim('?'.padRight(9))
            : e.stale
                ? style.dim('${e.headroomPercent!.round()}% last'.padRight(9))
                : style.health(
                    e.headroomPercent!,
                    '${e.headroomPercent!.round()}% free'.padRight(9),
                  ));
    final caps = [
      if (m.tier != null) m.tier!,
      if (m.tools == true) 'tools',
      if (m.vision == true) 'vision',
      if (m.reasoning != null) 'reason',
    ].join(',');
    final capStr = caps.isEmpty ? '' : style.dim('  $caps');
    final spent = e.available
        ? ''
        : e.stale
            ? style.dim('  unavailable')
            : style.red('  spent');
    final provenance = _modelEntryProvenance(e, now);
    // Pad the context cell to a fixed width so the capability column lines up
    // across "1M ctx", "400K ctx", and context-less local models. Only pad when
    // something follows, so a row that ends at the context adds no trailing gap.
    final ctxText =
        m.contextTokens == null ? '' : '${_ctxLabel(m.contextTokens!)} ctx';
    final trailing = '$capStr$spent';
    final ctx = trailing.isEmpty
        ? (ctxText.isEmpty ? '' : style.dim('  $ctxText'))
        : style.dim('  ${ctxText.padRight(8)}');
    print(
      '  ${m.id.padRight(22)} ${e.provider.padRight(11)} '
      '$budget $provenance$ctx$trailing',
    );
  }
  print(style.dim('\n  capability catalog updated $kCatalogUpdated'));
}

String _modelEntryProvenance(ModelEntry e, int decisionAsOf) {
  final parts = <String>[
    e.driftReason != null
        ? 'provider drift'
        : e.stale
            ? 'cached'
            : 'live',
    e.sourceClass.label,
  ];
  final spendClass = _modelSpendClass(e);
  if (spendClass != null) parts.add(spendClass);
  if (_modelHasAccountIdentity(e)) parts.add(e.account);
  final captured = routeCaptureAgeLabel(e.asOf, decisionAsOf);
  if (captured.isNotEmpty) parts.add(captured);
  return style.dim('[${parts.join(', ')}]');
}

String? _modelSpendClass(ModelEntry e) {
  if (e.local) {
    final readiness = e.localReadiness;
    return readiness;
  }
  if (e.sourceClass == ProviderSourceClass.manual) return null;
  return e.quotaBacked ? 'quota plan' : 'metered plan';
}

bool _modelHasAccountIdentity(ModelEntry e) =>
    !e.local && e.account.contains('@') && hasSpecificQuotaAccount(e.account);

/// Prints a routing recommendation: where to send the next request and why,
/// with the ranked alternatives below it.
void _printSuggest(RouteSuggestion s) {
  print('quotabot suggest  (which subscription to use next, 0 usage tokens)\n');
  final r = s.recommended;
  if (r == null) {
    print('  no provider to route to right now');
  } else {
    final tag = r.isLocal ? style.dim(' (runtime-classified fallback)') : '';
    final account = _routeAccountLabel(r);
    final provenance = _routeCandidateProvenance(r, s.asOf);
    print(
      '  ${style.green('->')} ${style.bold(r.provider)}$account$tag '
      '$provenance',
    );
  }
  print('  ${s.reason}\n');

  if (s.ranked.isEmpty) return;
  print('  candidates (best first):');
  for (final c in s.ranked) {
    final provenance = _routeCandidateProvenance(c, s.asOf);
    if (c.isLocal) {
      // Runtime-classified entries have no tracked subscription window. Do not
      // imply that adapter reachability proves execution location or cost.
      print(
        '    ${c.provider.padRight(12)} ${style.cyan('runtime fallback')}  '
        '$provenance',
      );
      continue;
    }
    // Internal scores (confidence, strand probability, cost weighting) stay in
    // `suggest --json`; the glance shows only what a person acts on. See
    // routeCandidateGlanceLine and ROADMAP 0.9.
    print(routeCandidateGlanceLine(c, style: style, provenance: provenance));
  }
}

String _routeAccountLabel(RouteCandidate c) =>
    _routeHasAccountIdentity(c) ? ' (${c.account})' : '';

String _routeCandidateProvenance(RouteCandidate c, int decisionAsOf) {
  final parts = <String>[
    c.driftReason != null
        ? 'provider drift'
        : c.stale
            ? 'cached'
            : 'live',
    c.sourceClass.label,
  ];
  if (!c.isLocal && c.sourceClass != ProviderSourceClass.manual) {
    parts.add(c.spendClass);
  }
  if (_routeHasAccountIdentity(c)) parts.add(c.account);
  final captured = routeCaptureAgeLabel(c.asOf, decisionAsOf);
  if (captured.isNotEmpty) parts.add(captured);
  return style.dim('[${parts.join(', ')}]');
}

bool _routeHasAccountIdentity(RouteCandidate c) =>
    !c.isLocal && c.account.contains('@') && hasSpecificQuotaAccount(c.account);

const routeFutureCaptureLabel = 'captured in the future';

String routeCaptureAgeLabel(int capturedAt, int decisionAsOf) {
  if (capturedAt <= 0) return '';
  if (capturedAt > decisionAsOf) return routeFutureCaptureLabel;
  return 'captured ${_ago(decisionAsOf - capturedAt)}';
}

/// Pace for a provider from its live binding window plus the recent burn rate.
Pace? _paceFor(ProviderQuota? q, Insights ins, int now) {
  if (q == null || q.isLocal) return null;
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

WeekHourScheduleHint? _scheduleFor(
  ProviderQuota? q,
  Insights ins,
  int now,
  Duration tz,
) {
  if (q == null || q.isLocal) return null;
  return weekHourScheduleHint(
    ins.bestTimeWindows,
    now,
    resetsAt: bindingWindow(q, now)?.resetsAt,
    tzOffset: tz,
  );
}

/// Prints historical analytics per provider: distribution, reliability, usage
/// pattern, and a forward-looking pace read for the current window.
void _printStats(
  List<StatsSeries> series,
  int now,
  Duration tz,
  Map<String, Insights> insights,
  _TierFitPolicy tierFitPolicy,
) {
  print(
    'quotabot stats  (90-day analytics from local history, 0 usage tokens)\n',
  );
  if (series.isEmpty) {
    print('  no history yet; leave quotabot running to build it');
    return;
  }

  // Portfolio view: where you actually spend, and what you barely use.
  final port = portfolioInsight({
    for (final row in series) row.label: insights[row.key]!,
  });
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

  var anyCalendar = false;
  for (final row in series) {
    final buckets = row.buckets;
    final ins = insights[row.key] ?? Insights.from(buckets, now, tzOffset: tz);
    final label = row.label;
    if (ins.samples == 0) {
      print('  ${label.padRight(12)} no history yet');
      continue;
    }
    final mean = ins.mean!.round();
    final rel = (ins.reliability! * 100).round();
    print(
      '  ${label.padRight(12)} avg ${mean.toString().padLeft(3)}% free'
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
    final tierFit = _tierFitFor(buckets, tierFitPolicy);
    if (tierFit != null) {
      print('  ${' '.padRight(12)} ${_tierFitSummary(tierFit)}');
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
    if (ins.bestTimeWindows.isNotEmpty) {
      extras.add('best ${ins.bestTimeWindows.first.summary}');
    }
    final schedule = _scheduleFor(row.quota, ins, now, tz);
    if (schedule != null) {
      extras.add('schedule ${schedule.summary}');
    }
    if (ins.spentDayStreak > 0) {
      extras.add('${ins.spentDayStreak}d spent streak');
    } else if (ins.usableDayStreak > 0) {
      extras.add('${ins.usableDayStreak}d usable streak');
    }
    final calendar = contributionCalendarMarkers(
      ins.contributionCalendar,
      maxDays: 28,
    );
    if (calendar.isNotEmpty) {
      extras.add('calendar $calendar');
      anyCalendar = true;
    }
    extras.add('${ins.samples} samples / ${ins.sampledDays} sampled days');
    print('  ${' '.padRight(12)} ${extras.join('   ')}');
    final pace = _paceFor(row.quota, ins, now);
    if (pace != null && pace.burnPerHour >= 0.2) {
      print('  ${' '.padRight(12)} pace: ${pace.verdict}');
    }
  }
  if (anyCalendar) {
    final legend =
        kContributionCalendarLegend.map((e) => '${e.$1} ${e.$2}').join('  ');
    print(style.dim(
      '\n  calendar (oldest to newest sampled day): $legend',
    ));
  }
}

TierFitAnalysis? _tierFitFor(
  List<HeadroomBucket> buckets,
  _TierFitPolicy policy,
) {
  if (policy.plans.isEmpty) return null;
  return tierFitAnalysis(
    buckets,
    policy.plans,
    maxBreachProbability: policy.maxBreachProbability,
    currentMonthlyPrice: policy.currentMonthlyPrice,
  );
}

String _tierFitSummary(TierFitAnalysis analysis) {
  final risk = _probPct(analysis.maxBreachProbability);
  final rec = analysis.recommended;
  if (analysis.sampleCount == 0) {
    return 'tier fit: no history yet for explicit plan analysis';
  }
  if (rec == null) {
    return 'tier fit: no supplied plan stays under $risk breach risk';
  }
  return 'tier fit: ${rec.name} cap ${_num(rec.capPercentOfCurrent)}% '
      'of current, breach ${_probPct(rec.breachProbability)}'
      '${_monthlyDelta(rec.monthlyDelta)}';
}

String _monthlyDelta(double? delta) {
  if (delta == null) return '';
  if (delta.abs() < 0.005) return ', same monthly price';
  final amount = delta.abs().toStringAsFixed(2);
  return delta < 0 ? ', saves ~\$$amount/mo' : ', costs +\$$amount/mo';
}

String _probPct(double probability) =>
    '${(probability * 100).toStringAsFixed(1)}%';

String _num(double value) {
  final rounded = value.roundToDouble();
  return (value - rounded).abs() < 0.001
      ? rounded.toInt().toString()
      : value.toStringAsFixed(1);
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
  const canLogin = {'grok', 'antigravity', 'claude', 'codex'};
  if (state == 'PROVIDER DRIFT') {
    return 'run: quotabot verify  (${_providerDriftEvidenceSummary(q)})';
  }
  if (state == 'cached' && canLogin.contains(q.provider)) {
    return 'run: quotabot login ${q.provider}  (keeps it live without reopening the app)';
  }
  if (state == 'cached' && q.error?.isNotEmpty == true) {
    return q.error;
  }
  if (state == 'no live data' && !q.isLocal) {
    // NVIDIA NIM is an env-key provider, not an installed app, so the generic
    // "open the app" guidance does not apply: point at the key instead.
    if (q.provider == 'nvidia') {
      return 'set NVIDIA_API_KEY (or nvapi) to check free-trial access';
    }
    if (canLogin.contains(q.provider)) {
      return 'open the ${q.displayName} app on this machine, '
          'or run: quotabot login ${q.provider}';
    }
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
