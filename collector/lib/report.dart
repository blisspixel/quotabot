import 'analysis.dart';
import 'insights.dart';
import 'labels.dart';
import 'models.dart';
import 'provenance.dart';

const quotaHealthReportSchema = 'quotabot.report.v1';

class QuotaHealthProviderLine {
  final String provider;
  final String displayName;
  final String account;
  final ProviderQuotaKind kind;
  final String? source;
  final ProviderSourceClass sourceClass;
  final String state;
  final bool ok;
  // The spend class for the trust tag ('quota plan', 'metered plan', 'loaded',
  // 'cold', or null), computed from the source quota via the shared
  // providerSpendClass so it cannot drift from `top` and the CLI.
  final String? spendClass;
  final int asOf;
  final int stalenessSeconds;
  final bool stale;
  final bool perMachine;
  final String? error;
  final String? driftReason;
  final int? driftObservedAt;
  final String? pipeHealth;
  final int? httpStatus;
  final int? retryAfterSeconds;
  final double? headroomPercent;
  final int? resetsAt;
  final double? p50Free;
  final double? reliability;
  final int? sampledDays;
  final int? usableDayStreak;
  final int? spentDayStreak;
  final List<ContributionDay> contributionCalendar;
  final List<WeekHourWindow> bestTimeWindows;
  final WeekHourScheduleHint? scheduleHint;
  final String? pace;

  const QuotaHealthProviderLine({
    required this.provider,
    required this.displayName,
    required this.account,
    required this.kind,
    required this.source,
    required this.sourceClass,
    required this.state,
    required this.ok,
    required this.spendClass,
    required this.asOf,
    required this.stalenessSeconds,
    required this.stale,
    required this.perMachine,
    required this.error,
    required this.driftReason,
    required this.driftObservedAt,
    required this.pipeHealth,
    required this.httpStatus,
    required this.retryAfterSeconds,
    required this.headroomPercent,
    required this.resetsAt,
    required this.p50Free,
    required this.reliability,
    required this.sampledDays,
    required this.usableDayStreak,
    required this.spentDayStreak,
    this.contributionCalendar = const [],
    this.bestTimeWindows = const [],
    this.scheduleHint,
    required this.pace,
  });

  bool get isManual => source == providerQuotaManualSource;

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'display_name': displayName,
        'account': account,
        'kind': kind.wireName,
        if (source != null) 'source': source,
        'source_class': sourceClass.wireName,
        'state': state,
        'ok': ok,
        // Same spend class the markdown Trust column shows (quota plan,
        // metered plan, loaded, cold, manual). Omitted only when unknown.
        if (spendClass != null) 'spend_class': spendClass,
        'as_of': asOf,
        'staleness_seconds': stalenessSeconds,
        'stale': stale,
        'per_machine': perMachine,
        if (error != null) 'error': error,
        if (driftReason != null) 'drift_reason': driftReason,
        if (driftObservedAt != null) 'drift_observed_at': driftObservedAt,
        if (pipeHealth != null) 'pipe_health': pipeHealth,
        if (httpStatus != null) 'http_status': httpStatus,
        if (retryAfterSeconds != null) 'retry_after_seconds': retryAfterSeconds,
        'headroom_percent': headroomPercent,
        'resets_at': resetsAt,
        'weekly_p50_free_percent': p50Free,
        'weekly_reliability': reliability,
        'weekly_sampled_days': sampledDays,
        'weekly_usable_day_streak': usableDayStreak,
        'weekly_spent_day_streak': spentDayStreak,
        'weekly_contribution_calendar':
            contributionCalendar.map((day) => day.toJson()).toList(),
        'weekly_best_time_windows':
            bestTimeWindows.map((window) => window.toJson()).toList(),
        if (scheduleHint != null)
          'weekly_schedule_hint': scheduleHint!.toJson(),
        'pace': pace,
      };
}

class QuotaHealthReport {
  final int generatedAt;
  final String? recommendedProvider;
  final String? recommendedAccount;
  final String recommendationReason;
  final String fallbackKind;
  final RouteDecisionCode decisionCode;
  final RouteDecisionReceipt receipt;
  final List<QuotaHealthProviderLine> providers;

