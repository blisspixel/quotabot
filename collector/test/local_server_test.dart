import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:quotabot_collector/leases.dart';
import 'package:quotabot_collector/litellm_metrics.dart';
import 'package:quotabot_collector/local_http_auth.dart';
import 'package:quotabot_collector/local_server.dart';
import 'package:quotabot_collector/models.dart';
import 'package:test/test.dart';

const _now = 1782000000;
const _mutationToken = 'local-http-mutation-token-0123456789';

class _LocalHttpAuthWorker {
  final Process process;
  final Future<String> stderrText;
  final File resultFile;

  _LocalHttpAuthWorker(this.process, this.stderrText, this.resultFile);

  static Future<_LocalHttpAuthWorker> start({
    required String script,
    required Directory directory,
    required String token,
    required File readyFile,
    required File startFile,
    required File beforeCallFile,
    required File factoryFile,
    required File? releaseFile,
    required File resultFile,
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=.dart_tool/package_config.json',
        script,
        directory.path,
        token,
        readyFile.path,
        startFile.path,
        beforeCallFile.path,
        factoryFile.path,
        releaseFile?.path ?? '-',
        resultFile.path,
      ],
      workingDirectory: Directory.current.path,
    );
    return _LocalHttpAuthWorker(
      process,
      process.stderr.transform(utf8.decoder).join(),
      resultFile,
    );
  }

  Future<Map<String, dynamic>> result() async {
    final exit = await process.exitCode;
    final stderr = await stderrText;
    if (!resultFile.existsSync()) {
      throw StateError('token worker produced no result: $exit $stderr');
    }
    final decoded = jsonDecode(resultFile.readAsStringSync());
    if (decoded is! Map<Object?, Object?>) {
      throw StateError('token worker produced an invalid result: $decoded');
    }
    return {
      ...decoded.cast<String, dynamic>(),
      'exit_code': exit,
      'stderr': stderr,
    };
  }

  Future<void> stop() async {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    try {
      await stderrText.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // Bounded cleanup keeps a failed worker from stalling the suite.
    }
  }
}

