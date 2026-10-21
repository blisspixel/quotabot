import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

const _now = 1_700_000_000;

void main() {
  test('an empty hard-task suggestion names the local tier gate', () {
    final suggestion = suggestModel(
      [
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: 'local',
          asOf: _now,
          kind: ProviderQuotaKind.local,
          models: const [
            ModelInfo(
              id: 'llama3.2',
              tools: true,
              reasoning: 'reasoning',
              contextTokens: 8192,
            ),
          ],
        ),
      ],
      _now,
      requirements: taskProfile('hard'),
    );

    expect(suggestion.ranked, isEmpty);
    expect(suggestion.recommended, isNull);
    expect(suggestion.excluded, hasLength(1));
    expect(suggestion.excluded.first.gate, 'tier');
    expect(suggestion.excluded.first.model, 'llama3.2');
    expect(
      suggestion.reason,
      contains(
          'local models have no tier, so a tier floor such as --task=hard'),
    );
    final json = suggestion.toJson(_now);
    expect(json['excluded'], [
      {'model': 'llama3.2', 'provider': 'ollama', 'gate': 'tier'},
    ]);
  });

  test('a successful suggestion omits the excluded list', () {
    final suggestion = suggestModel(
      [
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: 'local',
          asOf: _now,
          kind: ProviderQuotaKind.local,
          models: const [
            ModelInfo(id: 'llama3.2', tools: true),
          ],
        ),
      ],
      _now,
      requirements:
          const ModelRequirements(budgetPolicy: ModelBudgetPolicy.local),
    );
    expect(suggestion.recommended?.model.id, 'llama3.2');
    expect(suggestion.excluded, isEmpty);
    expect(suggestion.toJson(_now).containsKey('excluded'), isFalse);
  });
}
