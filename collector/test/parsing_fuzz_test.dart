import 'dart:math';
import 'dart:typed_data';

import 'package:quotabot_collector/adapters/lmstudio.dart';
import 'package:quotabot_collector/adapters/ollama.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:test/test.dart';

void main() {
  const now = 1782000000;

  test('JSON quota parsers do not throw and keep percentages bounded', () {
    final random = Random(0x51A7E);
    for (var i = 0; i < 500; i++) {
      final input = _jsonish(random);
      parseReset(input);
      parseIsoToEpoch(input);
      if (input is! Map<String, dynamic>) continue;

      _expectWindowsSafe(codexBindingWindows([input], now));
      _expectWindowsSafe(claudeWindows(input));
      for (final model in claudeModelQuotas(input)) {
        expect(model.model.trim(), isNotEmpty);
        expect(model.usedPercent, inInclusiveRange(0, 100));
      }
      _expectWindowsSafe(antigravityWindows(input, now));
      _expectWindowsSafe(cursorWindows(input, now));
      _expectWindowsSafe(windsurfWindows(input, now));
      _expectWindowsSafe(kiroWindows(input, now));

      lmStudioNativeFromJson(input);
      lmStudioCompatFromJson(input);
      for (final model in ollamaModelsFromJson(input)) {
        expect(model.name.trim(), isNotEmpty);
      }
    }
  });

  test('local-runtime parsers tolerate non-finite numeric fields', () {
    // A rogue localhost server could answer with Infinity/NaN where a size or
    // context is expected; .toInt() on a non-finite double throws, so the
    // parsers must drop it rather than crash the (caught) adapter path.
    final ollama = ollamaModelsFromJson({
      'models': [
        {'name': 'm', 'size': double.infinity, 'size_vram': double.nan},
      ],
    });
    expect(ollama.single.bytes, isNull);
    expect(ollama.single.vramBytes, isNull);

    final lm = lmStudioNativeFromJson({
      'data': [
        {'id': 'm', 'state': 'loaded', 'max_context_length': double.infinity},
      ],
    });
    expect(lm!.installed.single.context, isNull);
  });

  test('protobuf and token parsers tolerate arbitrary bytes and strings', () {
    final random = Random(0xB10B);
    final tokenPattern = r'ya29\.[A-Za-z0-9._\-]{20,}';
    for (var i = 0; i < 500; i++) {
      final bytes = Uint8List.fromList(
        List<int>.generate(random.nextInt(192), (_) => random.nextInt(256)),
      );

      final message = grpcMessage(bytes);
      expect(message.length, lessThanOrEqualTo(bytes.length));

      final scan = ProtoScan()..walk(bytes);
      final percent = scan.firstPercent;
      if (percent != null) {
        expect(percent, inInclusiveRange(0, 100));
      }

      final window = grokWindow(message, now);
      if (window != null) _expectWindowsSafe([window]);

      planFromProto(bytes);
      findEmbeddedToken(_base64ish(random), tokenPattern);
    }
  });
}

void _expectWindowsSafe(List<QuotaWindow> windows) {
  for (final window in windows) {
    expect(window.label.toString().trim(), isNotEmpty);
    final percent = window.percent;
    if (percent != null) {
      expect(percent.isFinite, isTrue);
      expect(percent, inInclusiveRange(0, 100));
    }
  }
}

dynamic _jsonish(Random random, [int depth = 0]) {
  if (depth >= 4) return _scalar(random);
  switch (random.nextInt(7)) {
    case 0:
    case 1:
      return _scalar(random);
    case 2:
      return List<dynamic>.generate(
        random.nextInt(5),
        (_) => _jsonish(random, depth + 1),
      );
    default:
      final out = <String, dynamic>{};
      final count = random.nextInt(6);
      for (var i = 0; i < count; i++) {
        out[_key(random)] = _jsonish(random, depth + 1);
      }
      return out;
  }
}

dynamic _scalar(Random random) {
  switch (random.nextInt(12)) {
    case 0:
      return null;
    case 1:
      return random.nextBool();
    case 2:
      return random.nextInt(4000) - 2000;
    case 3:
      return (random.nextDouble() * 500) - 150;
    case 4:
      return double.nan;
    case 5:
      return double.infinity;
    case 6:
      return '2026-07-${(random.nextInt(27) + 1).toString().padLeft(2, '0')}T00:00:00Z';
    case 7:
      return '${random.nextInt(10000)}';
    default:
      return _base64ish(random);
  }
}

String _key(Random random) {
  const keys = [
    'models',
    'quotaInfo',
    'remainingFraction',
    'resetTime',
    'five_hour',
    'seven_day',
    'utilization',
    'resets_at',
    'primary',
    'secondary',
    'used_percent',
    'resets_at',
    'usageBreakdowns',
    'currentUsage',
    'usageLimit',
    'percentageUsed',
    'resetDate',
    'displayName',
    'monthlyUsage',
    'usedCents',
    'includedCents',
    'currentPeriodEnd',
    'quotaUsage',
    'daily',
    'weekly',
    'remainingPercent',
    'usedMessages',
    'messages',
    'usedFlowActions',
    'flowActions',
    'data',
    'id',
    'state',
    'loaded_context_length',
    'max_context_length',
    'size',
    'size_vram',
    'expires_at',
    'models',
    'name',
    'details',
    'parameter_size',
    'quantization_level',
  ];
  if (random.nextInt(4) != 0) return keys[random.nextInt(keys.length)];
  return 'x${random.nextInt(1000)}';
}

String _base64ish(Random random) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/_-=.';
  return String.fromCharCodes(
    List<int>.generate(
      random.nextInt(80),
      (_) => chars.codeUnitAt(random.nextInt(chars.length)),
    ),
  );
}
