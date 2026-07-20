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

    test('a later 5h reset cannot hide a disappeared Codex weekly cap', () {
      // Reset order is not duration order. A weekly pool near its reset can end
      // before a fresh 5h pool while remaining the longer binding constraint.
      final prev = snap(codexProviderId, [
        win('5h', 40, 5000),
        win('weekly', 30, 1100),
      ]);
      final fresh = snap(codexProviderId, [win('5h', 45, 5000)]);

      expect(
        detectQuotaDrift(fresh, prev),
        contains('weekly quota window disappeared'),
      );
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

    test('Claude may add or remove an optional scoped model quota', () {
      final withoutFable = snapModels(claudeProviderId, const []);
      final withFable = snapModels(claudeProviderId, const [
        ModelQuota(model: 'Fable', usedPercent: 26, resetsAt: 2000),
      ]);

      expect(detectQuotaDrift(withFable, withoutFable), isNull);
      expect(detectQuotaDrift(withoutFable, withFable), isNull);
    });

    test('Codex may add or remove an optional scoped model quota', () {
      final withoutSpark = snapModels(codexProviderId, const []);
      final withSpark = snapModels(codexProviderId, const [
        ModelQuota(
          model: 'GPT-5.3-Codex-Spark',
          usedPercent: 26,
          resetsAt: 2000,
        ),
      ]);

      expect(detectQuotaDrift(withSpark, withoutSpark), isNull);
      expect(detectQuotaDrift(withoutSpark, withSpark), isNull);
    });

    test('Codex scoped quota uses its preserved window identity for drift', () {
      ProviderQuota spark(double used, String windowLabel) => snapModels(
            codexProviderId,
            [
              ModelQuota(
                model: 'GPT-5.3-Codex-Spark',
                usedPercent: used,
                resetsAt: 5000,
                windowLabel: windowLabel,
              ),
            ],
          );

      expect(
          detectQuotaDrift(spark(20, 'weekly'), spark(80, 'weekly')), isNull);
      expect(
        detectQuotaDrift(spark(20, '5h'), spark(80, '5h')),
        contains('usage fell'),
      );
    });

    test('Codex does not compare usage across different scoped windows', () {
      ProviderQuota spark(double used, String? windowLabel) => snapModels(
            codexProviderId,
            [
              ModelQuota(
                model: 'GPT-5.3-Codex-Spark',
                usedPercent: used,
                resetsAt: 5000,
                windowLabel: windowLabel,
              ),
            ],
          );

      expect(detectQuotaDrift(spark(20, 'weekly'), spark(80, '5h')), isNull);
      expect(detectQuotaDrift(spark(20, '5h'), spark(80, 'weekly')), isNull);
      expect(detectQuotaDrift(spark(20, 'weekly'), spark(80, null)), isNull);
    });

    test('Claude migrates legacy scoped windows out of provider windows', () {
      final previous = ProviderQuota(
        provider: claudeProviderId,
        displayName: 'Claude',
        account: 'max',
        asOf: 1000,
        windows: [
          win('5h', 45, 5000),
          win('weekly', 17, 9000),
          win('fable', 26, 9000),
        ],
      );
      final fresh = ProviderQuota(
        provider: claudeProviderId,
        displayName: 'Claude',
        account: 'max',
        asOf: 1100,
        windows: [win('5h', 45, 5000), win('weekly', 17, 9000)],
        modelQuotas: const [
          ModelQuota(model: 'Fable', usedPercent: 26, resetsAt: 9000),
        ],
      );

      expect(detectQuotaDrift(fresh, previous), isNull);
      final admission = admitQuotaEvidence(
        fresh,
        previous,
        observedAt: 1100,
      );
      expect(admission.shouldPersist, isTrue);
      expect(admission.snapshot, same(fresh));

      final withoutScopedCap = ProviderQuota(
        provider: claudeProviderId,
        displayName: 'Claude',
        account: 'max',
        asOf: 1100,
        windows: [win('5h', 45, 5000), win('weekly', 17, 9000)],
      );
      expect(detectQuotaDrift(withoutScopedCap, previous), isNull);
    });

    test('Claude still rejects impossible drift within the same scoped quota',
        () {
      final prev = snapModels(claudeProviderId, const [
        ModelQuota(model: 'Fable', usedPercent: 60, resetsAt: 2000),
      ]);
      final fresh = snapModels(claudeProviderId, const [
        ModelQuota(model: 'Fable', usedPercent: 20, resetsAt: 2000),
      ]);

      expect(detectQuotaDrift(fresh, prev), contains('usage fell'));
    });

    test('Antigravity still rejects a disappeared exhaustive model quota', () {
      final prev = snapModels(antigravityProviderId, const [
        ModelQuota(model: 'Gemini', usedPercent: 20, resetsAt: 2000),
      ]);
      final fresh = snapModels(antigravityProviderId, const []);

      expect(
          detectQuotaDrift(fresh, prev), contains('model quota disappeared'));
    });
  });

  group('admitQuotaEvidence', () {
    ProviderQuota evidence({
      required double used,
      required int asOf,
      String provider = codexProviderId,
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
          provider: provider,
          displayName: provider,
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

    test('a redeemed Codex reset may advance the 5h generation early', () {
      final previous = evidence(used: 92, asOf: 100, reset: 5000);
      final redeemed = evidence(used: 15, asOf: 200, reset: 11000);

      final admission = admitQuotaEvidence(
        redeemed,
        previous,
        observedAt: 210,
      );

      expect(210, lessThan(5000), reason: 'the prior reset has not passed');
      expect(admission.shouldPersist, isTrue);
      expect(admission.driftReason, isNull);
      expect(admission.snapshot, same(redeemed));
    });

    test('the early reset-generation exemption is Codex-only', () {
      final previous = evidence(
        provider: claudeProviderId,
        used: 92,
        asOf: 100,
        reset: 5000,
      );
      final advanced = evidence(
        provider: claudeProviderId,
        used: 15,
        asOf: 200,
        reset: 11000,
      );

      final admission = admitQuotaEvidence(
        advanced,
        previous,
        observedAt: 210,
      );

      expect(admission.shouldPersist, isFalse);
      expect(admission.driftReason, contains('before the prior reset'));
      expect(admission.snapshot.stale, isTrue);
    });

    test('same-generation Codex 5h usage drop remains drift', () {
      final previous = evidence(used: 92, asOf: 100, reset: 5000);
      final dropped = evidence(used: 15, asOf: 200, reset: 5000);

      final admission = admitQuotaEvidence(
        dropped,
        previous,
        observedAt: 210,
      );

      expect(admission.shouldPersist, isFalse);
      expect(admission.driftReason, contains('with no reset'));
      expect(admission.snapshot.stale, isTrue);
    });

    test('expired trusted baseline stays visible when fresh evidence fails',
        () {
      final previous = evidence(used: 72, asOf: 100, reset: 200);
      final expiredFresh = evidence(used: 0, asOf: 300, reset: 200);

      final admission = admitQuotaEvidence(
        expiredFresh,
        previous,
        observedAt: 300,
      );

      expect(admission.shouldPersist, isFalse);
      expect(admission.driftReason, contains('reset passed'));
      expect(admission.snapshot.stale, isTrue);
      expect(admission.snapshot.asOf, previous.asOf);
      expect(admission.snapshot.windows.single.usedPercent, 72);
      expect(admission.snapshot.windows.single.resetsAt, 200);
      expect(isTrustedQuotaEvidenceAt(admission.snapshot, 300), isFalse);
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
      final manualPrevious = evidence(
        provider: 'manual-tool',
        used: 60,
        asOf: 100,
      );
      final changedSource = evidence(
        provider: 'manual-tool',
        used: 10,
        asOf: 200,
        source: providerQuotaManualSource,
      );
      final antigravityPrevious = evidence(
        provider: antigravityProviderId,
        used: 60,
        asOf: 100,
      );
      final changedSourceClass = evidence(
        provider: antigravityProviderId,
        used: 10,
        asOf: 200,
        sourceClass: ProviderSourceClass.thisMachineFallback,
        perMachine: true,
      );

      for (final pair in [
        (previous: previous, fresh: changedAccount),
        (previous: manualPrevious, fresh: changedSource),
        (previous: antigravityPrevious, fresh: changedSourceClass),
      ]) {
        final admission = admitQuotaEvidence(
          pair.fresh,
          pair.previous,
          observedAt: 210,
        );
        expect(admission.shouldPersist, isTrue);
        expect(admission.snapshot, same(pair.fresh));
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
      expect(admission.driftReason, contains('not admitted for codex'));

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

    test('invalid model quota is quarantined behind trusted evidence', () {
      final previous = ProviderQuota(
        provider: antigravityProviderId,
        displayName: 'Antigravity',
        account: 'a',
        asOf: 100,
        windows: [win('weekly', 40, 5000)],
        modelQuotas: const [
          ModelQuota(model: 'Gemini', usedPercent: 40, resetsAt: 5000),
        ],
      );
      final invalid = ProviderQuota(
        provider: antigravityProviderId,
        displayName: 'Antigravity',
        account: 'a',
        asOf: 200,
        windows: [win('weekly', 45, 5000)],
        modelQuotas: const [
          ModelQuota(model: 'Gemini', usedPercent: -1, resetsAt: 5000),
        ],
      );

      expect(isTrustedQuotaEvidence(invalid), isFalse);
      final admission = admitQuotaEvidence(
        invalid,
        previous,
        observedAt: 210,
      );
      expect(admission.shouldPersist, isFalse);
      expect(admission.driftReason, contains('percent outside 0..100'));
      expect(admission.snapshot.stale, isTrue);
      expect(admission.snapshot.modelQuotas.single.usedPercent, 40);
    });

    test('malformed model quota cannot establish a trusted baseline', () {
      final invalid = ProviderQuota(
        provider: antigravityProviderId,
        displayName: 'Antigravity',
        account: 'a',
        asOf: 200,
        windows: [win('weekly', 45, 5000)],
        modelQuotas: const [
          ModelQuota(model: '', usedPercent: double.nan, resetsAt: -1),
        ],
      );

      final admission = admitQuotaEvidence(invalid, null, observedAt: 210);
      expect(admission.shouldPersist, isFalse);
      expect(admission.driftReason, contains('invalid model identifier'));
      expect(admission.snapshot.ok, isFalse);
      expect(admission.snapshot.windows, isEmpty);
      expect(admission.snapshot.modelQuotas, isEmpty);
    });

    test('malformed model quota window labels cannot become trusted', () {
      for (final label in [
        '',
        ' weekly',
        'weekly ',
        'week\u001b[31mly',
        List.filled(kMaxModelQuotaWindowLabelCharacters + 1, 'w').join(),
      ]) {
        final invalid = ProviderQuota(
          provider: codexProviderId,
          displayName: 'Codex',
          account: 'a',
          asOf: 200,
          windows: [win('weekly', 45, 5000)],
          modelQuotas: [
            ModelQuota(
              model: 'GPT-5.3-Codex-Spark',
              usedPercent: 20,
              resetsAt: 5000,
              windowLabel: label,
            ),
          ],
        );

        expect(isTrustedQuotaEvidence(invalid), isFalse, reason: label);
        final admission = admitQuotaEvidence(invalid, null, observedAt: 210);
        expect(admission.shouldPersist, isFalse, reason: label);
        expect(admission.driftReason, contains('invalid window label'));
      }
    });

    test('implausibly distant model reset is not trusted', () {
      final invalid = ProviderQuota(
        provider: antigravityProviderId,
        displayName: 'Antigravity',
        account: 'a',
        asOf: 200,
        windows: [win('weekly', 45, 5000)],
        modelQuotas: const [
          ModelQuota(
            model: 'Gemini',
            usedPercent: 20,
            resetsAt: 50000000,
          ),
        ],
      );

      expect(isTrustedQuotaEvidenceAt(invalid, 210), isFalse);
      final admission = admitQuotaEvidence(invalid, null, observedAt: 210);
      expect(admission.shouldPersist, isFalse);
      expect(admission.driftReason, contains('implausibly far'));
    });

    test('unknown model percent does not poison trusted provider evidence', () {
      final evidence = ProviderQuota(
        provider: claudeProviderId,
        displayName: 'Claude',
        account: 'a',
        asOf: 200,
        windows: [win('weekly', 45, 5000)],
        modelQuotas: const [
          ModelQuota(model: 'Fable', resetsAt: 5000),
        ],
      );

      expect(isTrustedQuotaEvidenceAt(evidence, 210), isTrue);
      final admission = admitQuotaEvidence(evidence, null, observedAt: 210);
      expect(admission.shouldPersist, isTrue);
      expect(admission.driftReason, isNull);
      expect(admission.snapshot.modelQuotas.single.usedPercent, isNull);
    });

    test('a model reset ends routable evidence without erasing its value', () {
      const quota = ModelQuota(
        model: 'Gemini 3.1 Pro',
        usedPercent: 27,
        resetsAt: 5000,
      );

      expect(isCurrentModelQuotaEvidenceAt(quota, 4999), isTrue);
      expect(isCurrentModelQuotaEvidenceAt(quota, 5000), isFalse);
      expect(quota.remainingPercent, 73);
      expect(quota.resetsAt, 5000);
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
