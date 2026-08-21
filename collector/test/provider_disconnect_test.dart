import 'dart:io';

import 'package:quotabot_collector/auth/provider_disconnect.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory authDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('quotabot_disconnect_test_');
    authDir = Directory('${root.path}/auth')..createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('provider markers are exact, isolated, and idempotent', () {
    Directory dirFactory() => authDir;

    for (final provider in ['grok', 'antigravity', 'claude', 'codex']) {
      expect(
        ProviderDisconnectStore.isDisconnected(
          provider,
          dirFactory: dirFactory,
        ),
        isFalse,
      );
      ProviderDisconnectStore.markDisconnected(
        provider,
        dirFactory: dirFactory,
      );
      ProviderDisconnectStore.markDisconnected(
        provider,
        dirFactory: dirFactory,
      );
      expect(
        ProviderDisconnectStore.isDisconnected(
          provider,
          dirFactory: dirFactory,
        ),
        isTrue,
      );
    }

    ProviderDisconnectStore.clearDisconnected(
      'claude',
      dirFactory: dirFactory,
    );
    ProviderDisconnectStore.clearDisconnected(
      'claude',
      dirFactory: dirFactory,
    );
    expect(
      ProviderDisconnectStore.isDisconnected(
        'claude',
        dirFactory: dirFactory,
      ),
      isFalse,
    );
    expect(
      ProviderDisconnectStore.isDisconnected(
        'codex',
        dirFactory: dirFactory,
      ),
      isTrue,
    );
  });

  test('unknown and path-like provider ids cannot select marker paths', () {
    Directory dirFactory() => authDir;
    for (final provider in ['bogus', '../claude', 'Claude']) {
      expect(
        () => ProviderDisconnectStore.markDisconnected(
          provider,
          dirFactory: dirFactory,
        ),
        throwsArgumentError,
      );
    }
  });

  test('cleanup failure leaves the marker published', () {
    Directory dirFactory() => authDir;

    expect(
      () => ProviderDisconnectStore.markDisconnected(
        'grok',
        dirFactory: dirFactory,
        afterMark: () => throw StateError('cleanup failed'),
      ),
      throwsStateError,
    );
    expect(
      ProviderDisconnectStore.isDisconnected(
        'grok',
        dirFactory: dirFactory,
      ),
      isTrue,
    );
  });

  test('only a successfully published login clears the marker', () {
    Directory dirFactory() => authDir;
    ProviderDisconnectStore.markDisconnected(
      'codex',
      dirFactory: dirFactory,
    );

    expect(
      () => ProviderDisconnectStore.publishSuccessfulLogin(
        'codex',
        () => throw StateError('grant save failed'),
        dirFactory: dirFactory,
      ),
      throwsStateError,
    );
    expect(
      ProviderDisconnectStore.isDisconnected(
        'codex',
        dirFactory: dirFactory,
      ),
      isTrue,
    );

    final saved = ProviderDisconnectStore.publishSuccessfulLogin(
      'codex',
      () => 'saved',
      dirFactory: dirFactory,
    );
    expect(saved, 'saved');
    expect(
      ProviderDisconnectStore.isDisconnected(
        'codex',
        dirFactory: dirFactory,
      ),
      isFalse,
    );
  });

  test('marker writes never follow a symbolic link', () {
    Directory dirFactory() => authDir;
    final outside = File('${root.path}/outside')..writeAsStringSync('sentinel');
    final marker = ProviderDisconnectStore.markerFile(
      'grok',
      dirFactory: dirFactory,
    );
    try {
      Link(marker.path).createSync(outside.path);
    } on FileSystemException {
      return;
    }

    expect(
      ProviderDisconnectStore.isDisconnected(
        'grok',
        dirFactory: dirFactory,
      ),
      isTrue,
    );
    expect(
      () => ProviderDisconnectStore.markDisconnected(
        'grok',
        dirFactory: dirFactory,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(outside.readAsStringSync(), 'sentinel');

    ProviderDisconnectStore.clearDisconnected(
      'grok',
      dirFactory: dirFactory,
    );
    expect(Link(marker.path).existsSync(), isFalse);
    expect(outside.readAsStringSync(), 'sentinel');
  });

  test('non-regular marker entries fail closed', () {
    Directory dirFactory() => authDir;
    final marker = ProviderDisconnectStore.markerFile(
      'claude',
      dirFactory: dirFactory,
    );
    Directory(marker.path).createSync();

    expect(
      ProviderDisconnectStore.isDisconnected(
        'claude',
        dirFactory: dirFactory,
      ),
      isTrue,
    );
    expect(
      () => ProviderDisconnectStore.markDisconnected(
        'claude',
        dirFactory: dirFactory,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      () => ProviderDisconnectStore.clearDisconnected(
        'claude',
        dirFactory: dirFactory,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
