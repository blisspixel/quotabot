import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/claude.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_adapters.dart';
import 'package:quotabot_collector/provider_read_gate.dart';
import 'package:quotabot_collector/util.dart';
import 'package:quotabot_collector/verification.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late File credentials;
  late int clock;
  late int usages;
  late int profiles;
  var usageStatus = 200;
  late MockClient client;
  ProviderReadGate gate() => ProviderReadGate(
      directory: Directory('${temp.path}/gates'),
      clock: () => clock,
      jitter: (_) => 0,
      hardenDirectory: (_) {},
      hardenFile: (_) {},
      acquisitionTimeout: const Duration(seconds: 12),
      minimumLiveInterval: const Duration(seconds: 30));
  ClaudeAdapter adapter() => ClaudeAdapter(
      client: client,
      credentialsFile: credentials,
      grantToken: () async => null,
      readGate: gate());

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_shared_snapshot_');
    setQuotabotDirOverrideForTesting(Directory('${temp.path}/quotabot'));
    clock = nowEpoch();
    usages = 0;
    profiles = 0;
    usageStatus = 200;
    ProviderReadGate.forceFresh = false;
    credentials = File('${temp.path}/credentials.json')
      ..writeAsStringSync(jsonEncode({
        'claudeAiOauth': {
          'accessToken': 'synthetic-token',
          'refreshToken': 'synthetic-refresh',
          'expiresAt': (clock + 3600) * 1000
        },
      }));
    client = MockClient((request) async {
      if (request.url.path.endsWith('/profile')) {
        profiles++;
        return http.Response(
            jsonEncode({
              'account': {'uuid': 'shared-account', 'has_claude_max': true}
            }),
            200);
      }
      usages++;
      // The adapter captures real time before reaching this mocked request.
      // Align the gate before saving its first receipt, then advance only the
      // fixture clock so slow host setup cannot create future-dated captures.
      if (usages == 1) clock = nowEpoch();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return http.Response(
          jsonEncode({
            'five_hour': {
              'utilization': 30,
              'resets_at': DateTime.fromMillisecondsSinceEpoch(
                      (clock + 3600) * 1000,
                      isUtc: true)
                  .toIso8601String()
            },
            'seven_day': {
              'utilization': 20,
              'resets_at': DateTime.fromMillisecondsSinceEpoch(
                      (clock + 86400) * 1000,
                      isUtc: true)
                  .toIso8601String()
            },
          }),
          usageStatus,
          headers: usageStatus == 429 ? {'retry-after': '120'} : {});
    });
  });
  tearDown(() {
    ProviderReadGate.forceFresh = false;
    client.close();
    setQuotabotDirOverrideForTesting(null);
    temp.deleteSync(recursive: true);
  });

  test('six independent adapters reuse one live read with original provenance',
      () async {
    // Reproduce setup/capture skew without a wall-clock delay.
    clock -= 60;
    final first = await adapter().collectAccounts();
    expect(first.single.ok, isTrue);
    for (var i = 0; i < 5; i++) {
      clock++;
      final shared = (await adapter().collectAccounts()).single;
      expect(shared.sharedFromCaptureAt, first.single.asOf);
      expect(shared.asOf, first.single.asOf);
      expect(shared.toJson()['shared_from_capture_at'], first.single.asOf);
      expect(
          sanitizeProviderQuota(shared).sharedFromCaptureAt, first.single.asOf);
      final verification = buildVerificationReport([shared], clock,
          os: Platform.operatingSystem,
          requireLive: true,
          registry: [providerAdapterById('claude')!]);
      expect(verification.passed, isTrue);
    }
    expect(usages, 1);
    expect(profiles, 1);
  });

  test('concurrent adapters wait for one original operation', () async {
    final reads = await Future.wait(
        [adapter().collectAccounts(), adapter().collectAccounts()]);
    expect(reads.every((rows) => rows.single.ok), isTrue);
    expect(reads.where((rows) => rows.single.sharedFromCaptureAt != null),
        hasLength(1));
    expect(usages, 1);
    expect(profiles, 1);
  });

  test('fresh bypasses sharing, but a 429 cannot be bypassed', () async {
    await adapter().collectAccounts();
    ProviderReadGate.forceFresh = true;
    usageStatus = 429;
    final failed = (await adapter().collectAccounts()).single;
    expect(failed.ok, isFalse);
    expect(usages, 2);
    await adapter().collectAccounts();
    expect(usages, 2);
    ProviderReadGate.forceFresh = false;
    expect(
        (await adapter().collectAccounts()).single.sharedFromCaptureAt, isNull);
    expect(usages, 2);
  });

  test('expired receipt performs a new live usage read', () async {
    await adapter().collectAccounts();
    clock += 30;
    expect(
        (await adapter().collectAccounts()).single.sharedFromCaptureAt, isNull);
    expect(usages, 2);
  });

  test(
      'credential removal and replacement never borrow a prior generation receipt',
      () async {
    await adapter().collectAccounts();
    credentials.deleteSync();
    final missing = (await adapter().collectAccounts()).single;
    expect(missing.ok, isFalse);
    expect(missing.sharedFromCaptureAt, isNull);
    expect(usages, 1);
    credentials.writeAsStringSync(jsonEncode({
      'claudeAiOauth': {
        'accessToken': 'replacement-token',
        'refreshToken': 'replacement-refresh',
        'expiresAt': (clock + 3600) * 1000,
      }
    }));
    expect(
        (await adapter().collectAccounts()).single.sharedFromCaptureAt, isNull);
    expect(usages, 2);
  });

  test('persisted drift prevents sharing previously trusted quota', () async {
    final original = (await adapter().collectAccounts()).single;
    admitAndCacheQuotaEvidence(
        ProviderQuota.fromJson({
          ...original.toJson(),
          'windows': [
            QuotaWindow(label: '5h', usedPercent: 0, resetsAt: clock + 7200)
                .toJson()
          ]
        }),
        observedAt: clock,
        observedAtMicros: DateTime.now().microsecondsSinceEpoch,
        rejectionReason: 'synthetic drift');
    final next = (await adapter().collectAccounts()).single;
    expect(next.sharedFromCaptureAt, isNull);
    expect(usages, 2);
  });

  test('same-second cache replacement does not satisfy credential receipt',
      () async {
    final original = (await adapter().collectAccounts()).single;
    final replacement = ProviderQuota.fromJson({
      ...original.toJson(),
      'details': ['different observation']
    });
    admitAndCacheQuotaEvidence(replacement,
        observedAt: clock,
        observedAtMicros: DateTime.now().microsecondsSinceEpoch);
    expect(
        (await adapter().collectAccounts()).single.sharedFromCaptureAt, isNull);
    expect(usages, 2);
  });
}
