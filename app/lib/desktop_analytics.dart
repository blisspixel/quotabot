import 'dart:async';
import 'dart:isolate';

import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/insights.dart';
import 'package:quotabot_collector/litellm_metrics.dart';
import 'package:quotabot_collector/models.dart';

class DesktopAnalyticsTarget {
  final ProviderQuota quota;
  final String displayKey;
  final bool fallbackToProvider;

  const DesktopAnalyticsTarget({
    required this.quota,
    required this.displayKey,
    required this.fallbackToProvider,
  });
}

class DesktopAnalyticsRequest {
  final int revision;
  final List<DesktopAnalyticsTarget> targets;
  final int now;
  final Duration timeZoneOffset;

  DesktopAnalyticsRequest({
    required this.revision,
    required List<DesktopAnalyticsTarget> targets,
    required this.now,
    required this.timeZoneOffset,
  }) : targets = List.unmodifiable(targets);
}

class DesktopAnalyticsData {
  final Map<String, List<ProviderQuota>> history;
  final Map<String, Insights> insights;
  final Map<String, List<List<double?>>> heatmaps;
  final Map<String, List<HeadroomBucket>> buckets;
  final Map<String, BurnStat> burnStats;
  final List<AnalyticsStorageNotice> notices;
  final AnalyticsIncidentInventory inventory;
  final RoutedRequestSummary routedRequests;
  final bool complete;

  const DesktopAnalyticsData({
    this.history = const {},
    this.insights = const {},
    this.heatmaps = const {},
    this.buckets = const {},
    this.burnStats = const {},
    this.notices = const [],
    this.inventory = const AnalyticsIncidentInventory.suppressed(),
    this.routedRequests = emptyRoutedRequestSummary,
    this.complete = true,
  });
}

enum DesktopAnalyticsState { pending, ready, unavailable }

typedef DesktopAnalyticsReader =
    Future<DesktopAnalyticsData> Function(
      DesktopAnalyticsRequest request,
      Future<void> Function() checkpoint,
    );

/// Runs only in the analytics isolate. Each reader finishes its own file guards
/// before the next cancellation checkpoint; cancellation never interrupts a
/// guarded migration or leaves a claim owned by the still-running desktop.
/// Tests can supply a routed-metrics reader to isolate its separate home path.
Future<DesktopAnalyticsData> readDesktopAnalytics(
  DesktopAnalyticsRequest request,
  Future<void> Function() checkpoint, {
  RoutedRequestSummary Function() readRoutedRequests = loadRoutedRequestSummary,
}) async {
  var complete = true;
  T read<T>(T Function() operation, T fallback) {
    try {
      return operation();
    } catch (_) {
      complete = false;
      return fallback;
    }
  }

  final quotas = [for (final target in request.targets) target.quota];
  await checkpoint();
  final notices = read(
    () => analyticsStorageNoticesForQuotas(quotas),
    const <AnalyticsStorageNotice>[],
  );
  await checkpoint();
  var inventory = const AnalyticsIncidentInventory.suppressed();
  try {
    inventory = await analyticsStorageIncidentInventory(quotas);
  } catch (_) {
    complete = false;
  }
  await checkpoint();
  final burnStats = read(
    () => recentBurnStatsByQuota(quotas, request.now),
    const <String, BurnStat>{},
  );
  await checkpoint();
  final routedRequests = read(readRoutedRequests, emptyRoutedRequestSummary);
  final history = <String, List<ProviderQuota>>{};
  final buckets = <String, List<HeadroomBucket>>{};
  final heatmaps = <String, List<List<double?>>>{};
  final rawInsights = <String, Insights>{};
  for (final target in request.targets) {
    await checkpoint();
    final quota = target.quota;
    history[target.displayKey] = read(
      () => loadHistory(quota.provider, account: quota.account),
      const <ProviderQuota>[],
    );
    if (quota.isLocal) continue;
    await checkpoint();
    final providerBuckets = read(
      () => loadBuckets(
        quota.provider,
        account: quota.account,
        fallbackToProvider: target.fallbackToProvider,
      ),
      const <HeadroomBucket>[],
    );
    buckets[target.displayKey] = providerBuckets;
    await checkpoint();
    rawInsights[target.displayKey] = Insights.from(
      providerBuckets,
      request.now,
      tzOffset: request.timeZoneOffset,
    );
    heatmaps[target.displayKey] = smoothedWeekHourHeatmap(
      providerBuckets,
      tzOffset: request.timeZoneOffset,
    );
  }
  await checkpoint();
  return DesktopAnalyticsData(
    history: history,
    buckets: buckets,
    heatmaps: heatmaps,
    insights: shrinkInsightsReliability(rawInsights),
    burnStats: burnStats,
    notices: notices,
    inventory: inventory,
    routedRequests: routedRequests,
    complete: complete,
  );
}

abstract interface class DesktopAnalyticsJob {
  /// Completes only after the worker exits, including after cancellation.
  Future<DesktopAnalyticsData?> get completed;

  /// Requests cancellation. It does not claim the underlying work has stopped.
  void cancel();
}

class _WorkerInput {
  final DesktopAnalyticsRequest request;
  final SendPort replies;
  final DesktopAnalyticsReader reader;

  const _WorkerInput(this.request, this.replies, this.reader);
}

class _AnalyticsCancelled implements Exception {
  const _AnalyticsCancelled();
}

class _WorkerResult {
  final DesktopAnalyticsData? data;

