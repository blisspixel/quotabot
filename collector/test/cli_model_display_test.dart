import 'dart:async';

import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

import '../bin/collect.dart' as cli;

const _now = 1788600000;

String _render(void Function() render) {
  final lines = <String>[];
  runZoned(render,
      zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line)));
  return lines.join('\n');
}

ProviderQuota _quota(List<ModelInfo> models) => ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: 'fixture',
      asOf: _now,
      kind: ProviderQuotaKind.local,
      models: models,
      active: true,
      localHardware: const LocalHardwareInfo(
        asOf: _now,
        systemMemoryTotalBytes: 16 * 1024 * 1024 * 1024,
        systemMemoryAvailableBytes: 12 * 1024 * 1024 * 1024,
      ),
    );

void main() {
  setUp(() {
    cli.style = const AnsiStyle(false);
  });

  for (final value in ['denied', 'future-admission']) {
    test('$value model display retains measured quota and explains exclusion',
        () {
      final quota = ProviderQuota.fromJson({
        'provider': 'codex',
        'display_name': 'Codex',
        'account': 'fixture',
        'as_of': _now,
        'request_admission': value,
        'windows': [
          {'label': 'weekly', 'used_percent': 50, 'resets_at': _now + 3600}
        ],
      });
      const catalog = {
        'codex': [
          ModelInfo(id: 'codex-test', tier: 'standard', reasoning: 'reasoning')
        ]
      };
      final registry = buildModelRegistry([quota], _now, catalog: catalog);
      final output = _render(() => cli.printModelRegistry(registry, _now));
      expect(registry.single.available, isFalse);
      expect(output, contains('50% free'));
      expect(
          output,
          contains(value == 'denied'
              ? 'requests denied'
              : 'request status unverified'));
      expect(output, isNot(contains('spent')));
      final suggested = suggestModel([quota], _now, catalog: catalog);
      expect(suggested.recommended, isNull);
      expect(_render(() => cli.printModelSuggestion(suggested, _now)),
          contains('request admission'));
    });
  }

  test('model inspection does not label upstream evidence as local readiness',
      () {
    final registry = buildModelRegistry([
      _quota(const [
        ModelInfo(
            id: 'private-alias',
            loaded: true,
            upstreamRouting: UpstreamRouting.declared),
        ModelInfo(
            id: 'partial-alias',
            loaded: true,
            upstreamRouting: UpstreamRouting.unresolved),
        ModelInfo(id: 'cloud-alias', loaded: true, cloudOffloaded: true),
      ])
    ], _now);
    final output = _render(() => cli.printModelRegistry(registry, _now));
    expect(output, contains('private-alias'));
    expect(output, contains('upstream'));
    expect(output, contains('partial-alias'));
    expect(output, contains('unverified'));
    expect(output, contains('cloud-alias'));
    expect(output, contains('location/cost unverified'));
    expect(output, contains('unavailable'));
    expect(output, isNot(contains('loaded')));
    expect(output, isNot(contains('cold')));
    expect(output, isNot(contains(' fit')));
    expect(output, isNot(contains('% free')));
  });

  test('explicit any-budget suggestion retains its location and cost caveat',
      () {
    final suggestion = suggestModel([
      _quota(const [
        ModelInfo(
            id: 'private-alias',
            loaded: true,
            tools: true,
            upstreamRouting: UpstreamRouting.declared)
      ])
    ], _now, requirements: const ModelRequirements(requireTools: true));
    final output = _render(() => cli.printModelSuggestion(suggestion, _now));
    expect(output, contains('private-alias'));
    expect(output, contains('declared upstream routing'));
    expect(output, contains('execution location and cost are unverified'));
    expect(output, contains('location/cost unverified'));
    expect(output, isNot(contains('loaded')));
    expect(output, isNot(contains('cold')));
    expect(output, isNot(contains(' fit')));
    expect(output, isNot(contains('% free')));
    expect(output, isNot(contains('paid')));
  });

  test('ordinary model display still renders its loaded and cold evidence', () {
    final registry = buildModelRegistry([
      _quota(const [
        ModelInfo(id: 'loaded-model', loaded: true),
        ModelInfo(id: 'cold-model', sizeBytes: 1024 * 1024 * 1024),
        ModelInfo(id: 'embedding-model', loaded: true, embedding: true),
      ])
    ], _now);
    final output = _render(() => cli.printModelRegistry(registry, _now));
    expect(output, contains('loaded-model'));
    expect(output, contains('cold-model'));
    expect(output, contains('comfortable fit'));
    final embeddingLine = output
        .split('\n')
        .singleWhere((line) => line.contains('embedding-model'));
    expect(embeddingLine, contains('embedding'));
    expect(embeddingLine, isNot(contains('loaded')));
    expect(embeddingLine, isNot(contains('cold')));
  });
}
