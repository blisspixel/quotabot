import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/claude.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late File credentials;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_claude_adapter_');
    credentials = File('${temp.path}/credentials.json');
    credentials.writeAsStringSync(jsonEncode({
      'claudeAiOauth': {
        'accessToken': 'claude-token',
        'subscriptionType': 'max',
        'expiresAt': (nowEpoch() + 3600) * 1000,
      },
    }));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('preserves throttled metadata from the usage endpoint', () async {
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer claude-token');
        return http.Response(
          '{}',
          429,
          headers: {'retry-after': '120'},
        );
      }),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, 'HTTP 429');
    expect(q.account, 'max');
    expect(q.plan, 'max');
    expect(q.pipeHealth, providerPipeHealthThrottled);
    expect(q.httpStatus, 429);
    expect(q.retryAfterSeconds, 120);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test(
      'preserves degraded metadata without treating auth failures as pipe health',
      () async {
    final degraded = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response('{}', 529)),
    ).collect();

    expect(degraded.ok, isFalse);
    expect(degraded.pipeHealth, providerPipeHealthDegraded);
    expect(degraded.httpStatus, 529);

    final expired = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response('{}', 401)),
    ).collect();

    expect(expired.ok, isFalse);
    expect(expired.error, contains('token expired'));
    expect(expired.account, 'max');
    expect(expired.pipeHealth, isNull);
    expect(expired.httpStatus, 401);
  });

  void writeCreds({required int expiresAtMs}) {
    credentials.writeAsStringSync(jsonEncode({
      'claudeAiOauth': {
        'accessToken': 'host-token',
        'subscriptionType': 'max',
        'expiresAt': expiresAtMs,
      },
    }));
  }

  test('uses a fresh host token first without touching the grant', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    var grantCalled = false;
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async {
        grantCalled = true;
        return 'grant-token';
      },
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.perMachine, isFalse);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
    expect(grantCalled, isFalse);
  });

  test('maps the current limits payload to live quota windows', () async {
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      client: MockClient((_) async => http.Response(_currentUsageBody(), 200)),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.windows.map((window) => window.label), ['5h', 'weekly']);
    expect(q.windows.map((window) => window.usedPercent), [45, 17]);
    expect(q.windows.every((window) => window.resetsAt != null), isTrue);
    expect(q.modelQuotas.map((quota) => quota.model), ['Fable']);
    expect(q.modelQuotas.single.usedPercent, 26);
    expect(q.modelQuotas.single.resetsAt, isNotNull);
    expect(q.perMachine, isFalse);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('a throwing grant loader cannot break a fresh host-token read',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => throw StateError('grant refresh unavailable'),
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('a malformed host credential falls through to the independent grant',
      () async {
    credentials.writeAsStringSync('{not valid json');
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer grant-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('falls through to the grant when the host token is expired', () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        // The expired host token is demoted below the grant, so the grant is
        // the first token tried.
        expect(request.headers['Authorization'], 'Bearer grant-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('keeps the stale host token as a last chance after grant auth fails',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final tried = <String>[];
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        final auth = request.headers['Authorization']!;
        tried.add(auth);
        if (auth == 'Bearer host-token') {
          return http.Response(_usageBody(), 200);
        }
        return http.Response('{}', 401);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(tried, ['Bearer grant-token', 'Bearer host-token']);
  });

  test('keeps the stale host token as a last chance when grant loading throws',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => throw StateError('grant store unavailable'),
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer host-token');
        return http.Response(_usageBody(), 200);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(q.hasWindows, isTrue);
    expect(q.sourceClass, ProviderSourceClass.authoritativeLive);
  });

  test('falls through to the grant on a 401 from a fresh host token', () async {
    writeCreds(expiresAtMs: (nowEpoch() + 3600) * 1000);
    final tried = <String>[];
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => 'grant-token',
      client: MockClient((request) async {
        final auth = request.headers['Authorization']!;
        tried.add(auth);
        if (auth == 'Bearer grant-token') {
          return http.Response(_usageBody(), 200);
        }
        return http.Response('{}', 401);
      }),
    ).collect();

    expect(q.ok, isTrue);
    expect(tried, ['Bearer host-token', 'Bearer grant-token']);
  });

  test('points at both recovery paths when expired with no grant', () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => null,
      client: MockClient((_) async => http.Response('{}', 401)),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, contains('re-run claude'));
    expect(q.error, contains('quotabot login claude'));
  });

  test('preserves throttle metadata and recovery for a known-expired login',
      () async {
    writeCreds(expiresAtMs: (nowEpoch() - 10) * 1000);
    final q = await ClaudeAdapter(
      credentialsFile: credentials,
      grantToken: () async => null,
      client: MockClient((_) async => http.Response(
            '{}',
            429,
            headers: {'retry-after': '120'},
          )),
    ).collect();

    expect(q.ok, isFalse);
    expect(q.error, startsWith('HTTP 429'));
    expect(q.error, contains('saved Claude login expired'));
    expect(q.error, contains('re-run claude'));
    expect(q.error, contains('quotabot login claude'));
    expect(q.account, 'max');
    expect(q.plan, 'max');
    expect(q.pipeHealth, providerPipeHealthThrottled);
    expect(q.httpStatus, 429);
    expect(q.retryAfterSeconds, 120);
  });
}

String _usageBody() => jsonEncode({
      'five_hour': {'utilization': 30, 'resets_at': '2030-01-01T00:00:00Z'},
      'seven_day': {'utilization': 20, 'resets_at': '2030-01-02T00:00:00Z'},
    });

String _currentUsageBody() => jsonEncode({
      'limits': [
        {
          'kind': 'session',
          'group': 'session',
          'percent': 45,
          'resets_at': '2030-01-01T00:00:00Z',
          'scope': null,
          'is_active': true,
        },
        {
          'kind': 'weekly_all',
          'group': 'weekly',
          'percent': 17,
          'resets_at': '2030-01-02T00:00:00Z',
          'scope': null,
          'is_active': false,
        },
        {
          'kind': 'weekly_scoped',
          'group': 'weekly',
          'percent': 26,
          'resets_at': '2030-01-02T00:00:00Z',
          'scope': {
            'model': {'id': null, 'display_name': 'Fable'},
            'surface': null,
          },
          'is_active': false,
        },
      ],
    });
