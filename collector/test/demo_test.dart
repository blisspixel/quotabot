import 'package:quotabot_collector/demo.dart';
import 'package:quotabot_collector/models.dart';
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
    for (final quota in fleet) {
      expect(quota.sourceClassViolation, isNull, reason: quota.provider);
    }
    final cursor = fleet.singleWhere((q) => q.provider == 'cursor');
    expect(cursor.sourceClass, ProviderSourceClass.passiveLocalEvidence);
    expect(cursor.perMachine, isTrue);
    // Every metered provider has at least one window with a future reset.
    for (final q in subs) {
      expect(q.windows, isNotEmpty, reason: q.provider);
      expect(q.windows.every((w) => (w.resetsAt ?? 0) > now), isTrue);
    }
    // Local runtimes expose models so the registry has something to show.
    expect(locals.any((q) => q.models.isNotEmpty), isTrue);
    expect(locals.any((q) => q.active), isTrue); // at least one loaded
    final grok = fleet.singleWhere((q) => q.provider == 'grok');
    expect(
      grok.details.single,
      'Category split of this weekly pool: 31%, 19%, 7%',
    );
    final ollama = fleet.singleWhere((q) => q.provider == 'ollama');
    expect(ollama.localHardware?.gpuName, 'GeForce RTX 4070');
    expect(
      ollama.details.any((line) => line.contains('GeForce RTX 4070')),
      isTrue,
    );
  });

  test('demo windows are within 0..100 percent used', () {
    for (final q in demoProviders(now)) {
      for (final w in q.windows) {
        expect(w.usedPercent, inInclusiveRange(0, 100));
      }
    }
  });
}
