import 'package:quotabot_collector/vscode_state.dart';
import 'package:test/test.dart';

void main() {
  group('decodeStateJsonObject', () {
    test('decodes a normal state value', () {
      final out = decodeStateJsonObject('{"a": {"b": 1}}');
      expect(out, isNotNull);
      expect(
          firstNestedString(out!, ['b']), isNull); // b is a number, not string
    });

    test('finds a nested string value', () {
      final out = decodeStateJsonObject('{"x": {"resetDate": "2026-07-01"}}');
      expect(firstNestedString(out!, ['resetDate']), '2026-07-01');
    });

    test('rejects an over-cap value blob rather than exhausting memory', () {
      // A same-user app can write any blob into the Cursor/Windsurf/Kiro SQLite
      // state; a value past the cap must be refused, not decoded.
      final huge = '"${'a' * (8 * 1024 * 1024 + 16)}"';
      expect(decodeStateJsonObject(huge), isNull);
      // A value comfortably under the cap still decodes.
      final ok = '{"k": "${'a' * 1024}"}';
      expect(decodeStateJsonObject(ok), isNotNull);
    });

    test('returns null on malformed or empty input, never throws', () {
      expect(decodeStateJsonObject('{not json'), isNull);
      expect(decodeStateJsonObject(''), isNull);
      expect(decodeStateJsonObject(null), isNull);
      expect(decodeStateJsonObject('[1,2,3]'), isNull); // not an object
    });
  });
}
