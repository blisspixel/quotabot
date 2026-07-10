/// A short-lived cache that shares one in-progress load across concurrent
/// callers. Failed loads are never cached and always clear the in-flight slot.
class ExpiringSingleFlight<T extends Object> {
  final Future<T> Function() _load;
  final int Function() _now;
  final int ttlSeconds;

  T? _value;
  int? _cachedAt;
  Future<T>? _inFlight;

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

  Future<T> read() {
    final currentValue = _value;
    final captured = _cachedAt;
    if (currentValue != null && captured != null) {
      final age = _now() - captured;
      if (age >= 0 && age < ttlSeconds) return Future.value(currentValue);
    }
    final active = _inFlight;
    if (active != null) return active;
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
