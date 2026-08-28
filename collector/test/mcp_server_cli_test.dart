import 'dart:io';

import 'package:quotabot_collector/mcp_server_options.dart';
import 'package:test/test.dart';

const _token = '0123456789abcdef0123456789abcdef';

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
      _token,
    ]);
    expect(separated.http, isTrue);
    expect(separated.host, 'localhost');
    expect(separated.port, 9999);
    expect(separated.path, '/custom');
    expect(separated.token, _token);

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
      () => McpServerCliOptions.parse([
        '--http',
        '--host',
        '127.0.0.1',
        '--host',
        'localhost',
        '--token',
        _token,
      ]),
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
    expect(
      () => McpServerCliOptions.parse(['--http']),
      throwsFormatException,
    );
    for (final sources in [
      ['--token', _token, '--token-env', 'QUOTABOT_TEST_TOKEN'],
      ['--token', _token, '--token-file', 'token.txt'],
      ['--token-env', 'QUOTABOT_TEST_TOKEN', '--token-file', 'token.txt'],
      ['--token', _token, '--token', _token],
    ]) {
      expect(
        () => McpServerCliOptions.parse(['--http', ...sources]),
        throwsFormatException,
      );
    }
  });

  test('token-file loading trims tokens and fails soft for missing files',
      () async {
    final temp = await Directory.systemTemp.createTemp('quotabot_mcp_token_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final tokenFile = File('${temp.path}${Platform.pathSeparator}token.txt');
    await tokenFile.writeAsString('  $_token  \n');
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
    expect(loaded, _token);

    await tokenFile.writeAsString('too-short');
    expect(
      () => loadMcpBearerToken(
        McpServerCliOptions.parse([
          '--http',
          '--token-file',
          tokenFile.path,
        ]),
      ),
      throwsFormatException,
    );

    await tokenFile.writeAsBytes(
      List<int>.filled(maxMcpHttpBearerTokenBytes + 1, 0x61),
    );
    expect(
      () => loadMcpBearerToken(
        McpServerCliOptions.parse([
          '--http',
          '--token-file',
          tokenFile.path,
        ]),
      ),
      throwsFormatException,
    );

    expect(
      () => loadMcpBearerToken(
        McpServerCliOptions.parse([
          '--http',
          '--token',
          'a' * (maxMcpHttpBearerTokenCharacters + 1),
        ]),
      ),
      throwsFormatException,
    );

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
