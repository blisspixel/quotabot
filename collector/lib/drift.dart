/// The silent-drift canary: compares a fresh provider reading against the last
/// cached one and flags a value that is implausible given the previous read.
///
/// 1.0 acceptance criterion 1 is that every provider either reads correctly or
/// fails with a plain message. Static bounds and staleness cover the "fails"
/// half, but a read that is *wrong yet does not fail* - a repurposed field, an
/// inverted value, a fuzzy-key match that grabs an unrelated number - slips
/// through. This is the first use of history to validate a fresh read: it does
/// not hide the number (that would be its own kind of lie), it annotates it so
/// `verify`, `doctor`, and agents can surface a concern and a human can
/// cross-check.
library;

import 'models.dart';
import 'provider_ids.dart';

/// A reset may jitter by this many seconds before a backwards move counts as a
/// regression, absorbing minor clock and reporting noise.
const int _resetRegressToleranceSeconds = 300;

/// Used-percent must fall by more than this many points, within an unreset
/// window, before it counts as an implausible headroom gain (absorbs rounding).
const double _headroomGainTolerancePoints = 2.0;

/// Providers whose single window is not a plain consume-then-reset pool, so the
/// monotonicity checks do not apply. Antigravity's lone window is a max over a
/// changing per-model set, so its headroom and reset can both move
/// non-monotonically; its real signal is per-model quota, checked elsewhere.
const _syntheticWindowProviders = {antigravityProviderId};

/// Providers whose pool total can legitimately be re-rated downward mid-window,
/// so a used-percent drop is expected rather than drift. xAI does this to the
/// Grok credit pool (observed 100 -> 73 under an unchanged reset).
const _reRatingProviders = {grokProviderId};

/// Returns a short reason when [fresh] is implausible versus [previous] - the
/// signature of a silently drifted read rather than normal consumption or a
/// reset - or null when the reading is consistent. Windows are matched by label
/// so only like is compared with like. Fail-soft: the caller still shows the
/// number, only annotated as suspect.
String? detectQuotaDrift(ProviderQuota fresh, ProviderQuota previous) {
  if (_syntheticWindowProviders.contains(fresh.provider)) return null;
  final prev = {for (final w in previous.windows) w.label: w};
  for (final w in fresh.windows) {
    final p = prev[w.label];
    if (p == null) continue;
    final reason = _windowDrift(fresh.provider, w, p);
    if (reason != null) return '${w.label} $reason';
  }
  return null;
}

String? _windowDrift(String provider, QuotaWindow fresh, QuotaWindow previous) {
  final fr = fresh.resetsAt;
  final pr = previous.resetsAt;
  // (1) A reset only ever advances or holds; one that moved earlier by more
  // than the tolerance is implausible for any provider.
  if (fr != null && pr != null && fr < pr - _resetRegressToleranceSeconds) {
    return 'reset moved earlier';
  }
  // (2) Within one window instance (same reset, none passed) usage can only
  // rise: you consume, you do not regain - unless the provider re-rates its
  // pool, which is accepted, not drift.
  if (!_reRatingProviders.contains(provider) &&
      fr != null &&
      pr != null &&
      fr == pr) {
    final fu = fresh.percent;
    final pu = previous.percent;
    if (fu != null && pu != null && fu < pu - _headroomGainTolerancePoints) {
      return 'usage fell ${pu.round()}% to ${fu.round()}% with no reset';
    }
  }
  return null;
}
