/// Normalized provenance classes for provider observations.
library;

import 'provider_ids.dart';

/// Legacy origin hint retained for manual-entry wire compatibility.
const providerQuotaManualSource = 'manual';

/// What a provider observation proves and where its quota evidence originated.
///
/// The wire names are a stable additive contract. They deliberately remain
/// separate from the legacy `source` hint, the subscription/local `kind`, and
/// the `per_machine` scope flag because none of those fields can express this
/// trust boundary on its own.
enum ProviderSourceClass {
  authoritativeLive('authoritative_live', 'authoritative'),
  thisMachineFallback('this_machine_fallback', 'this-machine fallback'),
  passiveLocalEvidence('passive_local_evidence', 'passive local'),
  localRuntime('local_runtime', 'local runtime'),
  statusOnly('status_only', 'status only'),
  manual('manual', 'manual');

  const ProviderSourceClass(this.wireName, this.label);

  final String wireName;
  final String label;

  static const wireValues = [
    'authoritative_live',
    'this_machine_fallback',
    'passive_local_evidence',
    'local_runtime',
    'status_only',
    'manual',
  ];

  bool get isMachineScoped =>
      this == ProviderSourceClass.thisMachineFallback ||
      this == ProviderSourceClass.passiveLocalEvidence;

  bool get carriesMeasuredQuota =>
      this == ProviderSourceClass.authoritativeLive ||
      this == ProviderSourceClass.thisMachineFallback ||
      this == ProviderSourceClass.passiveLocalEvidence;

  static ProviderSourceClass fromWire(String? value) {
    for (final sourceClass in values) {
      if (sourceClass.wireName == value) return sourceClass;
    }
    throw FormatException('unknown provider source class: $value');
  }
}

const kAuthoritativeLiveSourceClasses = {
  ProviderSourceClass.authoritativeLive,
};
const kLiveOrMachineFallbackSourceClasses = {
  ProviderSourceClass.authoritativeLive,
  ProviderSourceClass.thisMachineFallback,
};
const kPassiveLocalSourceClasses = {
  ProviderSourceClass.passiveLocalEvidence,
};
const kLocalRuntimeSourceClasses = {
  ProviderSourceClass.localRuntime,
};
const kStatusOnlySourceClasses = {
  ProviderSourceClass.statusOnly,
};

/// Canonical source classes admitted for a built-in provider id, or null for a
/// user-defined/manual provider. The adapter registry declares the same sets and
/// tests keep the compile-time admission table synchronized with this low-level
/// routing and cache boundary.
Set<ProviderSourceClass>? builtInProviderSourceClasses(String provider) =>
    switch (provider.trim().toLowerCase()) {
      claudeProviderId || grokProviderId => kAuthoritativeLiveSourceClasses,
      codexProviderId ||
      antigravityProviderId =>
        kLiveOrMachineFallbackSourceClasses,
      cursorProviderId ||
      windsurfProviderId ||
      kiroProviderId =>
        kPassiveLocalSourceClasses,
      ollamaProviderId ||
      lmStudioProviderId ||
      lemonadeProviderId =>
        kLocalRuntimeSourceClasses,
      nvidiaProviderId => kStatusOnlySourceClasses,
      _ => null,
    };

/// Infers provenance only when adapting a legacy document or an older call
/// site that predates `source_class`.
///
/// New provider admission is still explicit in the adapter registry. This
/// compatibility function is intentionally deterministic and provider-aware so
/// old caches cannot silently upgrade passive local evidence to authoritative
/// account-wide quota.
ProviderSourceClass inferProviderSourceClass({
  required String provider,
  required String? source,
  required bool isLocal,
  required bool perMachine,
}) {
  if (source == providerQuotaManualSource) return ProviderSourceClass.manual;
  if (isLocal) return ProviderSourceClass.localRuntime;

  return switch (provider.trim().toLowerCase()) {
    cursorProviderId ||
    windsurfProviderId ||
    kiroProviderId =>
      ProviderSourceClass.passiveLocalEvidence,
    nvidiaProviderId => ProviderSourceClass.statusOnly,
    _ when perMachine => ProviderSourceClass.thisMachineFallback,
    _ => ProviderSourceClass.authoritativeLive,
  };
}
