import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_analytics.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/litellm_metrics.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/storage_keys.dart';
import 'package:quotabot_collector/util.dart';

final _now = DateTime.utc(2026, 9, 1, 12).millisecondsSinceEpoch ~/ 1000;
const _hour = Duration.secondsPerHour;

ProviderQuota _cloud(String provider, String account, double usedPercent) =>
    ProviderQuota(
      provider: provider,
      displayName: provider,
      account: account,
      asOf: _now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: usedPercent,
          resetsAt: _now + Duration.secondsPerDay,
        ),
      ],
    );

DesktopAnalyticsTarget _target(
  ProviderQuota quota,
  String displayKey, {
  bool fallbackToProvider = false,
}) => DesktopAnalyticsTarget(
  quota: quota,
  displayKey: displayKey,
  fallbackToProvider: fallbackToProvider,
);

void _writeHistory(
  Directory cache,
  String provider,
  List<ProviderQuota> history, {
  String? account,
}) {
  final suffix = account == null ? '' : '_${accountStorageStem(account)}';
  File('${cache.path}/history_$provider$suffix.jsonl').writeAsStringSync(
    '${history.map((quota) => jsonEncode(quota.toJson())).join('\n')}\n',
  );
}

void _writeBuckets(
  Directory cache,
  String provider,
  List<double> headroom, {
  String? account,
}) {
  final suffix = account == null ? '' : '_${accountStorageStem(account)}';
  final buckets = [
    for (var index = 0; index < headroom.length; index++)
      HeadroomBucket(start: _now - (headroom.length - index - 1) * _hour)
        ..add(headroom[index])
        ..add(headroom[index]),
  ];
  File('${cache.path}/buckets_$provider$suffix.json').writeAsStringSync(
    jsonEncode([for (final bucket in buckets) bucket.toJson()]),
  );
}

