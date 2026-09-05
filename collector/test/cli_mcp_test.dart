import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

const _token = '0123456789abcdef0123456789abcdef';

Map<String, Object?> _initialize(int id) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'quotabot-cli-test', 'version': '1.0.0'},
      },
    };

void main() {
  late Directory temp;
  late HttpServer runtime;
  late StreamSubscription<HttpRequest> runtimeRequests;
  var collections = 0;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('quotabot_cli_mcp_');
    runtime = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    collections = 0;
    runtimeRequests = runtime.listen((request) async {
      collections++;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
  });

  tearDown(() async {
    await runtimeRequests.cancel();
    await runtime.close(force: true);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<Process> start(List<String> args,
      {bool standalone = false, String? entrypoint}) async {
    final runtimeUrl = 'http://127.0.0.1:${runtime.port}';
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=.dart_tool/package_config.json',
        entrypoint ?? (standalone ? 'bin/mcp_server.dart' : 'bin/collect.dart'),
        ...args,
      ],
      workingDirectory: Directory.current.path,
      includeParentEnvironment: false,
      environment: {
        for (final key in ['PATH', 'SystemRoot', 'WINDIR'])
          if (Platform.environment[key] != null)
            key: Platform.environment[key]!,
        'HOME': temp.path,
        'USERPROFILE': temp.path,
        'LOCALAPPDATA': temp.path,
        'APPDATA': temp.path,
        'XDG_CONFIG_HOME': temp.path,
        'TEMP': temp.path,
        'TMP': temp.path,
        'NO_COLOR': '1',
        'OLLAMA_HOST': runtimeUrl,
        'LMSTUDIO_HOST': runtimeUrl,
        'LEMONADE_HOST': runtimeUrl,
        'QUOTABOT_TEST_MCP_BEARER': _token,
      },
    );
    addTearDown(() async {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 10));
    });
    return process;
  }

  Future<ProcessResult> run(List<String> args,
      {bool standalone = false}) async {
    final process = await start(args, standalone: standalone);
    final output = utf8.decoder.bind(process.stdout).join();
    final errors = utf8.decoder.bind(process.stderr).join();
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 20));
    return ProcessResult(process.pid, code, await output, await errors);
  }

  test('MCP help forms match the standalone server without collection',
      () async {
    final direct = await run(['mcp', '--help']);
    final topic = await run(['help', 'mcp']);
    final standalone = await run(['--help'], standalone: true);
    for (final result in [direct, topic, standalone]) {
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stderr, isEmpty);
      expect(result.stdout, direct.stdout);
      expect(result.stdout, contains('quotabot mcp --http'));
      expect(result.stdout, contains('Startup does not collect quota'));
      expect(result.stdout, contains('--token-env NAME'));
    }
    final general = await run(['help']);
    expect(general.exitCode, 0);
    expect(general.stdout, contains('mcp                 MCP server'));
    expect(collections, 0);
    expect(temp.listSync(), isEmpty);
  });

  test('misplaced MCP commands cannot fall through to a quota read', () async {
    for (final args in [
      ['--no-color', 'mcp'],
      ['--json', 'mcp'],
      ['--', 'mcp'],
      ['--profile=missing', 'mcp'],
      ['--mock-provider', 'ollama', '--state=healthy', 'mcp'],
      ['--help', 'mcp'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 64, reason: args.join(' '));
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('mcp must be the first argument'));
    }
    expect(collections, 0);
    expect(temp.listSync(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('MCP rejects CLI presentation, simulation and profile options',
      () async {
    for (final args in [
      ['mcp', '--json'],
      ['mcp', '--version'],
      ['mcp', '--no-color'],
      ['mcp', '--profile', 'missing'],
      ['mcp', '--mock-provider=ollama', '--state=healthy'],
      ['mcp', '--help', '--profile=missing'],
      ['help', 'mcp', '--profile=missing'],
      ['mcp', 'models'],
      ['mcp', '--', 'models'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 64, reason: args.join(' '));
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('unknown option:'));
    }
    expect(collections, 0);
    expect(temp.listSync(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('MCP HTTP usage failures remain stderr-only and fail closed', () async {
    for (final args in [
      ['--http'],
      ['--host=127.0.0.1'],
      ['--port=8722'],
      ['--path=/mcp'],
      ['--http', '--host=0.0.0.0', '--token-env=QUOTABOT_TEST_MCP_BEARER'],
      ['--http', '--token-env=QUOTABOT_MISSING_TEST_BEARER'],
      ['--http', '--token=short'],
    ]) {
      final result = await run(['mcp', ...args]);
      expect(result.exitCode, 64, reason: args.join(' '));
      expect(result.stdout, isEmpty);
      expect(result.stderr, isNotEmpty);
      expect(result.stderr, isNot(contains(_token)));
    }
    expect(collections, 0);
    expect(temp.listSync(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  for (final mode in ['CLI', 'standalone', 'subscribed fixture']) {
    test('$mode MCP stdio stays protocol-only and closes', () async {
      final fixture = mode == 'subscribed fixture';
      final process = await start(mode == 'CLI' ? ['mcp'] : [],
          standalone: mode == 'standalone',
          entrypoint: fixture ? 'test/support/mcp_fixture_server.dart' : null);
      final lines = StreamIterator(
          utf8.decoder.bind(process.stdout).transform(const LineSplitter()));
      final errors = utf8.decoder.bind(process.stderr).join();
      addTearDown(lines.cancel);

      Future<Map<String, dynamic>> request(Map<String, Object?> body) async {
        process.stdin.writeln(jsonEncode(body));
        await process.stdin.flush();
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 20)),
          isTrue,
        );
        final result = jsonDecode(lines.current) as Map<String, dynamic>;
        expect(result['jsonrpc'], '2.0');
        expect(result['id'], body['id']);
        expect(result.containsKey('error'), isFalse, reason: lines.current);
        return result['result'] as Map<String, dynamic>;
      }

      final initialized = await request(_initialize(1));
      expect(initialized['protocolVersion'], '2025-11-25');
      expect((initialized['serverInfo'] as Map)['name'], 'quotabot');
      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }));
      final tools = await request({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
      });
      expect(
        (tools['tools'] as List).map((tool) => (tool as Map)['name']),
        containsAll([
          'list_quotas',
          'suggest_provider',
          'suggest_model',
          'decide_now',
          'reserve_provider',
          'release_provider',
        ]),
      );
      final resources = await request({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'resources/list',
      });
      expect(
        (resources['resources'] as List)
            .map((resource) => (resource as Map)['uri']),
        containsAll(['quotas://current', 'quotas://alerts']),
      );
      expect(collections, 0);
      expect(temp.listSync(), isEmpty);
      if (fixture) {
        await request({
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'resources/subscribe',
          'params': {'uri': 'quotas://alerts'},
        });
      }
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await lines.moveNext(), isFalse);
      // The pinned transport may log its EOF diagnostic on stderr. Preserve
      // that standalone behavior while requiring stdout to contain only RPC.
      expect((await errors).trim(),
          anyOf(isEmpty, '[DEBUG][mcp_dart.server.stdio] Stdin closed.'));
      expect(collections, 0);
      // An explicit subscription can touch bounded quotabot lease metadata.
      if (!fixture) expect(temp.listSync(), isEmpty);
    });
  }

  for (final mode in ['CLI', 'signal fixture']) {
    test('$mode MCP HTTP requires auth and serves metadata without collection',
        () async {
      final fixture = mode == 'signal fixture';
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final process = await start([
        if (!fixture) 'mcp',
        '--http',
        '--port=$port',
        '--path=/test-mcp',
        '--token-env=QUOTABOT_TEST_MCP_BEARER',
      ], entrypoint: fixture ? 'test/support/mcp_fixture_server.dart' : null);
      final output = utf8.decoder.bind(process.stdout).join();
      final ready = Completer<void>();
      final errorLines = <String>[];
      final errorStream = utf8.decoder
          .bind(process.stderr)
          .transform(const LineSplitter())
          .listen((line) {
        errorLines.add(line);
        if (line.contains('MCP Streamable HTTP listening on') &&
            !ready.isCompleted) {
          ready.complete();
        }
      });
      addTearDown(errorStream.cancel);
      await Future.any([
        ready.future,
        process.exitCode.then<void>((code) {
          throw StateError('MCP exited $code: ${errorLines.join('\n')}');
        }),
      ]).timeout(const Duration(seconds: 20));

      final uri = Uri.parse('http://127.0.0.1:$port/test-mcp');
      final unauthorized = await http.post(uri,
          headers: {
            HttpHeaders.contentTypeHeader: 'application/json',
            HttpHeaders.acceptHeader: 'application/json, text/event-stream',
          },
          body: jsonEncode(_initialize(1)));
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final client = McpClient(
        const Implementation(name: 'quotabot-cli-http-test', version: '1.0.0'),
      );
      addTearDown(client.close);
      await client.connect(StreamableHttpClientTransport(
        uri,
        opts: StreamableHttpClientTransportOptions(requestInit: {
          'headers': {HttpHeaders.authorizationHeader: 'Bearer $_token'},
        }),
      ));
      final tools = await client.listTools();
      expect(
          tools.tools.map((tool) => tool.name), contains('suggest_provider'));
      final resources = await client.listResources();
      expect(resources.resources.map((resource) => resource.uri),
          contains('quotas://current'));
      await client.close();
      if (fixture) {
        process.stdin.writeln('stop');
        await process.stdin.flush();
        // Stdin deliberately stays open: graceful exit requires cancellation of
        // the fixture's signal stream, as it does for the real signal watcher.
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      } else {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
      expect(await output, isEmpty);
      expect(errorLines.join('\n'), isNot(contains(_token)));
      expect(collections, 0);
      expect(temp.listSync(), isEmpty);
    });
  }
}
