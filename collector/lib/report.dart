import 'analysis.dart';
import 'insights.dart';
import 'model_catalog.dart';
import 'models.dart';

const quotaHealthReportSchema = 'quotabot.report.v1';

class QuotaHealthProviderLine {
  final String provider;
  final String displayName;
  final String account;
  final ProviderQuotaKind kind;
  final String? source;
  final ProviderSourceClass sourceClass;
  final String state;
  final int asOf;
  final bool perMachine;
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
    required this.asOf,
    required this.perMachine,
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
  final String recommendationReason;
  final String fallbackKind;
  final List<QuotaHealthProviderLine> providers;

  const QuotaHealthReport({
    required this.generatedAt,
    required this.recommendedProvider,
    required this.recommendationReason,
    required this.fallbackKind,
    required this.providers,
  });

  Map<String, dynamic> toJson() => {
        'schema': quotaHealthReportSchema,
        'generated_at': generatedAt,
        'recommended_provider': recommendedProvider,
        'recommendation_reason': recommendationReason,
        'fallback_kind': fallbackKind,
        'providers': providers.map((provider) => provider.toJson()).toList(),
      };

  String toMarkdown() {
    final lines = <String>[
      '# quotabot weekly quota health',
      '',
      'Generated: ${_iso(generatedAt)}',
      'Recommendation: ${recommendedProvider ?? 'none'} - $recommendationReason',
      'Fallback: $fallbackKind',
      '',
      '## Providers',
      '',
      '| Provider | Account | State | Trust | Headroom | Reset | 7d p50 free | 7d reliability | Streak | Pace |',
      '| --- | --- | --- | --- | ---: | --- | ---: | ---: | --- | --- |',
      for (final provider in providers)
        '| ${_cell(provider.displayName)} | ${_cell(provider.account)} | '
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
          '- ${_cell(provider.displayName)} (${_cell(provider.account)}): '
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
          '- ${_cell(provider.displayName)} (${_cell(provider.account)}): '
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
          '- ${_cell(provider.displayName)} (${_cell(provider.account)}): '
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
  final fallbackKind = switch (suggestion.fallback.kind) {
    RouteFallbackKind.local => 'local runtime',
    RouteFallbackKind.soonestReset => 'wait for reset',
    RouteFallbackKind.passthrough => 'passthrough',
  };
  return QuotaHealthReport(
    generatedAt: now,
    recommendedProvider: recommended?.provider,
    recommendationReason: suggestion.reason,
    fallbackKind: fallbackKind,
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
    asOf: provider.asOf,
    perMachine: provider.perMachine,
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

String _state(ProviderQuota provider, double? headroom) {
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
  final spendClass = _trustSpendClass(provider);
  if (spendClass != null) parts.add(spendClass);
  final captured = _captureAgeLabel(provider.asOf, generatedAt);
  if (captured.isNotEmpty) parts.add(captured);
  return parts.join(', ');
}

String _trustReadState(QuotaHealthProviderLine provider) {
  if (provider.state == 'unavailable') return 'error';
  if (provider.kind.isLocal) {
    return provider.state == 'local active' ? 'in use' : 'available';
  }
  return switch (provider.state) {
    'cached' => 'cached',
    'unknown' => 'metadata',
    _ => 'live',
  };
}

String? _trustSpendClass(QuotaHealthProviderLine provider) {
  if (provider.kind.isLocal) {
    return provider.state == 'local active' ? 'loaded' : 'cold';
  }
  if (provider.sourceClass == ProviderSourceClass.manual ||
      provider.sourceClass == ProviderSourceClass.statusOnly) {
    return null;
  }
  if (provider.headroomPercent == null) {
    return provider.state == 'unavailable' &&
            kQuotaPlanProviders.contains(provider.provider)
        ? 'quota plan'
        : null;
  }
  return kQuotaPlanProviders.contains(provider.provider)
      ? 'quota plan'
      : 'metered plan';
}

String _captureAgeLabel(int asOf, int generatedAt) {
  if (asOf <= 0) return '';
  if (asOf > generatedAt) return 'captured in the future';
  return 'captured ${_ageLabel(generatedAt - asOf)} ago';
}

String _ageLabel(int seconds) {
  if (seconds < 90) return '${seconds}s';
  if (seconds < 5400) return '${(seconds / 60).round()}m';
  if (seconds < 129600) return '${(seconds / 3600).round()}h';
  return '${(seconds / Duration.secondsPerDay).round()}d';
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
