import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/nvidia.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:test/test.dart';

void main() {
  group('NvidiaAdapter', () {
    test('does not call network without an API key', () async {
      var called = false;
      final q = await NvidiaAdapter(
        keySource: () => null,
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      ).collect();

      expect(called, isFalse);
      // Not configured is a setup state, not a failed read: ok with no windows
      // (renders as "no live data", not a red ERROR), and no error message.
      expect(q.ok, isTrue);
      expect(q.error, isNull);
      expect(q.windows, isEmpty);
      expect(q.status, contains('not configured'));
      expect(q.status, contains('optional'));
    });

    test('chooses the first nonblank key alias', () {
      expect(
        resolveNvidiaApiKey(env: {
          'NVIDIA_API_KEY': '   ',
          'nvapi': ' nvapi-real ',
        }),
        'nvapi-real',
      );
      expect(
        resolveNvidiaApiKey(
          explicit: '',
          env: {'NVIDIA_API_KEY': ' primary ', 'nvapi': 'secondary'},
        ),
        'primary',
      );
      expect(
        resolveNvidiaApiKey(
          explicit: ' explicit ',
          env: {'NVIDIA_API_KEY': 'primary'},
        ),
        'explicit',
      );
      expect(
        resolveNvidiaApiKey(env: {'NVIDIA_API_KEY': ' ', 'nvapi': ''}),
        isNull,
      );
    });

    test('reports catalog reachability without inventing quota windows',
        () async {
      final q = await NvidiaAdapter(
        keySource: () => 'nvapi-test',
        client: MockClient((request) async {
          expect(request.url.toString(),
              'https://integrate.api.nvidia.com/v1/models');
          expect(request.headers['Authorization'], 'Bearer nvapi-test');
          return http.Response(
            '{"object":"list","data":[{"id":"nvidia/test-model"}]}',
            200,
          );
        }),
      ).collect();

      expect(q.ok, isTrue);
      expect(q.plan, isNull);
      expect(q.status, 'model catalog reachable; account access unverified');
      expect(q.sourceClass, ProviderSourceClass.statusOnly);
      expect(q.windows, isEmpty);
    });

    test('a public catalog with an invalid key cannot prove account access',
        () async {
      // The live public endpoint returned the same usable listing with no
      // Authorization and this synthetic invalid bearer on 2026-09-13.
      const publicCatalog =
          '{"object":"list","data":[{"id":"nvidia/test-model"}]}';
      for (final key in [
        'quotabot-public-metadata-check-invalid',
        'nvapi-accepted-looking',
      ]) {
        final q = await NvidiaAdapter(
          keySource: () => key,
          client: MockClient((_) async => http.Response(publicCatalog, 200)),
        ).collect();
        final serialized = q.toJson();
        final restored = ProviderQuota.fromJson(serialized);

        expect(restored.ok, isTrue);
        expect(restored.plan, isNull);
        expect(restored.planEvidenceSource, isNull);
        expect(restored.requestAdmission, RequestAdmission.notReported);
        expect(restored.status, contains('account access unverified'));
        expect(restored.details.join(' '), contains('balance remain unknown'));
        expect(restored.sourceClass, ProviderSourceClass.statusOnly);
        expect(restored.windows, isEmpty);
        expect(serialized.toString(), isNot(contains(key)));
        expect(
          buildModelRegistry(
            [restored],
            restored.asOf,
            catalog: {
              'nvidia': [const ModelInfo(id: 'nvidia/test-model')],
            },
          ),
          isEmpty,
        );
      }
    });

    test('a 200 response must contain a usable model listing', () async {
      for (final body in [
        '<html>captive portal</html>',
        '{}',
        '{"data":"not-a-list"}',
        '{"data":[]}',
        '{"data":[{"id":""}]}',
      ]) {
        final q = await NvidiaAdapter(
          keySource: () => 'nvapi-test',
          client: MockClient((_) async => http.Response(body, 200)),
        ).collect();

        expect(q.ok, isFalse, reason: body);
        expect(q.httpStatus, 200, reason: body);
        expect(q.error, contains('invalid or empty response'), reason: body);
      }
    });

    test('fails softly when model discovery rejects the key', () async {
      final q = await NvidiaAdapter(
        keySource: () => 'nvapi-bad',
        client: MockClient((_) async => http.Response('{}', 401)),
      ).collect();

      expect(q.ok, isFalse);
      expect(q.error, 'NVIDIA key rejected by /models (HTTP 401)');
    });

    test('preserves throttled metadata from model discovery', () async {
      final q = await NvidiaAdapter(
        keySource: () => 'nvapi-throttled',
        client: MockClient((_) async => http.Response(
              '{}',
              429,
              headers: {'retry-after': '90'},
            )),
      ).collect();

      expect(q.ok, isFalse);
      expect(q.error, 'NVIDIA /models throttled (HTTP 429)');
      expect(q.pipeHealth, providerPipeHealthThrottled);
      expect(q.httpStatus, 429);
      expect(q.retryAfterSeconds, 90);
    });

    test('model discovery timeouts are throttled rather than key failures',
        () async {
      final q = await NvidiaAdapter(
        keySource: () => 'nvapi-slow',
        client: MockClient((_) async => throw TimeoutException('slow')),
      ).collect();

      expect(q.ok, isFalse);
      expect(q.error, 'NVIDIA /models throttled');
      expect(q.pipeHealth, providerPipeHealthThrottled);
      expect(q.httpStatus, isNull);
    });
  });
}
