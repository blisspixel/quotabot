import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/claude.dart';
import 'package:quotabot_collector/models.dart';
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
}
