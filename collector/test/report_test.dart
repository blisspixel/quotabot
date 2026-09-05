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
      models: kind.isLocal ? const [ModelInfo(id: 'installed:7b')] : const [],
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
  for (final value in ['denied', 'future-admission']) {
    test('$value report preserves measured headroom and an explicit rejection',
        () {
      final quota = ProviderQuota.fromJson({
        'provider': 'codex',
        'display_name': 'Codex',
        'account': 'fixture',
        'as_of': _now,
        'request_admission': value,
        'windows': [
          {'label': 'weekly', 'used_percent': 50, 'resets_at': _now + 3600}
        ],
      });
      final report =
          buildQuotaHealthReport([quota], _now, suggestRoute([quota], _now));
      final expected =
          value == 'denied' ? 'requests denied' : 'request status unverified';
      expect(report.providers.single.state, expected);
      expect(report.providers.single.headroomPercent, 50);
      expect(report.providers.single.toJson()['request_admission'],
          value == 'denied' ? 'denied' : 'unresolved');
      expect(report.toMarkdown(), contains(expected));
      expect(report.toMarkdown(), contains('50.0%'));
      expect(report.toJson()['recommended_provider'], isNull);
      final stale = quota.asStale('synthetic unavailable read');
      final cached =
          buildQuotaHealthReport([stale], _now, suggestRoute([stale], _now));
      expect(cached.providers.single.state, 'cached');
      expect(cached.providers.single.headroomPercent, 50);
    });
  }

  test('upstream and embedding inventory reports reachable without readiness',
      () {
    for (final model in const [
      ModelInfo(
          id: 'private',
          loaded: true,
          upstreamRouting: UpstreamRouting.declared),
      ModelInfo(
          id: 'partial',
          loaded: true,
          upstreamRouting: UpstreamRouting.unresolved),
      ModelInfo(id: 'cloud', loaded: true, cloudOffloaded: true),
      ModelInfo(id: 'embedding', loaded: true, embedding: true),
    ]) {
      for (final active in [true, false]) {
        final provider = ProviderQuota(
            provider: 'ollama',
            displayName: 'Ollama',
            account: 'fixture',
            asOf: _now,
            kind: ProviderQuotaKind.local,
            models: [model],
            active: active);
        final report = buildQuotaHealthReport(
            [provider], _now, suggestRoute([provider], _now));
        expect(report.providers.single.state, 'local reachable');
        expect(report.providers.single.toJson()['state'], 'local reachable');
        final markdown = report.toMarkdown();
        expect(markdown, contains('reachable, local runtime'));
        expect(markdown, isNot(contains('local active')));
        expect(markdown, isNot(contains('local ready')));
        expect(markdown, isNot(contains('loaded, local runtime')));
        if (model.hasLocalExecutionVeto) {
          expect(markdown, contains('location/cost unverified'));
        }
      }
    }
  });

  test('local report state preserves failure, stale and clock precedence', () {
    final cases = [
      (
        state: 'unavailable',
        trust: 'error',
        fields: <String, Object?>{
          'ok': false,
          'stale': true,
        }
      ),
      (
        state: 'unavailable',
        trust: 'error',
        fields: <String, Object?>{
          'error': 'metadata read failed',
        }
      ),
      (
        state: 'cached',
        trust: 'cached',
        fields: <String, Object?>{
          'stale': true,
        }
      ),
      (
        state: 'unverified',
        trust: 'unverified',
        fields: <String, Object?>{
          'as_of': _now + 3600,
        }
      ),
      (
        state: 'provider drift',
        trust: 'provider drift',
        fields: <String, Object?>{
          'drift_reason': 'metadata shape changed',
          'ok': false,
          'stale': true,
        }
      ),
    ];
    for (final fixture in cases) {
      final provider = ProviderQuota.fromJson({
        ...ProviderQuota(
            provider: 'ollama',
            displayName: 'Ollama',
            account: 'fixture',
            asOf: _now,
            kind: ProviderQuotaKind.local,
            active: true,
            models: const [
              ModelInfo(
                  id: 'private',
                  loaded: true,
                  upstreamRouting: UpstreamRouting.declared),
            ]).toJson(),
        ...fixture.fields,
      });
      final report = buildQuotaHealthReport(
          [provider], _now, suggestRoute([provider], _now));
      expect(report.providers.single.state, fixture.state);
      expect(report.toMarkdown(), contains('${fixture.trust}, local runtime'));
      expect(report.toMarkdown(), isNot(contains('local ready')));
      expect(report.toMarkdown(), isNot(contains('local active')));
    }
  });

  test('represented local generation keeps loaded and cold report states', () {
    for (final loaded in [true, false]) {
      final provider = ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: 'fixture',
          asOf: _now,
          kind: ProviderQuotaKind.local,
          active: !loaded,
          models: [
            ModelInfo(id: 'ordinary', loaded: loaded),
          ]);
      final report = buildQuotaHealthReport(
          [provider], _now, suggestRoute([provider], _now));
      expect(report.providers.single.state,
          loaded ? 'local active' : 'local ready');
      expect(report.toMarkdown(),
          contains(loaded ? 'loaded, local runtime' : 'ready, local runtime'));
    }
  });

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
    final json = line.toJson();
    expect(json['state'], 'provider drift');
    expect(json['ok'], isTrue);
    expect(json['as_of'], _now);
    expect(json['staleness_seconds'], 0);
    expect(json['stale'], isTrue);
    expect(json['per_machine'], isFalse);
    expect(json['drift_reason'], drifted.driftReason);
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
    expect(json['recommended_account'], 'work');
    expect(json['decision_code'], isA<String>());
    expect(json['decision_id'], startsWith('qb-'));
    final receipt = json['receipt'] as Map<String, dynamic>;
    expect(receipt['schema'], 'quotabot.receipt.v1');
    expect(receipt['decision_id'], json['decision_id']);
    expect((receipt['winner'] as Map)['account'], 'work');
    expect(json['providers'], hasLength(2));
    final claude = (json['providers'] as List).first as Map<String, dynamic>;
    expect(claude['source_class'], 'authoritative_live');
    // spend_class is machine-readable parity with the markdown Trust column.
    expect(claude['spend_class'], 'quota plan');
    expect(claude.containsKey('trust'), isFalse);
    expect(claude['ok'], isTrue);
    expect(claude['as_of'], _now);
    expect(claude['staleness_seconds'], 0);
    expect(claude['stale'], isFalse);
    expect(claude['per_machine'], isFalse);
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

  test('report keeps raw identity in JSON and anonymizes markdown by default',
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
    expect(report.toMarkdown(), contains('| Claude | account |'));
    expect(
      report.toMarkdown(),
      isNot(contains(quotaAccountDisplayLabel(identity))),
    );
    expect(report.toMarkdown(), isNot(contains(identity)));
    expect(
      report.toMarkdown(includeAccounts: true),
      contains(quotaAccountDisplayLabel(identity)),
    );
  });

  test('report correlates a multi-account recommendation without disclosure',
      () {
    ProviderQuota quota(String account, double used) => ProviderQuota(
          provider: 'claude',
          displayName: 'Claude',
          account: account,
          asOf: _now,
          windows: [QuotaWindow(label: 'weekly', usedPercent: used)],
        );
    final providers = [
      quota('work@example.com', 10),
      quota('home@example.com', 70),
    ];
    final report = buildQuotaHealthReport(
      providers,
      _now,
      suggestRoute(providers, _now),
    );

    final json = report.toJson();
    expect(json['recommended_provider'], 'claude');
    expect(json['recommended_account'], 'work@example.com');
    expect((json['receipt'] as Map)['decision_id'], json['decision_id']);
    final markdown = report.toMarkdown();
    expect(markdown, contains('Recommendation: claude (account 1)'));
    expect(markdown, contains('| Claude | account 1 |'));
    expect(markdown, contains('| Claude | account 2 |'));
    expect(markdown, isNot(contains('work@example.com')));
    expect(markdown, isNot(contains('home@example.com')));
    final included = report.toMarkdown(includeAccounts: true);
    expect(included, contains('Recommendation: claude (work@example.com)'));
    expect(included, contains('home@example.com'));
  });

  test('report JSON preserves failed provider diagnostics', () {
    final failed = ProviderQuota(
      provider: 'codex',
      displayName: 'Codex',
      account: 'work@example.com',
      asOf: _now - 120,
      ok: false,
      error: 'read timed out',
      pipeHealth: providerPipeHealthThrottled,
    );
    final report = buildQuotaHealthReport(
      [failed],
      _now,
      suggestRoute([failed], _now),
    );
    final row = (report.toJson()['providers'] as List).single as Map;

    expect(row['ok'], isFalse);
    expect(row['as_of'], _now - 120);
    expect(row['staleness_seconds'], 120);
    expect(row['stale'], isFalse);
    expect(row['error'], 'read timed out');
    expect(row['pipe_health'], providerPipeHealthThrottled);
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
        '| claude | account | available | live, authoritative, quota plan, captured just now | 80.0% |',
      ),
    );
    expect(markdown, contains('live, manual, captured just now'));
    expect(
      markdown,
      contains('ready, local runtime, cold, captured just now'),
    );
    expect(markdown, contains('| 3d usable |'));
    expect(markdown, contains('Manual entries are self-reported'));
    expect(markdown,
        contains('Local-runtime fallback excludes reported upstream'));
    expect(markdown, contains('## Weekly calendar'));
    expect(markdown, contains('claude (account):'));
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
    expect(
      report.toMarkdown(includeAccounts: true),
      contains('team\\|alpha'),
    );
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
          '| Codex | unknown | unavailable | error, authoritative, quota plan, captured just now |'),
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
        '| Codex | unknown | unknown | metadata, authoritative, captured just now |',
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
          '| Cursor | account | available | live, passive local, metered plan, captured just now |'),
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
          '| Ollama | installed | unavailable | error, local runtime, captured just now |'),
    );
  });
}