  const _WorkerResult(this.data);
}

Future<void> _analyticsWorker(_WorkerInput input) async {
  final control = ReceivePort();
  var cancelled = false;
  final controls = control.listen((_) => cancelled = true);
  input.replies.send(control.sendPort);
  Future<void> checkpoint() async {
    // Let cancellation messages run between synchronous reader operations.
    await Future<void>.delayed(Duration.zero);
    if (cancelled) throw const _AnalyticsCancelled();
  }

  DesktopAnalyticsData? result;
  try {
    result = await input.reader(input.request, checkpoint);
    await checkpoint();
  } catch (_) {
    result = null;
  } finally {
    await controls.cancel();
    control.close();
  }
  Isolate.exit(input.replies, _WorkerResult(result));
}

/// Owns a real background isolate, with no UI-isolate fallback. A blocked native
/// read can delay cancellation; callers retain this job until [completed].
class IsolateDesktopAnalyticsJob implements DesktopAnalyticsJob {
  final ReceivePort _replies = ReceivePort();
  final Completer<DesktopAnalyticsData?> _completion = Completer();
  SendPort? _control;
  DesktopAnalyticsData? _result;
  bool _cancelled = false;

  IsolateDesktopAnalyticsJob(
    DesktopAnalyticsRequest request, {
    DesktopAnalyticsReader reader = readDesktopAnalytics,
  }) {
    _replies.listen((message) {
      if (message is SendPort) {
        _control = message;
        if (_cancelled) message.send(null);
      } else if (message is _WorkerResult) {
        _result = message.data;
      } else if (message == null) {
        _finish();
      }
      // An unhandled isolate error is followed by its exit notification. The
      // error's private text is neither printed nor passed into the UI.
    });
    unawaited(_spawn(request, reader));
  }

  Future<void> _spawn(
    DesktopAnalyticsRequest request,
    DesktopAnalyticsReader reader,
  ) async {
    try {
      await Isolate.spawn<_WorkerInput>(
        _analyticsWorker,
        _WorkerInput(request, _replies.sendPort, reader),
        onExit: _replies.sendPort,
        onError: _replies.sendPort,
        errorsAreFatal: true,
        debugName: 'desktop-analytics',
      );
    } catch (_) {
      _finish();
    }
  }

  void _finish() {
    if (_completion.isCompleted) return;
    _replies.close();
    _control = null;
    _completion.complete(_cancelled ? null : _result);
  }

  @override
  Future<DesktopAnalyticsData?> get completed => _completion.future;

  @override
  void cancel() {
    _cancelled = true;
    _control?.send(null);
  }
}

typedef DesktopAnalyticsJobStarter =
    DesktopAnalyticsJob Function(DesktopAnalyticsRequest request);

typedef DesktopAnalyticsUpdate =
    void Function(
      DesktopAnalyticsRequest request,
      DesktopAnalyticsState state,
      DesktopAnalyticsData? data,
    );

/// One running job plus one replaceable pending request. Timing out only stops
/// admission of its result; it never frees a worker slot before confirmed exit.
class DesktopAnalyticsScheduler {
  final DesktopAnalyticsJobStarter start;
  final DesktopAnalyticsUpdate onUpdate;
  final Duration deadline;
  DesktopAnalyticsRequest? _latest;
  DesktopAnalyticsRequest? _pending;
  DesktopAnalyticsJob? _job;
  Timer? _timer;
  bool _timedOut = false;
  bool _disposed = false;

  DesktopAnalyticsScheduler({
    required this.start,
    required this.onUpdate,
    this.deadline = const Duration(seconds: 30),
  });

  void submit(DesktopAnalyticsRequest request) {
    if (_disposed) return;
    _latest = request;
    _pending = request;
    onUpdate(
      request,
      _timedOut
          ? DesktopAnalyticsState.unavailable
          : DesktopAnalyticsState.pending,
      null,
    );
    _startPending();
  }

  void _startPending() {
    final request = _pending;
    if (_disposed || _job != null || request == null) return;
    _pending = null;
    _timedOut = false;
    DesktopAnalyticsJob job;
    try {
      job = start(request);
    } catch (_) {
      onUpdate(request, DesktopAnalyticsState.unavailable, null);
      return;
    }
    _job = job;
    onUpdate(request, DesktopAnalyticsState.pending, null);
    _timer = Timer(deadline, () {
      _timedOut = true;
      job.cancel();
      final latest = _latest;
      if (!_disposed && latest != null) {
        onUpdate(latest, DesktopAnalyticsState.unavailable, null);
      }
    });
    unawaited(
      job.completed.then(
        (data) => _finished(request, data),
        onError: (Object _, StackTrace _) => _finished(request, null),
      ),
    );
  }

  void _finished(DesktopAnalyticsRequest request, DesktopAnalyticsData? data) {
    _timer?.cancel();
    _job = null;
    if (!_disposed && identical(request, _latest) && !_timedOut) {
      onUpdate(
        request,
        data?.complete == true
            ? DesktopAnalyticsState.ready
            : DesktopAnalyticsState.unavailable,
        data,
      );
    }
    _timedOut = false;
    _startPending();
  }

  void invalidate() {
    _latest = null;
    _pending = null;
    _job?.cancel();
  }

  void dispose() {
    _disposed = true;
    _latest = null;
    _pending = null;
    _timer?.cancel();
    _job?.cancel();
  }
}
