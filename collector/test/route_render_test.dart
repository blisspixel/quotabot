import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/route_render.dart';
import 'package:test/test.dart';

RouteCandidate _candidate({
  required String provider,
  double? headroom = 92,
  bool stale = false,
  bool available = true,
  String? driftReason,
  double? confidence,
  double? strandProbability,
  bool capabilityLimited = false,
  bool capabilityBudgetLimited = false,
  String? bindingPool,
}) =>
    RouteCandidate(
      provider: provider,
      account: 'a',
      plan: 'pro',
      source: null,
      sourceClass: ProviderSourceClass.authoritativeLive,
      isLocal: false,
      asOf: 1000,
      perMachine: false,
      headroom: headroom,
      effectiveHeadroom: headroom,
      resetsAt: 5000,
      stale: stale,
      available: available,
      driftReason: driftReason,
      confidence: confidence,
      strandProbability: strandProbability,
      capabilityLimited: capabilityLimited,
      capabilityBudgetLimited: capabilityBudgetLimited,
      bindingPool: bindingPool,
    );

void main() {
  final plain = AnsiStyle(false);

  test('the glance omits the internal confidence and strand scores', () {
    // Even a recommended candidate with a high strand probability must not leak
    // "conf" or "strand" onto the plain surface; those stay in suggest --json.
    final line = routeCandidateGlanceLine(
      _candidate(provider: 'codex', confidence: 0.33, strandProbability: 0.98),
      style: plain,
      provenance: '[live, authoritative, quota plan]',
    );
    expect(line, isNot(contains('conf')));
    expect(line, isNot(contains('strand')));
    expect(line, contains('codex'));
    expect(line, contains('92% free'));
    expect(line, contains('[live, authoritative, quota plan]'));
  });

  test('a spent candidate reads as spent, a stale one as last known', () {
    final spent = routeCandidateGlanceLine(
      _candidate(provider: 'claude', headroom: 0, available: false),
      style: plain,
      provenance: '[live]',
    );
    expect(spent, contains('spent'));

    final staleLine = routeCandidateGlanceLine(
      _candidate(
        provider: 'grok',
        headroom: 48,
        stale: true,
        available: false,
      ),
      style: plain,
      provenance: '[cached]',
    );
    expect(staleLine, contains('48% last known'));
    expect(staleLine, contains('unavailable'));
  });

  test('a capability-limited candidate with headroom reads "no capable model"',
      () {
    // The real kiro case: 100% free but no catalog model meets the route floor,
    // so it must not read the contradictory "free ... spent".
    final line = routeCandidateGlanceLine(
      _candidate(
        provider: 'kiro',
        headroom: 100,
        available: false,
        capabilityLimited: true,
      ),
      style: plain,
      provenance: '[live]',
    );
    expect(line, contains('100% free'));
    expect(line, contains('no capable model'));
    expect(line, isNot(contains('spent')));
  });

  test('a budget-limited candidate reads "model budget spent", not spent', () {
    // A capable model exists but its model-budget gate is closed - distinct from
    // "no capable model" and from a depleted window. The glance must match the
    // distinction suggestRoute's reason draws.
    final line = routeCandidateGlanceLine(
      _candidate(
        provider: 'codex',
        headroom: 100,
        available: false,
        capabilityBudgetLimited: true,
      ),
      style: plain,
      provenance: '[live]',
    );
    expect(line, contains('model budget spent'));
    expect(line, isNot(contains('no capable model')));
  });

  test('a genuinely spent candidate still reads as spent', () {
    final line = routeCandidateGlanceLine(
      _candidate(provider: 'claude', headroom: 0, available: false),
      style: plain,
      provenance: '[live]',
    );
    expect(line, contains('spent'));
    expect(line, isNot(contains('no capable model')));
  });

  test('a drift candidate reads as last trusted, never as fresh free', () {
    final line = routeCandidateGlanceLine(
      _candidate(
        provider: 'codex',
        headroom: 70,
        stale: true,
        available: false,
        driftReason: 'weekly quota window disappeared',
      ),
      style: plain,
      provenance: '[cached]',
    );
    expect(line, contains('last trusted'));
    expect(line, isNot(contains('free')));
  });

  test('an available model-budget route reads as an open pool', () {
    final line = routeCandidateGlanceLine(
      _candidate(
        provider: 'antigravity',
        headroom: 100,
        bindingPool: 'model_budget',
      ),
      style: plain,
      provenance: '[live]',
    );
    expect(line, contains('100% open pool'));
    expect(line, isNot(contains('100% free')));
    expect(line, isNot(contains('spent')));
  });

  test('the shared route line names the provider, headroom, and reason tail',
      () {
    final glance = humanRouteGlance(
      RouteSuggestion(
        recommended: _candidate(provider: 'antigravity', headroom: 79),
        ranked: const [],
        reason: 'Use antigravity - best risk-adjusted runway (79% free).',
        decisionCode: RouteDecisionCode.bestRunway,
        usingLocalFallback: false,
        fallback: const RouteFallback(
          kind: RouteFallbackKind.passthrough,
          reason: 'use the requested provider',
        ),
        asOf: 1000,
        riskZ: 0,
      ),
      1000,
    );
    expect(glance.signature, startsWith('next  Antigravity  79% free'));
    expect(glance.reasonTail, 'best risk-adjusted runway (79% free).');
    expect(glance.lines.join('\n'), isNot(contains('passthrough')));
    expect(glance.lines.join('\n'), isNot(contains('Evidence:')));
  });

  test('an empty fleet names the usual model instead of an internal fallback',
      () {
    final glance = humanRouteGlance(
      const RouteSuggestion(
        recommended: null,
        ranked: [],
        reason: 'No quota read yet.',
        decisionCode: RouteDecisionCode.noData,
        usingLocalFallback: false,
        fallback: RouteFallback(
          kind: RouteFallbackKind.passthrough,
          reason: 'use the requested provider',
        ),
        asOf: 1000,
        riskZ: 0,
      ),
      1000,
    );
    expect(
      glance.signature,
      'next  your usual model (no quota read yet; quotabot login claude)',
    );
    expect(glance.lines, hasLength(1));
  });

  test('cached evidence names the provider instead of a login prompt', () {
    final glance = humanRouteGlance(
      RouteSuggestion(
        recommended: null,
        ranked: [
          _candidate(
            provider: 'grok',
            headroom: 48,
            stale: true,
            available: false,
          ),
        ],
        reason:
            'Only cached quota evidence is present; grok last-known headroom was 48%. Reconnect before routing from that number.',
        decisionCode: RouteDecisionCode.staleEvidence,
        usingLocalFallback: false,
        fallback: const RouteFallback(
          kind: RouteFallbackKind.passthrough,
          reason: 'use the requested provider',
        ),
        asOf: 1000,
        riskZ: 0,
      ),
      1000,
    );
    expect(glance.signature, 'next  Grok  cached');
    expect(
        glance.reasonTail, contains('Only cached quota evidence is present'));
    expect(glance.lines.join('\n'), isNot(contains('quotabot login')));
    expect(glance.lines.join('\n'), isNot(contains('48% last known')));
  });

  test('provider drift names the provider and stays off the login prompt', () {
    final glance = humanRouteGlance(
      RouteSuggestion(
        recommended: null,
        ranked: [
          _candidate(
            provider: 'claude',
            headroom: 37,
            stale: true,
            available: false,
            driftReason: '5h usage fell 63% to 10% with no reset',
          ),
        ],
        reason:
            'Provider drift rejected the only quota evidence; claude is not routable because last-trusted headroom is 37%. Run quotabot verify and compare the provider view.',
        decisionCode: RouteDecisionCode.providerDrift,
        usingLocalFallback: false,
        fallback: const RouteFallback(
          kind: RouteFallbackKind.passthrough,
          reason: 'use the requested provider',
        ),
        asOf: 1000,
        riskZ: 0,
      ),
      1000,
    );
    expect(glance.signature, 'next  Claude  not routable');
    expect(glance.lines.join('\n'), contains('quotabot verify'));
    expect(glance.lines.join('\n'), isNot(contains('quotabot login')));
  });
}
