import 'dart:io';

import 'package:quotabot_collector/mcp_server_options.dart';
import 'package:test/test.dart';

void main() {
  test('usage documents stdio and Streamable HTTP modes', () {
    expect(mcpServerUsage, contains('bin/mcp_server.dart --http'));
    expect(mcpServerUsage, contains('--token-file PATH'));
  });

  test('parses Streamable HTTP flags in separated and equals forms', () {
    final separated = McpServerCliOptions.parse([
      '--http',
      '--host',
      'localhost',
      '--port',
      '9999',
      '--path',
      'custom',
      '--token',
      'secret',
    ]);
    expect(separated.http, isTrue);
    expect(separated.host, 'localhost');
    expect(separated.port, 9999);
    expect(separated.path, '/custom');
    expect(separated.token, 'secret');

    final equals = McpServerCliOptions.parse([
      '--http',
      '--host=127.0.0.1',
      '--port=8723',
      '--path=/mcp',
      '--token-env=QUOTABOT_TEST_TOKEN',
    ]);
    expect(equals.host, '127.0.0.1');
    expect(equals.port, 8723);
    expect(equals.path, '/mcp');
    expect(equals.tokenEnv, 'QUOTABOT_TEST_TOKEN');
  });

  test('rejects unsafe or incomplete HTTP CLI options', () {
    expect(
      () => McpServerCliOptions.parse(['--port', '9999']),
      throwsFormatException,
    );
    expect(
      () => McpServerCliOptions.parse(['--http', '--host', '0.0.0.0']),
      throwsFormatException,
    );
    expect(
      () => McpServerCliOptions.parse(['--http', '--port', '0']),
      throwsFormatException,
    );
    expect(
      () => McpServerCliOptions.parse(['--http', '--token']),
      throwsFormatException,
    );
  });

  test('token-file loading trims tokens and fails soft for missing files',
      () async {
    final temp = await Directory.systemTemp.createTemp('quotabot_mcp_token_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final tokenFile = File('${temp.path}${Platform.pathSeparator}token.txt');
    await tokenFile.writeAsString('  secret-token  \n');
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', tokenFile.path]);
      expect(chmod.exitCode, 0);
    }

    final loaded = await loadMcpBearerToken(
      McpServerCliOptions.parse([
        '--http',
        '--token-file',
        tokenFile.path,
      ]),
    );
    expect(loaded, 'secret-token');

    expect(
      () => loadMcpBearerToken(
        McpServerCliOptions.parse([
          '--http',
          '--token-file',
          '${temp.path}${Platform.pathSeparator}missing.txt',
        ]),
      ),
      throwsFormatException,
    );
  });
}
