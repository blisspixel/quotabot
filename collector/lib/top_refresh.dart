/// Lifecycle-safe refresh coordination for the interactive `quotabot top`
/// surface.
library;

import 'dart:async';

import 'models.dart';

/// Keeps the previous snapshot visible after a whole-refresh failure while
/// ensuring no previously current row remains routable or looks live.
///
/// Rows that were already stale or failed keep their more specific failure
/// state. All other rows retain their capture time and quota values as
/// last-known evidence.
List<ProviderQuota> retainSnapshotAfterRefreshFailure(
  Iterable<ProviderQuota> previous, {
  required String note,
}) =>
    [
      for (final quota in previous)
        if (!quota.ok || quota.stale) quota else quota.asStale(note),
    ];

typedef TopRefreshTimerFactory = Timer Function(
  Duration delay,
  void Function() callback,
);

/// Owns one collection at a time and one future refresh timer.
///
/// Repeated requests during a collection coalesce into one queued follow-up.
/// Disposing invalidates the active generation, cancels the timer, and prevents
/// a late result from updating or rescheduling a terminal that has been closed.
class TopRefreshCoordinator<T> {
  final Future<T> Function() collect;
  final void Function(T value) apply;
  final void Function()? onFailure;
  final Duration Function() nextDelay;
  final TopRefreshTimerFactory timerFactory;

  Timer? _timer;
  Future<void>? _inFlight;
  bool _queued = false;
  bool _disposed = false;
  int _generation = 0;

  TopRefreshCoordinator({
    required this.collect,
    required this.apply,
    required this.nextDelay,
    this.onFailure,
    TopRefreshTimerFactory? timerFactory,
  }) : timerFactory = timerFactory ?? Timer.new;

  bool get isDisposed => _disposed;
  bool get isRefreshing => _inFlight != null;
  bool get hasScheduledRefresh => _timer?.isActive ?? false;

  /// Starts a refresh, or queues exactly one follow-up when one is active.
  Future<void> refreshNow() {
    if (_disposed) return Future<void>.value();
    _timer?.cancel();
    _timer = null;
    final active = _inFlight;
    if (active != null) {
      _queued = true;
      return active;
    }
    final generation = ++_generation;
    final future = _drain(generation);
    _inFlight = future;
    return future;
  }

  Future<void> _drain(int generation) async {
    do {
      _queued = false;
      try {
        final value = await collect();
        if (!_disposed && generation == _generation) apply(value);
      } catch (_) {
        if (!_disposed && generation == _generation) onFailure?.call();
      }
    } while (_queued && !_disposed && generation == _generation);

    _inFlight = null;
    if (_disposed || generation != _generation) return;
    _timer = timerFactory(nextDelay(), () {
      _timer = null;
      unawaited(refreshNow());
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _queued = false;
    _timer?.cancel();
    _timer = null;
  }
}
