import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/http_client.dart';
import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late StreamSubscription<HttpRequest> requests;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_http_lifecycle_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      switch (request.uri.path) {
        case '/api/tags':
          request.response.write(jsonEncode({
            'models': [
              {
                'name': 'local-test:latest',
                'digest': 'abc123',
                'size': 1024,
                'details': {
                  'parameter_size': '1B',
                  'quantization_level': 'Q4',
                },
              },
            ],
          }));
        case '/api/ps':
          request.response.write(jsonEncode({'models': <Object?>[]}));
        case '/api/show':
          await utf8.decoder.bind(request).join();
          request.response.write(jsonEncode({
            'capabilities': ['completion', 'tools'],
            'model_info': {'test.context_length': 32768},
          }));
        default:
          request.response.statusCode = HttpStatus.notFound;
          request.response.write(jsonEncode({'error': 'not found'}));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    closeSharedHttpClient();
    await requests.cancel();
    await server.close(force: true);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('one-shot live CLI closes pooled keep-alive connections', () async {
    final watch = Stopwatch()..start();
    final result = await runCollectCli(
      ['check', 'ollama', '--json'],
      environment: {
        'OLLAMA_HOST': 'http://127.0.0.1:${server.port}',
        'LOCALAPPDATA': temp.path,
        'XDG_CONFIG_HOME': temp.path,
        'HOME': temp.path,
        'USERPROFILE': temp.path,
      },
    );
    watch.stop();

    expectExitCode(result, 0);
    final output = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(output['provider'], 'ollama');
    expect(output['available'], isTrue);
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 12)),
      reason: 'an unclosed pooled client waits for the 15-second socket idle '
          'timeout after the command has finished',
    );
  });

  test('a closed shared client is recreated for the next read', () async {
    final uri = Uri.parse('http://127.0.0.1:${server.port}/api/tags');

    expect((await sharedHttpClient.get(uri)).statusCode, HttpStatus.ok);
    closeSharedHttpClient();
    expect((await sharedHttpClient.get(uri)).statusCode, HttpStatus.ok);
  });
}
