import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

const _now = 1782000000;

ProviderQuota _cloud(
  String id,
  double usedPercent, {
  bool stale = false,
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: 'a',
      asOf: _now,
      stale: stale,
      windows: [QuotaWindow(label: 'weekly', usedPercent: usedPercent)],
    );

ProviderQuota _local(String id, List<ModelInfo> models) => ProviderQuota(
      provider: id,
      displayName: id,
      account: 'local',
      asOf: _now,
      kind: 'local',
      models: models,
    );

void main() {
  test('cloud models come from the catalog and inherit provider budget', () {
    final reg = buildModelRegistry(
      [_cloud('claude', 20)],
      _now,
      catalog: {
        'claude': [
          const ModelInfo(id: 'claude-opus', contextTokens: 200000),
        ],
      },
    );
    expect(reg, hasLength(1));
    final e = reg.first;
    expect(e.provider, 'claude');
    expect(e.local, isFalse);
    expect(e.headroomPercent, 80);
    expect(e.gatingWindow, 'weekly');
    expect(e.available, isTrue);
    expect(e.model.contextTokens, 200000);
  });

  test('local models come from the snapshot, no catalog needed', () {
    final reg = buildModelRegistry(
      [
        _local('ollama', const [
          ModelInfo(id: 'llama3:8b', local: true, loaded: true),
        ]),
      ],
      _now,
    );
    expect(reg, hasLength(1));
    expect(reg.first.local, isTrue);
    expect(reg.first.headroomPercent, isNull);
    expect(reg.first.available, isTrue);
  });

  test('available cloud leads, local is the tail fallback', () {
    final reg = buildModelRegistry(
      [
        _cloud('codex', 10), // 90% free
        _cloud('claude', 95), // 5% free, still available
        _local('ollama', const [ModelInfo(id: 'm', local: true)]),
      ],
      _now,
      catalog: {
        'codex': [const ModelInfo(id: 'codex-x')],
        'claude': [const ModelInfo(id: 'claude-x')],
      },
    );
    expect(reg.map((e) => e.model.id).toList(), ['codex-x', 'claude-x', 'm']);
  });

  test('a spent cloud model sorts below an available local fallback', () {
    final reg = buildModelRegistry(
      [
        _cloud('claude', 100), // spent
        _local('ollama', const [ModelInfo(id: 'local-m', local: true)]),
      ],
      _now,
      catalog: {
        'claude': [const ModelInfo(id: 'claude-x')],
      },
    );
    expect(reg.first.model.id, 'local-m'); // available beats spent
    expect(reg.last.available, isFalse);
  });

  test('a cloud provider absent from the catalog contributes no models', () {
    final reg = buildModelRegistry([_cloud('grok', 30)], _now);
    expect(reg, isEmpty);
  });

  test('entry JSON merges the model with its budget', () {
    final json = buildModelRegistry(
      [_cloud('claude', 20)],
      _now,
      catalog: {
        'claude': [const ModelInfo(id: 'claude-opus', tools: true)],
      },
    ).first.toJson();
    expect(json['id'], 'claude-opus');
    expect(json['tools'], isTrue);
    expect(json['provider'], 'claude');
    expect(json['headroom_percent'], 80);
    expect(json['gating_window'], 'weekly');
  });
}