  const QuotaHealthReport({
    required this.generatedAt,
    required this.recommendedProvider,
    required this.recommendedAccount,
    required this.recommendationReason,
    required this.fallbackKind,
    required this.decisionCode,
    required this.receipt,
    required this.providers,
  });

  Map<String, dynamic> toJson() => {
        'schema': quotaHealthReportSchema,
        'generated_at': generatedAt,
        'recommended_provider': recommendedProvider,
        'recommended_account': recommendedAccount,
        'recommendation_reason': recommendationReason,
        'fallback_kind': fallbackKind,
        'decision_code': decisionCode.wireName,
        'decision_id': receipt.decisionId,
        'receipt': receipt.toJson(),
        'providers': providers.map((provider) => provider.toJson()).toList(),
      };

  String toMarkdown({bool includeAccounts = false}) {
    final accountLabels = _markdownAccountLabels(
      providers,
      includeAccounts: includeAccounts,
    );
    String accountLabel(QuotaHealthProviderLine provider) =>
        accountLabels[quotaIdentityKey(provider.provider, provider.account)] ??
        quotaAccountDisplayLabel(provider.account);
    final providerCounts = <String, int>{};
    for (final provider in providers) {
      providerCounts[provider.provider] =
          (providerCounts[provider.provider] ?? 0) + 1;
    }
    var recommendationTarget = recommendedProvider ?? 'none';
    if (recommendedProvider != null &&
        recommendedAccount != null &&
        (providerCounts[recommendedProvider] ?? 0) > 1) {
      final winner = providers.where(
        (provider) =>
            provider.provider == recommendedProvider &&
            provider.account == recommendedAccount,
      );
      if (winner.isNotEmpty) {
        recommendationTarget =
            '$recommendedProvider (${accountLabel(winner.first)})';
      }
    }
    final lines = <String>[
      '# quotabot weekly quota health',
      '',
      'Generated: ${_iso(generatedAt)}',
      'Recommendation: $recommendationTarget - $recommendationReason',
      'Fallback: $fallbackKind',
      'Decision: ${receipt.decisionId}',
      'Evidence source: ${receipt.snapshot.source}',
      'Accounts: ${includeAccounts ? 'included by explicit request' : 'anonymized'}',
      '',
      '## Providers',
      '',
      '| Provider | Account | State | Trust | Headroom | Reset | 7d p50 free | 7d reliability | Streak | Pace |',
      '| --- | --- | --- | --- | ---: | --- | ---: | ---: | --- | --- |',
      for (final provider in providers)
        '| ${_cell(provider.displayName)} | '
            '${_cell(accountLabel(provider))} | '
            '${_cell(provider.state)} | '
            '${_cell(_trustContext(provider, generatedAt))} | '
            '${_percent(provider.headroomPercent)} | '
            '${provider.resetsAt == null ? 'n/a' : _iso(provider.resetsAt!)} | '
            '${_percent(provider.p50Free)} | ${_ratio(provider.reliability)} | '
            '${_cell(_streak(provider))} | '
            '${_cell(provider.pace ?? 'n/a')} |',
    ];
    if (providers.any((provider) => provider.isManual)) {
      lines
        ..add('')
        ..add(
          'Manual entries are self-reported and excluded from measured history.',
        );
    }
    if (providers.any((provider) => provider.kind.isLocal)) {
      lines
        ..add('')
        ..add(
          'Local runtimes are fallback capacity and do not spend subscription quota.',
        );
    }
    final calendars = providers
        .where((provider) => provider.contributionCalendar.isNotEmpty)
        .toList();
    if (calendars.isNotEmpty) {
      lines
        ..add('')
        ..add('## Weekly calendar')
        ..add('')
        ..add(
          '${kContributionCalendarLegend.map((e) => '`${e.$1}` ${e.$2}').join(', ')}. Oldest to newest.',
        );
      for (final provider in calendars) {
        lines.add(
          '- ${_cell(provider.displayName)} '
          '(${_cell(accountLabel(provider))}): '
          '`${contributionCalendarMarkers(
            provider.contributionCalendar,
            maxDays: 7,
          )}`',
        );
      }
    }
    final bestTimes =
        providers.where((provider) => provider.bestTimeWindows.isNotEmpty);
    if (bestTimes.isNotEmpty) {
      lines
        ..add('')
        ..add('## Best sampled windows')
        ..add('')
        ..add(
          'Best local weekday/hour windows from existing history buckets, '
          'smoothed when nearby samples support it.',
        );
      for (final provider in bestTimes) {
        lines.add(
          '- ${_cell(provider.displayName)} '
          '(${_cell(accountLabel(provider))}): '
          '${_cell(_bestWindows(provider.bestTimeWindows))}',
        );
      }
    }
    final scheduleHints =
        providers.where((provider) => provider.scheduleHint != null);
    if (scheduleHints.isNotEmpty) {
      lines
        ..add('')
        ..add('## Reset-aware schedule hints')
        ..add('')
        ..add(
          'Nearest strong weekday/hour slot from existing history that starts before the active reset.',
        );
      for (final provider in scheduleHints) {
        lines.add(
          '- ${_cell(provider.displayName)} '
          '(${_cell(accountLabel(provider))}): '
          '${_cell(provider.scheduleHint!.summary)}',
        );
      }
    }
    return '${lines.join('\n')}\n';
  }
}

QuotaHealthReport buildQuotaHealthReport(
  List<ProviderQuota> snapshot,
  int now,
  RouteSuggestion suggestion, {
  Map<String, Insights> insightsByProvider = const {},
  Duration tzOffset = Duration.zero,
}) {
  final recommended = suggestion.recommended;
  final receipt = suggestion.receipt;
  final fallbackKind = switch (suggestion.fallback.kind) {
    RouteFallbackKind.local => 'local runtime',
    RouteFallbackKind.soonestReset => 'wait for reset',
    RouteFallbackKind.passthrough => 'passthrough',
  };
  return QuotaHealthReport(
    generatedAt: now,
    recommendedProvider: recommended?.provider,
    recommendedAccount: recommended?.account,
    recommendationReason: suggestion.reason,
    fallbackKind: fallbackKind,
    decisionCode: suggestion.decisionCode,
    receipt: receipt,
    providers: [
      for (final provider in snapshot)
        _providerLine(
          provider,
          now,
          insightsByProvider[quotaIdentityKeyFor(provider)] ??
              insightsByProvider[provider.provider],
          tzOffset,
        ),
    ],
  );
}

QuotaHealthProviderLine _providerLine(
  ProviderQuota provider,
  int now,
  Insights? insights,
  Duration tzOffset,
) {
  final headroom = provider.isLocal ? null : providerHeadroom(provider, now);
  final binding = provider.isLocal ? null : bindingWindow(provider, now);
  final state = _state(provider, headroom);
  final scheduleHint = provider.isLocal || insights == null
      ? null
      : weekHourScheduleHint(
          insights.bestTimeWindows,
          now,
          resetsAt: binding?.resetsAt,
          tzOffset: tzOffset,
        );
  final pace = provider.isLocal || insights == null
      ? null
      : computePace(
          headroom: headroom ?? 0,
          resetsAt: binding?.resetsAt,
          burnPerHour: insights.burnPerHour,
          now: now,
        )?.verdict;
  return QuotaHealthProviderLine(
    provider: provider.provider,
    displayName: provider.displayName,
    account: provider.account,
    kind: provider.kind,
    source: provider.source,
    sourceClass: provider.sourceClass,
    state: state,
    ok: provider.ok,
    spendClass: providerSpendClass(provider),
    asOf: provider.asOf,
    stalenessSeconds: (now - provider.asOf).clamp(0, 1 << 31).toInt(),
    stale: provider.stale,
    perMachine: provider.perMachine,
    error: provider.error,
    driftReason: provider.driftReason,
    driftObservedAt: provider.driftObservedAt,
    pipeHealth: provider.pipeHealth,
    httpStatus: provider.httpStatus,
    retryAfterSeconds: provider.retryAfterSeconds,
    headroomPercent: headroom,
    resetsAt: binding?.resetsAt,
    p50Free: insights?.p50,
    reliability: insights?.reliability,
    sampledDays: insights?.sampledDays,
    usableDayStreak: insights?.usableDayStreak,
    spentDayStreak: insights?.spentDayStreak,
    contributionCalendar: insights?.contributionCalendar ?? const [],
    bestTimeWindows: insights?.bestTimeWindows ?? const [],
    scheduleHint: scheduleHint,
    pace: pace,
  );
}

Map<String, String> _markdownAccountLabels(
  List<QuotaHealthProviderLine> providers, {
  required bool includeAccounts,
}) {
  final counts = <String, int>{};
  for (final provider in providers) {
    counts[provider.provider] = (counts[provider.provider] ?? 0) + 1;
  }
  final indexes = <String, int>{};
  final labels = <String, String>{};
  for (final provider in providers) {
    final key = quotaIdentityKey(provider.provider, provider.account);
    if (includeAccounts || !_reportAccountNeedsRedaction(provider)) {
      labels[key] = quotaAccountDisplayLabel(provider.account);
      continue;
    }
    final next = (indexes[provider.provider] ?? 0) + 1;
    indexes[provider.provider] = next;
    labels[key] =
        (counts[provider.provider] ?? 0) > 1 ? 'account $next' : 'account';
  }
  return labels;
}

bool _reportAccountNeedsRedaction(QuotaHealthProviderLine provider) {
  if (provider.kind.isLocal) return false;
  if (!hasSpecificQuotaAccount(provider.account)) return false;
  return provider.account != 'simulated';
}

String _state(ProviderQuota provider, double? headroom) {
  // Drift is the top-priority read state, as it is in `top` and the desktop app:
  // a provider whose live read disagreed with its trusted history is showing a
  // held snapshot, and that must not be mislabeled as an ordinary live/cached
  // number. Checked before ok/local/stale so a drifted-and-stale read still reads
  // as drift.
  if (provider.driftReason != null) return 'provider drift';
  if (!provider.ok) return 'unavailable';
  if (provider.isLocal) return provider.active ? 'local active' : 'local ready';
  if (provider.stale) return 'cached';
  if (headroom == null) return 'unknown';
  if (headroom <= kSpentHeadroomFloor) return 'spent';
  if (headroom < 15) return 'tight';
  return 'available';
}

String _trustContext(QuotaHealthProviderLine provider, int generatedAt) {
  final parts = <String>[
    _trustReadState(provider),
    provider.sourceClass.label,
  ];
  if (provider.spendClass != null) parts.add(provider.spendClass!);
  final captured = _captureAgeLabel(provider.asOf, generatedAt);
  if (captured.isNotEmpty) parts.add(captured);
  return parts.join(', ');
}

String _trustReadState(QuotaHealthProviderLine provider) {
  if (provider.state == 'provider drift') return 'provider drift';
  if (provider.state == 'unavailable') return 'error';
  if (provider.kind.isLocal) {
    return provider.state == 'local active' ? 'loaded' : 'ready';
  }
  return switch (provider.state) {
    'cached' => 'cached',
    'unknown' => 'metadata',
    _ => 'live',
  };
}

String _captureAgeLabel(int asOf, int generatedAt) {
  return capturedAgeLabel(asOf, generatedAt);
}

String _iso(int epochSeconds) => DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    ).toIso8601String();

String _percent(double? value) =>
    value == null ? 'n/a' : '${value.toStringAsFixed(1)}%';

String _ratio(double? value) =>
    value == null ? 'n/a' : '${(value * 100).toStringAsFixed(1)}%';

String _streak(QuotaHealthProviderLine provider) {
  final sampled = provider.sampledDays;
  if (sampled == null || sampled == 0) return 'n/a';
  final spent = provider.spentDayStreak ?? 0;
  if (spent > 0) return '${spent}d spent';
  final usable = provider.usableDayStreak ?? 0;
  if (usable > 0) return '${usable}d usable';
  return '${sampled}d sampled';
}

String _bestWindows(List<WeekHourWindow> windows) =>
    windows.map((window) => window.summary).join('; ');

String _cell(String value) =>
    value.replaceAll('|', '\\|').replaceAll('\n', ' ');
