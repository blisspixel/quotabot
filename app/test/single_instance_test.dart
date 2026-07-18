import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/single_instance.dart';

Future<int> _unusedLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test(
    'a second instance detects the first and is told to step aside',
    () async {
      final port = await _unusedLoopbackPort();
      final primary = SingleInstanceGuard(port: port);
      var surfaced = false;
      final becamePrimary = await primary.tryBecomePrimary(
        onShowRequested: () async => surfaced = true,
      );
      addTearDown(primary.dispose);
      expect(becamePrimary, isTrue);

      final second = SingleInstanceGuard(port: port);
      final secondBecamePrimary = await second.tryBecomePrimary(
        onShowRequested: () async {},
      );
      // The second instance must step aside...
      expect(secondBecamePrimary, isFalse);
      // ...and the first must have been asked to surface its window.
      expect(surfaced, isTrue);
    },
  );

  test('the lock is reusable once the primary disposes', () async {
    final port = await _unusedLoopbackPort();
    final first = SingleInstanceGuard(port: port);
    expect(await first.tryBecomePrimary(onShowRequested: () async {}), isTrue);
    await first.dispose();

    final next = SingleInstanceGuard(port: port);
    final becamePrimary = await next.tryBecomePrimary(
      onShowRequested: () async {},
    );
    addTearDown(next.dispose);
    expect(becamePrimary, isTrue);
  });

  test('a failed surface request does not acknowledge success', () async {
    final port = await _unusedLoopbackPort();
    final primary = SingleInstanceGuard(port: port);
    expect(
      await primary.tryBecomePrimary(
        onShowRequested: () async => throw StateError('cannot show window'),
      ),
      isTrue,
    );
    addTearDown(primary.dispose);

    final second = SingleInstanceGuard(port: port);
    expect(await second.tryBecomePrimary(onShowRequested: () async {}), isTrue);
  });
}
