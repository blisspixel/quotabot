/// A short-lived cache that shares one in-progress load across concurrent
/// callers. Failed loads are never cached and always clear the in-flight slot.
class ExpiringSingleFlight<T extends Object> {
  final Future<T> Function() _load;
  final int Function() _now;
  final int ttlSeconds;

  T? _value;
  int? _cachedAt;
  Future<T>? _inFlight;
  bool _admitting = true;

  ExpiringSingleFlight({
    required Future<T> Function() load,
    required int Function() now,
    this.ttlSeconds = 5,
  })  : _load = load,
        _now = now {
    if (ttlSeconds <= 0) {
      throw ArgumentError.value(ttlSeconds, 'ttlSeconds', 'must be positive');
    }
  }

  T? get value => _value;
  int? get cachedAt => _cachedAt;
  bool get isAdmitting => _admitting;

  /// Stops starting new loads. In-flight readers still join the active load,
  /// and a cached value is returned even after its TTL so shutdown cannot
  /// launch another collect.
  void stopAdmitting() {
    _admitting = false;
  }

  /// Waits for the current load, if any. Errors stay with the original reader.
  Future<void> settle() async {
    final active = _inFlight;
    if (active == null) return;
    await active.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  }

  Future<T> read() {
    final currentValue = _value;
    final captured = _cachedAt;
    if (currentValue != null && captured != null) {
      final age = _now() - captured;
      if (age >= 0 && age < ttlSeconds) return Future.value(currentValue);
    }
    final active = _inFlight;
    if (active != null) return active;
    if (!_admitting) {
      if (currentValue != null) return Future.value(currentValue);
      throw StateError('snapshot admissions have stopped');
    }
    late final Future<T> tracked;
    tracked = Future<T>.sync(_load).then((next) {
      _value = next;
      _cachedAt = _now();
      return next;
    }).whenComplete(() {
      if (identical(_inFlight, tracked)) _inFlight = null;
    });
    _inFlight = tracked;
    return tracked;
  }
}
