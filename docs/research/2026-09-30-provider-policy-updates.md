# Provider policy and metadata review

Reviewed 2026-09-30 against README, ROADMAP, CLAUDE, DATA_SOURCES, the September
13 review, and the committed catalog, provider adapters, and pure parsers.
[ROADMAP](../../ROADMAP.md#next) remains the execution queue. This report is
dated evidence, not a claim that recommendations have shipped.

The most concrete currency gaps are missing Gemini 3.8 Flash and Grok 4.7
catalog entries. The existing distinctions between included quota, purchased
credits, account admission, and passive local evidence remain necessary.
Research also found an overstatement in the standing Grok credit roadmap:
first-party source already exposes purchased balance and an on-demand flag.
Those fields still need account validation before quotabot can display them.

All external links below were accessed on 2026-09-30. Public documentation and
first-party source were read without real account credentials. No quota-account
experiment, inference, host-state mutation, or paid API request was performed.
An access date alone does not establish when an undated page changed.

## Verified model currency gaps

| Provider | Verified current evidence | Difference from the reviewed tree | Safe next action |
|---|---|---|---|
| Antigravity | The [model table](https://antigravity.google/docs/models/) lists Gemini 3.8, 3.7, and 3.6 Flash, Gemini 3.1 Pro, Claude Sonnet/Opus 4.6 thinking, and GPT-OSS 120B. Its example separates Gemini and Claude/GPT five-hour and weekly pools. | `collector/lib/model_catalog.dart` includes 3.5/3.6/3.7 Flash and omits 3.8. The public table no longer lists 3.5. | Add the verified current hint; treat removal from one table as a maintenance signal, not proof that every existing account has lost access. Preserve provider-observed model gates. |
| Gemini 3.8 Flash | Google's [model reference](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash) gives exact id `gemini-3.8-flash`, text output, image input, function calling, thinking, 1,048,576 input tokens and 65,536 output tokens. The page says latest update September 2026. | The model and its capabilities are absent. | Use only documented fields. Input-token allowance is not automatically a combined context limit or an Antigravity configured context. API capabilities are curated hints; subscription access still needs its own evidence. |
| Grok | The [September 21 announcement](https://x.ai/news/grok-4-7) makes Grok 4.7 available through Grok Build, Cursor, and the separately billed API. The [exact model reference](https://docs.x.ai/developers/models/grok-4.7) identifies `grok-4.7`, 500,000 context tokens, image/text input, function calling, reasoning, and low/medium/high/xhigh efforts. | The committed catalog has only `grok-4.6` and `grok-4.5`. | Add `grok-4.7` with supported capability hints. Do not derive entitlement, fast-variant affordability, or numeric headroom from the release. |

The catalog's `kCatalogUpdated` remains 2026-09-02. Updating that date should
describe an actual curated refresh, with the other providers independently
reviewed. An authenticated API model list may help maintenance; it does not
prove that a consumer subscription or harness can use an API model.

## Subscription and application evidence

### Antigravity and Google AI

[Plans](https://antigravity.google/docs/plans) still distinguishes free weekly
baseline from Pro five-hour quota until its weekly limit binds, and Ultra
five-hour quota plus weekly limits. Capacity and work affect consumption;
published allowances are not measured account headroom. Purchased AI credits
can continue after baseline exhaustion under the host Never/Always overage
setting. Preserve the shipped quota-only path and never change that setting.

The [interactive usage panel](https://antigravity.google/docs/cli/commands/usage/)
documents a human model-quota cross-check. It does not establish a supported
JSON balance command. The [SDK quickstart](https://antigravity.google/docs/sdk/overview/)
uses `GEMINI_API_KEY`; a CLI subscription bar therefore cannot prove SDK/API
included spend. This is a billing-surface distinction, not an SDK collector.

The source adapter already uses the daily Cloud Code grouped summary, validates
typed weekly/five-hour buckets, and keeps `fetchAvailableModels` model gates
separate. Public docs do not validate that private wire contract across Free,
Pro, Ultra, and Enterprise. Preserve the September known-consumption Pro
evidence and obtain separate tier fixtures. The plans prose emphasizes Ultra
third-party access, while the model table shows third-party availability for
other consumer tiers too; resolve a particular account through observed
entitlement and gates rather than a static tier-name rule.

### Grok and xAI

The [consumer FAQ](https://docs.x.ai/grok/faq) still describes a shared included
weekly pool, compute-weighted use, a reset time shown in Settings, and separate
Extra Usage Credits. Top-ups are consumed after included quota, can expire a
year after purchase, and may have automatic replenishment. Product percentages
are diagnostic breakdowns, not independent remaining allowances.

The [current first-party billing source](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/extensions/billing.rs)
retains `creditUsagePercent` and typed `currentPeriod` as included evidence.
It also declares `prepaidBalance` as a positive purchased remainder,
`onDemandEnabled` from remote settings, and `isUnifiedBillingUser`. Those fields
exist in both previously reviewed pinned revisions, including
`37949780c144e37df692e3d669051a21fec24f20` and
`72a61251fcffb464bcc687aeb5a998e5a98ec0c9`. This is a correction to a prior
research conclusion, not evidence of a September 30 policy launch.

The separate [Management billing API](https://docs.x.ai/developers/rest-api-reference/management/billing)
still returns team prepaid accounting and postpaid limits, with examples using
negative purchased-credit values. Its units and sign are not interchangeable
with the consumer client fields. Do not import those values into included
headroom. Least-privilege authority, automatic top-up, enforcement, and current
account binding remain prerequisites for any paid-credit integration.

### Cursor

[Current pricing](https://cursor.com/docs/models-and-pricing) still has separate
Cursor Models and Other Models pools resetting with the monthly billing cycle.
The former now lists Grok 4.7/4.6/4.5 and Composer 2.5. Start has only the Cursor
Models pool; Pro and higher have both. API-priced on-demand use is a separate
continuation. Teams/Enterprise third-party use also has a Cursor Token Rate.
This reinforces the existing owner-bound diagnostic detection when current
local pool values are absent.

The [Admin API](https://cursor.com/docs/account/teams/admin-api) now documents
preview model-access reads requiring `models:read`; generic `read:*` is not
sufficient for them. Model toggles and permitted settings can describe team
policy. That does not supply missing individual quota or make spend-to-cap
equal funded balance. A future team integration should keep policy admission
separate from billing and test unrestricted/legacy/custom policy states.

### Windsurf and Devin

[Self-serve billing](https://docs.devin.ai/admin/billing/self-serve) confirms Pro
and Teams full seats have daily and weekly calendar allowances; Max has a
weekly allowance only. Flex seats draw entirely from shared purchased credits.
Teams Automations and Review use the shared credit pool rather than full-seat
quota. Purchased on-demand credits roll over and may auto-reload. These facts
were already present in September's review. No documented self-serve balance
API was established here; passive row freshness still governs the adapter.

A newly reviewed [ChatGPT-plan integration](https://docs.devin.ai/admin/billing/chatgpt)
links eligible Plus/Pro accounts to Devin and bills the GPT portion to that
subscription when enabled. Other ensemble models still consume Devin quota.
When the linked account is exhausted or unavailable, Devin automatically falls
back to Devin quota and then purchased credits. The link is per user and has a
grant/toggle, not a shared team subscription. quotabot must not interpret a
green Codex bar as proof that this whole ensemble is free or prevent that
provider-owned paid fallback. No host toggle should be changed.

### Kiro

[Billing](https://kiro.dev/docs/billing/) specifies monthly plan credits and
renewal at the next billing cycle. [Add-on rules](https://kiro.dev/docs/billing/add-on-credits/)
still combine purchased and plan credits in the client display, consume plan
first, and give purchased packs their own one-year expiry and rollover. The
adapter's aggregate remains outside `budget=quota`; no new wire evidence
justifies decomposition.

The [model reference](https://kiro.dev/docs/models/available-models/) records
Opus 5.5 experimental availability from September 28, with plan and region
restrictions and a 2.0 credit multiplier. Auto may choose generally available
models beyond individual admin approvals and excludes experimental models.
Model-name presence or a weighted credit multiplier does not give quotabot a
measured remaining model allowance. Kiro is not currently in the curated
quota-plan model set, so no cloud-catalog expansion follows automatically.

### NVIDIA NIM

Official material remains inconsistent. The [catalog FAQ](https://docs.api.nvidia.com/nim/re/docs/faq)
still describes trial credits deducted by remote API use. NVIDIA staff's
[credit-system explanation](https://forums.developer.nvidia.com/t/request-more-4-000-credits-option-on-build-nvidia-com/344567)
says the credit system was replaced by model-specific trial rate limits,
inspectable in the signed-in catalog UI. A staff response is primary provider
evidence; unaffiliated forum users' credit claims are not authoritative.

Neither source supplies an admitted numeric balance/reset metadata endpoint.
The [quickstart](https://docs.api.nvidia.com/nim/re/docs/api-quickstart) describes
hosted NIM inference, not such an interface. Preserve `status_only`, catalog
reachability, and explicit unknown account access/balance. The September public
catalog experiment already demonstrated why `/models` success cannot validate a
key. This review did not repeat it or infer changed admission.

## Candidates that remain gated

| Candidate | Current primary evidence | Consequence |
|---|---|---|
| Copilot | [Individual billing](https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing) uses monthly base and variable flex AI credits; unused included credits expire and reset at 00:00 UTC on the first of the month, independently of billing date. The [user usage report](https://docs.github.com/en/rest/billing/usage#get-billing-ai-credit-usage-report-for-a-user) needs Plan-read permission and excludes organization-billed licenses. | Keep individual and organization pools distinct. A usage report needs a current allowance, provenance, overage controls, and admission evidence before it can support routing. Do not reuse premium-request assumptions. |
| GLM Coding Plan | [Plan rules](https://docs.z.ai/devpack/overview) now list GLM-5.3 and GLM-5.3-Flash, redirect older names, and preserve five-hour/weekly credits plus weighted model/tool use. A dated September 25 to October 7 campaign applies the off-peak credit rate all day. The [FAQ](https://docs.z.ai/devpack/faq) limits plan use to supported tools and exact coding endpoints. | Treat campaigns as dated consumption policy, never as a measured balance or enduring unlimited allowance. Current five-hour and weekly metadata shapes still need regional and account validation. |
| GLM metadata | The [unchanged official usage script](https://github.com/zai-org/zai-coding-plugins/blob/0446d0bb0bc537d97d3ab3664c4b8b9c4a0e1254/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs) calls monitor model/tool/quota paths and still labels token limits five-hour and tool limits monthly. | Source proves a metadata path, not complete current binding pools. Implement exact allowlisted hosts and bounded reads instead of copying the script's substring host selection and unbounded output. |
| OpenRouter | [Ordinary-key metadata](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key) now documents `free_model_daily_requests` with used/limit/remaining alongside dollar spending-ceiling fields. [Limits guidance](https://openrouter.ai/docs/api_reference/limits) defines that counter as current UTC-day free-model use and warns it is not an enforced ceiling for exempt accounts/endpoints or BYOK; it omits per-minute limits. [Purchased account credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits) still require a Management key. | Investigate display-only free request evidence separately from paid key allowance. Free count cannot prove upstream admission or a nonnegative funded account; negative account balance may block even free models. Positive key remainder remains spending ceiling, not purchased funds. |

## Status sources and display

The official [xAI status page](https://status.x.ai/) and [Cursor status page](https://status.cursor.com/)
were readable. Their service components can explain a metadata failure without
rewriting an account's measured percentage. Google links [AI Studio status](https://aistudio.google.com/status)
from its Gemini model documentation, but the read returned only the application
shell. [Google Cloud Service Health](https://status.cloud.google.com/) is a
different service scope and does not certify consumer Antigravity health.

Reads of `status.devin.ai` and `status.kiro.dev` failed in this research transport;
that does not establish an outage or absence of a status service. The
OpenRouter status host returned no readable page content. No automated status
integration is validated by these observations. Future status reads should be
explicit, bounded, provider-scoped, and advisory. Never convert an all-clear
status page into quota, loaded state, admission, or 100 percent headroom.

## Recommended follow-up and acceptance

1. Refresh the missing model hints first. Pin official identifiers and supported
   fields, retain old-model uncertainty, and run catalog/registry contract
   tests. New rows must remain unavailable with denied, exhausted, stale, or
   drifted provider evidence. API presence must not widen included spend.
2. Correct standing evidence claims. Replace Grok's blanket no-machine-field
   statement with source-observed fields awaiting account validation; record
   the NVIDIA source disagreement. README's Cursor limitation remains accurate.
   DATA_SOURCES should avoid implying every Devin tier has a daily cap and
   should link the distinct ChatGPT billing surface when discussing harnesses.
3. Continue typed-pool work before expansion. Antigravity Gemini and Claude/GPT
   pools, Kiro plan/add-on packs, Devin seat/shared credits, and Copilot
   base/flex/overage evidence must retain distinct identity, reset, and spend.
   Test healthy siblings beside exhausted pools, weekly-only plans, partially
   paid aggregates, and stale resets without resurrection.
4. Validate Grok purchased-credit display through the existing bounded metadata
   seam. Require sanitized personal/team, absent/zero/positive/invalid balance,
   typed period, on-demand false/true/missing, auto-top-up, expiry, and account
   mismatch cases. Keep every paid field out of included headroom and default
   model routing. Source declarations alone do not close live acceptance.
5. Investigate OpenRouter free daily counters and Cursor team admission as
   separate display-first candidates. Test UTC rollover, missing/negative or
   malformed values, exemptions, BYOK, upstream 429, denied policy, and current
   account ownership. Require an explicit supported execution surface before
   routing and keep the current spend exclusions.
6. Improve failure explanations using existing status and retry evidence. Keep
   authentication failure, throttle, provider incident, passive cache age, and
   exhausted quota distinguishable, with the last trusted percentage visible.
   Metadata failure must never be described as proven exhaustion.

## Verification limits

This document changes no adapters, parsers, catalog rows, credentials, or routing
policy. The reviewed source defects are missing current catalog hints and
overstated documentation, not a demonstrated new live-quota parser failure.
Provider account experiments and native application comparisons remain open.
Documentation checks and the full contributor gate must run on the integrated
tree; a research-only review cannot claim current account accuracy or new CI
coverage.
