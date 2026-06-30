/// Capability catalog for cloud-provider models, keyed by quotabot provider id.
///
/// This is a committed data file, read at runtime so the registry stays
/// local-first and zero-extra-network. It is a best-effort snapshot of each
/// provider's current models and is audited by `bin/catalog_audit.dart` against
/// each provider's own model endpoint. Local-runtime models are NOT here; those
/// are read live from the runtime by the adapters.
///
/// Capability fields are hints (context window, tool use, vision, reasoning) and
/// may lag a provider's newest release until the next curated update; the
/// registry always pairs them with that provider's live quota for the budget
/// half.
library;

import 'models.dart';

/// The date the catalog was last refreshed (YYYY-MM-DD). Surfaced so consumers
/// can see how fresh the capability hints are.
const String kCatalogUpdated = '2026-06-28';

/// Cloud models per provider id. Context windows are total tokens. Kept to the
/// current flagships per provider; the refresh tool can widen this.
const Map<String, List<ModelInfo>> kModelCatalog = {
  'claude': [
    ModelInfo(
      id: 'claude-opus-4-8',
      displayName: 'Claude Opus 4.8',
      contextTokens: 200000,
      maxOutputTokens: 64000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'claude-sonnet-4-6',
      displayName: 'Claude Sonnet 4.6',
      contextTokens: 200000,
      maxOutputTokens: 64000,
      tools: true,
      vision: true,
      tier: 'standard',
    ),
    ModelInfo(
      id: 'claude-haiku-4-5',
      displayName: 'Claude Haiku 4.5',
      contextTokens: 200000,
      maxOutputTokens: 32000,
      tools: true,
      vision: true,
      tier: 'light',
    ),
  ],
  'codex': [
    ModelInfo(
      id: 'gpt-5.5',
      displayName: 'GPT-5.5',
      contextTokens: 1000000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'gpt-5.1-codex',
      displayName: 'GPT-5.1-Codex',
      contextTokens: 400000,
      tools: true,
      reasoning: 'reasoning',
      tier: 'standard',
    ),
  ],
  'grok': [
    ModelInfo(
      id: 'grok-4.3',
      displayName: 'Grok 4.3',
      contextTokens: 1000000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'standard',
    ),
    ModelInfo(
      id: 'grok-4.20',
      displayName: 'Grok 4.20 (Heavy)',
      contextTokens: 2000000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
  ],
  'antigravity': [
    ModelInfo(
      id: 'gemini-3.1-pro',
      displayName: 'Gemini 3.1 Pro',
      contextTokens: 1000000,
      maxOutputTokens: 64000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'gemini-3-flash',
      displayName: 'Gemini 3 Flash',
      contextTokens: 1000000,
      tools: true,
      vision: true,
      tier: 'standard',
    ),
  ],
};
