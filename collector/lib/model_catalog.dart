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
import 'provider_ids.dart';

/// The date the catalog was last refreshed (YYYY-MM-DD). Surfaced so consumers
/// can see how fresh the capability hints are.
const String kCatalogUpdated = '2026-11-17';

/// Providers whose windows are true rolling included-quota plans. Only these
/// can ever mark a model quota-backed for the no-surprise `--budget=quota`
/// envelope. Credit-pool and request-metered providers (Cursor, Kiro,
/// Windsurf/Devin) stay out even if a future catalog update lists their
/// models, so adding models can never silently widen the spend envelope.
const Set<String> kQuotaPlanProviders = {
  claudeProviderId,
  codexProviderId,
  antigravityProviderId,
  grokProviderId,
};

/// Cloud models per provider id. Context windows are total tokens. Kept to the
/// current flagships per provider; the refresh tool can widen this.
const Map<String, List<ModelInfo>> kModelCatalog = {
  claudeProviderId: [
    // Checked 2026-11-15:
    // https://platform.claude.com/docs/en/models/fable-5-2/overview
    // 1M context, 128K max output, tools, vision, and adaptive thinking.
    ModelInfo(
      id: 'claude-fable-5-2',
      displayName: 'Claude Fable 5.2',
      contextTokens: 1000000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'adaptive',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'claude-opus-5-5',
      displayName: 'Claude Opus 5.5',
      contextTokens: 1000000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'adaptive',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'claude-sonnet-5-5',
      displayName: 'Claude Sonnet 5.5',
      contextTokens: 1000000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'adaptive',
      tier: 'standard',
    ),
    // Current light model. Haiku 4.5 remains Active and is omitted so the
    // light pick stays unambiguous. Checked 2026-11-15:
    // https://platform.claude.com/docs/en/models/haiku-5-5/overview
    // 1M context, 128K max output, adaptive thinking. Retirement not sooner
    // than October 7, 2027.
    ModelInfo(
      id: 'claude-haiku-5-5',
      displayName: 'Claude Haiku 5.5',
      contextTokens: 1000000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'adaptive',
      tier: 'light',
    ),
  ],
  'codex': [
    ModelInfo(
      id: 'gpt-6.1-sol',
      displayName: 'GPT-6.1 Sol',
      contextTokens: 1050000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
    // Checked 2026-11-15:
    // https://developers.openai.com/api/docs/models/gpt-6.1-terra
    // Text and image in, text out, tools, 1,050,000 context, 128,000 output.
    ModelInfo(
      id: 'gpt-6.1-terra',
      displayName: 'GPT-6.1 Terra',
      contextTokens: 1050000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'standard',
    ),
    ModelInfo(
      id: 'gpt-6-luna',
      displayName: 'GPT-6 Luna',
      contextTokens: 1050000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'light',
    ),
    ModelInfo(
      id: 'gpt-6-astra',
      displayName: 'GPT-6 Astra',
      contextTokens: 1050000,
      maxOutputTokens: 128000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
  ],
  'grok': [
    // Checked 2026-11-15:
    // https://docs.x.ai/developers/models/grok-4.7
    // 500,000 context, tools, vision, and reasoning.
    ModelInfo(
      id: 'grok-4.7',
      displayName: 'Grok 4.7',
      contextTokens: 500000,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
  ],
  'antigravity': [
    // Presence checked 2026-11-17 against
    // https://antigravity.google/docs/models/
    // and a live `agy models` list. Ids are the stable prefixes of the
    // effort-suffixed account ids, such as gemini-4-hydrogen-xhigh and
    // claude-opus-5-5-high. The Gemini API list is a Gemini-id cross-check
    // only and does not prove this page. The page marks Claude Sonnet 4.6
    // (thinking), Claude Opus 4.6 (thinking), and GPT-OSS-120b removed on
    // 2026-11-18. That account list already omitted the 4.6 ids and
    // gemini-3.5-flash-lite, and it still included gpt-oss-120b-medium.
    // Orchestrator and the Enterprise-only 3.7, 3.6, and 3.1 Pro rows are
    // on the page and are not catalog models. Antigravity does not publish
    // Claude context lengths, so those rows omit them.
    //
    // Gemini limits checked 2026-11-17:
    // https://aistudio.google.com/docs/models/gemini-4-carbon
    // https://aistudio.google.com/docs/models/gemini-4-argon
    // https://aistudio.google.com/docs/models/gemini-4-hydrogen
    // https://aistudio.google.com/docs/models/gemini-3.8-flash
    // Unified context 1,048,576. Default sync max output 65,536. Tools,
    // vision, and thinking. The catalog has no price fields. Carbon remains
    // the Ultra and Enterprise row. This account's list did not include it.
    ModelInfo(
      id: 'gemini-4-carbon',
      displayName: 'Gemini 4 Carbon',
      contextTokens: 1048576,
      maxOutputTokens: 65536,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'gemini-4-argon',
      displayName: 'Gemini 4 Argon',
      contextTokens: 1048576,
      maxOutputTokens: 65536,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'gemini-4-hydrogen',
      displayName: 'Gemini 4 Hydrogen',
      contextTokens: 1048576,
      maxOutputTokens: 65536,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'standard',
    ),
    ModelInfo(
      id: 'gemini-3.8-flash',
      displayName: 'Gemini 3.8 Flash',
      contextTokens: 1048576,
      maxOutputTokens: 65536,
      tools: true,
      vision: true,
      reasoning: 'reasoning',
      tier: 'standard',
    ),
    ModelInfo(
      id: 'claude-opus-5-5',
      displayName: 'Claude Opus 5.5 (thinking)',
      reasoning: 'reasoning',
      tier: 'flagship',
    ),
    ModelInfo(
      id: 'claude-sonnet-5-5',
      displayName: 'Claude Sonnet 5.5 (thinking)',
      reasoning: 'reasoning',
      tier: 'standard',
    ),
  ],
};
