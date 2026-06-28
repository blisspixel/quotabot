import 'package:quotabot_collector/demo.dart';
import 'package:test/test.dart';

void main() {
  const now = 1782000000;

  test('demo fleet has metered subscriptions and local runtimes', () {
    final fleet = demoProviders(now);
    expect(fleet, isNotEmpty);
    final subs = fleet.where((q) => !q.isLocal).toList();
    final locals = fleet.where((q) => q.isLocal).toList();
    expect(subs, isNotEmpty);
    expect(locals, isNotEmpty);
    // Every metered provider has at least one window with a future reset.
    for (final q in subs) {
      expect(q.windows, isNotEmpty, reason: q.provider);
      expect(q.windows.every((w) => (w.resetsAt ?? 0) > now), isTrue);
    }
    // Local runtimes expose models so the registry has something to show.
    expect(locals.any((q) => q.models.isNotEmpty), isTrue);
    expect(locals.any((q) => q.active), isTrue); // at least one loaded
  });

  test('demo windows are within 0..100 percent used', () {
    for (final q in demoProviders(now)) {
      for (final w in q.windows) {
        expect(w.usedPercent, inInclusiveRange(0, 100));
      }
    }
  });
}
