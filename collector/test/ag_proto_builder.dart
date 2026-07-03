// Minimal protobuf encoder for building synthetic Antigravity `userStatus`
// blobs in tests, so a fixture never carries a real account's data. It mirrors
// exactly the schema `antigravityModelQuotas` reads: a model entry is field 1
// (name) plus a field-15 quota submessage `{field 1: remainingFraction
// (fixed32), field 2: {field 1: reset (varint)}}`, with an optional speed
// category in field 16 and a badge in field 17.
import 'dart:convert';
import 'dart:typed_data';

List<int> pbVarint(int value) {
  final out = <int>[];
  var n = value;
  while (true) {
    final b = n & 0x7f;
    n >>= 7;
    if (n == 0) {
      out.add(b);
      break;
    }
    out.add(b | 0x80);
  }
  return out;
}

// A field tag is itself a varint `(field << 3) | wireType`, so fields >= 16
// span more than one byte and must be varint-encoded, not written raw.
List<int> pbTag(int field, int wireType) => pbVarint((field << 3) | wireType);

List<int> pbLenField(int field, List<int> payload) =>
    [...pbTag(field, 2), ...pbVarint(payload.length), ...payload];

List<int> pbStringField(int field, String value) =>
    pbLenField(field, utf8.encode(value));

List<int> pbFixed32Field(int field, double value) {
  final bd = ByteData(4)..setFloat32(0, value, Endian.little);
  return [...pbTag(field, 5), ...bd.buffer.asUint8List()];
}

List<int> pbVarintField(int field, int value) =>
    [...pbTag(field, 0), ...pbVarint(value)];

/// One model entry as `antigravityModelQuotas` expects it.
List<int> agModelEntry(
  String name, {
  required double remaining,
  int? reset,
  String? category,
  String? badge,
}) {
  final quota = <int>[
    ...pbFixed32Field(1, remaining),
    if (reset != null) ...pbLenField(2, pbVarintField(1, reset)),
  ];
  return [
    ...pbStringField(1, name),
    ...pbLenField(15, quota),
    if (category != null) ...pbStringField(16, category),
    if (badge != null) ...pbStringField(17, badge),
  ];
}

/// The model list as the blob stores it: each entry repeated in field 1.
List<int> agModelList(List<List<int>> entries) =>
    [for (final e in entries) ...pbLenField(1, e)];

/// The stored `userStatus` value: base64 of a wrapper whose field 2 holds the
/// base64-encoded model list, exercising the nested-base64 descent the real
/// blob uses.
String agUserStatusValue(List<List<int>> entries) =>
    base64Encode(pbStringField(2, base64Encode(agModelList(entries))));
