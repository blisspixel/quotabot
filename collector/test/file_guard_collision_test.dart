import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/file_guard.dart';
import 'package:quotabot_collector/src/exclusive_create_collision.dart';
import 'package:test/test.dart';

FileSystemException _failure(int? code) => FileSystemException(
      'exclusive create failed',
      'claim',
      code == null ? null : OSError('test', code),
    );

void main() {
  test('known exclusive-create collisions retry after file churn', () {
    for (final code in [17, 80, 183]) {
      expect(
        shouldRetryExclusiveCreateFailure(
          _failure(code),
          FileSystemEntityType.file,
        ),
        isTrue,
        reason: 'existing claim, error $code',
      );
      expect(
        shouldRetryExclusiveCreateFailure(
          _failure(code),
          FileSystemEntityType.notFound,
        ),
        isTrue,
        reason: 'released claim, error $code',
      );
    }
  });

  test('non-collision failures stay fatal for regular or vanished claims', () {
    for (final code in <int?>[null, 2, 3, 5, 32]) {
      expect(
        shouldRetryExclusiveCreateFailure(
          _failure(code),
          FileSystemEntityType.file,
        ),
        isFalse,
        reason: 'existing claim, error $code',
      );
      expect(
        shouldRetryExclusiveCreateFailure(
          _failure(code),
          FileSystemEntityType.notFound,
        ),
        isFalse,
        reason: 'vanished claim, error $code',
      );
    }
  });

  test('invalid claim entity types never become contention', () {
    for (final type in [
      FileSystemEntityType.directory,
      FileSystemEntityType.link,
      FileSystemEntityType.unixDomainSock,
      FileSystemEntityType.pipe,
    ]) {
      expect(
        shouldRetryExclusiveCreateFailure(_failure(17), type),
        isFalse,
        reason: 'entity type $type',
      );
    }
  });

  test('claim ownership is published before hardening and cleanup is owned',
      () {
    final dir = Directory.systemTemp.createTempSync('quotabot-guard-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final lockFile = File('${dir.path}${Platform.pathSeparator}store.lock')
      ..createSync();
    final claimFile = File('${lockFile.path}.claim');

    expect(
      () => acquireInterprocessFileGuardSync(
        lockFile,
        hardenClaim: (file) {
          final published = jsonDecode(file.readAsStringSync()) as Map;
          expect(published['pid'], pid);
          expect(published['owner'], isA<String>());
          file.writeAsStringSync(
            jsonEncode({'pid': pid, 'owner': 'replacement-owner'}),
            flush: true,
          );
          throw StateError('injected hardener failure');
        },
      ),
      throwsStateError,
    );
    expect(claimFile.existsSync(), isTrue);
    expect(
      (jsonDecode(claimFile.readAsStringSync()) as Map)['owner'],
      'replacement-owner',
    );
  });

  test('oversized stale claims fail closed without an unbounded read', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-guard-test-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final lockFile = File('${dir.path}${Platform.pathSeparator}store.lock')
      ..createSync();
    final claimFile = File('${lockFile.path}.claim')
      ..writeAsStringSync(List.filled(1025, 'x').join(), flush: true)
      ..setLastModifiedSync(
        DateTime.now().subtract(const Duration(seconds: 5)),
      );

    expect(
      () => acquireInterprocessFileGuardSync(
        lockFile,
        hardenClaim: (_) {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(claimFile.lengthSync(), 1025);
  });

  test('a missing lock parent remains fatal instead of retrying forever', () {
    final dir = Directory.systemTemp.createTempSync('quotabot-guard-test-');
    final missingParent = Directory(
      '${dir.path}${Platform.pathSeparator}missing',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    expect(
      () => acquireInterprocessFileGuardSync(
        File('${missingParent.path}${Platform.pathSeparator}store.lock'),
        hardenClaim: (_) {},
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
