import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/provider_read_gate.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory storage;
  late int now;
  late int attempts;
  late ProviderReadGate gate;
  final credential = opaqueCredentialIdentity('claude', 'synthetic-generation');

  ProviderReadGate makeGate({
    void Function(File)? hardenFile,
    void Function(Directory)? hardenDirectory,
    Duration acquisitionTimeout = const Duration(milliseconds: 30),
  }) =>
      ProviderReadGate(
        directory: storage,
        clock: () => now,
        jitter: (_) => 0,
        hardenFile: hardenFile ?? (_) {},
        hardenDirectory: hardenDirectory ?? (_) {},
        acquisitionTimeout: acquisitionTimeout,
      );

  Future<Object> read({
    ProviderReadGate? using,
    String provider = 'claude',
    String? identity,
    ProviderReadPurpose purpose = ProviderReadPurpose.usage,
    ProviderReadDisposition result = const ProviderReadDisposition.completed(),
    Future<Object> Function(ProviderReadOperation)? attempt,
  }) =>
      (using ?? gate).run<Object>(
        provider: provider,
        credentialIdentity: identity ?? credential,
        purpose: purpose,
        attempt: (operation) async {
          attempts++;
          return attempt == null ? result : await attempt(operation);
        },
        classify: (value) => value as ProviderReadDisposition,
        deferred: (deferral) => deferral,
      );

  File stateFile() => storage
      .listSync()
      .whereType<File>()
      .singleWhere((file) => file.path.endsWith('.json'));

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_read_gate_');
    storage = Directory('${temp.path}/gates');
    now = 1800000000;
    attempts = 0;
    gate = makeGate();
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('a long provider deadline persists without sliding or a local cap',
      () async {
    const limited = ProviderReadDisposition.failed(
      ProviderReadFailure.rateLimited,
      httpStatus: 429,
      retryAfterSeconds: 172800,
    );
    expect(await read(result: limited), same(limited));
    final bytes = stateFile().readAsStringSync();
    expect(bytes.length, lessThan(2048));
    expect(bytes, isNot(contains('synthetic-generation')));
    expect(bytes, isNot(contains(credential)));
    expect(jsonDecode(bytes), {
      'schema': 'quotabot.provider-read.v1',
      'pending': false,
      'observed_at': now,
      'failures': 1,
      'failure': 'rateLimited',
      'http_status': 429,
      'retry_not_before': '${now + 172800}',
    });

    now += 30;
    final deferred = await read(using: makeGate()) as ProviderReadDeferral;
    expect(deferred.reason, ProviderReadDeferralReason.cooldown);
    expect(deferred.httpStatus, 429);
    expect(deferred.retryAfterSeconds, 172770);
    expect(attempts, 1);
    expect(stateFile().readAsStringSync(), bytes);
    now += 172770;
    expect(await read(), isA<ProviderReadDisposition>());
    expect(attempts, 2);
    expect(
        storage
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.json')),
        isEmpty);
    await read(
        result: const ProviderReadDisposition.failed(
      ProviderReadFailure.rateLimited,
    ));
    expect((await read() as ProviderReadDeferral).retryAfterSeconds, 60);
  });

  test('credentials, providers and purposes have independent cooldowns',
      () async {
    await read(
        result: const ProviderReadDisposition.failed(
      ProviderReadFailure.rateLimited,
      httpStatus: 429,
      retryAfterSeconds: 7200,
    ));
    await read(purpose: ProviderReadPurpose.profile);
    await read(identity: opaqueCredentialIdentity('claude', 'another-grant'));
    await read(provider: 'codex');
    expect(attempts, 4);
    final blocked = await read() as ProviderReadDeferral;
    expect(blocked.retryAfterSeconds, 7200);
    expect(attempts, 4);
  });

  test('missing headers back off finitely and success resets the sequence',
      () async {
    for (final expected in [60, 120, 300, 600, 1200, 1200]) {
      await read(
          result: const ProviderReadDisposition.failed(
        ProviderReadFailure.serviceUnavailable,
        httpStatus: 503,
      ));
      expect(
          (await read() as ProviderReadDeferral).retryAfterSeconds, expected);
      now += expected;
    }
    await read();
    await read(
        result: const ProviderReadDisposition.failed(
      ProviderReadFailure.timedOut,
      retryAfterSeconds: -1,
    ));
    expect((await read() as ProviderReadDeferral).retryAfterSeconds, 60);
    expect(attempts, 8);
  });

  test('maximum integer Retry-After cannot wrap into an expired deadline',
      () async {
    const delay = 0x7fffffffffffffff;
    await read(
        result: const ProviderReadDisposition.failed(
      ProviderReadFailure.rateLimited,
      httpStatus: 429,
      retryAfterSeconds: delay,
    ));
    expect((await read() as ProviderReadDeferral).retryAfterSeconds, delay);
    now += 5;
    expect(
        (await read(using: makeGate()) as ProviderReadDeferral)
            .retryAfterSeconds,
        delay - 5);
    expect(attempts, 1);
  });

  for (final damage in [
    'invalid-json',
    'oversized',
    'unknown-field',
    'negative-deadline',
    'invalid-pending',
    'invalid-status'
  ]) {
    test('$damage storage never starts a metadata request', () async {
      await read(
          result: const ProviderReadDisposition.failed(
        ProviderReadFailure.rateLimited,
        httpStatus: 429,
        retryAfterSeconds: 7200,
      ));
      final file = stateFile();
      final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final String damaged;
      switch (damage) {
        case 'invalid-json':
          damaged = '{';
        case 'oversized':
          damaged = ' ' * 2049;
        case 'unknown-field':
          value['unexpected'] = 'synthetic-private-detail';
          damaged = jsonEncode(value);
        case 'negative-deadline':
          value['retry_not_before'] = '-1';
          damaged = jsonEncode(value);
        case 'invalid-pending':
          value['pending'] = true;
          damaged = jsonEncode(value);
        default:
          value['http_status'] = 'synthetic-private-detail';
          damaged = jsonEncode(value);
      }
      file.writeAsStringSync(damaged);
      final deferred = await read() as ProviderReadDeferral;
      expect(deferred.reason, ProviderReadDeferralReason.storageUnavailable);
      expect(deferred.httpStatus, isNull);
      expect(attempts, 1);
      expect(file.readAsStringSync(), damaged);
    });
  }

  for (final suffix in ['', '.lock', '.lock.claim']) {
    test('a directory at the state$suffix path fails closed', () async {
      await read(
          result: const ProviderReadDisposition.failed(
        ProviderReadFailure.unavailable,
      ));
      final path = '${stateFile().path}$suffix';
      if (File(path).existsSync()) File(path).deleteSync();
      Directory(path).createSync();
      expect((await read() as ProviderReadDeferral).reason,
          ProviderReadDeferralReason.storageUnavailable);
      expect(attempts, 1);
    });
  }

  test('a linked state is rejected without reading or changing its target',
      () async {
    await read(
        result: const ProviderReadDisposition.failed(
      ProviderReadFailure.unavailable,
    ));
    final file = stateFile();
    final target = File('${temp.path}/unrelated.json')
      ..writeAsStringSync('synthetic-private-detail');
    file.deleteSync();
    try {
      Link(file.path).createSync(target.path);
    } on FileSystemException catch (error) {
      if (!Platform.isWindows || error.osError?.errorCode != 1314) rethrow;
      markTestSkipped('Windows file symlink privilege unavailable');
      return;
    }
    expect((await read() as ProviderReadDeferral).reason,
        ProviderReadDeferralReason.storageUnavailable);
    expect(attempts, 1);
    expect(target.readAsStringSync(), 'synthetic-private-detail');
  });

  test('failed final persistence retains the known deadline within the isolate',
      () async {
    var temporaryWrites = 0;
    final failing = makeGate(hardenFile: (file) {
      if (file.path.endsWith('.tmp') && ++temporaryWrites == 2) {
        throw const FileSystemException('synthetic write failure');
      }
    });
    final result = await read(
        using: failing,
        result: const ProviderReadDisposition.failed(
          ProviderReadFailure.rateLimited,
          httpStatus: 429,
          retryAfterSeconds: 7200,
        ));
    expect((result as ProviderReadDeferral).reason,
        ProviderReadDeferralReason.storageUnavailable);
    expect(
        (jsonDecode(stateFile().readAsStringSync()) as Map)['pending'], isTrue);
    now += 121;
    final deferred = await read(using: makeGate()) as ProviderReadDeferral;
    expect(deferred.retryAfterSeconds, 7079);
    expect(deferred.httpStatus, 429);
    expect(attempts, 1);
    now += 7079;
    expect(await read(), isA<ProviderReadDisposition>());
    expect(attempts, 2);
  });

  test('permission failure and raw identities cannot start outbound work',
      () async {
    final failing = makeGate(hardenDirectory: (_) {
      throw const FileSystemException('synthetic permission failure');
    });
    expect((await read(using: failing) as ProviderReadDeferral).reason,
        ProviderReadDeferralReason.storageUnavailable);
    expect((await read(identity: 'raw-secret') as ProviderReadDeferral).reason,
        ProviderReadDeferralReason.storageUnavailable);
    expect((await read(provider: 'unknown') as ProviderReadDeferral).reason,
        ProviderReadDeferralReason.storageUnavailable);
    expect(attempts, 0);
  });

  test(
      'caller timeout cannot release a live request or an aged same-process claim',
      () async {
    final started = Completer<void>();
    final pending = Completer<Object>();
    final source = read(attempt: (operation) {
      started.complete();
      return operation.track(pending.future);
    });
    try {
      await started.future;
      await expectLater(source.timeout(const Duration(milliseconds: 10)),
          throwsA(isA<TimeoutException>()));
      final claim = storage
          .listSync()
          .whereType<File>()
          .singleWhere((file) => file.path.endsWith('.claim'));
      claim.setLastModifiedSync(
          DateTime.now().subtract(const Duration(minutes: 3)));
      now += 600;
      expect((await read() as ProviderReadDeferral).reason,
          ProviderReadDeferralReason.busy);
      expect(attempts, 1);
      expect(
          await read(identity: opaqueCredentialIdentity('claude', 'healthy')),
          isA<ProviderReadDisposition>());
      expect(attempts, 2);
    } finally {
      pending.complete(const ProviderReadDisposition.completed());
      await source;
    }
    expect(await read(), isA<ProviderReadDisposition>());
    expect(attempts, 3);
  });

  test('a timed-out wrapper is not mistaken for raw request cancellation',
      () async {
    final raw = Completer<void>();
    final wrapperFinished = Completer<void>();
    final source = read(attempt: (operation) async {
      try {
        await operation
            .track(raw.future)
            .timeout(const Duration(milliseconds: 10));
      } on TimeoutException {
        wrapperFinished.complete();
      }
      return const ProviderReadDisposition.failed(ProviderReadFailure.timedOut);
    });
    try {
      await wrapperFinished.future;
      expect((await read() as ProviderReadDeferral).reason,
          ProviderReadDeferralReason.busy);
      expect(attempts, 1);
    } finally {
      raw.complete();
      await source;
    }
    expect((await read() as ProviderReadDeferral).failure,
        ProviderReadFailure.timedOut);
    expect(attempts, 1);
  });

  test('an abort-ignoring client keeps its request guarded until it settles',
      () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final client = MockClient((_) {
      started.complete();
      return response.future;
    });
    final source = read(attempt: (operation) async {
      try {
        await operation.get(client, Uri.parse('http://127.0.0.1/metadata'),
            headers: {}, timeout: const Duration(milliseconds: 10));
        return const ProviderReadDisposition.completed();
      } on TimeoutException {
        return const ProviderReadDisposition.failed(
            ProviderReadFailure.timedOut);
      }
    });
    try {
      await started.future;
      await expectLater(source.timeout(const Duration(milliseconds: 30)),
          throwsA(isA<TimeoutException>()));
      expect((await read() as ProviderReadDeferral).reason,
          ProviderReadDeferralReason.busy);
      expect(attempts, 1);
    } finally {
      response.complete(http.Response('{}', 200));
      await source;
      client.close();
    }
    expect((await read() as ProviderReadDeferral).failure,
        ProviderReadFailure.timedOut);
  });

  test('native HTTP cancellation settles without closing the shared client',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = http.Client();
    var requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      if (requests > 1) {
        request.response.write('{}');
        await request.response.close();
      }
    });
    Future<Object> attempt(ProviderReadOperation operation) async {
      try {
        await operation.get(
            client, Uri.parse('http://127.0.0.1:${server.port}/metadata'),
            headers: {}, timeout: const Duration(milliseconds: 100));
        return const ProviderReadDisposition.completed();
      } on TimeoutException {
        return const ProviderReadDisposition.failed(
            ProviderReadFailure.timedOut);
      }
    }

    try {
      expect(await read(attempt: attempt), isA<ProviderReadDisposition>());
      expect((await read(attempt: attempt) as ProviderReadDeferral).failure,
          ProviderReadFailure.timedOut);
      expect(requests, 1);
      expect(
          await read(
              attempt: attempt,
              identity:
                  opaqueCredentialIdentity('claude', 'healthy-client-reuse')),
          isA<ProviderReadDisposition>());
      expect(requests, 2);
    } finally {
      client.close();
      await server.close(force: true);
      await subscription.cancel();
    }
  });

  test('a terminated process recovers automatically after its bounded marker',
      () async {
    final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          'test/fixtures/provider_read_gate_holder.dart',
          storage.path,
          credential,
          '$now',
        ],
        workingDirectory: Directory.current.path);
    final stderr = process.stderr.transform(utf8.decoder).join();
    try {
      final ready = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      expect(ready, 'metadata-held');
      expect(process.kill(), isTrue);
      await process.exitCode.timeout(const Duration(seconds: 10));
      expect(await stderr, isEmpty);
      final retryGate =
          makeGate(acquisitionTimeout: const Duration(seconds: 3));
      expect(
          (await read(using: retryGate) as ProviderReadDeferral)
              .retryAfterSeconds,
          120);
      expect(attempts, 0);
      now += 120;
      expect(await read(using: retryGate), isA<ProviderReadDisposition>());
      expect(attempts, 1);
    } finally {
      process.kill();
      await process.exitCode;
    }
  });

  test(
      'a worker can publish a bounded result then drain without abandoning its guard',
      () async {
    final messages = ReceivePort();
    final stream = StreamIterator<Object?>(messages);
    final worker = await Isolate.spawn(
      _drainingWorker,
      (messages.sendPort, storage.path, credential, now),
    );
    try {
      expect(
          await stream.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      final snapshot = stream.current as (String, SendPort);
      expect(snapshot.$1, 'snapshot-ready');
      expect((await read() as ProviderReadDeferral).reason,
          ProviderReadDeferralReason.busy);
      expect(attempts, 0);
      snapshot.$2.send(null);
      expect(
          await stream.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      expect(stream.current, 'drained');
      expect(await read(), isA<ProviderReadDisposition>());
      expect(attempts, 1);
    } finally {
      await stream.cancel();
      messages.close();
      worker.kill(priority: Isolate.immediate);
    }
  });
}

Future<void> _drainingWorker((SendPort, String, String, int) input) async {
  final release = ReceivePort();
  final gate = ProviderReadGate(
    directory: Directory(input.$2),
    clock: () => input.$4,
    jitter: (_) => 0,
    hardenDirectory: (_) {},
    hardenFile: (_) {},
  );
  try {
    await gate
        .run<bool>(
          provider: 'claude',
          credentialIdentity: input.$3,
          purpose: ProviderReadPurpose.usage,
          attempt: (operation) async {
            await operation.track(release.first);
            return true;
          },
          classify: (_) => const ProviderReadDisposition.completed(),
          deferred: (_) => false,
        )
        .timeout(const Duration(milliseconds: 20), onTimeout: () => false);
    input.$1.send(('snapshot-ready', release.sendPort));
    await ProviderReadGate.drainActive();
    input.$1.send('drained');
  } finally {
    release.close();
  }
}
