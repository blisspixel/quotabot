import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/report.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _quota(
  String provider,
  double usedPercent, {
  ProviderQuotaKind kind = ProviderQuotaKind.subscription,
  String? source,
  int resetInSeconds = 8 * Duration.secondsPerDay,
}) =>
    ProviderQuota(
      provider: provider,
      displayName: provider,
      account: 'work',
      asOf: _now,
      kind: kind,
      source: source,
      windows: kind.isLocal
          ? const []
          : [
              QuotaWindow(
                label: 'weekly',
                usedPercent: usedPercent,
                resetsAt: _now + resetInSeconds,
              ),
            ],
    );

Insights _insights() => Insights.from([
      HeadroomBucket(start: _now - 3 * 86400)..add(80),
      HeadroomBucket(start: _now - 2 * 86400)..add(70),
      HeadroomBucket(start: _now - 86400)..add(60),
    ], _now);

void main() {
  test('a drifted provider reads as drift in the report, not live', () {
    // Regression: report _state omitted the driftReason check that top and the
    // desktop app apply first, so a held-during-drift snapshot was mislabeled as
    // an ordinary live/cached number on the report health surface only.
    final drifted = ProviderQuota(
      provider: 'codex',
      displayName: 'codex',
      account: 'work',
      asOf: _now,
      stale: true,
      driftReason: 'provider drift detected; showing last trusted snapshot',
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 20,
          resetsAt: _now + 8 * Duration.secondsPerDay,
        ),
      ],
    );
    final report = buildQuotaHealthReport(
      [drifted],
      _now,
      suggestRoute([drifted], _now),
    );

    final line = report.providers.single;
    expect(line.state, 'provider drift');
    expect(line.toJson()['state'], 'provider drift');
    // The trust context (State + Trust columns in the markdown) names the drift
    // rather than reading 'live' or a bare 'cached'.
    expect(report.toMarkdown(), contains('provider drift'));

    // A clean provider is unaffected.
    final clean = buildQuotaHealthReport([_quota('claude', 20)], _now,
        suggestRoute([_quota('claude', 20)], _now));
    expect(clean.providers.single.state, isNot('provider drift'));
  });

  test('report spend class is the shared classifier, consistent under drift',
      () {
    // A plan-quota provider names its plan; a measured non-plan provider reads
    // metered - both from the shared providerSpendClass, not a report-local copy.
    final claude = buildQuotaHealthReport([_quota('claude', 20)], _now,
        suggestRoute([_quota('claude', 20)], _now));
    expect(claude.providers.single.spendClass, 'quota plan');
    expect(claude.toMarkdown(), contains('quota plan'));

    final cursor = _quota('cursor', 30);
    final metered =
        buildQuotaHealthReport([cursor], _now, suggestRoute([cursor], _now));
    expect(metered.providers.single.spendClass, 'metered plan');

    // Consistency: a drifted, unavailable plan provider still names the plan.
    // The report previously returned null here because it keyed the plan case off
    // the 'unavailable' state, which the 'provider drift' state now precedes.
    final driftedDown = ProviderQuota(
      provider: 'codex',
      displayName: 'codex',
      account: 'work',
      asOf: _now,
      ok: false,
      driftReason: 'provider drift detected; showing last trusted snapshot',
      windows: const [],
    );
    final drift = buildQuotaHealthReport(
        [driftedDown], _now, suggestRoute([driftedDown], _now));
    expect(drift.providers.single.spendClass, 'quota plan');
  });

  test('buildQuotaHealthReport produces versioned JSON', () {
    final providers = [
      _quota('claude', 20),
      _quota('ollama', 0, kind: ProviderQuotaKind.local)
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
      insightsByProvider: {'claude': _insights()},
    );

    final json = report.toJson();
    expect(json['schema'], quotaHealthReportSchema);
    expect(json['recommended_provider'], 'claude');
    expect(json['providers'], hasLength(2));
    final claude = (json['providers'] as List).first as Map<String, dynamic>;
    expect(claude['source_class'], 'authoritative_live');
    // spend_class is machine-readable parity with the markdown Trust column.
    expect(claude['spend_class'], 'quota plan');
    expect(claude.containsKey('trust'), isFalse);
    expect(claude.containsKey('as_of'), isFalse);
    expect(claude['weekly_sampled_days'], 3);
    expect(claude['weekly_usable_day_streak'], 3);
    final calendar = claude['weekly_contribution_calendar'] as List;
    expect(calendar, hasLength(3));
    expect(calendar.last['state'], 'usable');
    final best = claude['weekly_best_time_windows'] as List;
    expect(best, isNotEmpty);
    final firstBest = best.first as Map<String, dynamic>;
    expect(firstBest['label'], isA<String>());
    expect(firstBest['smoothed_free_percent'], isA<double>());
    expect(firstBest['support_samples'], greaterThanOrEqualTo(2));
    final schedule = claude['weekly_schedule_hint'] as Map<String, dynamic>;
    expect(schedule['summary'], contains('before reset'));
    expect(schedule['window'], isA<Map<String, dynamic>>());
  });

  test('report keeps raw credential identity in JSON and abbreviates markdown',
      () {
    final identity = opaqueCredentialIdentity('claude', 'report-grant');
    final provider = ProviderQuota(
      provider: 'claude',
      displayName: 'Claude',
      account: identity,
      asOf: _now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: 20,
          resetsAt: _now + 3600,
        ),
      ],
    );
    final report = buildQuotaHealthReport(
      [provider],
      _now,
      suggestRoute([provider], _now),
    );

    final jsonProvider =
        (report.toJson()['providers'] as List).single as Map<String, dynamic>;
    expect(jsonProvider['account'], identity);
    expect(report.toMarkdown(), contains(quotaAccountDisplayLabel(identity)));
    expect(report.toMarkdown(), isNot(contains(identity)));
  });

  test('markdown report includes recommendation, metrics, and local note', () {
    final providers = [
      _quota('claude', 20),
      _quota('manual-ai', 50, source: providerQuotaManualSource),
      _quota('ollama', 0, kind: ProviderQuotaKind.local),
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
      insightsByProvider: {'claude': _insights()},
    );

    final markdown = report.toMarkdown();
    expect(markdown, startsWith('# quotabot weekly quota health'));
    expect(markdown, contains('Recommendation: claude'));
    expect(
      markdown,
      contains(
        '| claude | work | available | live, authoritative, quota plan, captured 0s ago | 80.0% |',
      ),
    );
    expect(markdown, contains('live, manual, captured 0s ago'));
    expect(
        markdown, contains('available, local runtime, cold, captured 0s ago'));
    expect(markdown, contains('| 3d usable |'));
    expect(markdown, contains('Manual entries are self-reported'));
    expect(markdown, contains('Local runtimes are fallback capacity'));
    expect(markdown, contains('## Weekly calendar'));
    expect(markdown, contains('claude (work):'));
    expect(markdown, contains('## Best sampled windows'));
    expect(markdown, contains('raw '));
    expect(markdown, contains('support='));
    expect(markdown, contains('## Reset-aware schedule hints'));
    expect(markdown, contains('before reset'));
  });

  test('markdown escapes table cell separators', () {
    final providers = [
      ProviderQuota(
        provider: 'custom',
        displayName: 'custom|ai',
        account: 'team|alpha',
        asOf: _now,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 10)],
      ),
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
    );

    expect(report.toMarkdown(), contains('custom\\|ai'));
    expect(report.toMarkdown(), contains('team\\|alpha'));
  });

  test('markdown labels failed quota-plan providers by spend class', () {
    final providers = [
      ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'unknown',
        asOf: _now,
        ok: false,
        error: 'signed out',
      ),
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
    );

    expect(
      report.toMarkdown(),
      contains(
          '| Codex | unknown | unavailable | error, authoritative, quota plan, captured 0s ago |'),
    );
  });

  test('markdown keeps successful no-window quota-plan rows metadata-only', () {
    final providers = [
      ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'unknown',
        asOf: _now,
        status: 'signed in, quota unavailable',
      ),
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
    );

    expect(
      report.toMarkdown(),
      contains(
        '| Codex | unknown | unknown | metadata, authoritative, captured 0s ago |',
      ),
    );
  });

  test('markdown trust context flags per-machine cloud snapshots', () {
    final providers = [
      ProviderQuota(
        provider: 'cursor',
        displayName: 'Cursor',
        account: 'work@example.com',
        asOf: _now,
        perMachine: true,
        windows: [QuotaWindow(label: 'monthly', usedPercent: 20)],
      ),
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
    );

    expect(
      report.toMarkdown(),
      contains(
          '| Cursor | work@example.com | available | live, passive local, metered plan, captured 0s ago |'),
    );
  });

  test('markdown trust context labels failed local runtimes as errors', () {
    final providers = [
      ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'installed',
        asOf: _now,
        kind: ProviderQuotaKind.local,
        ok: false,
        error: 'not running',
      ),
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
    );

    expect(
      report.toMarkdown(),
      contains(
          '| Ollama | installed | unavailable | error, local runtime, cold, captured 0s ago |'),
    );
  });
}
