import 'dart:convert';
import 'dart:typed_data';

import 'package:quotabot_collector/parsing.dart';
import 'package:test/test.dart';

/// Builds a protobuf field-1 32-bit float, then a field-4 varint timestamp.
Uint8List _grokMessage(double percent, int timestamp) {
  final out = <int>[];
  out.add(0x0d); // field 1, wire type 5 (32-bit)
  final f = ByteData(4)..setFloat32(0, percent, Endian.little);
  out.addAll(f.buffer.asUint8List());
  out.add(0x20); // field 4, wire type 0 (varint)
  var t = timestamp;
  while (true) {
    final b = t & 0x7f;
    t >>= 7;
    if (t == 0) {
      out.add(b);
      break;
    }
    out.add(b | 0x80);
  }
  return Uint8List.fromList(out);
}

List<int> _fieldString(String value) {
  final bytes = utf8.encode(value);
  final out = <int>[0x0a];
  var len = bytes.length;
  while (true) {
    final b = len & 0x7f;
    len >>= 7;
    if (len == 0) {
      out.add(b);
      break;
    }
    out.add(b | 0x80);
  }
  out.addAll(bytes);
  return out;
}

void main() {
  group('codex', () {
    test('builds 5h and weekly windows', () {
      final w = codexWindows({
        'primary': {
          'used_percent': 12.0,
          'window_minutes': 300,
          'resets_at': 10,
        },
        'secondary': {
          'used_percent': 80.0,
          'window_minutes': 10080,
          'resets_at': 20,
        },
      });
      expect(w.length, 2);
      expect(w[0].label, '5h');
      expect(w[0].usedPercent, 12.0);
      expect(w[1].label, 'weekly');
      expect(w[1].resetsAt, 20);
    });

    test('binding windows keep the most-used bucket per slot', () {
      // A fresh model bucket (0% on both) plus a standard bucket at 26% weekly.
      // The weekly slot must reflect the 26%, not the fresh bucket's 0%.
      final now = 1782000000;
      final w = codexBindingWindows([
        {
          'limit_name': 'Spark',
          'primary': {
            'used_percent': 0.0,
            'window_minutes': 300,
            'resets_at': now + 3600,
          },
          'secondary': {
            'used_percent': 0.0,
            'window_minutes': 10080,
            'resets_at': now + 86400,
          },
        },
        {
          'primary': {
            'used_percent': 0.0,
            'window_minutes': 300,
            'resets_at': now + 1800,
          },
          'secondary': {
            'used_percent': 26.0,
            'window_minutes': 10080,
            'resets_at': now + 90000,
          },
        },
      ], now);
      expect(w.length, 2);
      expect(w[1].label, 'weekly');
      expect(w[1].usedPercent, 26.0);
      expect(w[1].resetsAt, now + 90000);
    });

    test('binding windows ignore a bucket whose window already reset', () {
      // The 40% weekly bucket has already passed its reset, so it counts as
      // fresh (0) and must not beat a live 5% bucket.
      final now = 1782000000;
      final w = codexBindingWindows([
        {
          'secondary': {
            'used_percent': 40.0,
            'window_minutes': 10080,
            'resets_at': now - 10,
          },
        },
        {
          'secondary': {
            'used_percent': 5.0,
            'window_minutes': 10080,
            'resets_at': now + 1000,
          },
        },
      ], now);
      expect(w.single.usedPercent, 5.0);
    });

    test('label falls back and derives from minutes', () {
      expect(codexLabel(300, 'x'), '5h');
      expect(codexLabel(10080, 'x'), 'weekly');
      expect(codexLabel(2880, 'x'), '2d');
      expect(codexLabel(120, 'x'), '2h');
      expect(codexLabel(45, 'x'), '45m');
      expect(codexLabel(null, 'fallback'), 'fallback');
    });
  });

  group('claude', () {
    test('parses utilization blocks and iso reset', () {
      final w = claudeWindows({
        'five_hour': {'utilization': 18.0, 'resets_at': '2026-06-21T17:00:00Z'},
        'seven_day': {'utilization': 23.0, 'resets_at': null},
        'seven_day_opus': {'utilization': 0.0},
      });
      expect(w.map((e) => e.label), ['5h', 'weekly', 'opus']);
      expect(w[0].usedPercent, 18.0);
      expect(w[0].resetsAt, isNotNull);
      expect(w[1].resetsAt, isNull);
    });

    test('skips blocks without utilization', () {
      expect(claudeWindows({'five_hour': {}}), isEmpty);
      expect(claudeWindows({'seven_day': 'nope'}), isEmpty);
    });

    test('parseIsoToEpoch handles bad input', () {
      expect(parseIsoToEpoch(null), isNull);
      expect(parseIsoToEpoch(123), isNull);
      expect(parseIsoToEpoch('not-a-date'), isNull);
      expect(parseIsoToEpoch('2026-01-01T00:00:00Z'), isPositive);
    });
  });

  group('antigravity', () {
    const now = 1782000000;
    test('buckets models by reset window keeping most constrained', () {
      final w = antigravityWindows({
        'models': {
          'a': {
            'quotaInfo': {'remainingFraction': 0.9, 'resetTime': now + 3600},
          },
          'b': {
            'quotaInfo': {'remainingFraction': 0.5, 'resetTime': now + 7200},
          },
          'c': {
            'quotaInfo': {
              'remainingFraction': 0.8,
              'resetTime': now + 5 * 86400,
            },
          },
        },
      }, now);
      // a and b both fall in the 5h bucket; b is more used so it wins.
      final fiveH = w.firstWhere((e) => e.label == '5h');
      expect(fiveH.usedPercent, closeTo(50, 0.01));
      expect(w.any((e) => e.label == 'weekly'), isTrue);
    });

    test('ignores models lacking fraction or reset', () {
      expect(antigravityWindows({'models': {}}, now), isEmpty);
      expect(antigravityWindows({'models': 'x'}, now), isEmpty);
      expect(antigravityWindows(null, now), isEmpty);
    });

    test('resetLabel and parseReset', () {
      expect(resetLabel(now + 3600, now), '5h');
      expect(resetLabel(now + 30 * 3600, now), 'daily');
      expect(resetLabel(now + 5 * 86400, now), 'weekly');
      expect(parseReset(1234), 1234);
      expect(parseReset('5678'), 5678);
      expect(parseReset('2026-01-01T00:00:00Z'), isPositive);
      expect(parseReset(null), isNull);
    });

    test('findEmbeddedToken recovers a base64-wrapped token', () {
      final token = 'ya'
          '29.AbCdEfGhIjKlMnOpQrStUvWxYz0123456789';
      final wrapped = base64.encode(utf8.encode('noise $token noise'));
      final found = findEmbeddedToken(wrapped, r'ya29\.[A-Za-z0-9._\-]{20,}');
      expect(found, token);
    });

    test('planFromProto finds the tier string', () {
      // protobuf: field 1, wire type 2 (len-delimited), value "Pro"
      final bytes = [0x0a, 3, ...utf8.encode('Pro')];
      expect(planFromProto(bytes), 'Pro');
      expect(planFromProto([0x0a, 2, ...utf8.encode('xx')]), isNull);
    });

    test('userStatus parser extracts account, plan, model, and local note', () {
      final nested = _fieldString(
        'Nick Seal blisspixel@gmail.com Gemini 3.1 Pro (High) '
        'Google AI Pro subscribers get higher rate limits',
      );
      final outer = _fieldString(base64Url.encode(nested));

      final parsed = antigravityUserStatusFromProto(outer);

      expect(parsed, isNotNull);
      expect(parsed!.email, 'blisspixel@gmail.com');
      expect(parsed.plan, 'Google AI Pro');
      expect(parsed.model, 'Gemini 3.1 Pro (High)');
      expect(
        parsed.note,
        'Local Antigravity status reports higher rate limits',
      );
    });

    test('userStatus parser recovers prefixed nested status payloads', () {
      final nested = _fieldString(
        'blisspixel@gmail.com Gemini 3.5 Flash (Medium) '
        'Gemini 3.1 Pro (Low) Gemini 3.1 Pro (High) '
        'Google AI Pro subscribers get higher rate limits Google AI Ultra',
      );
      final outer = _fieldString('0${base64Encode(nested)}');

      final parsed = antigravityUserStatusFromProto(outer);

      expect(parsed, isNotNull);
      expect(parsed!.email, 'blisspixel@gmail.com');
      expect(parsed.plan, 'Google AI Pro');
      expect(parsed.model, 'Gemini 3.1 Pro (High)');
    });
  });

  group('grok', () {
    test('grpcMessage extracts the data frame payload', () {
      final payload = [1, 2, 3, 4];
      final framed = Uint8List.fromList([
        0,
        0,
        0,
        0,
        payload.length,
        ...payload,
      ]);
      expect(grpcMessage(framed), payload);
    });

    test('grpcMessage rejects trailer-first and short input', () {
      expect(grpcMessage(Uint8List.fromList([0x80, 0, 0, 0, 0])), isEmpty);
      expect(grpcMessage(Uint8List.fromList([0, 0])), isEmpty);
    });

    test('grokWindow parses percent and nearest future reset', () {
      const now = 1782000000;
      final msg = _grokMessage(6.0, now + 86400);
      final w = grokWindow(msg, now);
      expect(w, isNotNull);
      expect(w!.label, 'weekly');
      expect(w.usedPercent, 6.0);
      expect(w.resetsAt, now + 86400);
    });

    test('grokWindow returns null without a percent', () {
      expect(grokWindow(const [], 0), isNull);
    });

    test('ProtoScan walks nested messages', () {
      // field 1 (len-delimited) wrapping a float field
      final inner = _grokMessage(7.5, 1782000001);
      final outer = <int>[0x0a, inner.length, ...inner];
      final scan = ProtoScan()..walk(outer);
      expect(scan.firstPercent, 7.5);
      expect(scan.nearestFutureTimestamp(1782000000), 1782000001);
    });

    test('kiroWindows parses usageState with 100% credit exhaustion', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final state = {
        'usageBreakdowns': [
          {
            'currentUsage': 10000,
            'usageLimit': 10000,
            'percentageUsed': 100,
            'resetDate': '2026-07-01T00:00:00.000Z',
            'displayName': 'Credit',
          },
        ],
      };
      final ws = kiroWindows(state, now);
      expect(ws.length, 1);
      expect(ws.first.label, 'credit');
      expect(ws.first.percent, closeTo(100, 0.1));
      expect(ws.first.resetsAt, isNotNull);
    });
  });

  group('windsurf', () {
    const now = 1782000000;
    test('windsurfWindows handles daily/weekly remaining percent', () {
      final w = windsurfWindows({
        'daily_quota_remaining_percent': 35,
        'weekly_quota_remaining_percent': 80,
      }, now);
      expect(w.length, 2);
      expect(w[0].label, 'daily');
      expect(w[0].usedPercent, closeTo(65, 0.1));
      expect(w[1].label, 'weekly');
    });

    test('windsurfWindows falls back to messages/flow counters', () {
      final w = windsurfWindows({
        'usedMessages': 450,
        'messages': 500,
        'usedFlowActions': 10,
        'flowActions': 100,
      }, now);
      expect(
        w.any((e) => e.label == 'messages' && (e.usedPercent ?? 0) > 80),
        isTrue,
      );
      expect(
        w.any((e) => e.label == 'flow' && (e.usedPercent ?? 0) > 0),
        isTrue,
      );
    });

    test('windsurfWindows reads nested quotaUsage and is empty otherwise', () {
      final w = windsurfWindows({
        'quotaUsage': {
          'daily': {'used': 5, 'limit': 20},
        },
      }, now);
      expect(w.single.label, 'daily');
      expect(w.single.usedPercent, closeTo(25, 0.1));
      expect(windsurfWindows('not a map', now), isEmpty);
      expect(windsurfWindows({}, now), isEmpty);
    });
  });

  group('cursor', () {
    const now = 1782000000;
    test('cursorWindows reads the current monthly included-usage pool', () {
      final w = cursorWindows({
        'monthlyUsage': {
          'usedCents': 1250,
          'includedCents': 2000,
          'currentPeriodEnd': '2026-07-01T00:00:00.000Z',
        },
      }, now);
      expect(w.single.label, 'monthly');
      expect(w.single.usedPercent, closeTo(62.5, 0.1));
      expect(w.single.resetsAt, isNotNull);
    });

    test('cursorWindows reads usageBreakdowns', () {
      final w = cursorWindows({
        'usageBreakdowns': [
          {
            'currentUsage': 30,
            'usageLimit': 100,
            'displayName': 'Premium',
            'resetDate': '2026-07-01T00:00:00.000Z',
          },
        ],
      }, now);
      expect(w.single.label, 'premium');
      expect(w.single.usedPercent, closeTo(30, 0.1));
      expect(w.single.resetsAt, isNotNull);
    });

    test('cursorWindows falls back to planUsage and handles non-maps', () {
      final w = cursorWindows({
        'planUsage': {'used': 40, 'limit': 50},
      }, now);
      expect(w.single.label, 'monthly');
      expect(w.single.usedPercent, closeTo(80, 0.1));
      expect(cursorWindows('nope', now), isEmpty);
    });
  });
}
