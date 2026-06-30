import 'dart:convert';

import 'package:quotabot_collector/parsing.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  group('windsurfWindows fallbacks', () {
    final now = nowEpoch();

    test('reads a usageBreakdowns list', () {
      final w = windsurfWindows({
        'usageBreakdowns': [
          {'displayName': 'Prompts', 'currentUsage': 50, 'usageLimit': 100},
          {'percentageUsed': 25.0},
          'not a map', // skipped
        ],
      }, now);
      expect(w.length, 2);
      expect(w.first.label, 'prompts');
      expect(w.first.usedPercent, 50);
      expect(w[1].usedPercent, 25);
    });

    test('does not invent quota from an undecodable raw blob', () {
      final w = windsurfWindows({'raw': 'blob'}, now);
      expect(w, isEmpty);
    });

    test('returns nothing for a non-map', () {
      expect(windsurfWindows('nope', now), isEmpty);
    });
  });

  group('findEmbeddedToken', () {
    const pattern = r'ya29\.[A-Za-z0-9]{10,}';

    test('finds a token directly inside the decoded bytes', () {
      final stored =
          base64.encode(utf8.encode('hdr ya29.ABCDEFGHIJKLMNOP end'));
      expect(findEmbeddedToken(stored, pattern), 'ya29.ABCDEFGHIJKLMNOP');
    });

    test('digs through a nested base64 layer', () {
      final inner = base64.encode(utf8.encode('pad ya29.ZYXWVUTSRQPONMLK pad'));
      final outer = base64.encode(utf8.encode('noise $inner more'));
      expect(findEmbeddedToken(outer, pattern), 'ya29.ZYXWVUTSRQPONMLK');
    });

    test('returns null when no token is present', () {
      final stored = base64.encode(utf8.encode('nothing to see here'));
      expect(findEmbeddedToken(stored, pattern), isNull);
    });

    test('returns null on undecodable input rather than throwing', () {
      expect(findEmbeddedToken('!!!not base64!!!', pattern), isNull);
    });
  });
}
