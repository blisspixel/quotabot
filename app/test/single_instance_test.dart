import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/single_instance.dart';

void main() {
  test(
    'a second instance detects the first and is told to step aside',
    () async {
      final primary = SingleInstanceGuard();
      var surfaced = false;
      final becamePrimary = await primary.tryBecomePrimary(
        onShowRequested: () async => surfaced = true,
      );
      addTearDown(primary.dispose);
      expect(becamePrimary, isTrue);

      final second = SingleInstanceGuard();
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
    final first = SingleInstanceGuard();
    expect(await first.tryBecomePrimary(onShowRequested: () async {}), isTrue);
    await first.dispose();

    final next = SingleInstanceGuard();
    final becamePrimary = await next.tryBecomePrimary(
      onShowRequested: () async {},
    );
    addTearDown(next.dispose);
    expect(becamePrimary, isTrue);
  });
}
