@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:quotabot_collector/storage_keys.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void _holdAgedCacheEvidenceLock(List<Object> arguments) {
  final root = Directory(arguments[0] as String);
  final account = arguments[1] as String;
  final sendPort = arguments[2] as SendPort;
  final releaseFile = File(arguments[3] as String);
  setQuotabotDirOverrideForTesting(root);
  withCacheEvidenceLockForTesting(
    codexProviderId,
    account,
    () {
      final lock = File(
        '${cacheDir().path}/evidence_${codexProviderId}_${accountStorageStem(account)}.lock',
      );
      File('${lock.path}.claim').setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 5)),
      );
      sendPort.send('locked');
      final timeout = Stopwatch()..start();
      while (!releaseFile.existsSync()) {
        if (timeout.elapsed >= const Duration(seconds: 10)) {
          throw StateError('timed out waiting to release evidence guard');
        }
        sleep(const Duration(milliseconds: 10));
      }
    },
  );
  sendPort.send('released');
}

void _waitForCacheEvidenceLock(List<Object> arguments) {
  final root = Directory(arguments[0] as String);
  final account = arguments[1] as String;
  final sendPort = arguments[2] as SendPort;
  final releaseFile = File(arguments[3] as String);
  setQuotabotDirOverrideForTesting(root);
  var announced = false;
  setEvidenceGuardObserverForTesting((phase, _) {
    if (phase == 'before_acquire' && !announced) {
      announced = true;
      sendPort.send('waiting');
    }
  });
  final elapsed = Stopwatch()..start();
  final releaseObserved = withCacheEvidenceLockForTesting(
    codexProviderId,
    account,
    releaseFile.existsSync,
  );
  elapsed.stop();
  sendPort.send(<String, Object>{
    'elapsed_ms': elapsed.elapsedMilliseconds,
    'release_observed': releaseObserved,
  });
}