Future<void> _waitForFile(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!file.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _createLocalHttpTokenInIsolate(List<Object?> arguments) async {
  final id = arguments[0] as String;
  final directory = Directory(arguments[1] as String);
  final token = arguments[2] as String;
  final releasePath = arguments[3] as String?;
  final events = arguments[4] as SendPort;
  final commands = ReceivePort();
  events.send(<Object>[id, 'ready', commands.sendPort]);
  await commands.first;
  try {
    final result = loadOrCreateLocalHttpMutationToken(
      dirFactory: () => directory,
      tokenFactory: () {
        events.send(<Object>[id, 'factory']);
        if (releasePath != null) {
          final release = File(releasePath);
          while (!release.existsSync()) {
            sleep(const Duration(milliseconds: 2));
          }
        }
        return token;
      },
    );
    events.send(<Object>[id, 'result', result]);
  } catch (error) {
    events.send(<Object>[id, 'error', error.toString()]);
  } finally {
    commands.close();
  }
}

ProviderQuota _q(
  String id,
  double usedPercent, {
  String account = 'a',
  List<ModelQuota> modelQuotas = const [],
}) =>
    ProviderQuota(
      provider: id,
      displayName: id,
      account: account,
      asOf: _now,
      windows: [
        QuotaWindow(
          label: 'weekly',
          usedPercent: usedPercent,
          resetsAt: _now + 3600,
        ),
      ],
      modelQuotas: modelQuotas,
    );

ProviderQuota _local(String id) => ProviderQuota(
      provider: id,
      displayName: id,
      account: 'local',
      asOf: _now,
      kind: ProviderQuotaKind.local,
      models: const [ModelInfo(id: 'local-model', local: true)],
    );

RoutedRequestSummary _emptyRouteSummary() => const RoutedRequestSummary(
      totalRequests: 0,
      routedRequests: 0,
      successfulRequests: 0,
      failedRequests: 0,
      throttledRequests: 0,
      degradedRequests: 0,
      promptTokens: 0,
      completionTokens: 0,
      cost: 0,
      firstAt: null,
      lastAt: null,
      topServedModels: [],
    );

Future<({int status, Map<String, dynamic> body})> _requestJson(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? jsonBody,
  String? rawBody,
}) async {
  if (jsonBody != null && rawBody != null) {
    throw ArgumentError('jsonBody and rawBody are mutually exclusive');
  }
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (jsonBody != null) {
      final hasContentType = headers.keys.any(
        (key) => key.toLowerCase() == HttpHeaders.contentTypeHeader,
      );
      if (!hasContentType) request.headers.contentType = ContentType.json;
      request.write(jsonEncode(jsonBody));
    } else if (rawBody != null) {
      request.write(rawBody);
    }
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return (
      status: response.statusCode,
      body: jsonDecode(body) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _getJson(
  Uri uri, {
  int expectedStatus = 200,
}) async {
  final response = await _requestJson(uri);
  expect(response.status, expectedStatus);
  return response.body;
}

Future<({int status, Map<String, dynamic> body})> _waitForStatus(
  Uri uri,
  int expectedStatus, {
  Set<int> retryStatuses = const {},
}) async {
  final elapsed = Stopwatch()..start();
  const timeout = Duration(seconds: 2);
  while (elapsed.elapsed < timeout) {
    final response = await _requestJson(uri).timeout(timeout - elapsed.elapsed);
    if (response.status == expectedStatus) return response;
    if (!retryStatuses.contains(response.status)) {
      fail(
        'expected HTTP $expectedStatus but received HTTP ${response.status}',
      );
    }
  }
  fail('timed out waiting for HTTP $expectedStatus');
}

void main() {
  test('rejects a non-loopback bind address before opening a socket', () async {
    await expectLater(
      startLocalQuotabotServer(
        port: 0,
        address: InternetAddress.anyIPv4,
        snapshotProvider: () async => [_q('claude', 20)],
        now: () => _now,
      ),
      throwsArgumentError,
    );
  });

  test('rejects an invalid mutation token before opening a socket', () async {
    await expectLater(
      startLocalQuotabotServer(
        port: 0,
        snapshotProvider: () async => [_q('claude', 20)],
        mutationToken: 'too-short',
        now: () => _now,
      ),
      throwsArgumentError,
    );
  });

  test('local server serves snapshot, health, providers, and errors', () async {
    var collections = 0;
    final logs = <String>[];
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections += 1;
        return [_q('claude', 20)];
      },
      now: () => _now,
      log: logs.add,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      expect(logs.first, contains('quotabot local server listening'));

      final snapshot = await _getJson(Uri.parse('$base/'));
      expect(snapshot['schema'], 'quotabot.v1');
      expect(snapshot['providers'], hasLength(1));

      final suggestion = await _getJson(Uri.parse('$base/suggest'));
      expect((suggestion['recommended'] as Map)['provider'], 'claude');
      final receipt = suggestion['receipt'] as Map;
      expect(receipt['schema'], 'quotabot.receipt.v1');
      expect(receipt['decision_id'], startsWith('qb-'));

      final provider = await _getJson(Uri.parse('$base/providers/claude'));
      expect(provider['provider'], 'claude');
      expect(collections, 1);

      final health = await _getJson(Uri.parse('$base/health'));
      expect(health['ok'], isTrue);

      final unknownProvider = await _getJson(
        Uri.parse('$base/providers/missing'),
        expectedStatus: 404,
      );
      expect(unknownProvider['error'], 'unknown provider');

      final missingPath = await _getJson(
        Uri.parse('$base/missing'),
        expectedStatus: 404,
      );
      expect(missingPath['error'], 'not found');

      final wrongMethod = await _requestJson(
        Uri.parse('$base/health'),
        method: 'POST',
      );
      expect(wrongMethod.status, 405);
      expect(wrongMethod.body['error'], 'method not allowed');

      final disabledMutation = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        jsonBody: const {},
      );
      expect(disabledMutation.status, HttpStatus.notFound);
      expect(collections, 1);
    } finally {
      await server.close(force: true);
    }
  });

  test('HTTP lease mutations authenticate, distribute, and release', () async {
    var collections = 0;
    final leaseIds = ['lease-claude-0001', 'lease-codex-0002'];
    final leaseStore = InMemoryRouteLeaseStore(
      idFactory: () => leaseIds.removeAt(0),
    );
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections++;
        return [
          _q('claude', 20, account: 'claude-account'),
          _q('codex', 30, account: 'codex-account'),
        ];
      },
      routeSummaryProvider: _emptyRouteSummary,
      leaseStore: leaseStore,
      mutationToken: _mutationToken,
      now: () => _now,
    );
    final base = 'http://127.0.0.1:${server.port}';
    final headers = {
      HttpHeaders.authorizationHeader: 'Bearer $_mutationToken',
    };
    Map<String, dynamic> reserveBody(String idempotencyKey) => {
          'targets': [
            {'provider': 'claude', 'account': 'claude-account'},
            {'provider': 'codex', 'account': 'codex-account'},
          ],
          'minimum_effective_headroom': 15,
          'lease_seconds': 120,
          'weight_percent': 50,
          'client': 'litellm',
          'idempotency_key': idempotencyKey,
        };
    try {
      final denied = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        jsonBody: reserveBody('denied-request-0001'),
      );
      expect(denied.status, HttpStatus.unauthorized);
      expect(collections, 0, reason: 'auth must precede provider collection');
      expect(leaseStore.active(_now), isEmpty);

      final first = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: headers,
        jsonBody: reserveBody('reserve-request-0001'),
      );
      expect(first.status, HttpStatus.ok);
      expect(first.body['schema'], 'quotabot.reserve.v1');
      expect(first.body['reserved'], isTrue);
      expect(first.body['reused'], isFalse);
      expect((first.body['selected'] as Map)['provider'], 'claude');
      expect((first.body['lease'] as Map)['id'], 'lease-claude-0001');
      expect(first.body['decision_id'], startsWith('qb-'));

      final second = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: headers,
        jsonBody: reserveBody('reserve-request-0002'),
      );
      expect(second.status, HttpStatus.ok);
      expect(second.body['reserved'], isTrue);
      expect((second.body['selected'] as Map)['provider'], 'codex');
      expect((second.body['lease'] as Map)['id'], 'lease-codex-0002');
      expect(leaseStore.active(_now), hasLength(2));

      final retry = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: headers,
        jsonBody: reserveBody('reserve-request-0001'),
      );
      expect(retry.body['reserved'], isTrue);
      expect(retry.body['reused'], isTrue);
      expect((retry.body['lease'] as Map)['id'], 'lease-claude-0001');
      expect(leaseStore.active(_now), hasLength(2));

      final released = await _requestJson(
        Uri.parse('$base/leases/release'),
        method: 'POST',
        headers: headers,
        jsonBody: {'lease_id': 'lease-claude-0001'},
      );
      expect(released.status, HttpStatus.ok);
      expect(released.body['schema'], 'quotabot.release.v1');
      expect(released.body['released'], isTrue);

      final releasedAgain = await _requestJson(
        Uri.parse('$base/leases/release'),
        method: 'POST',
        headers: headers,
        jsonBody: {'lease_id': 'lease-claude-0001'},
      );
      expect(releasedAgain.body['released'], isFalse);
      expect(leaseStore.active(_now), hasLength(1));
    } finally {
      await server.close(force: true);
    }
  });

  test('HTTP reservation TTL starts after slow collection completes', () async {
    var current = _now;
    final collectionStarted = Completer<void>();
    final collectionResult = Completer<List<ProviderQuota>>();
    final store = InMemoryRouteLeaseStore(
      idFactory: () => 'lease-after-collect-0001',
    );
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () {
        collectionStarted.complete();
        return collectionResult.future;
      },
      routeSummaryProvider: _emptyRouteSummary,
      leaseStore: store,
      mutationToken: _mutationToken,
      now: () => current,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final response = _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $_mutationToken',
        },
        jsonBody: {
          'targets': [
            {'provider': 'claude', 'account': 'claude-account'},
          ],
          'lease_seconds': 120,
          'idempotency_key': 'slow-collection-request-0001',
        },
      );
      await collectionStarted.future;
      current += 200;
      collectionResult.complete([
        _q('claude', 20, account: 'claude-account'),
      ]);

      final result = await response;
      expect(result.body['reserved'], isTrue);
      final lease = result.body['lease'] as Map<String, dynamic>;
      expect(lease['created_at'], _now + 200);
      expect(lease['expires_at'], _now + 320);
      expect(store.active(current), hasLength(1));
    } finally {
      if (!collectionResult.isCompleted) {
        collectionResult.complete([
          _q('claude', 20, account: 'claude-account'),
        ]);
      }
      await server.close(force: true);
    }
  });

  test('HTTP lease mutations reject malformed and oversized input', () async {
    var collections = 0;
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections++;
        return [_q('claude', 20, account: 'claude-account')];
      },
      routeSummaryProvider: _emptyRouteSummary,
      leaseStore: InMemoryRouteLeaseStore(),
      mutationToken: _mutationToken,
      now: () => _now,
    );
    final base = 'http://127.0.0.1:${server.port}';
    final headers = {
      HttpHeaders.authorizationHeader: 'Bearer $_mutationToken',
    };
    try {
      final wrongMethod = await _requestJson(
        Uri.parse('$base/leases/reserve'),
      );
      expect(wrongMethod.status, HttpStatus.methodNotAllowed);

      final wrongType = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: {
          ...headers,
          HttpHeaders.contentTypeHeader: 'text/plain',
        },
        rawBody: '{}',
      );
      expect(wrongType.status, 415);

      final malformed = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: {
          ...headers,
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        rawBody: '{',
      );
      expect(malformed.status, HttpStatus.badRequest);

      final unknown = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: headers,
        jsonBody: {
          'targets': [
            {'provider': 'claude'},
          ],
          'unexpected': true,
        },
      );
      expect(unknown.status, HttpStatus.badRequest);
      expect(unknown.body['error'], contains('unknown field'));

      final oversized = await _requestJson(
        Uri.parse('$base/leases/reserve'),
        method: 'POST',
        headers: {
          ...headers,
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        rawBody: jsonEncode({'padding': 'x' * (33 * 1024)}),
      );
      expect(oversized.status, 413);
      expect(collections, 0, reason: 'invalid bodies must not collect quota');
    } finally {
      await server.close(force: true);
    }
  });

  test('local HTTP mutation token is stable and owner-only', () async {
    final root = await Directory.systemTemp.createTemp('quotabot-http-token-');
    final dir = Directory('${root.path}/config');
    var factoryCalls = 0;
    try {
      final first = loadOrCreateLocalHttpMutationToken(
        dirFactory: () => dir,
        tokenFactory: () {
          factoryCalls++;
          return 'first-local-mutation-token-0123456789';
        },
      );
      final second = loadOrCreateLocalHttpMutationToken(
        dirFactory: () => dir,
        tokenFactory: () {
          factoryCalls++;
          return 'second-local-mutation-token-012345678';
        },
      );
      final file = localHttpMutationTokenFile(dirFactory: () => dir);

      expect(first, 'first-local-mutation-token-0123456789');
      expect(second, first);
      expect(factoryCalls, 1);
      expect(file.readAsStringSync().trim(), first);
      if (!Platform.isWindows) {
        expect(dir.statSync().mode & 0x3f, 0);
        expect(file.statSync().mode & 0x3f, 0);
      }
    } finally {
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test('an existing invalid mutation token is never overwritten', () async {
    final root = await Directory.systemTemp.createTemp('quotabot-http-token-');
    final dir = Directory('${root.path}/config')..createSync();
    final file = localHttpMutationTokenFile(dirFactory: () => dir);
    const existing = 'existing-token-that-must-not-be-overwritten!\n';
    file.writeAsStringSync(existing, flush: true);
    var factoryCalls = 0;
    try {
      expect(
        () => loadOrCreateLocalHttpMutationToken(
          dirFactory: () => dir,
          tokenFactory: () {
            factoryCalls++;
            return 'replacement-local-mutation-token-012345';
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(factoryCalls, 0);
      expect(file.readAsStringSync(), existing);
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x3f, 0);
      }
    } finally {
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test(
    'a symbolic-link mutation token is rejected without reading its target',
    () async {
      final root = await Directory.systemTemp.createTemp('quotabot-http-link-');
      final dir = Directory('${root.path}/config')..createSync();
      const linkedToken = 'linked-local-mutation-token-0123456789';
      final linkedTarget = File('${root.path}/target')
        ..writeAsStringSync('$linkedToken\n', flush: true);
      final file = localHttpMutationTokenFile(dirFactory: () => dir);
      Link(file.path).createSync(linkedTarget.path);
      try {
        expect(
          () => loadOrCreateLocalHttpMutationToken(dirFactory: () => dir),
          throwsA(isA<FileSystemException>()),
        );
        expect(linkedTarget.readAsStringSync(), '$linkedToken\n');
      } finally {
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'ordinary Windows test accounts cannot create symbolic links'
        : false,
  );

  test('a credential published during creation is not overwritten', () async {
    final root = await Directory.systemTemp.createTemp('quotabot-http-token-');
    final dir = Directory('${root.path}/config');
    final file = localHttpMutationTokenFile(dirFactory: () => dir);
    const existing = 'late-existing-mutation-token-0123456789';
    try {
      final result = loadOrCreateLocalHttpMutationToken(
        dirFactory: () => dir,
        tokenFactory: () {
          file.writeAsStringSync('$existing\n', flush: true);
          return 'replacement-local-mutation-token-012345';
        },
      );

      expect(result, existing);
      expect(file.readAsStringSync(), '$existing\n');
      expect(
        dir.listSync().where((entry) => entry.path.endsWith('.tmp')),
        isEmpty,
      );
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x3f, 0);
      }
    } finally {
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test('concurrent first starts publish one complete mutation token', () async {
    final root = await Directory.systemTemp.createTemp('quotabot-http-race-');
    final dir = Directory('${root.path}/config');
    final workerScript = File(
      '${Directory.current.path}${Platform.pathSeparator}test'
      '${Platform.pathSeparator}support${Platform.pathSeparator}'
      'local_http_auth_worker.dart',
    ).absolute.path;
    final readyA = File('${root.path}/ready-a');
    final readyB = File('${root.path}/ready-b');
    final startA = File('${root.path}/start-a');
    final startB = File('${root.path}/start-b');
    final beforeA = File('${root.path}/before-a');
    final beforeB = File('${root.path}/before-b');
    final factoryA = File('${root.path}/factory-a');
    final factoryB = File('${root.path}/factory-b');
    final releaseA = File('${root.path}/release-a');
    final resultA = File('${root.path}/result-a');
    final resultB = File('${root.path}/result-b');
    final workers = <_LocalHttpAuthWorker>[];
    try {
      expect(File(workerScript).existsSync(), isTrue);
      workers.add(
        await _LocalHttpAuthWorker.start(
          script: workerScript,
          directory: dir,
          token: 'first-concurrent-mutation-token-012345',
          readyFile: readyA,
          startFile: startA,
          beforeCallFile: beforeA,
          factoryFile: factoryA,
          releaseFile: releaseA,
          resultFile: resultA,
        ),
      );
      workers.add(
        await _LocalHttpAuthWorker.start(
          script: workerScript,
          directory: dir,
          token: 'second-concurrent-mutation-token-01234',
          readyFile: readyB,
          startFile: startB,
          beforeCallFile: beforeB,
          factoryFile: factoryB,
          releaseFile: null,
          resultFile: resultB,
        ),
      );
      await Future.wait([_waitForFile(readyA), _waitForFile(readyB)]);

      startA.writeAsStringSync('start\n', flush: true);
      await _waitForFile(factoryA);
      final tokenFile = localHttpMutationTokenFile(dirFactory: () => dir);
      expect(
        tokenFile.existsSync(),
        isFalse,
        reason: 'the final path must not expose an incomplete token',
      );

      startB.writeAsStringSync('start\n', flush: true);
      await _waitForFile(beforeB);
      releaseA.writeAsStringSync('continue\n', flush: true);
      final results =
          await Future.wait(workers.map((worker) => worker.result()))
              .timeout(const Duration(seconds: 20));
      final diagnostics = jsonEncode(results);

      expect(results.map((result) => result['ok']), everyElement(isTrue),
          reason: diagnostics);
      expect(results.map((result) => result['exit_code']), everyElement(0),
          reason: diagnostics);
      expect(
        results.map((result) => result['token']),
        everyElement('first-concurrent-mutation-token-012345'),
        reason: diagnostics,
      );
      expect(factoryB.existsSync(), isFalse,
          reason: 'the losing creator must read rather than overwrite');
      expect(
        tokenFile.readAsStringSync(),
        'first-concurrent-mutation-token-012345\n',
      );
      expect(
        dir.listSync().where((entry) => entry.path.endsWith('.tmp')),
        isEmpty,
      );
      if (!Platform.isWindows) {
        expect(tokenFile.statSync().mode & 0x3f, 0);
        expect(File('${tokenFile.path}.lock').statSync().mode & 0x3f, 0);
      }
    } finally {
      await Future.wait(workers.map((worker) => worker.stop()));
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('concurrent isolates publish one complete mutation token', () async {
    final root =
        await Directory.systemTemp.createTemp('quotabot-http-isolate-');
    final dir = Directory('${root.path}/config');
    final releaseA = File('${root.path}/release-a');
    final events = ReceivePort();
    final ready = <String, Completer<SendPort>>{
      'a': Completer<SendPort>(),
      'b': Completer<SendPort>(),
    };
    final enteredFactory = <String>{};
    final factoryA = Completer<void>();
    final results = <String, Completer<String>>{
      'a': Completer<String>(),
      'b': Completer<String>(),
    };
    final subscription = events.listen((message) {
      final event = (message as List<Object>).cast<Object>();
      final id = event[0] as String;
      final kind = event[1] as String;
      if (kind == 'ready') ready[id]!.complete(event[2] as SendPort);
      if (kind == 'factory') {
        enteredFactory.add(id);
        if (id == 'a' && !factoryA.isCompleted) factoryA.complete();
      }
      if (kind == 'result') results[id]!.complete(event[2] as String);
      if (kind == 'error') {
        results[id]!.completeError(StateError(event[2] as String));
      }
    });
    Isolate? first;
    Isolate? second;
    try {
      first = await Isolate.spawn<List<Object?>>(
        _createLocalHttpTokenInIsolate,
        <Object?>[
          'a',
          dir.path,
          'first-isolate-mutation-token-012345678',
          releaseA.path,
          events.sendPort,
        ],
      );
      second = await Isolate.spawn<List<Object?>>(
        _createLocalHttpTokenInIsolate,
        <Object?>[
          'b',
          dir.path,
          'second-isolate-mutation-token-01234567',
          null,
          events.sendPort,
        ],
      );
      final firstCommands =
          await ready['a']!.future.timeout(const Duration(seconds: 3));
      final secondCommands =
          await ready['b']!.future.timeout(const Duration(seconds: 3));

      firstCommands.send('start');
      await factoryA.future.timeout(const Duration(seconds: 3));
      secondCommands.send('start');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(enteredFactory, {'a'});

      releaseA.writeAsStringSync('continue\n', flush: true);
      final tokens = await Future.wait([
        results['a']!.future,
        results['b']!.future,
      ]).timeout(const Duration(seconds: 5));
      expect(
        tokens,
        everyElement('first-isolate-mutation-token-012345678'),
      );
      expect(enteredFactory, {'a'});
      expect(
        localHttpMutationTokenFile(dirFactory: () => dir)
            .readAsStringSync()
            .trim(),
        tokens.first,
      );
    } finally {
      first?.kill(priority: Isolate.immediate);
      second?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      events.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('/providers selects a live account after a spent first match', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 100, account: 'spent'),
        _q('claude', 20, account: 'live'),
      ],
      now: () => _now,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final provider = await _getJson(Uri.parse('$base/providers/claude'));

      expect(provider['account'], 'live');
      expect((provider['windows'] as List).single['used_percent'], 20);
    } finally {
      await server.close(force: true);
    }
  });

  test('/providers resolves equal accounts by stable account key', () async {
    for (final accounts in const [
      ['zeta', 'alpha'],
      ['alpha', 'zeta'],
    ]) {
      final server = await startLocalQuotabotServer(
        port: 0,
        snapshotProvider: () async => [
          _q('claude', 20, account: accounts[0]),
          _q('claude', 20, account: accounts[1]),
        ],
        now: () => _now,
      );
      final base = 'http://127.0.0.1:${server.port}';
      try {
        final provider = await _getJson(Uri.parse('$base/providers/claude'));

        expect(provider['account'], 'alpha');
      } finally {
        await server.close(force: true);
      }
    }
  });

  test('snapshot throttle age starts after a slow collection completes',
      () async {
    var current = _now;
    var collections = 0;
    final collectionStarted = Completer<void>();
    final collectionResult = Completer<List<ProviderQuota>>();
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () {
        collections += 1;
        collectionStarted.complete();
        return collectionResult.future;
      },
      now: () => current,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final firstRequest = _getJson(Uri.parse('$base/'));
      await collectionStarted.future;
      current += 10;
      collectionResult.complete([_q('claude', 20)]);

      final first = await firstRequest;
      expect(first['providers'], hasLength(1));
      final second = await _getJson(Uri.parse('$base/suggest'));
      expect((second['recommended'] as Map)['provider'], 'claude');
      expect(collections, 1);
    } finally {
      await server.close(force: true);
    }
  });

  test('slow collection keeps health responsive and reads coalesce', () async {
    var collections = 0;
    final collectionStarted = Completer<void>();
    final collectionResult = Completer<List<ProviderQuota>>();
    final server = await startLocalQuotabotServer(
      port: 0,
      maxConcurrentRequests: 2,
      snapshotProvider: () {
        collections += 1;
        if (!collectionStarted.isCompleted) collectionStarted.complete();
        return collectionResult.future;
      },
      now: () => _now,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final first = _getJson(Uri.parse('$base/'));
      await collectionStarted.future;

      final health = await _getJson(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 1));
      expect(health['ok'], isTrue);

      final second = _getJson(Uri.parse('$base/suggest'));

      // Wait until both snapshot-backed requests occupy the two request slots.
      // A busy response proves the second request reached the server and is
      // waiting on the same collection, without relying on a scheduling delay.
      final probe = await _waitForStatus(
        Uri.parse('$base/health'),
        HttpStatus.serviceUnavailable,
        retryStatuses: const {HttpStatus.ok},
      );
      expect(probe.body['error'], 'server busy');
      expect(collections, 1);

      collectionResult.complete([_q('claude', 20)]);
      final responses = await Future.wait([first, second]);
      expect(responses.first['providers'], hasLength(1));
      expect((responses.last['recommended'] as Map)['provider'], 'claude');
      expect(collections, 1);
    } finally {
      if (!collectionResult.isCompleted) {
        collectionResult.complete([_q('claude', 20)]);
      }
      await server.close(force: true);
    }
  });

  test('rejects a non-loopback Host header (DNS-rebinding guard)', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/'),
        );
        request.headers.set('host', 'evil.example');
        final response = await request.close();
        final body = jsonDecode(await utf8.decodeStream(response))
            as Map<String, dynamic>;
        expect(response.statusCode, 403);
        expect(body['error'], 'forbidden host');
        expect(body.containsKey('providers'), isFalse);
      } finally {
        client.close(force: true);
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('allows a loopback Host header with a port', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      for (final host in ['localhost:9999', '127.0.0.1:1', '[::1]:8721']) {
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/health'),
          );
          request.headers.set('host', host);
          final response = await request.close();
          expect(response.statusCode, 200, reason: 'host $host must pass');
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects external and null browser origins before provider work',
      () async {
    var collections = 0;
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections += 1;
        return [_q('claude', 20)];
      },
      now: () => _now,
    );
    final uri = Uri.parse('http://127.0.0.1:${server.port}/');
    try {
      for (final origin in ['https://evil.example', 'null']) {
        final response = await _requestJson(
          uri,
          headers: {'origin': origin},
        );
        expect(response.status, 403, reason: origin);
        expect(response.body['error'], 'forbidden origin', reason: origin);
      }
      expect(collections, 0);
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects originless cross-site fetches before provider work', () async {
    var collections = 0;
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections += 1;
        return [_q('claude', 20)];
      },
      now: () => _now,
    );
    final uri = Uri.parse('http://127.0.0.1:${server.port}/');
    try {
      for (final site in ['cross-site', 'same-site', 'unknown']) {
        final response = await _requestJson(
          uri,
          headers: {
            'sec-fetch-site': site,
            'sec-fetch-mode': 'no-cors',
            'sec-fetch-dest': 'image',
          },
        );
        expect(response.status, 403, reason: site);
        expect(
          response.body['error'],
          'forbidden fetch metadata',
          reason: site,
        );
      }
      expect(collections, 0);
    } finally {
      await server.close(force: true);
    }
  });

  test('allows originless non-browser and safe browser fetches', () async {
    var collections = 0;
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections += 1;
        return [_q('claude', 20)];
      },
      now: () => _now,
    );
    final uri = Uri.parse('http://127.0.0.1:${server.port}/');
    try {
      final controls = <Map<String, String>>[
        const {},
        const {
          'sec-fetch-site': 'same-origin',
          'sec-fetch-mode': 'cors',
          'sec-fetch-dest': 'empty',
        },
        const {
          'sec-fetch-site': 'none',
          'sec-fetch-mode': 'navigate',
          'sec-fetch-user': '?1',
          'sec-fetch-dest': 'document',
        },
        const {
          'sec-fetch-site': 'cross-site',
          'sec-fetch-mode': 'navigate',
          'sec-fetch-user': '?1',
          'sec-fetch-dest': 'document',
        },
        const {
          'sec-fetch-site': 'same-site',
          'sec-fetch-mode': 'navigate',
          'sec-fetch-user': '?1',
          'sec-fetch-dest': 'document',
        },
      ];
      for (final headers in controls) {
        final response = await _requestJson(uri, headers: headers);
        expect(response.status, 200, reason: headers.toString());
        expect(response.body['providers'], hasLength(1));
      }
      expect(collections, 1);
    } finally {
      await server.close(force: true);
    }
  });

  test('allows a syntactically valid loopback browser origin', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      final response = await _requestJson(
        Uri.parse('http://127.0.0.1:${server.port}/health'),
        headers: {
          'origin': 'http://localhost:3000',
          'sec-fetch-site': 'cross-site',
          'sec-fetch-mode': 'cors',
          'sec-fetch-dest': 'empty',
        },
      );
      expect(response.status, 200);
      expect(response.body['ok'], isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects malformed loopback Host headers', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      for (final host in [
        'localhost:not-a-port',
        'localhost:+1',
        'localhost:1:2',
        '[::1]evil.example',
        '[::1]:99999',
      ]) {
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/health'),
          );
          request.headers.set('host', host);
          final response = await request.close();
          expect(response.statusCode, 403, reason: 'host $host must fail');
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('bounds stalled requests and returns capacity after success', () async {
    final collectionStarted = Completer<void>();
    final collectionResult = Completer<List<ProviderQuota>>();
    final server = await startLocalQuotabotServer(
      port: 0,
      maxConcurrentRequests: 1,
      snapshotProvider: () {
        if (!collectionStarted.isCompleted) collectionStarted.complete();
        return collectionResult.future;
      },
      now: () => _now,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final active = _getJson(Uri.parse('$base/'));
      await collectionStarted.future;

      final busy = await _requestJson(Uri.parse('$base/suggest'))
          .timeout(const Duration(seconds: 1));
      expect(busy.status, HttpStatus.serviceUnavailable);
      expect(busy.body['error'], 'server busy');

      collectionResult.complete([_q('claude', 20)]);
      expect((await active)['providers'], hasLength(1));

      final recovered = await _waitForStatus(
        Uri.parse('$base/health'),
        HttpStatus.ok,
        retryStatuses: const {HttpStatus.serviceUnavailable},
      );
      expect(recovered.body['ok'], isTrue);
    } finally {
      if (!collectionResult.isCompleted) {
        collectionResult.complete([_q('claude', 20)]);
      }
      await server.close(force: true);
    }
  });

  test('returns request capacity after a collection failure', () async {
    var collections = 0;
    final collectionStarted = Completer<void>();
    final collectionResult = Completer<List<ProviderQuota>>();
    final server = await startLocalQuotabotServer(
      port: 0,
      maxConcurrentRequests: 1,
      snapshotProvider: () {
        collections += 1;
        if (collections == 1) {
          collectionStarted.complete();
          return collectionResult.future;
        }
        return Future.value([_q('claude', 20)]);
      },
      now: () => _now,
    );
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final failed = _requestJson(Uri.parse('$base/'));
      await collectionStarted.future;

      final busy = await _requestJson(Uri.parse('$base/health'));
      expect(busy.status, HttpStatus.serviceUnavailable);

      collectionResult.completeError(StateError('provider unavailable'));
      final failedResponse = await failed;
      expect(failedResponse.status, HttpStatus.internalServerError);
      expect(failedResponse.body['error'], 'internal error');

      final recovered = await _waitForStatus(
        Uri.parse('$base/'),
        HttpStatus.ok,
        retryStatuses: const {HttpStatus.serviceUnavailable},
      );
      expect(recovered.body['providers'], hasLength(1));
      expect(collections, 2);
    } finally {
      if (!collectionResult.isCompleted) {
        collectionResult.completeError(StateError('test cleanup'));
      }
      await server.close(force: true);
    }
  });

  test('local /suggest honors exclude query providers', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 20),
        _q('codex', 30),
      ],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest?exclude=claude'),
      );

      expect((json['recommended'] as Map)['provider'], 'codex');
      final ranked = json['ranked'] as List;
      expect(
        ranked.map((entry) => (entry as Map)['provider']),
        isNot(contains('claude')),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest honors local-first query policy', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 20),
        _local('ollama'),
      ],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse(
          'http://127.0.0.1:${server.port}/suggest?local_first=true',
        ),
      );

      expect(json['routing_policy'], 'local_first');
      expect((json['recommended'] as Map)['provider'], 'ollama');
      expect(json['using_local_fallback'], isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest honors active cross-process routing leases', () async {
    final leases = InMemoryRouteLeaseStore();
    final reservation = leases.reserve(
      provider: 'claude',
      account: 'a',
      now: _now,
      leaseSeconds: 300,
      weightPercent: 50,
    );
    expect(reservation.reserved, isTrue);
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 10),
        _q('codex', 30),
      ],
      leaseStore: leases,
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest'),
      );

      expect((json['recommended'] as Map)['provider'], 'codex');
      final claude = (json['ranked'] as List<Object?>)
          .cast<Map<String, dynamic>>()
          .singleWhere((candidate) => candidate['provider'] == 'claude');
      expect(claude['lease_discount_percent'], 50.0);
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest applies provider-route task query context', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q(
          'antigravity',
          10,
          modelQuotas: const [
            ModelQuota(model: 'gemini', usedPercent: 100),
            ModelQuota(model: 'Gemini 3 Flash', usedPercent: 0),
          ],
        ),
      ],
      now: () => _now,
    );
    try {
      final defaultRoute = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest'),
      );
      expect(defaultRoute['recommended'], isNull);
      final blocked =
          (defaultRoute['ranked'] as List).cast<Map<String, dynamic>>().single;
      expect(blocked['capability_budget_limited'], isTrue);

      final simpleRoute = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest?task=simple'),
      );
      expect((simpleRoute['recommended'] as Map)['provider'], 'antigravity');
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest rejects malformed routing constraints', () async {
    var collections = 0;
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async {
        collections += 1;
        return [_q('claude', 20)];
      },
      now: () => _now,
    );
    try {
      final cases = {
        'min_context=garbage': 'min_context',
        'min_context=0': 'min_context',
        'tier_floor=banana': 'tier_floor',
        'tier_ceiling=': 'tier_ceiling',
        'tier_floor=flagship&tier_ceiling=light': 'tier_floor cannot be higher',
        'task=banana': 'task profile',
        'require_tools=perhaps': 'require_tools',
        'budget=': 'budget policy',
        'local_first=perhaps': 'local_first',
        'local_frist=true': 'unknown query parameter: local_frist',
      };
      for (final entry in cases.entries) {
        final response = await _requestJson(
          Uri.parse(
            'http://127.0.0.1:${server.port}/suggest?${entry.key}',
          ),
        );
        expect(response.status, 400, reason: entry.key);
        expect(
          response.body['error'],
          contains(entry.value),
          reason: entry.key,
        );
      }
      expect(collections, 0);
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest honors explicit cost policy', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 20),
        _q('codex', 30),
      ],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse(
          'http://127.0.0.1:${server.port}/suggest?cost_penalty=claude:1',
        ),
      );

      expect(json['cost_weight'], 1.0);
      expect(
          (json['recommended'] as Map<String, dynamic>)['provider'], 'codex');
      final claude = (json['ranked'] as List<Object?>)
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (entry) => entry['provider'] == 'claude',
          );
      expect(claude['cost_penalty'], 1.0);
      expect(claude['cost_discount'], 0.5);
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest discounts recent LiteLLM pipe failures', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [
        _q('claude', 10),
        _q('codex', 30),
      ],
      routeSummaryProvider: () => summarizeRoutedRequests([
        const LiteLlmRouteMetric(
          at: _now,
          provider: 'claude',
          account: 'a',
          requestedModel: 'claude-3',
          servedModel: 'claude-3',
          promptTokens: 0,
          completionTokens: 0,
          cost: 0,
          spend: litellmSpendQuotaPlan,
          event: litellmEventFailure,
          latencyMs: 0,
          httpStatus: 429,
          retryAfterSeconds: 60,
        ),
      ]),
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest'),
      );

      expect((json['recommended'] as Map)['provider'], 'codex');
      final claude = (json['ranked'] as List<Object?>)
          .cast<Map<String, dynamic>>()
          .firstWhere((entry) => entry['provider'] == 'claude');
      expect(claude['pipe_discount_percent'], greaterThan(0));
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest rejects malformed exclude providers', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/suggest?exclude=../bad'),
        expectedStatus: 400,
      );

      expect(json['error'], 'invalid exclude provider: ../bad');
    } finally {
      await server.close(force: true);
    }
  });

  test('local /suggest rejects malformed cost policy', () async {
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => [_q('claude', 20)],
      now: () => _now,
    );
    try {
      final json = await _getJson(
        Uri.parse(
          'http://127.0.0.1:${server.port}/suggest?cost_penalty=../bad:1',
        ),
        expectedStatus: 400,
      );

      expect(json['error'], 'invalid cost-penalty provider: ../bad');
    } finally {
      await server.close(force: true);
    }
  });

  test('local server hides internal errors from clients', () async {
    final logs = <String>[];
    final server = await startLocalQuotabotServer(
      port: 0,
      snapshotProvider: () async => throw StateError('secret detail'),
      now: () => _now,
      log: logs.add,
    );
    try {
      final json = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/'),
        expectedStatus: 500,
      );

      expect(json['error'], 'internal error');
      expect(json.toString(), isNot(contains('secret detail')));
      expect(logs, contains('local server GET / failed: StateError'));
      expect(logs.join('\n'), isNot(contains('secret detail')));
    } finally {
      await server.close(force: true);
    }
  });
}
