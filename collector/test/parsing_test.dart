import 'dart:convert';
import 'dart:typed_data';

import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:test/test.dart';

/// Builds a protobuf field-1 32-bit float, then a field-4 varint timestamp.
Uint8List _grokMessage(double percent, int timestamp) => Uint8List.fromList([
      ..._float32Field(1, percent),
      ..._varintField(4, timestamp),
    ]);

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  while (true) {
    final b = v & 0x7f;
    v >>= 7;
    if (v == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
}

List<int> _varintField(int field, int value) =>
    [(field << 3) | 0, ..._varint(value)];

List<int> _float32Field(int field, double value) {
  final f = ByteData(4)..setFloat32(0, value, Endian.little);
  return [(field << 3) | 5, ...f.buffer.asUint8List()];
}

List<int> _messageField(int field, List<int> body) =>
    [(field << 3) | 2, ..._varint(body.length), ...body];

List<int> _grpcFrame(int flag, List<int> body) => [
      flag,
      (body.length >> 24) & 0xff,
      (body.length >> 16) & 0xff,
      (body.length >> 8) & 0xff,
      body.length & 0xff,
      ...body,
    ];

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

const Object _absentCodexField = Object();

Map<String, dynamic> _codexLiveWindow({
  Object? usedPercent = 10,
  Object? durationSeconds = 604800,
  Object? resetAt = 1785011368,
}) =>
    {
      'used_percent': usedPercent,
      'limit_window_seconds': durationSeconds,
      'reset_at': resetAt,
    };

Map<String, dynamic> _validCodexLiveResponse({
  num usedPercent = 10,
  Object? additionalRateLimits = _absentCodexField,
}) {
  final spent = usedPercent == 100;
  return {
    'rate_limit': {
      'allowed': !spent,
      'limit_reached': spent,
      'primary_window': _codexLiveWindow(usedPercent: usedPercent),
      'secondary_window': null,
    },
    if (!identical(additionalRateLimits, _absentCodexField))
      'additional_rate_limits': additionalRateLimits,
  };
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

    test('equal-use buckets choose the later reset independent of order', () {
      const now = 1782000000;
      Map<String, dynamic> weekly(int reset) => {
            'secondary': {
              'used_percent': 40,
              'window_minutes': 10080,
              'resets_at': reset,
            },
          };
      final earlier = weekly(now + 1000);
      final later = weekly(now + 2000);

      for (final snapshots in [
        [earlier, later],
        [later, earlier],
      ]) {
        final window = codexBindingWindows(snapshots, now).single;
        expect(window.usedPercent, 40);
        expect(window.resetsAt, now + 2000);
      }
    });

    test('binding windows preserve a tighter bucket after its reset', () {
      // A reset timestamp does not prove a fresh balance. The expired 40% row
      // remains the tightest last observation so admission can mark the
      // provider stale instead of hiding it behind the 5% bucket.
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
      expect(w.single.usedPercent, 40.0);
      expect(w.single.resetsAt, now - 10);
      final quota = ProviderQuota(
        provider: 'codex',
        displayName: 'Codex',
        account: 'local session',
        asOf: now,
        windows: w,
        perMachine: true,
      );
      expect(isTrustedQuotaEvidenceAt(quota, now), isFalse);
    });

    test('rejects impossible percentages while accepting exact boundaries', () {
      final w = codexWindows({
        'primary': {
          'used_percent': 0,
          'window_minutes': 300,
          'resets_at': 10,
        },
        'secondary': {
          'used_percent': 100,
          'window_minutes': 10080,
          'resets_at': 20,
        },
      });
      expect(w.map((window) => window.usedPercent), [0, 100]);

      for (final invalid in <Object?>[
        -1,
        101,
        double.nan,
        double.infinity,
        true,
        '10',
        <String, Object?>{},
      ]) {
        expect(
          codexUsageWindows({
            'rate_limit': {
              'primary_window': _codexLiveWindow(usedPercent: invalid),
            },
          }),
          isEmpty,
          reason: 'invalid percentage $invalid must not become quota',
        );
      }

      expect(
        codexUsageWindows({
          'rate_limit': {
            'primary_window': _codexLiveWindow(usedPercent: -1),
            'secondary_window': _codexLiveWindow(usedPercent: 20),
          },
        }),
        isEmpty,
        reason: 'one invalid binding pool invalidates the shared observation',
      );
    });

    test('label falls back and derives from minutes', () {
      expect(codexLabel(300, 'x'), '5h');
      expect(codexLabel(10080, 'x'), 'weekly');
      expect(codexLabel(2880, 'x'), '2d');
      expect(codexLabel(120, 'x'), '2h');
      expect(codexLabel(45, 'x'), '45m');
      expect(codexLabel(null, 'fallback'), 'fallback');
      expect(codexLabel(-5, 'fallback'), 'fallback');
      expect(codexLabel(12.5, 'fallback'), 'fallback');
      expect(codexLabel(999999999, 'fallback'), 'fallback');
    });

    test('live window label uses integer minutes, not "90.0m"', () {
      final w = codexUsageWindows({
        'rate_limit': {
          'primary_window': _codexLiveWindow(durationSeconds: 5400),
        },
      });
      expect(w.single.label, '90m');
    });

    test('live explicit null window is absent, not a malformed response', () {
      final windows = codexUsageWindows({
        'rate_limit': {
          'primary_window': {
            'used_percent': 63,
            'limit_window_seconds': 604800,
            'reset_at': 1785011368,
          },
          'secondary_window': null,
        },
      });

      expect(windows, hasLength(1));
      expect(windows.single.label, 'weekly');
      expect(windows.single.usedPercent, 63);
    });

    test('unknown quota-shaped live windows reject the whole response', () {
      final complete = _validCodexLiveResponse();
      (complete['rate_limit'] as Map<String, dynamic>)['tertiary_window'] =
          _codexLiveWindow(
        usedPercent: 100,
        durationSeconds: 2592000,
      );

      expect(codexLiveUsage(complete), isNull);
      expect(codexUsageWindows(complete), isEmpty);

      for (final marker in const [
        'used_percent',
        'reset_at',
        'limit_window_seconds',
      ]) {
        final malformed = _validCodexLiveResponse();
        (malformed['rate_limit'] as Map<String, dynamic>)['future_pool'] = {
          marker: 1,
        };
        expect(
          codexLiveUsage(malformed),
          isNull,
          reason: 'unknown pool marker $marker must reject the observation',
        );
      }

      final namedButIncomplete = _validCodexLiveResponse();
      (namedButIncomplete['rate_limit']
          as Map<String, dynamic>)['monthly_window'] = null;
      expect(codexLiveUsage(namedButIncomplete), isNull);
    });

    test('benign additive live rate-limit metadata remains compatible', () {
      final response = _validCodexLiveResponse();
      (response['rate_limit'] as Map<String, dynamic>)
        ..['future_scalar'] = 2
        ..['future_metadata'] = {'version': 2, 'opaque': true};

      final usage = codexLiveUsage(response);
      expect(usage, isNotNull);
      expect(usage!.windows, hasLength(1));
    });

    test('duplicate scoped limits reduce conservatively in either order', () {
      Map<String, dynamic> scoped({
        required String model,
        required int resetAt,
        required int durationSeconds,
      }) =>
          {
            'limit_name': model,
            'rate_limit': {
              'allowed': true,
              'limit_reached': false,
              'primary_window': _codexLiveWindow(
                usedPercent: 35,
                durationSeconds: durationSeconds,
                resetAt: resetAt,
              ),
            },
          };

      final earlier = scoped(
        model: 'GPT-5.3-Codex-Spark',
        resetAt: 1785011368,
        durationSeconds: 18000,
      );
      final later = scoped(
        model: 'gpt-5.3-codex-spark',
        resetAt: 1785012368,
        durationSeconds: 604800,
      );

      for (final rows in [
        [earlier, later],
        [later, earlier],
      ]) {
        final usage = codexLiveUsage(_validCodexLiveResponse(
          additionalRateLimits: rows,
        ));

        expect(usage, isNotNull);
        expect(usage!.modelQuotas, hasLength(1));
        expect(usage.modelQuotas.single.model, 'gpt-5.3-codex-spark');
        expect(usage.modelQuotas.single.usedPercent, 35);
        expect(usage.modelQuotas.single.resetsAt, 1785012368);
        expect(usage.modelQuotas.single.windowLabel, 'weekly');
      }
    });

    test('live windows require bounded minute-aligned durations', () {
      for (final duration in <Object?>[
        null,
        -60,
        0,
        61,
        90.5,
        999999999,
        '18000',
      ]) {
        final response = _validCodexLiveResponse();
        (response['rate_limit'] as Map<String, dynamic>)['primary_window'] =
            _codexLiveWindow(durationSeconds: duration);
        expect(
          codexLiveUsage(response),
          isNull,
          reason: 'invalid duration $duration must reject the observation',
        );
      }
    });

    test('live windows require a positive parseable reset', () {
      for (final reset in <Object?>[
        null,
        0,
        -1,
        1785011368.5,
        'not-a-reset',
      ]) {
        final response = _validCodexLiveResponse();
        (response['rate_limit'] as Map<String, dynamic>)['primary_window'] =
            _codexLiveWindow(resetAt: reset);
        expect(
          codexLiveUsage(response),
          isNull,
          reason: 'invalid reset $reset must reject the observation',
        );
      }
    });

    test('live reset forms normalize before time-aware admission', () {
      const observedAt = 1782000000;
      const normalizedReset = 1782088200;
      final accepted = <Object>[
        '1782088200',
        '2026-06-22T00:30:00Z',
        1782088200000,
        1782088200000000,
        1782088200000000000,
      ];

      ProviderQuota quotaFor(CodexLiveUsage usage) => ProviderQuota(
            provider: 'codex',
            displayName: 'Codex',
            account: 'test',
            asOf: observedAt,
            windows: usage.windows,
            modelQuotas: usage.modelQuotas,
          );

      for (final rawReset in accepted) {
        final response = _validCodexLiveResponse();
        (response['rate_limit'] as Map<String, dynamic>)['primary_window'] =
            _codexLiveWindow(resetAt: rawReset);
        final usage = codexLiveUsage(response);

        expect(usage, isNotNull, reason: '$rawReset should parse');
        expect(usage!.windows.single.resetsAt, normalizedReset);
        expect(
          isTrustedQuotaEvidenceAt(quotaFor(usage), observedAt),
          isTrue,
          reason: '$rawReset should normalize to a current quota epoch',
        );
      }

      final durationLike = _validCodexLiveResponse();
      (durationLike['rate_limit'] as Map<String, dynamic>)['primary_window'] =
          _codexLiveWindow(resetAt: 604800);
      final parsedDurationLike = codexLiveUsage(durationLike);
      expect(parsedDurationLike, isNotNull);
      expect(parsedDurationLike!.windows.single.resetsAt, 604800);
      final durationQuota = quotaFor(parsedDurationLike);
      expect(isTrustedQuotaEvidenceAt(durationQuota, observedAt), isFalse);
      expect(
        unusableQuotaEvidenceDriftReason(
          durationQuota,
          observedAt: observedAt,
        ),
        contains('reset passed'),
      );
    });

    test('live allowed flags require booleans and agree with the windows', () {
      final malformed = <Map<String, Object?>>[
        {'allowed': 'true', 'limit_reached': false},
        {'allowed': true, 'limit_reached': 0},
        {'allowed': null, 'limit_reached': false},
        {'allowed': true, 'limit_reached': true},
        {'allowed': false, 'limit_reached': false},
      ];
      for (final flags in malformed) {
        final response = _validCodexLiveResponse();
        (response['rate_limit'] as Map<String, dynamic>)
          ..remove('allowed')
          ..remove('limit_reached')
          ..addAll(flags);
        expect(codexLiveUsage(response), isNull, reason: flags.toString());
      }

      final falselyAllowed = _validCodexLiveResponse(usedPercent: 100);
      (falselyAllowed['rate_limit'] as Map<String, dynamic>)
        ..['allowed'] = true
        ..['limit_reached'] = false;
      expect(codexLiveUsage(falselyAllowed), isNull);

      final falselySpent = _validCodexLiveResponse(usedPercent: 50);
      (falselySpent['rate_limit'] as Map<String, dynamic>)
        ..['allowed'] = false
        ..['limit_reached'] = true;
      expect(codexLiveUsage(falselySpent), isNull);

      final nearLimitAllowed = _validCodexLiveResponse(usedPercent: 99);
      expect(codexLiveUsage(nearLimitAllowed), isNotNull);

      final falselySpentNearLimit = _validCodexLiveResponse(usedPercent: 99);
      (falselySpentNearLimit['rate_limit'] as Map<String, dynamic>)
        ..['allowed'] = false
        ..['limit_reached'] = true;
      expect(codexLiveUsage(falselySpentNearLimit), isNull);
    });

    test('a scoped boolean contradiction rejects valid shared quota', () {
      final response = _validCodexLiveResponse(
        additionalRateLimits: [
          {
            'limit_name': 'GPT-5.3-Codex-Spark',
            'rate_limit': {
              'allowed': true,
              'limit_reached': false,
              'primary_window': _codexLiveWindow(usedPercent: 100),
            },
          },
        ],
      );

      expect(codexLiveUsage(response), isNull);
      expect(codexUsageWindows(response), isEmpty);
    });

    test('additional rate limits may be absent, null, or empty', () {
      expect(codexLiveUsage(_validCodexLiveResponse()), isNotNull);
      expect(
        codexLiveUsage(
          _validCodexLiveResponse(additionalRateLimits: null),
        ),
        isNotNull,
      );
      expect(
        codexLiveUsage(
          _validCodexLiveResponse(additionalRateLimits: const []),
        ),
        isNotNull,
      );
    });

    test('one malformed additional limit rejects the whole live response', () {
      final invalidRows = <Object?>[
        'not-a-list-container',
        [null],
        [42],
        [<String, Object?>{}],
        [
          {
            'limit_name': '',
            'rate_limit': _validCodexLiveResponse()['rate_limit'],
          },
        ],
        [
          {
            'limit_name': '   ',
            'rate_limit': _validCodexLiveResponse()['rate_limit'],
          },
        ],
        [
          {
            'limit_name': 53,
            'rate_limit': _validCodexLiveResponse()['rate_limit'],
          },
        ],
        [
          {
            'limit_name': 'bad\u0000name',
            'rate_limit': _validCodexLiveResponse()['rate_limit'],
          },
        ],
        [
          {
            'limit_name': List.filled(161, 'x').join(),
            'rate_limit': _validCodexLiveResponse()['rate_limit'],
          },
        ],
        [
          {
            'limit_name': 'GPT-5.3-Codex-Spark',
            'rate_limit': 'not-a-rate-limit',
          },
        ],
        [
          {
            'limit_name': 'GPT-5.3-Codex-Spark',
            'rate_limit': {
              'primary_window': _codexLiveWindow(durationSeconds: 61),
            },
          },
        ],
        [
          {
            'limit_name': 'GPT-5.3-Codex-Spark',
            'rate_limit': {
              'allowed': 'true',
              'primary_window': _codexLiveWindow(),
            },
          },
        ],
      ];
      for (final additional in invalidRows) {
        final response = _validCodexLiveResponse(
          additionalRateLimits: additional,
        );
        expect(
          codexLiveUsage(response),
          isNull,
          reason: 'malformed additional limit must be atomic: $additional',
        );
        expect(codexUsageWindows(response), isEmpty);
      }
    });

    test('reads the available redeemable reset-credit count', () {
      expect(
        codexResetCredits({
          'rate_limit_reset_credits': {'available_count': 2},
        }),
        2,
      );
      expect(
        codexResetCredits({
          'rate_limit_reset_credits': {'available_count': 0},
        }),
        0,
      );
    });

    test('reset credits are null when absent or malformed, not silently zero',
        () {
      expect(codexResetCredits(null), isNull);
      expect(codexResetCredits({}), isNull);
      expect(codexResetCredits({'rate_limit_reset_credits': null}), isNull);
      expect(
        codexResetCredits({'rate_limit_reset_credits': 'two'}),
        isNull,
      );
      expect(
        codexResetCredits({
          'rate_limit_reset_credits': {'available_count': -1},
        }),
        isNull,
      );
      expect(
        codexResetCredits({
          'rate_limit_reset_credits': {'available_count': 'lots'},
        }),
        isNull,
      );
      // A fractional count is rejected, not truncated, and an absurd count is
      // rejected rather than rendered as "1000000000 resets available".
      expect(
        codexResetCredits({
          'rate_limit_reset_credits': {'available_count': 2.9},
        }),
        isNull,
      );
      expect(
        codexResetCredits({
          'rate_limit_reset_credits': {'available_count': 1000000000},
        }),
        isNull,
      );
    });
  });

  group('claude', () {
    test('prefers canonical limits and normalizes scoped families', () {
      final data = <String, dynamic>{
        'limits': [
          {
            'kind': 'session',
            'group': 'session',
            'percent': 45,
            'resets_at': '2026-07-18T17:00:00Z',
            'scope': null,
            'is_active': true,
          },
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'percent': 17,
            'resets_at': '2026-07-24T09:00:00Z',
            'scope': null,
            // Live responses mark weekly rows inactive even though `/usage`
            // displays and enforces them.
            'is_active': false,
          },
          {
            'kind': 'weekly_scoped',
            'group': 'weekly',
            'percent': 26,
            'resets_at': '2026-07-24T09:00:00Z',
            'scope': {
              'model': {'id': null, 'display_name': 'Claude Fable 5'},
              'surface': null,
            },
            'is_active': false,
          },
          {
            'kind': 'session',
            'group': 'session',
            'percent': 99,
            'resets_at': '2026-07-18T18:00:00Z',
            'scope': null,
            'is_active': true,
          },
        ],
        // Canonical rows win over duplicate legacy buckets.
        'five_hour': {'utilization': 1},
        'seven_day': {'utilization': 2},
      };
      final w = claudeWindows(data);
      final models = claudeModelQuotas(data);

      expect(w.map((e) => e.label), ['5h', 'weekly']);
      expect(w.map((e) => e.usedPercent), [99, 17]);
      expect(w.every((e) => e.resetsAt != null), isTrue);
      expect(models.map((e) => e.model), ['Fable']);
      expect(models.single.usedPercent, 26);
      expect(models.single.resetsAt, isNotNull);
      expect(models.single.windowLabel, 'weekly');
    });

    test('duplicate canonical rows choose the tightest independent of order',
        () {
      Map<String, dynamic> response(List<Map<String, dynamic>> rows) => {
            'limits': rows,
          };
      Map<String, dynamic> shared(num percent, String reset) => {
            'kind': 'session',
            'group': 'session',
            'scope': null,
            'percent': percent,
            'resets_at': reset,
          };
      Map<String, dynamic> scoped(num percent, String reset) => {
            'kind': 'weekly_scoped',
            'group': 'weekly',
            'scope': {
              'model': {'display_name': 'Claude Fable 5'},
            },
            'percent': percent,
            'resets_at': reset,
          };
      final weekly = <String, dynamic>{
        'kind': 'weekly_all',
        'group': 'weekly',
        'scope': null,
        'percent': 10,
        'resets_at': '2026-07-24T09:00:00Z',
      };

      final lowShared = shared(20, '2026-07-18T17:00:00Z');
      final highShared = shared(80, '2026-07-18T18:00:00Z');
      final earlyScoped = scoped(40, '2026-07-24T08:00:00Z');
      final lateScoped = scoped(40, '2026-07-24T09:00:00Z');
      for (final rows in [
        [lowShared, highShared, weekly, earlyScoped, lateScoped],
        [lateScoped, earlyScoped, weekly, highShared, lowShared],
      ]) {
        final data = response(rows);
        final window =
            claudeWindows(data).singleWhere((item) => item.label == '5h');
        final model = claudeModelQuotas(data).single;
        expect(window.usedPercent, 80);
        expect(window.resetsAt, parseIsoToEpoch('2026-07-18T18:00:00Z'));
        expect(model.usedPercent, 40);
        expect(model.resetsAt, parseIsoToEpoch('2026-07-24T09:00:00Z'));
      }
    });

    test('current Claude generations supersede expired duplicates in any order',
        () {
      const now = 1782000000;
      final expiredReset = DateTime.fromMillisecondsSinceEpoch(
        (now - 1) * 1000,
        isUtc: true,
      ).toIso8601String();
      final currentReset = DateTime.fromMillisecondsSinceEpoch(
        (now + 604800) * 1000,
        isUtc: true,
      ).toIso8601String();
      Map<String, dynamic> shared(num percent, String reset) => {
            'kind': 'weekly_all',
            'group': 'weekly',
            'scope': null,
            'percent': percent,
            'resets_at': reset,
          };
      Map<String, dynamic> scoped(num percent, String reset) => {
            'kind': 'weekly_scoped',
            'group': 'weekly',
            'scope': {
              'model': {'display_name': 'Claude Fable 5'},
            },
            'percent': percent,
            'resets_at': reset,
          };
      final expiredShared = shared(95, expiredReset);
      final currentShared = shared(25, currentReset);
      final expiredScoped = scoped(90, expiredReset);
      final currentScoped = scoped(30, currentReset);
      final session = <String, dynamic>{
        'kind': 'session',
        'group': 'session',
        'scope': null,
        'percent': 10,
        'resets_at': currentReset,
      };

      for (final rows in [
        [session, expiredShared, currentShared, expiredScoped, currentScoped],
        [currentScoped, expiredScoped, currentShared, expiredShared, session],
      ]) {
        final data = <String, dynamic>{'limits': rows};
        final window = claudeWindows(data, observedAt: now)
            .singleWhere((item) => item.label == 'weekly');
        final model = claudeModelQuotas(data, observedAt: now).single;
        expect(window.usedPercent, 25);
        expect(window.resetsAt, now + 604800);
        expect(model.usedPercent, 30);
        expect(model.resetsAt, now + 604800);
      }
    });

    test('an expired Claude generation remains fail-closed without a successor',
        () {
      const now = 1782000000;
      final expiredReset = DateTime.fromMillisecondsSinceEpoch(
        (now - 1) * 1000,
        isUtc: true,
      ).toIso8601String();
      final windows = claudeWindows({
        'limits': [
          {
            'kind': 'session',
            'group': 'session',
            'scope': null,
            'percent': 10,
            'resets_at': DateTime.fromMillisecondsSinceEpoch(
              (now + 3600) * 1000,
              isUtc: true,
            ).toIso8601String(),
          },
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'scope': null,
            'percent': 70,
            'resets_at': expiredReset,
          },
        ],
      }, observedAt: now);
      final quota = ProviderQuota(
        provider: 'claude',
        displayName: 'Claude',
        account: 'test',
        asOf: now,
        windows: windows,
      );

      final weekly = windows.singleWhere((window) => window.label == 'weekly');
      expect(weekly.usedPercent, 70);
      expect(weekly.resetsAt, now - 1);
      expect(isTrustedQuotaEvidenceAt(quota, now), isFalse);
    });

    test('one malformed canonical row rejects every sibling and legacy field',
        () {
      final data = <String, dynamic>{
        'limits': [
          'not a row',
          {
            'kind': 'session',
            'group': 'session',
            'percent': '88',
            'scope': null,
            'is_active': false,
          },
          {
            'kind': 'session',
            'group': 'weekly',
            'percent': 44,
            'scope': null,
            'is_active': true,
          },
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'percent': 101,
            'scope': null,
            'is_active': true,
          },
          {
            'kind': 'weekly_scoped',
            'group': 'weekly',
            'percent': 20,
            'scope': null,
            'is_active': true,
          },
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'percent': 31,
            'resets_at': null,
            'scope': null,
            'is_active': true,
          },
        ],
        'five_hour': {'utilization': 5},
      };
      expect(claudeLiveUsage(data), isNull);
      expect(claudeWindows(data), isEmpty);
      expect(claudeModelQuotas(data), isEmpty);
    });

    test('merges scoped-only canonical data with legacy primary windows', () {
      final data = <String, dynamic>{
        'limits': [
          {
            'kind': 'weekly_scoped',
            'group': 'weekly',
            'percent': 26,
            'resets_at': '2026-07-24T09:00:00Z',
            'scope': {
              'model': {'id': null, 'display_name': 'Fable'},
              'surface': null,
            },
            'is_active': false,
          },
        ],
        'five_hour': {'utilization': 45},
        'seven_day': {'utilization': 17},
      };
      final w = claudeWindows(data);
      final models = claudeModelQuotas(data);

      expect(w.map((e) => e.label), ['5h', 'weekly']);
      expect(w.map((e) => e.usedPercent), [45, 17]);
      expect(models.map((e) => e.model), ['Fable']);
      expect(models.single.usedPercent, 26);
    });

    test('malformed canonical rows cannot be backfilled from legacy fields',
        () {
      final data = <String, dynamic>{
        'limits': [
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'percent': '17',
            'scope': null,
            'is_active': true,
          },
          {
            'kind': 'session',
            'group': 'session',
            'percent': 45,
            'resets_at': 'not-a-date',
            'scope': null,
            'is_active': true,
          },
        ],
        'five_hour': {'utilization': 18},
        'seven_day': {'utilization': 23},
      };

      expect(claudeLiveUsage(data), isNull);
      expect(claudeWindows(data), isEmpty);
      expect(claudeModelQuotas(data), isEmpty);
    });

    test('parses utilization blocks and iso reset', () {
      final w = claudeWindows({
        'five_hour': {'utilization': 18.0, 'resets_at': '2026-06-21T17:00:00Z'},
        'seven_day': {'utilization': 23.0, 'resets_at': null},
        'seven_day_opus': {'utilization': 0.0},
      });
      expect(w.map((e) => e.label), ['5h', 'weekly']);
      expect(w[0].usedPercent, 18.0);
      expect(w[0].resetsAt, isNotNull);
      expect(w[1].resetsAt, isNull);
    });

    test('keeps a legacy Opus cap as model quota', () {
      final models = claudeModelQuotas({
        'five_hour': {'utilization': 18},
        'seven_day': {'utilization': 23},
        'seven_day_opus': {
          'utilization': 12,
          'resets_at': '2026-06-21T17:00:00Z',
        },
      });

      expect(models.map((e) => e.model), ['Opus']);
      expect(models.single.usedPercent, 12);
      expect(models.single.resetsAt, isNotNull);
      expect(models.single.windowLabel, 'weekly');
    });

    test('an explicit null legacy Opus block means no optional scoped pool',
        () {
      final usage = claudeLiveUsage({
        'five_hour': {'utilization': 18},
        'seven_day': {'utilization': 23},
        'seven_day_opus': null,
      });

      expect(usage, isNotNull);
      expect(usage!.windows.map((window) => window.label), ['5h', 'weekly']);
      expect(usage.modelQuotas, isEmpty);
    });

    test('a short-window row cannot survive a missing binding weekly row', () {
      final data = <String, dynamic>{
        'limits': [
          {
            'kind': 'session',
            'group': 'session',
            'scope': null,
            'percent': 45,
            'resets_at': '2026-07-18T17:00:00Z',
          },
        ],
      };

      expect(claudeLiveUsage(data), isNull);
      expect(claudeWindows(data), isEmpty);
      expect(claudeModelQuotas(data), isEmpty);
    });

    test('a short-window row cannot survive a malformed binding weekly row',
        () {
      final session = <String, dynamic>{
        'kind': 'session',
        'group': 'session',
        'scope': null,
        'percent': 45,
        'resets_at': '2026-07-18T17:00:00Z',
      };
      final malformedWeeklyRows = <Map<String, dynamic>>[
        {
          'kind': 'weekly_all',
          'group': 'weekly',
          'scope': null,
          'percent': '17',
          'resets_at': '2026-07-24T09:00:00Z',
        },
        {
          'kind': 'weekly_all',
          'group': 'weekly',
          'scope': null,
          'percent': 101,
          'resets_at': '2026-07-24T09:00:00Z',
        },
        {
          'kind': 'weekly_all',
          'group': 'weekly',
          'scope': null,
          'percent': 17,
          'resets_at': null,
        },
        {
          'kind': 'weekly_all',
          'group': 'weekly',
          'scope': null,
          'percent': 17,
          'resets_at': '2026-07-24T09:00:00',
        },
        {
          'kind': 'weekly_all',
          'group': 'session',
          'scope': null,
          'percent': 17,
          'resets_at': '2026-07-24T09:00:00Z',
        },
        {
          'kind': 'weekly_all',
          'group': 'weekly',
          'scope': {'model': null},
          'percent': 17,
          'resets_at': '2026-07-24T09:00:00Z',
        },
      ];

      for (final malformed in malformedWeeklyRows) {
        final data = <String, dynamic>{
          'limits': [session, malformed],
        };
        expect(claudeLiveUsage(data), isNull, reason: malformed.toString());
        expect(claudeWindows(data), isEmpty);
      }
    });

    test('a scoped row cannot survive a missing shared session row', () {
      final data = <String, dynamic>{
        'limits': [
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'scope': null,
            'percent': 17,
            'resets_at': '2026-07-24T09:00:00Z',
          },
          {
            'kind': 'weekly_scoped',
            'group': 'weekly',
            'percent': 26,
            'resets_at': '2026-07-24T09:00:00Z',
            'scope': {
              'model': {'display_name': 'Fable'},
            },
          },
        ],
      };

      expect(claudeLiveUsage(data), isNull);
      expect(claudeModelQuotas(data), isEmpty);
    });

    test('one malformed recognized scoped row rejects valid Fable siblings',
        () {
      Map<String, dynamic> response(Object malformed) => {
            'limits': [
              {
                'kind': 'session',
                'group': 'session',
                'scope': null,
                'percent': 45,
                'resets_at': '2026-07-18T17:00:00Z',
              },
              {
                'kind': 'weekly_all',
                'group': 'weekly',
                'scope': null,
                'percent': 17,
                'resets_at': '2026-07-24T09:00:00Z',
              },
              {
                'kind': 'weekly_scoped',
                'group': 'weekly',
                'percent': 26,
                'resets_at': '2026-07-24T09:00:00Z',
                'scope': {
                  'model': {'display_name': 'Fable'},
                },
              },
              malformed,
            ],
          };

      final malformedRows = <Object>[
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': '27',
          'resets_at': '2026-07-24T09:00:00Z',
          'scope': {
            'model': {'display_name': 'Fable'},
          },
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': 27,
          'resets_at': 'not-a-date',
          'scope': {
            'model': {'display_name': 'Fable'},
          },
        },
        {
          'kind': 'weekly_scoped',
          'group': 'session',
          'percent': 27,
          'resets_at': '2026-07-24T09:00:00Z',
          'scope': {
            'model': {'display_name': 'Fable'},
          },
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': 27,
          'resets_at': '2026-07-24T09:00:00Z',
          'scope': null,
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': 27,
          'resets_at': '2026-07-24T09:00:00Z',
          'scope': {
            'model': {'display_name': 'Fable'},
          },
          'is_active': 'false',
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': 27,
          'resets_at': '2026-07-24T09:00:00Z',
          'scope': {
            'model': {'display_name': 'Fable\u0000hidden'},
          },
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': 27,
          'resets_at': '2026-07-24T09:00:00Z',
          'scope': {
            'model': {'display_name': List.filled(161, 'x').join()},
          },
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': '60',
          'resets_at': '2026-07-24T09:00:00Z',
          'scope': {
            'model': {'display_name': 'Opus'},
          },
        },
      ];
      for (final malformed in malformedRows) {
        final data = response(malformed);
        expect(claudeLiveUsage(data), isNull, reason: malformed.toString());
        expect(claudeWindows(data), isEmpty);
        expect(claudeModelQuotas(data), isEmpty);
      }
    });

    test('present malformed legacy blocks reject a complete canonical body',
        () {
      final canonical = <String, dynamic>{
        'limits': [
          {
            'kind': 'session',
            'group': 'session',
            'scope': null,
            'percent': 45,
            'resets_at': '2026-07-18T17:00:00Z',
          },
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'scope': null,
            'percent': 17,
            'resets_at': '2026-07-24T09:00:00Z',
          },
        ],
      };
      final malformed = <String, Object?>{
        'five_hour': {'utilization': '45'},
        'seven_day': {'utilization': 17, 'resets_at': 'not-a-date'},
        'seven_day_opus': {'utilization': 26, 'resets_at': false},
      };
      for (final entry in malformed.entries) {
        final data = <String, dynamic>{...canonical, entry.key: entry.value};
        expect(claudeLiveUsage(data), isNull, reason: entry.key);
      }
    });

    test('unknown additive fields do not invalidate complete known evidence',
        () {
      final data = <String, dynamic>{
        'future_root_metadata': {'version': 2},
        'limits': [
          {
            'kind': 'session',
            'group': 'session',
            'scope': null,
            'percent': 45,
            'resets_at': '2026-07-18T17:00:00Z',
          },
          {
            'kind': 'weekly_all',
            'group': 'weekly',
            'scope': null,
            'percent': 17,
            'resets_at': '2026-07-24T09:00:00Z',
          },
          {
            'kind': 'future_advisory',
            'opaque': true,
          },
        ],
      };

      final usage = claudeLiveUsage(data);
      expect(usage, isNotNull);
      expect(usage!.windows.map((window) => window.label), ['5h', 'weekly']);
      expect(usage.modelQuotas, isEmpty);
    });

    test('unknown canonical quota rows reject the whole observation', () {
      Map<String, dynamic> responseWith(Map<String, Object?> unknown) => {
            'limits': [
              {
                'kind': 'session',
                'group': 'session',
                'scope': null,
                'percent': 45,
                'resets_at': '2026-07-18T17:00:00Z',
              },
              {
                'kind': 'weekly_all',
                'group': 'weekly',
                'scope': null,
                'percent': 17,
                'resets_at': '2026-07-24T09:00:00Z',
              },
              unknown,
            ],
          };

      final complete = responseWith({
        'kind': 'monthly_all',
        'group': 'monthly',
        'scope': null,
        'percent': 100,
        'resets_at': '2026-08-01T00:00:00Z',
      });
      expect(claudeLiveUsage(complete), isNull);
      expect(claudeWindows(complete), isEmpty);
      expect(claudeModelQuotas(complete), isEmpty);

      for (final partial in <Map<String, Object?>>[
        {'kind': 'future_pool', 'percent': 25},
        {'kind': 'future_pool', 'resets_at': '2026-08-01T00:00:00Z'},
      ]) {
        expect(
          claudeLiveUsage(responseWith(partial)),
          isNull,
          reason: 'partial unknown quota row must fail closed: $partial',
        );
      }
    });

    test('unknown root quota blocks reject the whole observation', () {
      final data = <String, dynamic>{
        'five_hour': {
          'utilization': 45,
          'resets_at': '2026-07-18T17:00:00Z',
        },
        'seven_day': {
          'utilization': 17,
          'resets_at': '2026-07-24T09:00:00Z',
        },
        'monthly_all': {
          'utilization': 100,
          'resets_at': '2026-08-01T00:00:00Z',
        },
      };

      expect(claudeLiveUsage(data), isNull);
      expect(claudeWindows(data), isEmpty);
      expect(claudeModelQuotas(data), isEmpty);
    });

    test('rejects out-of-range legacy utilization instead of clamping it', () {
      final windows = claudeWindows({
        'five_hour': {'utilization': -1},
        'seven_day': {'utilization': 101},
      });
      final models = claudeModelQuotas({
        'seven_day_opus': {'utilization': 250},
      });

      expect(windows, isEmpty);
      expect(models, isEmpty);
    });

    test('skips blocks without utilization', () {
      expect(claudeWindows({'five_hour': <String, Object?>{}}), isEmpty);
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
    test('surfaces the most-constrained binding limit as one weekly window',
        () {
      // The endpoint reports each model's single binding limit with no window
      // type. quotabot shows the account's tightest one as its weekly allowance,
      // with that model's reset - not a reset-delta guess that would mislabel a
      // near-term weekly reset as a "5h" window.
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
      expect(w, hasLength(1));
      expect(w.single.label, 'weekly');
      // b is the most-constrained (50% used); its reset is surfaced.
      expect(w.single.usedPercent, closeTo(50, 0.01));
      expect(w.single.resetsAt, now + 7200);
    });

    test('returns no live quota for absent or wrong-shaped model tables', () {
      expect(antigravityWindows({'models': <String, Object?>{}}, now), isEmpty);
      expect(antigravityWindows({'models': 'x'}, now), isEmpty);
      expect(antigravityWindows(null, now), isEmpty);
    });

    test('rejects every partial live model table atomically', () {
      final reset = now + 3600;
      final invalidSiblings = <Object?>[
        'wrong-shaped model row',
        <String, Object?>{},
        {'quotaInfo': 'wrong-shaped quota info'},
        {
          'quotaInfo': {'remainingFraction': 0.1},
        },
        {
          'quotaInfo': {
            'remainingFraction': 0.1,
            'resetTime': 'not-a-reset',
          },
        },
        {
          'quotaInfo': {
            'remainingFraction': 0.1,
            'resetTime': 0,
          },
        },
        {
          'quotaInfo': {
            'remainingFraction': 1.01,
            'resetTime': reset,
          },
        },
      ];

      for (final invalidSibling in invalidSiblings) {
        final response = {
          'models': {
            'Gemini 3.5 Flash (Medium)': {
              'quotaInfo': {
                'remainingFraction': 0.9,
                'resetTime': reset,
              },
            },
            'Gemini 3.5 Flash (High)': invalidSibling,
          },
        };

        expect(
          antigravityWindows(response, now),
          isEmpty,
          reason: 'an omitted sibling could be the account binding pool',
        );
        expect(
          antigravityModelQuotasFromLive(response),
          isEmpty,
          reason: 'a partial table must not be treated as exhaustive',
        );
      }
    });

    test('fraction parsing accepts exact 0 and 1', () {
      final response = {
        'models': {
          'empty': {
            'quotaInfo': {
              'remainingFraction': 0,
              'resetTime': now + 3600,
            },
          },
          'full': {
            'quotaInfo': {
              'remainingFraction': 1,
              'resetTime': now + 3600,
            },
          },
        },
      };

      final models = antigravityModelQuotasFromLive(response);
      expect(models.map((model) => model.model), ['empty', 'full']);
      expect(models.map((model) => model.usedPercent), [100, 0]);
      expect(antigravityWindows(response, now).single.usedPercent, 100);
    });

    test('does not infer a weekly window from a far-future baseline reset', () {
      final resp = {
        'models': {
          'weekly-real': {
            'quotaInfo': {
              'remainingFraction': 0.4, // 60% used
              'resetTime': now + 5 * 86400, // a genuine ~weekly cadence
            },
          },
          'baseline': {
            'quotaInfo': {
              'remainingFraction': 0.2, // 80% used - would win the bucket
              'resetTime': now + 30 * 86400, // a month out: not weekly
            },
          },
        },
      };
      final w = antigravityWindows(resp, now);
      // The far-future, higher-usage balance must not hijack the weekly bucket;
      // only the genuine ~weekly reset is asserted as a window.
      expect(w.map((e) => e.label), ['weekly']);
      expect(w.single.resetsAt, now + 5 * 86400);
      expect(w.single.usedPercent, closeTo(60, 0.01));
      // The baseline balance stays visible per-model, without a claimed cadence.
      expect(
        antigravityModelQuotasFromLive(resp).map((q) => q.model),
        containsAll(<String>['weekly-real', 'baseline']),
      );
    });

    test('resetLabel and parseReset', () {
      expect(resetLabel(now + 3600, now), '5h');
      expect(resetLabel(now + 30 * 3600, now), 'daily');
      expect(resetLabel(now + 5 * 86400, now), 'weekly');
      expect(parseReset(1234), 1234);
      expect(parseReset('5678'), 5678);
      expect(parseReset('2026-01-01T00:00:00Z'), isPositive);
      expect(parseReset(null), isNull);
      // A millisecond timestamp (numeric or string) is rescaled to seconds; a
      // real seconds value is never large enough to be mistaken for millis.
      expect(parseReset(1782088200000), 1782088200);
      expect(parseReset('1782088200000'), 1782088200);
      expect(parseReset(1782088200000000), 1782088200);
      expect(parseReset('1782088200000000'), 1782088200);
      expect(parseReset(1782088200000000000), 1782088200);
      expect(parseReset('1782088200000000000'), 1782088200);
      expect(parseReset(1782088200), 1782088200); // plain seconds untouched
      expect(parseReset(1782088200.5), isNull);
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
      final framed = Uint8List.fromList(_grpcFrame(0, payload));
      expect(grpcMessage(framed), payload);
    });

    test('grpcMessage rejects trailer-first and short input', () {
      expect(grpcMessage(Uint8List.fromList([0x80, 0, 0, 0, 0])), isEmpty);
      expect(grpcMessage(Uint8List.fromList([0, 0])), isEmpty);
    });

    test('grpcMessage enforces body trailer status and frame integrity', () {
      final data = _grpcFrame(0, [1, 2, 3]);
      final okTrailer = _grpcFrame(0x80, ascii.encode('grpc-status: 0\r\n'));
      final denied = _grpcFrame(0x80, ascii.encode('grpc-status: 16\r\n'));
      final malformed =
          _grpcFrame(0x80, ascii.encode('grpc-message: nope\r\n'));

      expect(
          grpcMessage(Uint8List.fromList([...data, ...okTrailer])), [1, 2, 3]);
      expect(grpcMessage(Uint8List.fromList([...data, ...denied])), isEmpty);
      expect(grpcMessage(Uint8List.fromList([...data, ...malformed])), isEmpty);
      expect(grpcMessage(Uint8List.fromList([...data, ...data])), isEmpty);
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

    test('grokWindow reads the pool percent by field, never the first float',
        () {
      const now = 1782000000;
      // A per-product breakdown float precedes the pool total in the bytes;
      // the schema-anchored read must still report the total.
      final config = <int>[
        ..._messageField(7, [..._varintField(1, 5), ..._float32Field(2, 66)]),
        ..._float32Field(1, 73),
        ..._messageField(4, _varintField(1, now - 3 * 86400)),
        ..._messageField(5, _varintField(1, now + 4 * 86400)),
      ];
      final w = grokWindow(_messageField(1, config), now);
      expect(w, isNotNull);
      expect(w!.usedPercent, 73);
      expect(w.resetsAt, now + 4 * 86400);
    });

    test('grokWindow takes the reset from the window end, not the start', () {
      const now = 1782000000;
      final config = <int>[
        ..._float32Field(1, 100),
        ..._messageField(4, _varintField(1, now + 3600)),
        ..._messageField(5, _varintField(1, now + 7200)),
      ];
      final w = grokWindow(_messageField(1, config), now);
      expect(w, isNotNull);
      expect(w!.usedPercent, 100);
      expect(w.resetsAt, now + 7200);
    });

    test(
        'grokWindow rejects an out-of-bounds pool total without falling '
        'back to a breakdown percent', () {
      const now = 1782000000;
      final config = <int>[
        ..._messageField(7, [..._varintField(1, 5), ..._float32Field(2, 66)]),
        ..._float32Field(1, 100.5),
        ..._messageField(5, _varintField(1, now + 7200)),
      ];
      final w = grokWindow(_messageField(1, config), now);
      expect(w, isNull);
    });

    test('grokWindow accepts exact 0 and 100 percent boundaries', () {
      const now = 1782000000;
      for (final percent in [0.0, 100.0]) {
        final config = <int>[
          ..._float32Field(1, percent),
          ..._messageField(5, _varintField(1, now + 7200)),
        ];
        expect(
          grokWindow(_messageField(1, config), now)!.usedPercent,
          percent,
        );
      }
    });

    test('grokWindow keeps the anchored read despite trailing garbage', () {
      const now = 1782000000;
      final config = <int>[
        ..._messageField(7, [..._varintField(1, 5), ..._float32Field(2, 66)]),
        ..._float32Field(1, 73),
        ..._messageField(5, _varintField(1, now + 7200)),
      ];
      final w = grokWindow([..._messageField(1, config), 0xff], now);
      expect(w, isNotNull);
      expect(w!.usedPercent, 73);
      expect(w.resetsAt, now + 7200);
    });

    test('hostile length varints are rejected, not thrown', () {
      // A 9-byte length varint decodes near 2^62; an addition-form bounds
      // check would wrap negative and throw in sublist.
      final hostile = [0x0a, 255, 255, 255, 255, 255, 255, 255, 255, 0x7f];
      expect(grokWindow(hostile, 1782000000), isNull);
      expect((ProtoScan()..walk(hostile)).floats, isEmpty);
    });

    test('grokWindow falls back to the scan on malformed config bytes', () {
      // Field 1 wraps a truncated tag, so the anchored read fails; the
      // schema-less scan still finds the bare percent that follows.
      final msg = <int>[
        ..._messageField(1, [0x0d]),
        ..._float32Field(2, 41)
      ];
      final w = grokWindow(msg, 1782000000);
      expect(w, isNotNull);
      expect(w!.usedPercent, 41);
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

    test('kiroWindows keeps the window when resetDate is a numeric epoch', () {
      // A numeric resetDate previously hit an `as String?` cast that threw and
      // discarded every parseable window; parseReset now tolerates it.
      final ws = kiroWindows({
        'usageBreakdowns': [
          {
            'currentUsage': 5000,
            'usageLimit': 10000,
            'percentageUsed': 50,
            'resetDate': 1782088200,
            'displayName': 'Credit',
          },
        ],
      }, 1782000000);
      expect(ws.length, 1);
      expect(ws.first.percent, closeTo(50, 0.1));
      expect(ws.first.resetsAt, 1782088200);
    });

    test('kiroWindows rejects invalid percent and negative count evidence', () {
      expect(
        kiroWindows({
          'usageBreakdowns': [
            {'percentageUsed': -1},
          ],
        }, 1782000000),
        isEmpty,
      );
      expect(
        kiroWindows({
          'usageBreakdowns': [
            {'currentUsage': -1, 'usageLimit': 100},
          ],
        }, 1782000000),
        isEmpty,
      );
      expect(
        kiroWindows({
          'usageBreakdowns': [
            {'percentageUsed': 0},
            {'percentageUsed': 100},
          ],
        }, 1782000000)
            .map((window) => window.usedPercent),
        [0, 100],
      );
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
      expect(windsurfWindows(<String, Object?>{}, now), isEmpty);
    });

    test('windsurf rejects invalid percentages and negative counters', () {
      for (final invalid in <Object?>[
        -1,
        101,
        double.nan,
        double.infinity,
        true,
        <String, Object?>{},
      ]) {
        expect(
          windsurfWindows({
            'daily_quota_remaining_percent': invalid,
          }, now),
          isEmpty,
        );
      }
      expect(
        windsurfWindows({'usedMessages': -1, 'messages': 100}, now),
        isEmpty,
      );
      expect(
        windsurfWindows({'usedMessages': 101, 'messages': 100}, now)
            .single
            .usedPercent,
        100,
        reason: 'real overage is exhausted rather than invalid headroom',
      );
    });

    test('windsurf duplicate quota shapes keep the tightest pool', () {
      final windows = windsurfWindows({
        'dailyQuotaUsedPercent': 20,
        'quotaUsage': {
          'daily': {'usedPercent': 85},
        },
      }, now);
      expect(windows.single.label, 'daily');
      expect(windows.single.usedPercent, 85);
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

    test('cursor rejects negative counters and keeps legitimate overage spent',
        () {
      expect(
        cursorWindows({
          'planUsage': {'used': -1, 'limit': 100},
        }, now),
        isEmpty,
      );
      expect(
        cursorWindows({
          'planUsage': {'used': 120, 'limit': 100},
        }, now)
            .single
            .usedPercent,
        100,
      );
      expect(
        cursorWindows({
          'usageBreakdowns': [
            {'percentageUsed': -5},
          ],
        }, now),
        isEmpty,
      );
    });

    test('cursor duplicate monthly shapes keep the tightest pool', () {
      final windows = cursorWindows({
        'used': 10,
        'limit': 100,
        'monthlyUsage': {'used': 90, 'limit': 100},
      }, now);
      expect(windows.single.usedPercent, 90);
    });
  });
}
