import 'dart:convert';

import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  test('nowEpoch and home return sensible values', () {
    expect(nowEpoch(), greaterThan(1700000000));
    expect(home(), isNotEmpty);
  });

  test('detectInstalledAgenticTools returns set (never throws)', () {
    final d = detectInstalledAgenticTools();
    expect(d, isA<Set<String>>());
  });

  group('findKey', () {
    test('finds a nested value', () {
      final tree = {
        'a': [
          {'b': 1},
          {'rate_limits': 42},
        ],
      };
      expect(findKey(tree, 'rate_limits'), 42);
    });

    test('returns null when absent', () {
      expect(findKey({'a': 1}, 'missing'), isNull);
    });
  });

  group('readVarint', () {
    test('decodes a multi-byte varint', () {
      // 300 = 0xAC 0x02
      expect(readVarint([0xAC, 0x02], 0), (300, 2));
    });

    test('returns null on truncation', () {
      expect(readVarint([0x80], 0), (null, 1));
    });
  });

  group('protoStrings and asciiString', () {
    test('extracts a length-delimited string', () {
      final bytes = [0x0a, 5, ...utf8.encode('hello')];
      expect(protoStrings(bytes).contains('hello'), isTrue);
    });

    test('asciiString rejects binary and short input', () {
      expect(asciiString([0x01]), isNull);
      expect(asciiString([0x00, 0x01, 0x02, 0x03]), isNull);
      expect(asciiString(utf8.encode('ok')), 'ok');
    });
  });
}
