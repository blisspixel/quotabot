import 'dart:convert';

import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/parsing.dart';
import 'package:test/test.dart';

import 'ag_proto_builder.dart';

void main() {
  group('antigravityModelQuotas', () {
    test('extracts per-model quota from the raw model list', () {
      final quotas = antigravityModelQuotas(
        agModelList([
          agModelEntry('Gemini 3.5 Flash', remaining: 0.985, reset: 1782098301),
          agModelEntry('Claude Opus 4.6', remaining: 1.0, reset: 1782098733),
        ]),
      );

      expect(
          quotas.map((q) => q.model), ['Gemini 3.5 Flash', 'Claude Opus 4.6']);
      expect(quotas[0].usedPercent, closeTo(1.5, 1e-9));
      expect(quotas[0].resetsAt, 1782098301);
      expect(quotas[0].remainingPercent, closeTo(98.5, 1e-9));
      expect(quotas[1].usedPercent, 0);
      expect(quotas[1].resetsAt, 1782098733);
    });

    test('descends the nested base64 wrapping of the stored value', () {
      final bytes = base64Decode(
        agUserStatusValue([
          agModelEntry('Gemini 3.1 Pro', remaining: 0.5, reset: 1782098301),
        ]),
      );

      final quotas = antigravityModelQuotas(bytes);
      expect(quotas.single.model, 'Gemini 3.1 Pro');
      expect(quotas.single.usedPercent, 50);
    });

    test('rolls up effort variants that share a pool to the base model', () {
      final quotas = antigravityModelQuotas(
        agModelList([
          agModelEntry('Gemini 3.5 Flash (Medium)',
              remaining: 0.985, reset: 1782098301, category: 'Fast'),
          agModelEntry('Gemini 3.5 Flash (High)',
              remaining: 0.985, reset: 1782098301),
          agModelEntry('Gemini 3.5 Flash (Low)',
              remaining: 0.985, reset: 1782098301, badge: 'Limited time'),
        ]),
      );

      expect(quotas, hasLength(1));
      expect(quotas.single.model, 'Gemini 3.5 Flash');
      expect(quotas.single.usedPercent, closeTo(1.5, 1e-9));
      expect(quotas.single.category, 'Fast');
      expect(quotas.single.note, 'Limited time');
    });

    test('keeps variants separate when their quota diverges', () {
      final quotas = antigravityModelQuotas(
        agModelList([
          agModelEntry('Sonar (Low)', remaining: 0.9, reset: 1782098301),
          agModelEntry('Sonar (High)', remaining: 0.5, reset: 1782098301),
        ]),
      );

      expect(quotas.map((q) => q.model), ['Sonar (Low)', 'Sonar (High)']);
      expect(quotas[0].usedPercent, closeTo(10, 1e-9));
      expect(quotas[1].usedPercent, closeTo(50, 1e-9));
    });

    test('ignores sub-records that have a name but no quota submessage', () {
      // A "Recommended" list and mime-type entries carry a field-1 string but
      // no field-15 quota, so they must never surface as a model.
      final recommended = pbLenField(1, [
        ...pbStringField(1, 'Recommended'),
        ...pbStringField(2, 'Gemini 3.5 Flash'),
      ]);
      final mime = pbLenField(1, [
        ...pbStringField(1, 'application/json'),
        ...pbVarintField(2, 1),
      ]);
      final model = pbLenField(
        1,
        agModelEntry('Gemini 3.5 Flash', remaining: 0.985, reset: 1782098301),
      );

      final quotas =
          antigravityModelQuotas([...recommended, ...mime, ...model]);
      expect(quotas.map((q) => q.model), ['Gemini 3.5 Flash']);
    });

    test('rejects an implausible remaining fraction', () {
      final quotas = antigravityModelQuotas(
        agModelList([
          agModelEntry('Broken', remaining: 5.0, reset: 1782098301),
          agModelEntry('Good', remaining: 0.75, reset: 1782098301),
        ]),
      );

      expect(quotas.map((q) => q.model), ['Good']);
      expect(quotas.single.usedPercent, closeTo(25, 1e-9));
    });

    test('tolerates a missing reset', () {
      final quotas = antigravityModelQuotas(
        agModelList([agModelEntry('Gemini 3.5 Flash', remaining: 0.8)]),
      );
      expect(quotas.single.usedPercent, closeTo(20, 1e-9));
      expect(quotas.single.resetsAt, isNull);
    });

    test('returns nothing for an empty or non-model blob', () {
      expect(antigravityModelQuotas(const []), isEmpty);
      expect(antigravityModelQuotas(utf8.encode('not a protobuf at all')),
          isEmpty);
    });
  });

  group('ModelQuota', () {
    test('round-trips through JSON', () {
      const q = ModelQuota(
        model: 'Gemini 3.5 Flash',
        usedPercent: 1.5,
        resetsAt: 1782098301,
        category: 'Fast',
        note: 'Limited time',
      );
      final back = ModelQuota.fromJson(q.toJson());
      expect(back.model, q.model);
      expect(back.usedPercent, q.usedPercent);
      expect(back.resetsAt, q.resetsAt);
      expect(back.category, q.category);
      expect(back.note, q.note);
    });

    test('clamps a hostile percent and drops a non-finite reset on reload', () {
      final back = ModelQuota.fromJson({
        'model': 'X',
        'used_percent': 250,
        'resets_at': double.infinity,
      });
      expect(back.usedPercent, 100);
      expect(back.resetsAt, isNull);
      expect(back.remainingPercent, 0);
      expect(back.exhausted, isTrue);
    });

    test('travels with ProviderQuota through JSON', () {
      final q = ProviderQuota(
        provider: 'antigravity',
        displayName: 'Antigravity',
        account: 'me@example.com',
        asOf: 1782098301,
        modelQuotas: const [
          ModelQuota(model: 'Gemini 3.5 Flash', usedPercent: 1.5),
          ModelQuota(model: 'Claude Opus 4.6', usedPercent: 0),
        ],
        perMachine: true,
      );
      final back = ProviderQuota.fromJson(
        jsonDecode(jsonEncode(q.toJson())) as Map<String, dynamic>,
      );
      expect(back.modelQuotas.map((m) => m.model),
          ['Gemini 3.5 Flash', 'Claude Opus 4.6']);
      expect(back.modelQuotas.first.usedPercent, 1.5);
      expect(back.perMachine, isTrue);
    });
  });
}
