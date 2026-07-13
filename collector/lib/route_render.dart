/// Presentation for the human `suggest` glance, kept separate from the routing
/// logic in analysis.dart and testable without spawning the CLI.
library;

import 'analysis.dart';
import 'ansi.dart';

/// The one-line human summary of a metered route candidate for the `suggest`
/// candidates list. It states only what a person acts on: how much headroom
/// remains, whether the route is usable now, and how the number reads (free,
/// last known/trusted, spent).
///
/// The model's internal scores - confidence, strand probability, and cost
/// weighting - are deliberately omitted here and reserved for the
/// machine-readable JSON (`suggest --json`), where they remain in full. The
/// raw scores read as jargon on a glance ("strand 98%" on the recommended
/// provider is alarming and needs a paragraph to interpret), so keeping them
/// out of the plain surface is what makes the advisor self-explanatory
/// (ROADMAP 0.9). This renders one metered candidate; local runtimes are a
/// distinct "runtime fallback" line handled by the caller.
///
/// [provenance] is the already-formatted trust and source tag, and [style]
/// applies color (or is a no-color style). The leading indent matches the rest
/// of the candidates block.
String routeCandidateGlanceLine(
  RouteCandidate c, {
  required AnsiStyle style,
  required String provenance,
}) {
  final pct = c.headroom == null
      ? '   ? '
      : '${c.headroom!.round().toString().padLeft(3)}%';
  final head = c.headroom == null
      ? pct
      : c.stale
          ? style.dim(pct)
          : style.health(c.headroom!, pct);
  final qualifier = c.driftReason != null
      ? c.headroom == null
          ? 'no trusted quota'
          : 'last trusted'
      : c.stale
          ? 'last known'
          : 'free';
  final state = c.available
      ? ''
      : c.driftReason != null || c.stale
          ? style.dim('  unavailable')
          : style.red('  spent');
  return '    ${c.provider.padRight(12)} $head $qualifier  $provenance$state';
}
