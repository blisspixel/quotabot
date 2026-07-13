import 'dart:convert';

import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_ids.dart';
import 'package:test/test.dart';

void main() {
  ProviderQuota snap(String provider, List<QuotaWindow> windows) =>
      ProviderQuota(
        provider: provider,
        displayName: provider,
        account: 'a',
        asOf: 0,
        windows: windows,
      );
  QuotaWindow win(String label, double used, int reset) =>
      QuotaWindow(label: label, usedPercent: used, resetsAt: reset);
  ProviderQuota snapModels(String provider, List<ModelQuota> models) =>
      ProviderQuota(
        provider: provider,
        displayName: provider,
        account: 'a',
        asOf: 0,
        modelQuotas: models,
      );

  group('detectQuotaDrift', () {
    test('normal consumption within a window is not flagged', () {
      final prev = snap(claudeProviderId, [win('5h', 20, 1000)]);
      final fresh = snap(claudeProviderId, [win('5h', 35, 1000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('a reset that moved earlier is flagged for any provider', () {
      final prev = snap(claudeProviderId, [win('weekly', 40, 2000)]);
      final fresh = snap(claudeProviderId, [win('weekly', 41, 1000)]);
      expect(detectQuotaDrift(fresh, prev), contains('reset moved earlier'));
    });

    test('usage falling with no reset is flagged for a normal provider', () {
      final prev = snap(codexProviderId, [win('5h', 60, 1000)]);
      final fresh = snap(codexProviderId, [win('5h', 10, 1000)]);
      final reason = detectQuotaDrift(fresh, prev);
      expect(reason, contains('usage fell'));
      expect(reason, contains('no reset'));
    });

    test('a clean reset rollover (reset advances, usage drops) is not flagged',
        () {
      final prev = snap(claudeProviderId, [win('5h', 90, 1000)]);
      final fresh = snap(claudeProviderId, [win('5h', 0, 5000)]);
      expect(detectQuotaDrift(fresh, prev, observedAt: 1001), isNull);
    });

    test('a forward reset cannot hide a usage drop before the prior reset', () {
      final prev = snap(claudeProviderId, [win('5h', 90, 5000)]);
      final fresh = snap(claudeProviderId, [win('5h', 0, 9000)]);
      expect(
        detectQuotaDrift(fresh, prev, observedAt: 200),
        contains('before the prior reset'),
      );
    });

    test('Grok pool re-rating (usage drops, no reset) is accepted, not flagged',
        () {
      // xAI re-rates the credit pool, so headroom can grow with no reset.
      final prev = snap(grokProviderId, [win('weekly', 27, 1000)]);
      final fresh = snap(grokProviderId, [win('weekly', 0, 1000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('a Grok reset that moved earlier is still flagged', () {
      // Re-rating exempts headroom gains, not an implausible reset.
      final prev = snap(grokProviderId, [win('weekly', 20, 2000)]);
      final fresh = snap(grokProviderId, [win('weekly', 20, 1000)]);
      expect(detectQuotaDrift(fresh, prev), contains('reset moved earlier'));
    });

    test('Codex weekly re-rating (usage drops, no reset) is accepted', () {
      // OpenAI's Codex weekly window is non-monotonic; a used-percent drop is
      // the latest truth to show, not drift, so the fresh lower value must be
      // admitted rather than replaced with a stale higher one.
      final prev = snap(codexProviderId, [win('weekly', 59, 1000)]);
      final fresh = snap(codexProviderId, [win('weekly', 34, 1000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('a Codex reset that moved earlier is still flagged', () {
      // The re-rating exemption covers usage drops, not an implausible reset.
      final prev = snap(codexProviderId, [win('weekly', 20, 2000)]);
      final fresh = snap(codexProviderId, [win('weekly', 20, 1000)]);
      expect(detectQuotaDrift(fresh, prev), contains('reset moved earlier'));
    });

    test('a Codex window disappearing is a restructure, not drift', () {
      // OpenAI collapsed Codex Pro's separate 5h and weekly buckets into a
      // single weekly window. The vanished 5h must not pin the pre-restructure
      // snapshot; the fresh single-window read is the current truth to show.
      final prev = snap(codexProviderId, [
        win('5h', 40, 1000),
        win('weekly', 93, 2000),
      ]);
      final fresh = snap(codexProviderId, [win('weekly', 4, 600000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('the disappeared-window exemption is scoped to Codex', () {
      // A non-variable provider losing a window is still genuine drift, so the
      // Codex restructure carve-out cannot mask a parser regression elsewhere.
      final prev = snap(claudeProviderId, [
        win('5h', 40, 1000),
        win('weekly', 30, 2000),
      ]);
      final fresh = snap(claudeProviderId, [win('weekly', 30, 2000)]);
      expect(detectQuotaDrift(fresh, prev),
          contains('5h quota window disappeared'));
    });

    test('a Codex collapse that loses the longest cap is still flagged', () {
      // The exemption covers folding into a longer window (5h vanishes, weekly
      // survives), not losing the long-term cap. If a parser regression drops
      // the weekly (reset far out) and only the 5h (reset soon) survives, no
      // surviving window reaches as far, so it must still be flagged rather than
      // silently accepted.
      final prev = snap(codexProviderId, [
        win('5h', 40, 1000),
        win('weekly', 30, 600000),
      ]);
      final fresh = snap(codexProviderId, [win('5h', 40, 1000)]);
      expect(detectQuotaDrift(fresh, prev),
          contains('weekly quota window disappeared'));
    });

    test('Antigravity is exempt: its window is a max over a changing set', () {
      final prev = snap(antigravityProviderId, [win('5h', 80, 2000)]);
      // Both a headroom gain and a reset regression, yet not flagged.
      final fresh = snap(antigravityProviderId, [win('5h', 5, 1000)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('small reset jitter and rounding stay within tolerance', () {
      final prev = snap(claudeProviderId, [win('5h', 40, 2000)]);
      final fresh = snap(claudeProviderId, [win('5h', 39, 1900)]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('a previously trusted window cannot disappear', () {
      final prev = snap(claudeProviderId, [win('5h', 40, 1000)]);
      final fresh = snap(claudeProviderId, [win('weekly', 5, 9000)]);
      expect(detectQuotaDrift(fresh, prev),
          contains('5h quota window disappeared'));
    });

    test('an additive window does not invalidate retained evidence', () {
      final prev = snap(claudeProviderId, [win('5h', 40, 1000)]);
      final fresh = snap(claudeProviderId, [
        win('5h', 45, 1000),
        win('weekly', 5, 9000),
      ]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });

    test('the flagged reason names the window', () {
      final prev = snap(claudeProviderId, [win('weekly', 50, 1000)]);
      final fresh = snap(claudeProviderId, [win('weekly', 5, 1000)]);
      expect(detectQuotaDrift(fresh, prev), startsWith('weekly '));
    });

    test('Antigravity per-model drift is caught though its window is exempt',
        () {
      final prev = snapModels(antigravityProviderId, [
        const ModelQuota(
            model: 'Gemini 3.5 Flash', usedPercent: 60, resetsAt: 1000),
      ]);
      final fresh = snapModels(antigravityProviderId, [
        const ModelQuota(
            model: 'Gemini 3.5 Flash', usedPercent: 5, resetsAt: 1000),
      ]);
      final reason = detectQuotaDrift(fresh, prev);
      expect(reason, contains('Gemini 3.5 Flash'));
      expect(reason, contains('usage fell'));
    });

    test('a per-model reset that moved earlier is flagged', () {
      final prev = snapModels(antigravityProviderId, [
        const ModelQuota(
            model: 'Claude Opus 4.6', usedPercent: 10, resetsAt: 2000),
      ]);
      final fresh = snapModels(antigravityProviderId, [
        const ModelQuota(
            model: 'Claude Opus 4.6', usedPercent: 10, resetsAt: 1000),
      ]);
      expect(detectQuotaDrift(fresh, prev), contains('reset moved earlier'));
    });

    test('normal per-model consumption is not flagged', () {
      final prev = snapModels(antigravityProviderId, [
        const ModelQuota(
            model: 'Gemini 3.5 Flash', usedPercent: 5, resetsAt: 1000),
      ]);
      final fresh = snapModels(antigravityProviderId, [
        const ModelQuota(
            model: 'Gemini 3.5 Flash', usedPercent: 20, resetsAt: 1000),
      ]);
      expect(detectQuotaDrift(fresh, prev), isNull);
    });
  });

  group('admitQuotaEvidence', () {
    ProviderQuota evidence({
      required double used,
      required int asOf,
      String account = 'a',
      String? source,
      ProviderSourceClass? sourceClass,
      bool perMachine = false,
      bool stale = false,
      String? suspect,
      String plan = 'pro',
      List<ModelInfo> models = const [],
      int reset = 5000,
    }) =>
        ProviderQuota(
          provider: codexProviderId,
          displayName: 'Codex',
          account: account,
          plan: plan,
          source: source,
          sourceClass: sourceClass,
          perMachine: perMachine,
          asOf: asOf,
          stale: stale,
          suspect: suspect,
          models: models,
          windows: [win('5h', used, reset)],
        );

    test('admits a consistent fresh reading for persistence', () {
      final previous = evidence(used: 20, asOf: 100);
      final fresh = evidence(used: 35, asOf: 200);

      final admission = admitQuotaEvidence(
        fresh,
        previous,
        observedAt: 210,
      );

      expect(admission.shouldPersist, isTrue);
      expect(admission.snapshot, same(fresh));
      expect(admission.driftReason, isNull);
    });

    test('rejects drift and returns only the exact last trusted evidence', () {
      final previous = evidence(
        used: 60,
        asOf: 100,
        models: const [ModelInfo(id: 'trusted-model')],
      );
      final fresh = evidence(
        used: 10,
        asOf: 200,
        models: const [ModelInfo(id: 'rejected-model')],
      );

      final admission = admitQuotaEvidence(
        fresh,
        previous,
        observedAt: 210,
      );

      expect(admission.shouldPersist, isFalse);
      expect(admission.driftReason, contains('usage fell'));
      expect(admission.snapshot.stale, isTrue);
      expect(admission.snapshot.asOf, previous.asOf);
      expect(admission.snapshot.windows.single.usedPercent, 60);
      expect(admission.snapshot.models.single.id, 'trusted-model');
      expect(admission.snapshot.driftObservedAt, 210);
      expect(admission.snapshot.error, contains('last trusted snapshot'));
      expect(previous.stale, isFalse, reason: 'the baseline stays immutable');
    });

    test('restored capacity after a reset is admitted, not held as drift', () {
      // The real Codex case behind "after the reset, quotabot should show the
      // capacity": the 5h window was nearly spent, then a reset advanced its
      // window and restored headroom. Because the reset moved forward, the drop
      // in used-percent is a legitimate refill, not a suspicious fall, so the
      // fresh higher-headroom reading must be admitted and shown - never held
      // back as "usage fell with no reset".
      final previous = evidence(used: 92, asOf: 100, reset: 5000);
      final restored = evidence(used: 15, asOf: 6000, reset: 11000);

      final admission = admitQuotaEvidence(
        restored,
        previous,
        observedAt: 6000,
      );

      expect(admission.shouldPersist, isTrue);
      expect(admission.driftReason, isNull);
      expect(admission.snapshot.windows.single.usedPercent, 15);
      expect(admission.snapshot.stale, isFalse);
    });

    test('an off-cycle Codex restructure admits the fresh single window', () {
      // The exact live case: a nearly-spent 5h+weekly snapshot, then OpenAI
      // restructures to one fresh weekly window at 4% used. The old 5h vanishes,
      // so the pre-restructure guard would otherwise pin the stale 93% weekly
      // and tell the user they are nearly out when they have full headroom.
      final previous = ProviderQuota(
        provider: codexProviderId,
        displayName: 'Codex',
        account: 'a',
        plan: 'pro',
        asOf: 100,
        windows: [win('5h', 40, 1000), win('weekly', 93, 2000)],
      );
      final restructured = ProviderQuota(
        provider: codexProviderId,
        displayName: 'Codex',
        account: 'a',
        plan: 'pro',
        asOf: 6000,
        windows: [win('weekly', 4, 600000)],
      );

      final admission = admitQuotaEvidence(
        restructured,
        previous,
        observedAt: 6000,
      );

      expect(admission.shouldPersist, isTrue);
      expect(admission.driftReason, isNull);
      expect(admission.snapshot.windows.single.label, 'weekly');
      expect(admission.snapshot.windows.single.usedPercent, 4);
    });

    test('identity and evidence-class changes establish a new baseline', () {
      final previous = evidence(used: 60, asOf: 100);
      final changedAccount = evidence(
        used: 10,
        asOf: 200,
        account: 'other',
      );
      final changedSource = evidence(
        used: 10,
        asOf: 200,
        source: providerQuotaManualSource,
      );
      final changedSourceClass = evidence(
        used: 10,
        asOf: 200,
        sourceClass: ProviderSourceClass.thisMachineFallback,
        perMachine: true,
      );

      for (final fresh in [changedAccount, changedSource, changedSourceClass]) {
        final admission = admitQuotaEvidence(
          fresh,
          previous,
          observedAt: 210,
        );
        expect(admission.shouldPersist, isTrue);
        expect(admission.snapshot, same(fresh));
      }
    });

    test('invalid source-class evidence is quarantined and never trusted', () {
      final invalid = evidence(
        used: 20,
        asOf: 100,
        sourceClass: ProviderSourceClass.thisMachineFallback,
      );

      expect(isTrustedQuotaEvidence(invalid), isFalse);
      final admission = admitQuotaEvidence(invalid, null, observedAt: 110);
      expect(admission.shouldPersist, isFalse);
      expect(admission.snapshot.ok, isFalse);
      expect(admission.snapshot.windows, isEmpty);
      expect(admission.driftReason, contains('machine-scoped'));

      final disallowed = ProviderQuota(
        provider: claudeProviderId,
        displayName: 'Claude',
        account: 'a',
        asOf: 100,
        sourceClass: ProviderSourceClass.passiveLocalEvidence,
        perMachine: true,
        windows: [win('5h', 20, 5000)],
      );
      expect(isTrustedQuotaEvidence(disallowed), isFalse);
      final rejected = admitQuotaEvidence(disallowed, null, observedAt: 110);
      expect(rejected.shouldPersist, isFalse);
      expect(rejected.driftReason, contains('not admitted for claude'));
    });

    test('legacy suspect evidence cannot be laundered by a repeated read', () {
      final legacy = evidence(used: 10, asOf: 100)
          .withSuspect('5h usage fell without a reset');
      final repeated = evidence(used: 10, asOf: 200);

      final admission = admitQuotaEvidence(
        repeated,
        legacy,
        observedAt: 210,
      );

      expect(admission.shouldPersist, isFalse);
      expect(admission.snapshot.ok, isFalse);
      expect(admission.snapshot.windows, isEmpty);
      expect(admission.snapshot.driftReason, contains('unresolved legacy'));
      expect(admission.snapshot.driftObservedAt, 210);
      expect(admission.snapshot.error, contains('no trusted snapshot'));
    });

    test('a materially advanced reset recovers from legacy quarantine', () {
      final legacy = evidence(used: 10, asOf: 100, reset: 5000)
          .withSuspect('5h usage fell without a reset');
      final afterReset = evidence(used: 12, asOf: 6000, reset: 9000);

      final admission = admitQuotaEvidence(
        afterReset,
        legacy,
        observedAt: 6010,
      );

      expect(admission.shouldPersist, isTrue);
      expect(admission.snapshot, same(afterReset));
      expect(admission.driftReason, isNull);
    });

    test('an unrelated short reset cannot clear legacy quarantine', () {
      final legacy = ProviderQuota(
        provider: codexProviderId,
        displayName: 'Codex',
        account: 'a',
        plan: 'pro',
        asOf: 100,
        windows: [
          win('5h', 10, 5000),
          win('weekly', 70, 10000),
        ],
        suspect: 'weekly usage fell without a reset',
      );
      final shortWindowRolled = ProviderQuota(
        provider: codexProviderId,
        displayName: 'Codex',
        account: 'a',
        plan: 'pro',
        asOf: 6000,
        windows: [
          win('5h', 5, 9000),
          win('weekly', 70, 10000),
        ],
      );

      final admission = admitQuotaEvidence(
        shortWindowRolled,
        legacy,
        observedAt: 6000,
      );

      expect(admission.shouldPersist, isFalse);
      expect(admission.snapshot.windows, isEmpty);
      expect(admission.driftReason, contains('unresolved legacy'));
    });

    test('live drift diagnostics are sanitized and bounded', () {
      final longLabel = '\x1b[31m${List.filled(700, 'x').join()}';
      final previous = ProviderQuota(
        provider: codexProviderId,
        displayName: 'Codex',
        account: 'a',
        plan: 'pro',
        asOf: 100,
        windows: [win(longLabel, 60, 5000)],
      );
      final fresh = ProviderQuota(
        provider: codexProviderId,
        displayName: 'Codex',
        account: 'a',
        plan: 'pro',
        asOf: 200,
        windows: [win(longLabel, 10, 5000)],
      );

      final admission = admitQuotaEvidence(
        fresh,
        previous,
        observedAt: 210,
      );

      expect(admission.driftReason, isNot(contains('\x1b')));
      expect(
        admission.driftReason!.length,
        lessThanOrEqualTo(kMaxQuotaDriftReasonCharacters),
      );
      expect(admission.snapshot.driftReason, admission.driftReason);
    });

    test('stale, suspect, and drift-marked evidence is never trusted', () {
      final trusted = evidence(used: 20, asOf: 100);
      expect(isTrustedQuotaEvidence(trusted), isTrue);
      expect(
        isTrustedQuotaEvidence(evidence(used: 20, asOf: 100, stale: true)),
        isFalse,
      );
      expect(
        isTrustedQuotaEvidence(
          evidence(used: 20, asOf: 100, suspect: 'legacy concern'),
        ),
        isFalse,
      );
      expect(
        isTrustedQuotaEvidence(
          trusted.withProviderDrift('usage fell', 120),
        ),
        isFalse,
      );
      expect(
        isTrustedQuotaEvidence(
          ProviderQuota(
            provider: codexProviderId,
            displayName: 'Codex',
            account: 'a',
            asOf: 100,
            windows: [QuotaWindow(label: 'weekly', resetsAt: 5000)],
          ),
        ),
        isFalse,
      );
    });
  });

  group('ProviderQuota.suspect', () {
    test('withSuspect annotates without hiding the reading', () {
      final q = snap(claudeProviderId, [win('5h', 40, 1000)]);
      final flagged = q.withSuspect('5h reset moved earlier');
      expect(flagged.suspect, '5h reset moved earlier');
      expect(flagged.windows.single.usedPercent, 40);
      expect(q.suspect, isNull); // original untouched
    });

    test('suspect round-trips through JSON and survives asStale', () {
      final q = snap(claudeProviderId, [win('5h', 40, 1000)])
          .withSuspect('5h usage fell 60% to 10% with no reset');
      final back = ProviderQuota.fromJson(
        jsonDecode(jsonEncode(q.toJson())) as Map<String, dynamic>,
      );
      expect(back.suspect, q.suspect);
      expect(back.asStale('cached').suspect, q.suspect);
    });

    test('stale fallback never grafts untrusted per-model quota', () {
      final trusted = ProviderQuota(
        provider: antigravityProviderId,
        displayName: 'Antigravity',
        account: 'a',
        asOf: 100,
        windows: [win('5h', 40, 1000)],
        modelQuotas: const [
          ModelQuota(model: 'Gemini', usedPercent: 40, resetsAt: 1000),
        ],
      );
      final failed = ProviderQuota(
        provider: antigravityProviderId,
        displayName: 'Antigravity',
        account: 'a',
        asOf: 200,
        ok: false,
        error: 'partial read failed',
        modelQuotas: const [
          ModelQuota(model: 'Gemini', usedPercent: 0, resetsAt: 9000),
        ],
      );

      final fallback = trusted.asStale('cached', metadataFrom: failed);
      expect(fallback.modelQuotas.single.usedPercent, 40);
      expect(fallback.modelQuotas.single.resetsAt, 1000);
    });
  });

  test('provider drift fields round-trip without changing suspect semantics',
      () {
    final trusted = snap(codexProviderId, [win('5h', 40, 1000)]);
    final drifted = trusted.withProviderDrift(
      '5h usage fell 60% to 10% with no reset',
      1234,
    );
    final back = ProviderQuota.fromJson(
      jsonDecode(jsonEncode(drifted.toJson())) as Map<String, dynamic>,
    );

    expect(back.stale, isTrue);
    expect(back.driftReason, drifted.driftReason);
    expect(back.driftObservedAt, 1234);
    expect(back.suspect, isNull);
  });
}
