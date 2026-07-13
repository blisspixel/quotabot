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
}