void main() {
  late Directory temporary;
  late File metrics;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'quotabot_analytics_reader_',
    );
    setQuotabotDirOverrideForTesting(temporary);
    // Routed metrics intentionally use a different root from the cache. Every
    // reader call below supplies this file instead of consulting host HOME.
    metrics = File('${temporary.path}/routed-metrics.jsonl');
    metrics.writeAsStringSync(
      [
        for (final spend in [
          litellmSpendQuotaPlan,
          litellmSpendLocal,
          litellmSpendPaidApi,
        ])
          jsonEncode({
            'at': _now,
            'provider': spend == litellmSpendLocal ? 'ollama' : 'codex',
            'account': 'synthetic-work',
            'requested_model': 'synthetic-requested',
            'served_model': 'synthetic-$spend',
            'spend': spend,
            'prompt_tokens': 10,
            'completion_tokens': 2,
            'cost': spend == litellmSpendPaidApi ? 0.12 : 0,
          }),
      ].join('\n'),
    );
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    final root = Directory.systemTemp.absolute.path;
    expect(
      temporary.absolute.path,
      startsWith('$root${Platform.pathSeparator}'),
    );
    temporary.deleteSync(recursive: true);
  });

  Future<DesktopAnalyticsData> read(List<DesktopAnalyticsTarget> targets) =>
      readDesktopAnalytics(
        DesktopAnalyticsRequest(
          revision: 1,
          targets: targets,
          now: _now,
          timeZoneOffset: const Duration(hours: 2),
        ),
        () async {},
        readRoutedRequests: () => loadRoutedRequestSummary(file: metrics),
      );

  test(
    'real storage keeps account displays, fallback policy, and local history distinct',
    () async {
      final cache = cacheDir();
      final work = _cloud('codex', 'synthetic-work', 20);
      final home = _cloud('codex', 'synthetic-home', 60);
      final single = _cloud('claude', 'synthetic-single', 30);
      final local = ProviderQuota(
        provider: 'ollama',
        displayName: 'Ollama',
        account: 'default',
        asOf: _now,
        kind: ProviderQuotaKind.local,
      );
      _writeHistory(cache, 'codex', [work], account: work.account);
      _writeHistory(cache, 'codex', [work, home]);
      _writeHistory(cache, 'claude', [single], account: single.account);
      _writeHistory(cache, 'ollama', [local]);
      _writeBuckets(cache, 'codex', [80, 70], account: work.account);
      _writeBuckets(cache, 'codex', [40, 10]);
      _writeBuckets(cache, 'claude', [90, 80]);
      // A local bucket file must not turn local history into cloud analytics.
      _writeBuckets(cache, 'ollama', [50, 40]);

      final data = await read([
        _target(work, 'work display'),
        _target(home, 'home display'),
        _target(single, 'single display', fallbackToProvider: true),
        _target(local, 'local display'),
      ]);

      expect(data.complete, isTrue);
      expect(data.inventory.complete, isTrue);
      expect(data.notices, isEmpty);
      expect(
        data.history.keys,
        unorderedEquals([
          'work display',
          'home display',
          'single display',
          'local display',
        ]),
      );
      expect(data.history['work display']!.single.account, work.account);
      expect(data.history['home display']!.single.account, home.account);
      expect(
        data.history['home display']!.single.windows.single.usedPercent,
        60,
      );
      expect(
        data.history['local display'],
        isEmpty,
        reason: 'Runtime metadata is not subscription-quota history',
      );
      expect(
        data.buckets.keys,
        unorderedEquals(['work display', 'home display', 'single display']),
      );
      expect(
        data.buckets['home display'],
        isEmpty,
        reason: 'A second account must not inherit provider-only buckets',
      );
      expect(data.insights['work display']!.mean, 75);
      expect(data.insights['home display']!.samples, 0);
      expect(data.insights['single display']!.mean, 85);
      expect(data.insights, isNot(contains('local display')));
      expect(data.heatmaps, isNot(contains('local display')));
      expect(
        data.heatmaps['home display']!.expand((day) => day).whereType<double>(),
        isEmpty,
      );
      expect(
        data.insights['work display']!.bestTimeWindows.first.hour,
        13,
        reason: 'The request timezone must be applied to hourly analytics',
      );
      expect(
        data.burnStats[quotaIdentityKeyFor(work)]!.perHour,
        closeTo(10, 0.001),
      );
      expect(data.burnStats[quotaIdentityKeyFor(home)]!.perHour, isNull);
      expect(
        data.burnStats[quotaIdentityKeyFor(single)]!.perHour,
        closeTo(10, 0.001),
      );
      expect(data.burnStats, isNot(contains(quotaIdentityKeyFor(local))));
      expect(data.routedRequests.totalRequests, 3);
      expect(data.routedRequests.routedRequests, 3);
      expect(data.routedRequests.localRequests, 1);
      expect(data.routedRequests.quotaPlanRequests, 1);
      expect(data.routedRequests.paidApiRequests, 1);
      expect(data.routedRequests.paidApiCost, 0.12);
    },
  );

  test(
    'malformed incident storage stays partial while healthy history survives',
    () async {
      final cache = cacheDir();
      final work = _cloud('codex', 'synthetic-work', 20);
      _writeHistory(cache, 'codex', [work], account: work.account);
      _writeBuckets(cache, 'codex', [80, 70], account: work.account);
      final marker = File('${cache.path}/analytics_migration_invalid.json')
        ..writeAsStringSync('{malformed synthetic metadata');

      final data = await read([_target(work, 'work display')]);

      expect(data.inventory.complete, isFalse);
      expect(data.inventory.state, 'partial');
      expect(data.inventory.invalidMarkers, 1);
      expect(data.inventory.globalUncertainty, isTrue);
      expect(data.history['work display']!.single.account, work.account);
      expect(data.insights['work display']!.mean, 75);
      expect(data.routedRequests.totalRequests, 3);
      expect(jsonEncode(data.inventory.toJson()), isNot(contains(marker.path)));
      expect(marker.readAsStringSync(), '{malformed synthetic metadata');
    },
  );

  test(
    'unavailable cache returns incomplete analytics and keeps routed metrics',
    () async {
      final base = Directory('${temporary.path}/quotabot')..createSync();
      final unavailable = File('${base.path}/cache')
        ..writeAsStringSync('synthetic unavailable storage');
      final work = _cloud('codex', 'synthetic-work', 20);

      final data = await read([_target(work, 'work display')]);

      expect(data.complete, isFalse);
      expect(data.inventory.complete, isFalse);
      expect(data.history['work display'], isEmpty);
      expect(data.buckets['work display'], isEmpty);
      expect(data.insights['work display']!.samples, 0);
      expect(data.burnStats, isEmpty);
      expect(data.routedRequests.totalRequests, 3);
      expect(unavailable.readAsStringSync(), 'synthetic unavailable storage');
    },
  );
}
