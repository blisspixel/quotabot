import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/simulation.dart';
import 'package:test/test.dart';

void main() {
  const now = 1782000000;

  test('healthy simulation produces one live provider with future resets', () {
    final fleet = simulateFleet(
      provider: 'Claude',
      state: 'healthy',
      now: now,
    )!;

    expect(fleet, hasLength(1));
    final q = fleet.single;
    expect(q.provider, 'claude');
    expect(q.account, 'simulated');
    expect(q.plan, 'simulation');
    expect(q.ok, isTrue);
    expect(q.stale, isFalse);
    expect(q.windows, hasLength(2));
    expect(q.windows.every((w) => (w.resetsAt ?? 0) > now), isTrue);
    expect(providerHeadroom(q, now), greaterThan(50));
  });

  test('exhausted simulation marks the provider unavailable', () {
    final q = simulateProvider(
      provider: 'claude',
      state: 'exhausted',
      now: now,
    )!;

    expect(providerHeadroom(q, now), 0);
    expect(bindingWindow(q, now)?.label, '5h');
  });

  test('blocked simulation exercises the binding-window rule', () {
    final q = simulateProvider(
      provider: 'claude',
      state: 'blocked',
      now: now,
    )!;

    expect(providerHeadroom(q, now), 0);
    expect(bindingWindow(q, now)?.label, 'weekly');
  });

  test('invalid state and invalid provider are rejected', () {
    expect(normalizeSimulationState('missing'), isNull);
    expect(
      simulateFleet(provider: '../claude', state: 'healthy', now: now),
      isNull,
    );
  });
}
