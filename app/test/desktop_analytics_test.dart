import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/desktop_analytics.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/models.dart';

DesktopAnalyticsRequest _request(int revision) => DesktopAnalyticsRequest(
  revision: revision,
  targets: [
    DesktopAnalyticsTarget(
      quota: ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'synthetic-account',
        asOf: 1788610000,
        windows: [QuotaWindow(label: 'weekly', usedPercent: 30)],
      ),
      displayKey: 'codex|synthetic-account',
      fallbackToProvider: true,
    ),
  ],
  now: 1788610000,
  timeZoneOffset: Duration.zero,
);

Future<DesktopAnalyticsData> _syntheticReader(
  DesktopAnalyticsRequest request,
  Future<void> Function() checkpoint,
) async {
  await checkpoint();
  final key = request.targets.single.displayKey;
  return DesktopAnalyticsData(
    history: {
      key: [request.targets.single.quota],
    },
    insights: {key: const Insights(samples: 2, spanDays: 1, mean: 70)},
    heatmaps: {
      key: [
        [70, null],
      ],
    },
    buckets: {
      key: [HeadroomBucket(start: request.now)..add(70)],
    },
    burnStats: {key: const BurnStat(perHour: 2, samples: 3)},
    notices: [
      AnalyticsStorageNotice(
        provider: 'codex',
        account: 'synthetic-account',
        tiers: const ['history'],
        observedAt: request.now,
      ),
    ],
  );
}

Future<DesktopAnalyticsData> _failingReader(
  DesktopAnalyticsRequest request,
  Future<void> Function() checkpoint,
) async => throw StateError('synthetic private diagnostic');

Future<DesktopAnalyticsData> _cancellableReader(
  DesktopAnalyticsRequest request,
  Future<void> Function() checkpoint,
) async {
  while (true) {
    await checkpoint();
  }
}

class _Job implements DesktopAnalyticsJob {
  final Completer<DesktopAnalyticsData?> done = Completer();
  int cancellations = 0;

  @override
  Future<DesktopAnalyticsData?> get completed => done.future;

  @override
  void cancel() => cancellations++;
}

