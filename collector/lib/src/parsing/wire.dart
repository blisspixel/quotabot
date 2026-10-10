part of '../../parsing.dart';

/// Private helpers shared by the provider parts: percent bounds, reset
/// normalization, and the protobuf walker.

bool _tighterWindow(QuotaWindow candidate, QuotaWindow current) {
  final candidateUsed = candidate.usedPercent;
  final currentUsed = current.usedPercent;
  if (candidateUsed == null) return false;
  if (currentUsed == null || candidateUsed > currentUsed) return true;
  if (candidateUsed < currentUsed) return false;
  return (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1);
}

/// Resolves an equal-use tie without depending on provider row order. A later
/// reset is the conservative choice because the same amount of spent quota
/// remains binding for longer. A known reset also wins over an unknown one.
bool _saferEqualUseWindow(QuotaWindow candidate, QuotaWindow current) =>
    (candidate.resetsAt ?? -1) > (current.resetsAt ?? -1);

double? _boundedPercent(dynamic value) {
  final parsed = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.replaceAll(',', '').trim()),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 100) {
    return null;
  }
  return parsed;
}

/// Magnitude boundaries for present-day unix timestamps in milliseconds,
/// microseconds, and nanoseconds. Provider and IDE state has used all four
/// units over time, so normalize them before trust admission rather than
/// interpreting a microsecond value as a reset tens of thousands of years out.
const int _resetMillisThreshold = 100000000000;
const int _resetMicrosThreshold = 100000000000000;
const int _resetNanosThreshold = 100000000000000000;

int _normalizeEpochSeconds(int value) {
  final magnitude = value.abs();
  if (magnitude >= _resetNanosThreshold) return value ~/ 1000000000;
  if (magnitude >= _resetMicrosThreshold) return value ~/ 1000000;
  if (magnitude >= _resetMillisThreshold) return value ~/ 1000;
  return value;
}

int? parseReset(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    if (!v.toDouble().isFinite) return null;
    if (v.truncateToDouble() != v.toDouble()) return null;
    return _normalizeEpochSeconds(v.toInt());
  }
  final s = v.toString();
  final asInt = int.tryParse(s);
  if (asInt != null) {
    return _normalizeEpochSeconds(asInt);
  }
  final dt = DateTime.tryParse(s);
  return dt == null ? null : dt.millisecondsSinceEpoch ~/ 1000;
}

String resetLabel(int reset, int now) {
  final dt = reset - now;
  if (dt <= 6 * 3600) return '5h';
  if (dt <= 36 * 3600) return 'daily';
  return 'weekly';
}

int? parseIsoToEpoch(dynamic v) {
  if (v is! String) return null;
  final dt = DateTime.tryParse(v);
  return dt == null ? null : dt.millisecondsSinceEpoch ~/ 1000;
}

String _detailPercent(double p) {
  if ((p - p.roundToDouble()).abs() < 0.05) return p.round().toString();
  return p.toStringAsFixed(1);
}

/// Plausibility bounds for a unix-seconds varint (2020..2100), so field ids,
/// enums, and sub-second counts are never mistaken for timestamps without
/// imposing a 2033 parser expiry on valid long-lived code.
bool _plausibleEpochSeconds(int v) => v > 1600000000 && v < 4102444800;

double _percent2(double f) => double.parse(f.toStringAsFixed(2));

double _float32(List<int> bytes) =>
    ByteData.sublistView(Uint8List.fromList(bytes))
        .getFloat32(0, Endian.little);

/// Calls [visit] for each top-level field of protobuf [b]. Varint fields pass
/// their value; fixed-width and length-delimited fields pass their raw bytes.
/// Returns false as soon as the buffer stops parsing as valid protobuf.
bool _forEachProtoField(
  List<int> b,
  void Function(int field, int wireType, int? varint, List<int> bytes) visit,
) {
  var i = 0;
  while (i < b.length) {
    final (tag, ni) = readVarint(b, i);
    if (tag == null) return false;
    i = ni;
    final field = tag >> 3;
    final wireType = tag & 7;
    switch (wireType) {
      case 0:
        final (v, n2) = readVarint(b, i);
        if (v == null) return false;
        i = n2;
        visit(field, wireType, v, const []);
      case 5:
        if (i + 4 > b.length) return false;
        visit(field, wireType, null, b.sublist(i, i + 4));
        i += 4;
      case 1:
        if (i + 8 > b.length) return false;
        visit(field, wireType, null, b.sublist(i, i + 8));
        i += 8;
      case 2:
        // Subtraction-form bounds check: a hostile 9-byte length varint
        // decodes near 2^62, where `n2 + len` wraps negative and would pass
        // an addition-form check straight into a throwing sublist.
        final (len, n2) = readVarint(b, i);
        if (len == null || len < 0 || len > b.length - n2) return false;
        visit(field, wireType, null, b.sublist(n2, n2 + len));
        i = n2 + len;
      default:
        return false;
    }
  }
  return true;
}

/// Walks a protobuf collecting 32-bit floats and timestamp-like varints without
/// the schema. Used for the Grok billing response.
class ProtoScan {
  final List<double> floats = [];
  final List<int> timestamps = [];

  double? get firstPercent {
    for (final f in floats) {
      if (f >= 0 && f <= 100) return _percent2(f);
    }
    return null;
  }

  int? nearestFutureTimestamp(int now) {
    final future = timestamps.where((t) => t > now).toList()..sort();
    if (future.isNotEmpty) return future.first;
    if (timestamps.isEmpty) return null;
    return timestamps.reduce((a, b) => a > b ? a : b);
  }

  void walk(List<int> b, [int depth = 0]) {
    if (depth > 8) return;
    _forEachProtoField(b, (field, wireType, varint, bytes) {
      switch (wireType) {
        case 0:
          if (_plausibleEpochSeconds(varint!)) timestamps.add(varint);
        case 5:
          floats.add(_float32(bytes));
        case 2:
          walk(bytes, depth + 1);
      }
    });
  }
}
