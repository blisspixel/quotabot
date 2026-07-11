import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/nvidia.dart';
import 'package:quotabot_collector/models.dart';
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
      expect(q.ok, isFalse);
      expect(q.error, contains('NVIDIA_API_KEY'));
      expect(q.error, contains('nvapi'));
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

    test('reports free trial availability without inventing quota windows',
        () async {
      final q = await NvidiaAdapter(
        keySource: () => 'nvapi-test',
        client: MockClient((request) async {
          expect(request.url.toString(),
              'https://integrate.api.nvidia.com/v1/models');
          expect(request.headers['Authorization'], 'Bearer nvapi-test');
          return http.Response('{"object":"list","data":[]}', 200);
        }),
      ).collect();

      expect(q.ok, isTrue);
      expect(q.plan, 'free trial');
      expect(q.status, contains('balance unknown'));
      expect(q.sourceClass, ProviderSourceClass.statusOnly);
      expect(q.windows, isEmpty);
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
  });
}
