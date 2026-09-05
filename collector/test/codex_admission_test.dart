import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/codex.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/decision.dart';
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_read_gate.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:quotabot_collector/routing_context.dart';
import 'package:quotabot_collector/schema_contracts.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

const _catalog = {
  'codex': [
    ModelInfo(
        id: 'codex-test',
        reasoning: 'reasoning',
        tier: 'standard',
        vision: true),
    ModelInfo(id: 'codex-other', reasoning: 'reasoning', tier: 'standard'),
  ],
};

void main() {
  late Directory temp;
  late int now;
  late String identity;
  late int gateNow;
  late ProviderReadGate readGate;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_codex_admission_');
    setQuotabotDirOverrideForTesting(temp);
    now = nowEpoch();
    gateNow = now;
    readGate = ProviderReadGate(
      directory: Directory('${temp.path}/read-gates'),
      clock: () => gateNow,
      jitter: (_) => 0,
      hardenDirectory: (_) {},
      hardenFile: (_) {},
    );
    identity = opaqueCredentialIdentity('codex', 'synthetic-admission');
  });
  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    temp.deleteSync(recursive: true);
  });

  Map<String, dynamic> pool({
    double used = 50,
    Map<String, Object?> flags = const {
      'allowed': true,
      'limit_reached': false
    },
  }) =>
      {
        ...flags,
        'primary_window': {
          'used_percent': used,
          'limit_window_seconds': 604800,
          'reset_at': now + 86400,
        },
        'secondary_window': null,
      };

  Future<ProviderQuota> collect(Map<String, dynamic> body) async {
    var reads = 0;
    final result = await CodexAdapter(
      readGate: readGate,
      authFile: File('${temp.path}/missing-host-auth.json'),
      disconnectReader: () => false,
      grantCredential: () async => OpenAiCredential(
        accessToken: 'synthetic-never-sent-token',
        identity: identity,
      ),
      client: MockClient((request) async {
        reads++;
        expect(request.method, 'GET');
        expect(request.url.toString(),
            'https://chatgpt.com/backend-api/wham/usage');
        return http.Response(jsonEncode(body), 200);
      }),
    ).collect();
    expect(reads, 1);
    return result;
  }

  for (final entry in <String, (Map<String, Object?>, RequestAdmission)>{
    'denied pair': (
      {'allowed': false, 'limit_reached': true},
      RequestAdmission.denied
    ),
    'negative allowed alone': ({'allowed': false}, RequestAdmission.denied),
    'reached alone': ({'limit_reached': true}, RequestAdmission.denied),
    'allowed pair': (
      {'allowed': true, 'limit_reached': false},
      RequestAdmission.allowed
    ),
    'allowed alone': ({'allowed': true}, RequestAdmission.allowed),
    'not reached alone': ({'limit_reached': false}, RequestAdmission.allowed),
    'absent': ({}, RequestAdmission.notReported),
  }.entries) {
    test(
        '${entry.key} reaches DTO, registry and provider gates without changing usage',
        () async {
      final quota = await collect({'rate_limit': pool(flags: entry.value.$1)});
      final roundTrip =
          ProviderQuota.fromJson(sanitizeProviderQuota(quota).toJson());
      final admission = entry.value.$2;
      expect(quota.ok, isTrue);
      expect(roundTrip.requestAdmission, admission);
      expect(roundTrip.windows.single.usedPercent, 50);
      expect(isTrustedQuotaEvidenceAt(roundTrip, now), isTrue);
      expect(providerHeadroom(roundTrip, now), 50);
      expect(providerAvailability(roundTrip, now).available,
          !admission.blocksRequests);
      expect(providerWithMostHeadroom([roundTrip], now) != null,
          !admission.blocksRequests);
      final checked = availabilityResponse([roundTrip], now, 'codex', identity);
      expect(checked['available'], !admission.blocksRequests);
      expect(checked['headroom_percent'], 50);
      expect(mostHeadroomResponse([roundTrip], now)['provider'] != null,
          !admission.blocksRequests);
      for (final budget in [ModelBudgetPolicy.any, ModelBudgetPolicy.quota]) {
        final entries = buildModelRegistry([roundTrip], now,
            catalog: _catalog,
            requirements: ModelRequirements(budgetPolicy: budget));
        expect(entries, hasLength(2));
        expect(entries.every((model) => model.available),
            !admission.blocksRequests);
        expect(entries.every((model) => model.headroomPercent == 50), isTrue);
        expect(entries.every((model) => model.requestAdmission == admission),
            isTrue);
      }
      final route = decide([roundTrip], now,
              context: providerRouteDecisionContext([roundTrip], now,
                  catalog: _catalog))
          .route;
      expect(route.recommended != null, !admission.blocksRequests);
      if (admission.blocksRequests) {
        expect(route.decisionCode, RouteDecisionCode.requestBlocked);
        expect(route.receipt.alternatives.single.verdict,
            RouteCandidateVerdict.requestDenied);
        expect(route.receipt.alternatives.single.rawHeadroomPercent, 50);
        expect(route.fallback.kind, RouteFallbackKind.passthrough);
      }
    });
  }

  test('malformed or contradictory flags still reject the atomic observation',
      () async {
    for (final flags in <Map<String, Object?>>[
      {'allowed': 'false'},
      {'limit_reached': null},
      {'allowed': true, 'limit_reached': true},
      {'allowed': false, 'limit_reached': false},
    ]) {
      // Each row is an independent parser case after the prior read's retry
      // deadline. The dedicated read-gate suite covers intervening deferral.
      gateNow += 1200;
      final quota = await collect({'rate_limit': pool(flags: flags)});
      expect(quota.ok, isFalse, reason: flags.toString());
      expect(quota.windows, isEmpty);
      expect(providerAvailability(quota, now).available, isFalse);
    }
  });

  test(
      'positive admission cannot revive spent, stale, drifted or expired evidence',
      () async {
    final healthy = await collect({'rate_limit': pool()});
    final spent = await collect({'rate_limit': pool(used: 100)});
    final expired = ProviderQuota.fromJson({
      ...healthy.toJson(),
      'windows': [
        {'label': 'weekly', 'used_percent': 50, 'resets_at': now}
      ],
    });
    for (final quota in [
      spent,
      healthy.asStale('offline'),
      healthy.withProviderDrift('synthetic drift', now),
      expired
    ]) {
      expect(quota.requestAdmission, RequestAdmission.allowed);
      expect(providerAvailability(quota, now).available, isFalse);
      expect(
          buildModelRegistry([quota], now, catalog: _catalog)
              .every((entry) => !entry.available),
          isTrue);
    }
  });

  test(
      'named denial stays scoped and is explained when it is the only matching capability',
      () async {
    final quota = await collect({
      'rate_limit': pool(used: 20),
      'additional_rate_limits': [
        {
          'limit_name': 'codex-test',
          'rate_limit':
              pool(used: 10, flags: {'allowed': false, 'limit_reached': true})
        },
      ],
    });
    expect(providerAvailability(quota, now).available, isTrue);
    final entries = buildModelRegistry([quota], now, catalog: _catalog);
    expect(
        entries
            .singleWhere((entry) => entry.model.id == 'codex-other')
            .available,
        isTrue);
    final denied =
        entries.singleWhere((entry) => entry.model.id == 'codex-test');
    expect(denied.available, isFalse);
    expect(denied.headroomPercent, 80);
    expect(denied.toJson()['request_admission'], 'denied');
    final unrestricted =
        providerRouteDecisionContext([quota], now, catalog: _catalog);
    expect(decide([quota], now, context: unrestricted).recommended, isNotNull);
    final visionOnly = providerRouteDecisionContext([quota], now,
        catalog: _catalog,
        routeRequirements: const ModelRequirements(requireVision: true));
    final route = decide([quota], now, context: visionOnly).route;
    expect(route.recommended, isNull);
    expect(route.receipt.alternatives.single.verdict,
        RouteCandidateVerdict.requestDenied);
    expect(route.ranked.single.requestAdmission, RequestAdmission.denied);
    expect(quota.requestAdmission, RequestAdmission.allowed);
  });

  test(
      'duplicate named rows and equal model matches cannot erase a lower-use denial',
      () async {
    for (final reverse in [false, true]) {
      final rows = [
        {
          'limit_name': 'codex-test',
          'rate_limit': pool(used: 10, flags: {'allowed': false})
        },
        {'limit_name': 'codex-test', 'rate_limit': pool(used: 55)},
      ];
      final quota = await collect({
        'rate_limit': pool(used: 20),
        'additional_rate_limits': reverse ? rows.reversed.toList() : rows
      });
      expect(quota.modelQuotas.single.usedPercent, 55);
      expect(
          quota.modelQuotas.single.requestAdmission, RequestAdmission.denied);
      final duplicated = ProviderQuota.fromJson({
        ...quota.toJson(),
        'model_quotas': [
          quota.modelQuotas.single.toJson(),
          {
            'model': 'codex-test',
            'used_percent': 60,
            'resets_at': now + 86400,
            'request_admission': 'allowed'
          },
        ],
      });
      final matching = buildModelRegistry([duplicated], now, catalog: _catalog)
          .singleWhere((entry) => entry.model.id == 'codex-test');
      expect(matching.available, isFalse);
      expect(matching.headroomPercent, 40);
      expect(matching.requestAdmission, RequestAdmission.denied);
    }
  });

  test(
      'denied observation replaces cache and a later positive observation recovers',
      () async {
    final denied = await collect({
      'rate_limit': pool(flags: {'allowed': false})
    });
    final accepted = admitAndCacheQuotaEvidence(denied,
        observedAt: now, observedAtMicros: now * 1000000);
    expect(accepted.requestAdmission, RequestAdmission.denied);
    final cached = loadAccountSnapshot('codex', identity)!;
    expect(cached.requestAdmission, RequestAdmission.denied);
    expect(cached.windows.single.usedPercent, 50);
    expect(providerAvailability(cached, now).available, isFalse);
    final recovered = ProviderQuota.fromJson({
      ...denied.toJson(),
      'as_of': now + 1,
      'request_admission': 'allowed',
    });
    final next = admitAndCacheQuotaEvidence(recovered,
        observedAt: now + 1, observedAtMicros: (now + 1) * 1000000);
    expect(next.requestAdmission, RequestAdmission.allowed);
    expect(next.driftReason, isNull);
    expect(providerAvailability(next, now + 1).available, isTrue);
  });

  test('legacy omission and unknown persisted values have distinct semantics',
      () async {
    final original = await collect({'rate_limit': pool(flags: {})});
    expect(original.toJson().containsKey('request_admission'), isFalse);
    expect(
        const ModelQuota(model: 'codex-test')
            .toJson()
            .containsKey('request_admission'),
        isFalse);
    for (final unknown in <Object?>[
      'future-state',
      null,
      true,
      1,
      <String, Object?>{}
    ]) {
      final quota = ProviderQuota.fromJson({
        ...original.toJson(),
        'request_admission': unknown,
        'model_quotas': [
          {
            'model': 'codex-test',
            'used_percent': 10,
            'resets_at': now + 86400,
            'request_admission': unknown
          }
        ],
      });
      expect(quota.requestAdmission, RequestAdmission.unresolved);
      expect(quota.modelQuotas.single.requestAdmission,
          RequestAdmission.unresolved);
      expect(quota.toJson()['request_admission'], 'unresolved');
      expect(providerAvailability(quota, now).available, isFalse);
      final route = suggestRoute([quota], now);
      expect(route.receipt.alternatives.single.verdict,
          RouteCandidateVerdict.requestAdmissionUnresolved);
      expect(
          validateQuotabotV1Snapshot({
            'schema': 'quotabot.v1',
            'generated_at': now,
            'providers': [quota.toJson()]
          }),
          isEmpty);
      expect(
          validateQuotabotV1Snapshot({
            'schema': 'quotabot.v1',
            'generated_at': now,
            'providers': [
              {...original.toJson(), 'request_admission': unknown}
            ]
          }),
          isNotEmpty);
    }
  });

  test(
      'snapshot transformations preserve the admission attached to measured evidence',
      () async {
    final quota = await collect({
      'rate_limit': pool(flags: {'allowed': false}),
      'additional_rate_limits': [
        {
          'limit_name': 'codex-test',
          'rate_limit': pool(flags: {'limit_reached': true})
        }
      ]
    });
    for (final copy in [
      quota.asStale('offline'),
      quota.withSuspect('synthetic concern'),
      quota.withProviderDrift('synthetic drift', now),
      quota.withLocalHardware(LocalHardwareInfo(asOf: now)),
      quota.withSupplementalManualQuota(SupplementalManualQuota(
          displayName: 'manual annotation', asOf: now, windows: const [])),
      sanitizeProviderQuota(quota),
    ]) {
      expect(copy.requestAdmission, RequestAdmission.denied);
      expect(copy.modelQuotas.single.requestAdmission, RequestAdmission.denied);
      expect(copy.windows.single.usedPercent, 50);
    }
    expect(quota.asProviderDriftQuarantine('synthetic', now).requestAdmission,
        RequestAdmission.denied);
  });

  test('unknown persisted model admission blocks only the matching model',
      () async {
    final original = await collect({'rate_limit': pool()});
    final quota = ProviderQuota.fromJson({
      ...original.toJson(),
      'model_quotas': [
        {
          'model': 'codex-test',
          'used_percent': 10,
          'resets_at': now + 86400,
          'request_admission': 'future-state'
        }
      ],
    });
    final entries = buildModelRegistry([quota], now, catalog: _catalog);
    expect(providerAvailability(quota, now).available, isTrue);
    expect(
        entries
            .singleWhere((entry) => entry.model.id == 'codex-test')
            .available,
        isFalse);
    expect(
        entries
            .singleWhere((entry) => entry.model.id == 'codex-other')
            .available,
        isTrue);
    expect(suggestModel([quota], now, catalog: _catalog).recommended?.model.id,
        'codex-other');
  });

  test('admission denied on one account does not cross the account boundary',
      () async {
    final denied = await collect({
      'rate_limit': pool(flags: {'allowed': false})
    });
    final other = ProviderQuota.fromJson({
      ...denied.toJson(),
      'account': 'synthetic-other-account',
      'request_admission': 'allowed',
    });
    final route = decide([denied, other], now,
        context: providerRouteDecisionContext([denied, other], now,
            catalog: _catalog));
    expect(route.recommended?.account, 'synthetic-other-account');
    expect(providerWithMostHeadroom([denied, other], now)?.account,
        'synthetic-other-account');
    expect(suggestModel([denied], now, catalog: _catalog).reason,
        contains('request admission'));
  });

  test('unknown additive admission cannot create a local-provider gate bypass',
      () {
    final quota = ProviderQuota.fromJson({
      'provider': 'ollama',
      'display_name': 'Ollama',
      'account': 'fixture',
      'kind': 'local',
      'as_of': now,
      'request_admission': 'future-state',
      'models': [
        {'id': 'local-test', 'local': true, 'loaded': true}
      ],
    });
    expect(isLocalRuntimeReachableAt(quota, now), isTrue);
    expect(isLocalRuntimeAvailableAt(quota, now), isFalse);
    expect(anyProviderUsable([quota], now), isFalse);
    expect(suggestRoute([quota], now, preferLocal: true).recommended, isNull);
    expect(buildModelRegistry([quota], now).single.available, isFalse);
  });
}