void main() {
  test('a real isolate transfers synthetic analytics and exits', () async {
    final job = IsolateDesktopAnalyticsJob(
      _request(1),
      reader: _syntheticReader,
    );
    final result = await job.completed.timeout(const Duration(seconds: 10));
    expect(result, isNotNull);
    expect(result!.history.values.single.single.account, 'synthetic-account');
    expect(result.insights.values.single.mean, 70);
    expect(result.buckets.values.single.single.count, 1);
    expect(result.heatmaps.values.single, [
      [70, null],
    ]);
    expect(result.burnStats.values.single.perHour, 2);
    expect(result.notices.single.tiers, ['history']);
  });

  test(
    'a failed isolate returns unavailable without a fallback reader',
    () async {
      final job = IsolateDesktopAnalyticsJob(
        _request(1),
        reader: _failingReader,
      );
      expect(await job.completed.timeout(const Duration(seconds: 10)), isNull);
    },
  );

  test(
    'cancellation before worker startup reaches its checkpoint and exits',
    () async {
      final job = IsolateDesktopAnalyticsJob(
        _request(1),
        reader: _cancellableReader,
      );
      job.cancel();
      expect(await job.completed.timeout(const Duration(seconds: 10)), isNull);
    },
  );

  testWidgets('only the newest queued snapshot runs after confirmed exit', (
    tester,
  ) async {
    final started = <int>[];
    final jobs = <_Job>[];
    final admitted = <int>[];
    final scheduler = DesktopAnalyticsScheduler(
      start: (request) {
        started.add(request.revision);
        final job = _Job();
        jobs.add(job);
        return job;
      },
      onUpdate: (request, state, data) {
        if (state == DesktopAnalyticsState.ready) {
          admitted.add(request.revision);
        }
      },
    );
    addTearDown(scheduler.dispose);
    scheduler.submit(_request(1));
    for (var revision = 2; revision <= 20; revision++) {
      scheduler.submit(_request(revision));
    }
    expect(started, [1]);
    jobs.single.done.complete(const DesktopAnalyticsData());
    await tester.pump();
    expect(started, [1, 20]);
    expect(admitted, isEmpty);
    jobs.last.done.complete(const DesktopAnalyticsData());
    await tester.pump();
    expect(admitted, [20]);
  });

  testWidgets(
    'timeout retains the worker until exit then recovers newest pending',
    (tester) async {
      final started = <int>[];
      final jobs = <_Job>[];
      final updates = <(int, DesktopAnalyticsState)>[];
      final scheduler = DesktopAnalyticsScheduler(
        deadline: const Duration(seconds: 5),
        start: (request) {
          started.add(request.revision);
          final job = _Job();
          jobs.add(job);
          return job;
        },
        onUpdate: (request, state, _) => updates.add((request.revision, state)),
      );
      addTearDown(scheduler.dispose);
      scheduler.submit(_request(1));
      await tester.pump(const Duration(seconds: 6));
      expect(jobs.single.cancellations, 1);
      expect(updates.last, (1, DesktopAnalyticsState.unavailable));
      scheduler.submit(_request(2));
      scheduler.submit(_request(3));
      await tester.pump(const Duration(minutes: 1));
      expect(started, [1]);
      expect(updates.last, (3, DesktopAnalyticsState.unavailable));
      jobs.single.done.complete(const DesktopAnalyticsData());
      await tester.pump();
      expect(started, [1, 3]);
      expect(updates.last, (3, DesktopAnalyticsState.pending));
      jobs.last.done.complete(const DesktopAnalyticsData());
      await tester.pump();
      expect(updates.last, (3, DesktopAnalyticsState.ready));
      expect(updates, isNot(contains((1, DesktopAnalyticsState.ready))));
    },
  );

  testWidgets('failed or partial analytics remains explicitly unavailable', (
    tester,
  ) async {
    final jobs = <_Job>[];
    final states = <DesktopAnalyticsState>[];
    final scheduler = DesktopAnalyticsScheduler(
      start: (_) {
        final job = _Job();
        jobs.add(job);
        return job;
      },
      onUpdate: (_, state, _) => states.add(state),
    );
    addTearDown(scheduler.dispose);
    scheduler.submit(_request(1));
    jobs.single.done.completeError(StateError('synthetic diagnostic'));
    await tester.pump();
    expect(states.last, DesktopAnalyticsState.unavailable);
    scheduler.submit(_request(2));
    jobs.last.done.complete(const DesktopAnalyticsData(complete: false));
    await tester.pump();
    expect(states.last, DesktopAnalyticsState.unavailable);
  });

  testWidgets('invalidation and disposal drop queued and late work', (
    tester,
  ) async {
    final jobs = <_Job>[];
    final admitted = <int>[];
    final scheduler = DesktopAnalyticsScheduler(
      start: (_) {
        final job = _Job();
        jobs.add(job);
        return job;
      },
      onUpdate: (request, state, _) {
        if (state == DesktopAnalyticsState.ready) {
          admitted.add(request.revision);
        }
      },
    );
    scheduler.submit(_request(1));
    scheduler.submit(_request(2));
    scheduler.invalidate();
    expect(jobs.single.cancellations, 1);
    jobs.single.done.complete(const DesktopAnalyticsData());
    await tester.pump();
    expect(jobs, hasLength(1));
    expect(admitted, isEmpty);
    scheduler.submit(_request(3));
    scheduler.submit(_request(4));
    scheduler.dispose();
    expect(jobs.last.cancellations, 1);
    jobs.last.done.complete(const DesktopAnalyticsData());
    await tester.pump();
    expect(jobs, hasLength(2));
    expect(admitted, isEmpty);
  });

  testWidgets(
    'startup failure is unavailable and a later request can recover',
    (tester) async {
      var starts = 0;
      final job = _Job();
      final states = <DesktopAnalyticsState>[];
      final scheduler = DesktopAnalyticsScheduler(
        start: (_) {
          if (++starts == 1) throw StateError('synthetic spawn failure');
          return job;
        },
        onUpdate: (_, state, _) => states.add(state),
      );
      addTearDown(scheduler.dispose);
      scheduler.submit(_request(1));
      expect(states.last, DesktopAnalyticsState.unavailable);
      scheduler.submit(_request(2));
      job.done.complete(const DesktopAnalyticsData());
      await tester.pump();
      expect(states.last, DesktopAnalyticsState.ready);
    },
  );
}