void main() {
  const account = 'z@example.com';
  late Directory temp;

  String canonicalLockPath() =>
      '${cacheDir().path}/evidence_${codexProviderId}_${accountStorageStem(account)}.lock';
  String legacyLockPath() =>
      '${cacheDir().path}/evidence_${codexProviderId}_z_example.com.lock';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_evidence_guard_');
    setQuotabotDirOverrideForTesting(temp);
  });

  tearDown(() {
    setEvidenceGuardObserverForTesting(null);
    setQuotabotDirOverrideForTesting(null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('multiple evidence guards use deterministic normalized path order', () {
    final acquired = <String>[];
    setEvidenceGuardObserverForTesting((phase, path) {
      if (phase == 'before_acquire') acquired.add(path);
    });

    final value = withCacheEvidenceLockForTesting(
      codexProviderId,
      account,
      () => 42,
      includeLegacy: true,
    );

    expect(value, 42);
    final expected = <String>[
      File(legacyLockPath()).absolute.path,
      File(canonicalLockPath()).absolute.path,
    ];
    expect(acquired, expected);
    for (final path in expected) {
      expect(File('$path.claim').existsSync(), isFalse);
    }
  });

  test('partial acquisition failure releases earlier guards and claims', () {
    var attempts = 0;
    setEvidenceGuardObserverForTesting((phase, _) {
      if (phase != 'before_acquire') return;
      attempts++;
      if (attempts == 2) throw StateError('injected acquisition failure');
    });

    expect(
      () => withCacheEvidenceLockForTesting(
        codexProviderId,
        account,
        () {},
        includeLegacy: true,
      ),
      throwsStateError,
    );
    expect(File('${canonicalLockPath()}.claim').existsSync(), isFalse);
    expect(File('${legacyLockPath()}.claim').existsSync(), isFalse);

    setEvidenceGuardObserverForTesting(null);
    expect(
      withCacheEvidenceLockForTesting(
        codexProviderId,
        account,
        () => 'released',
        includeLegacy: true,
      ),
      'released',
    );
  });

  test('unsafe evidence lock path fails closed', () {
    Directory(canonicalLockPath()).createSync(recursive: true);
    var entered = false;

    expect(
      () => withCacheEvidenceLockForTesting(
        codexProviderId,
        account,
        () => entered = true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(entered, isFalse);
    expect(Directory(canonicalLockPath()).existsSync(), isTrue);
  });

  test('unsafe claim path fails closed without entering the guard', () {
    File(canonicalLockPath()).createSync(recursive: true);
    Directory('${canonicalLockPath()}.claim').createSync();
    var entered = false;

    expect(
      () => withCacheEvidenceLockForTesting(
        codexProviderId,
        account,
        () => entered = true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(entered, isFalse);
    expect(Directory('${canonicalLockPath()}.claim').existsSync(), isTrue);
  });

  test('ordinary first-use create contention proceeds with the winner file',
      () {
    var injected = false;
    setEvidenceGuardObserverForTesting((phase, path) {
      if (phase == 'before_create' && !injected) {
        injected = true;
        File(path).createSync(recursive: true, exclusive: true);
      }
    });

    expect(
      withCacheEvidenceLockForTesting(
        codexProviderId,
        account,
        () => 'entered',
      ),
      'entered',
    );
    expect(injected, isTrue);
    expect(
      FileSystemEntity.typeSync(canonicalLockPath(), followLinks: false),
      FileSystemEntityType.file,
    );
    expect(File('${canonicalLockPath()}.claim').existsSync(), isFalse);
  });

  test('ordered guards share one acquisition deadline', () {
    setEvidenceGuardObserverForTesting((phase, _) {
      if (phase == 'before_acquire') {
        sleep(const Duration(milliseconds: 20));
      }
    });
    var entered = false;

    expect(
      () => withCacheEvidenceLockForTesting(
        codexProviderId,
        account,
        () => entered = true,
        includeLegacy: true,
        operationTimeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(entered, isFalse);
    expect(File('${canonicalLockPath()}.claim').existsSync(), isFalse);
    expect(File('${legacyLockPath()}.claim').existsSync(), isFalse);
  });

  test('leaf replacement before acquisition fails closed', () {
    var replaced = false;
    setEvidenceGuardObserverForTesting((phase, path) {
      if (phase != 'before_acquire' || replaced) return;
      File(path).deleteSync();
      Directory(path).createSync();
      replaced = true;
    });
    var entered = false;

    expect(
      () => withCacheEvidenceLockForTesting(
        codexProviderId,
        account,
        () => entered = true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(replaced, isTrue);
    expect(entered, isFalse);
  });

  test('non-directory cache root fails closed before hardening a leaf', () {
    final root = Directory('${temp.path}/quotabot/cache');
    root.parent.createSync(recursive: true);
    File(root.path).createSync();

    expect(
      cacheDir,
      throwsA(isA<FileSystemException>()),
    );
  });

  test('a second process cannot enter until the evidence guard is released',
      () async {
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final fixture =
        File('test/fixtures/cache_evidence_lock_holder.dart').absolute.path;
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--enable-asserts',
        '--packages=$packageConfig',
        fixture,
        temp.path,
        account,
        '1000',
      ],
      workingDirectory: Directory.current.path,
    );
    final stderr = process.stderr.transform(utf8.decoder).join();
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 30));
    expect(line, 'locked');

    final elapsed = Stopwatch()..start();
    final value = withCacheEvidenceLockForTesting(
      codexProviderId,
      account,
      () => 'after',
    );
    elapsed.stop();

    expect(value, 'after');
    expect(elapsed.elapsedMilliseconds, greaterThanOrEqualTo(500));
    expect(await process.exitCode, 0, reason: await stderr);
    expect(File('${canonicalLockPath()}.claim').existsSync(), isFalse);
  });

  test('an aged live claim excludes another isolate in the same process',
      () async {
    final releaseFile = File('${temp.path}/release-evidence-guard');
    final holderMessages = ReceivePort();
    final holder = await Isolate.spawn<List<Object>>(
      _holdAgedCacheEvidenceLock,
      <Object>[
        temp.path,
        account,
        holderMessages.sendPort,
        releaseFile.path,
      ],
    );
    final holderIterator = StreamIterator<Object?>(holderMessages);
    Isolate? waiter;
    ReceivePort? waiterMessages;
    addTearDown(() {
      holder.kill(priority: Isolate.immediate);
      waiter?.kill(priority: Isolate.immediate);
      holderMessages.close();
      waiterMessages?.close();
    });
    expect(
      await holderIterator.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(holderIterator.current, 'locked');

    waiterMessages = ReceivePort();
    final waiterIterator = StreamIterator<Object?>(waiterMessages);
    waiter = await Isolate.spawn<List<Object>>(
      _waitForCacheEvidenceLock,
      <Object>[
        temp.path,
        account,
        waiterMessages.sendPort,
        releaseFile.path,
      ],
    );
    expect(
      await waiterIterator.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(waiterIterator.current, 'waiting');
    // Give an incorrectly admitted waiter time to enter before allowing the
    // holder to release. The callback records whether release was observable,
    // so runner scheduling cannot create a timing-threshold failure.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    releaseFile.createSync();
    expect(
      await waiterIterator.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    final waited = waiterIterator.current;

    expect(waited, isA<Map<Object?, Object?>>());
    final result = waited as Map<Object?, Object?>;
    expect(result['release_observed'], isTrue);
    expect(result['elapsed_ms'], isA<int>());
    expect(
      await holderIterator.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(holderIterator.current, 'released');
    expect(File('${canonicalLockPath()}.claim').existsSync(), isFalse);
    await holderIterator.cancel();
    await waiterIterator.cancel();
  });
}
