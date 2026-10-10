part of '../../parsing.dart';

// --- Grok -------------------------------------------------------------------

/// Extracts the unary gRPC-web DATA frame payload from a valid response.
///
/// gRPC-web commonly carries `grpc-status` in a body trailer rather than an
/// HTTP header. A nonzero or malformed trailer invalidates the data frame so an
/// authentication failure cannot be mistaken for successful quota evidence.
List<int> grpcMessage(Uint8List resp) {
  List<int>? message;
  var offset = 0;
  while (offset < resp.length) {
    if (resp.length - offset < 5) return const [];
    final flag = resp[offset];
    final len = (resp[offset + 1] << 24) |
        (resp[offset + 2] << 16) |
        (resp[offset + 3] << 8) |
        resp[offset + 4];
    offset += 5;
    if (len < 0 || len > resp.length - offset) return const [];
    final payload = resp.sublist(offset, offset + len);
    offset += len;

    if ((flag & 0x80) != 0) {
      if (flag != 0x80 || message == null || offset != resp.length) {
        return const [];
      }
      final status = _grpcWebTrailerStatusFromPayload(payload);
      if (status != 0) return const [];
      continue;
    }

    // Grok's billing RPC is unary and uncompressed. Multiple data frames or a
    // compression flag are response-shape drift, not quota evidence.
    if (flag != 0 || message != null) return const [];
    message = payload;
  }
  return message ?? const [];
}

/// gRPC-web unary trailer status, when the body is framed well enough to read
/// one. A missing, truncated, or malformed trailer is not a status.
int? grpcWebTrailerStatus(Uint8List resp) {
  var offset = 0;
  var sawData = false;
  while (offset < resp.length) {
    if (resp.length - offset < 5) return null;
    final flag = resp[offset];
    final len = (resp[offset + 1] << 24) |
        (resp[offset + 2] << 16) |
        (resp[offset + 3] << 8) |
        (resp[offset + 4]);
    offset += 5;
    if (len < 0 || len > resp.length - offset) return null;
    final payload = resp.sublist(offset, offset + len);
    offset += len;
    if ((flag & 0x80) != 0) {
      if (flag != 0x80 || !sawData || offset != resp.length) return null;
      return _grpcWebTrailerStatusFromPayload(payload);
    }
    if (flag != 0) return null;
    sawData = true;
  }
  return null;
}

int? _grpcWebTrailerStatusFromPayload(List<int> payload) {
  final trailer = ascii.decode(payload, allowInvalid: true);
  final status = RegExp(
    r'(?:^|\r?\n)grpc-status:\s*([0-9]+)\s*(?:\r?\n|$)',
    caseSensitive: false,
  ).firstMatch(trailer);
  if (status == null) return null;
  return int.tryParse(status.group(1)!);
}

/// Parses the Grok billing protobuf into a single shared weekly usage window.
///
/// GetGrokCreditsConfig wraps one config message in field 1. Inside it, field
/// 1 is the shared pool's used percent (fixed32 float), fields 4 and 5 are the
/// window start and end timestamps, and repeated field 7 carries per-product
/// breakdown percents that sum to the total. Reading the percent by field
/// number keeps a breakdown value from ever posing as the pool total, and the
/// reset comes from the window end, never the start. The schema-less scan
/// remains as a fallback for shape drift. Note that xAI can revise the pool
/// percent downward mid-window (observed live: 100 to 73 under an unchanged
/// reset), so Grok usage is not monotonic between resets.
QuotaWindow? grokWindow(List<int> message, int now) {
  if (message.isEmpty) return null;
  final anchored = _grokConfigWindow(message, now);
  if (anchored.recognized) return anchored.window;
  return _grokScanWindow(message, now);
}

/// Per-product percents inside Grok's shared weekly pool (Imagine / Chat /
/// Build). These are a split of [grokWindow], never extra caps. Empty when the
/// anchored config is missing or a breakdown row is unusable.
List<double> grokCategoryPercents(List<int> message) {
  if (message.isEmpty) return const [];
  List<int>? config;
  _forEachProtoField(message, (field, wireType, varint, bytes) {
    if (field == 1 && wireType == 2) config ??= bytes;
  });
  final body = config;
  if (body == null) return const [];
  final percents = <double>[];
  final ok = _forEachProtoField(body, (field, wireType, varint, bytes) {
    if (field != 7 || wireType != 2) return;
    double? used;
    var invalid = false;
    _forEachProtoField(bytes, (subField, subWire, subVarint, subBytes) {
      if (subField == 2 && subWire == 5) {
        final f = _float32(subBytes);
        if (!f.isFinite || f < 0 || f > 100) {
          invalid = true;
        } else {
          used ??= _percent2(f);
        }
      }
    });
    final categoryUsed = used;
    if (!invalid && categoryUsed != null) percents.add(categoryUsed);
  });
  if (!ok) return const [];
  return percents;
}

/// Display-only Grok usage-tab split. Never becomes a routing window.
List<String> grokCategoryDetails(List<int> message) {
  final percents = grokCategoryPercents(message);
  if (percents.length < 2) return const [];
  final parts = [for (final p in percents) '${_detailPercent(p)}%'];
  return ['Category split of this weekly pool: ${parts.join(', ')}'];
}

/// Schema-anchored read of the Grok credits config message.
({bool recognized, QuotaWindow? window}) _grokConfigWindow(
  List<int> message,
  int now,
) {
  List<int>? config;
  // The top-level walk's verdict is deliberately ignored: trailing garbage
  // after a well-delimited config must not force the less precise scan
  // fallback. The config body itself is still parsed strictly below.
  _forEachProtoField(message, (field, wireType, varint, bytes) {
    if (field == 1 && wireType == 2) config ??= bytes;
  });
  final body = config;
  if (body == null) return (recognized: false, window: null);
  double? used;
  int? windowEnd;
  var invalidPoolPercent = false;
  final ok = _forEachProtoField(body, (field, wireType, varint, bytes) {
    if (field == 1 && wireType == 5) {
      final f = _float32(bytes);
      // This field is the pool total by schema. An impossible total invalidates
      // the anchored response and must not hand parsing to the schema-less scan,
      // which could mistake a valid-looking product breakdown for the total.
      if (!f.isFinite || f < 0 || f > 100) {
        invalidPoolPercent = true;
      } else {
        used ??= _percent2(f);
      }
    } else if (field == 5 && wireType == 2) {
      _forEachProtoField(bytes, (subField, subWire, subVarint, _) {
        if (subField == 1 &&
            subWire == 0 &&
            subVarint != null &&
            _plausibleEpochSeconds(subVarint)) {
          windowEnd ??= subVarint;
        }
      });
    }
  });
  if (invalidPoolPercent) return (recognized: true, window: null);
  if (!ok) return (recognized: false, window: null);
  if (used == null) return (recognized: false, window: null);
  return (
    recognized: true,
    window: QuotaWindow(
      label: 'weekly',
      usedPercent: used,
      resetsAt:
          windowEnd ?? (ProtoScan()..walk(message)).nearestFutureTimestamp(now),
    ),
  );
}

/// Schema-less fallback: first plausible percent, nearest future timestamp.
QuotaWindow? _grokScanWindow(List<int> message, int now) {
  final scan = ProtoScan()..walk(message);
  final percent = scan.firstPercent;
  if (percent == null) return null;
  return QuotaWindow(
    label: 'weekly',
    usedPercent: percent,
    resetsAt: scan.nearestFutureTimestamp(now),
  );
}
