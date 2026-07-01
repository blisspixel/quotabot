import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/report.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _quota(
  String provider,
  double usedPercent, {
  String kind = 'subscription',
  String? source,
}) =>
    ProviderQuota(
      provider: provider,
      displayName: provider,
      account: 'work',
      asOf: _now,
      kind: kind,
      source: source,
      windows: kind == 'local'
          ? const []
          : [
              QuotaWindow(
                label: 'weekly',
                usedPercent: usedPercent,
                resetsAt: _now + 3600,
              ),
            ],
    );

Insights _insights() => Insights.from([
      HeadroomBucket(start: _now - 3 * 86400)..add(80),
      HeadroomBucket(start: _now - 2 * 86400)..add(70),
      HeadroomBucket(start: _now - 86400)..add(60),
    ], _now);

void main() {
  test('buildQuotaHealthReport produces versioned JSON', () {
    final providers = [
      _quota('claude', 20),
      _quota('ollama', 0, kind: 'local')
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
    expect(claude['weekly_sampled_days'], 3);
    expect(claude['weekly_usable_day_streak'], 3);
    final calendar = claude['weekly_contribution_calendar'] as List;
    expect(calendar, hasLength(3));
    expect(calendar.last['state'], 'usable');
    final best = claude['weekly_best_time_windows'] as List;
    expect(best, isNotEmpty);
    expect((best.first as Map<String, dynamic>)['label'], isA<String>());
  });

  test('markdown report includes recommendation, metrics, and local note', () {
    final providers = [
      _quota('claude', 20),
      _quota('manual-ai', 50, source: 'manual'),
      _quota('ollama', 0, kind: 'local'),
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
    expect(markdown, contains('| claude | work | available | 80.0% |'));
    expect(markdown, contains('| 3d usable |'));
    expect(markdown, contains('Manual entries are self-reported'));
    expect(markdown, contains('Local runtimes are fallback capacity'));
    expect(markdown, contains('## Weekly calendar'));
    expect(markdown, contains('claude (work):'));
    expect(markdown, contains('## Best sampled windows'));
    expect(markdown, contains('free, n='));
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
}
