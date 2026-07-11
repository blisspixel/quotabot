import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/lemonade.dart';
import 'package:quotabot_collector/local_runtime_config.dart';
import 'package:test/test.dart';

void main() {
  group('LemonadeAdapter', () {
    test('reports installed models from an OpenAI-style listing', () async {
      final mock = MockClient((req) async {
        expect(req.url.port, lemonadeDefaultPort);
        expect(req.url.path, contains('models'));
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'llama-3'},
              {'id': 'qwen-coder'},
            ],
          }),
          200,
        );
      });
      final q = await LemonadeAdapter(client: mock).collect();
      expect(q.provider, 'lemonade');
      expect(q.isLocal, isTrue);
      expect(q.ok, isTrue);
      expect(q.account, contains('2'));
      expect(q.sourceClass.wireName, 'local_runtime');
    });

    test('uses the current default port and honors host overrides', () {
      expect(
        LemonadeAdapter.baseUrl(environment: const {}),
        'http://127.0.0.1:13305',
      );
      expect(
        LemonadeAdapter.baseUrl(
          environment: const {
            'LEMONADE_HOST': 'localhost',
            'LEMONADE_PORT': '14000',
          },
        ),
        'http://localhost:14000',
      );
    });

    test('is not-running when the server is unreachable', () async {
      final mock = MockClient((req) async => http.Response('down', 500));
      final q = await LemonadeAdapter(client: mock).collect();
      expect(q.ok, isFalse);
      expect(q.error, 'not running');
      expect(q.isLocal, isTrue);
    });

    test('is not-running when the listing is empty', () async {
      final mock = MockClient(
        (req) async => http.Response(jsonEncode({'data': <Object?>[]}), 200),
      );
      final q = await LemonadeAdapter(client: mock).collect();
      expect(q.ok, isFalse);
    });
  });
}
