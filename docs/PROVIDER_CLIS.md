# Provider CLIs and usage commands

A quick reference to the AI coding CLIs quotabot tracks: each one's own
usage/quota command, and how quotabot reads the same numbers.

These tools change often. Treat this as a starting point and verify against each
vendor's official docs (linked per provider). For exactly where quotabot reads
each number, see [DATA_SOURCES.md](DATA_SOURCES.md).

**Last broad review: 2026-09-02. Claude, Codex, and Grok interfaces rechecked
2026-09-05.**

The provider command is only one part of the trust statement. quotabot also
emits a normalized `source_class`: Claude and live Codex, Grok, and Antigravity
are `authoritative_live`; Antigravity local fallback is
`this_machine_fallback`; Cursor, Windsurf/Devin, and Kiro are
`passive_local_evidence`; Ollama, LM Studio, and Lemonade are `local_runtime`;
NVIDIA NIM is `status_only`; and user entries are `manual`. The exact routing
and verification rules are in [DATA_SOURCES.md](DATA_SOURCES.md#source-classes).

## Claude (Claude Code)

- Official docs: https://platform.claude.com/docs/en/models/overview, the
  [plan usage-credit guide](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans),
  and the [Fable plan guide](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan).
- Check usage yourself: `/usage` in a Claude Code session shows current-window
  usage bars and reset times. Its separate contribution breakdown can be based
  only on local sessions and does not prove account balance or cross-device
  burn. quotabot derives burn rate from its own bounded local quota history.
  Related: `/cost`, `/stats`, `/context`.
- Do not automate this as `claude -p /usage` or `/quota`. Print mode is a
  prompt-execution surface, not a stable quota API, and `/quota` is not a
  documented built-in command. quotabot calls the account-wide usage metadata
  endpoint directly so collection remains content-blind and uses zero inference.
  Extra-usage credits on that same response can appear as display-only card
  detail; they are not plan windows.
- `claude auth status` checks authentication, not remaining quota. Current
  [status-line input](https://code.claude.com/docs/en/statusline) can supply
  quota percentages and reset times after an existing session receives an API
  response. Missing windows are unknown. A future metadata-only bridge must
  allowlist those fields without reading transcripts or initiating a model turn.
  A quota-endpoint HTTP 429 describes a throttled metadata check, not proof that
  the user's included plan is spent.
- Quota shape: a rolling 5-hour window plus a weekly cap, shared across Claude
  Code, Claude.ai, and related products. Anthropic doubled the five-hour Claude
  Code allowance for Pro, Max, Team, and seat-based Enterprise on 2026-05-06
  and removed the prior peak-hours reduction for Pro and Max. quotabot reads
  provider percentages and reset times, so no plan amount is hardcoded.
- The live response may also include a model-scoped weekly cap. Beginning July
  20, 2026, Anthropic says Fable 5 and Fable 5.1 use up to 50% of the regular
  shared weekly plan limit for Max, Team Premium, and premium legacy seat-based
  Enterprise. Pro, Team Standard, Enterprise Standard, and usage-based
  Enterprise use pay-as-you-go credits. This is a dated plan policy, not a
  value quotabot hardcodes. `budget=quota` therefore requires both a live scoped
  Fable row and a current provider entitlement that quotabot can identify
  exactly. Max and Team Premium are supported today. Generic Enterprise remains
  fail-closed because the current profile response does not distinguish premium
  from standard reliably. The
  `subscriptionType` in the local Claude credential is
  labeled `host_credential` evidence and never proves included spend after a
  plan change. Positive included-quota and credit-backed labels both require
  current provider plan evidence. Unknown, host-label-only, and credit-backed
  plans remain visible only under the unrestricted budget. See the
  [current Fable plan guide](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan).
- quotabot reads: the OAuth usage and profile metadata endpoints, reusing the
  token Claude Code stores.
  Live with no quotabot login when Claude Code has a valid signed-in token here;
  `quotabot login claude` adds a self-refreshing grant designed to keep the
  account-wide read live on a machine you have not opened Claude Code on
  recently. Inspect the result with `quotabot doctor`, and use scoped
  `quotabot verify --require-live` when automation must enforce freshness;
  real-account evidence after an idle interval remains a tracked 1.0 acceptance
  item.
- The usage endpoint does not return a stable account id, but the profile
endpoint returns account and organization ids. quotabot hashes those ids to
form the stable live snapshot, cache, drift, and lease identity and to collapse
two credentials for the same subscription. If identity cannot be proven for
every successful credential, at most one remains routable and an irreversible
local credential fingerprint is the fallback boundary. Switching credentials
cannot lend a new login an old 100% reading. No raw credential or provider
account id enters quota output.

## Codex (OpenAI)

- Official docs: [Codex CLI](https://learn.chatgpt.com/docs/cli) and
  [app-server rate limits](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).
- Check usage in the current product's account/usage surface. The documented
  CLI `/status` summarizes session configuration and token activity; extension
  surfaces can also show rate limits. This is a version-sensitive cross-check,
  not a promise that `/status` forces fresh quota collection. See the
  [developer command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli#inspect-the-session-with-status).
- The documented programmatic quota method is `account/rateLimits/read`, with
  `account/rateLimits/updated` notifications. Token activity uses the separate
  `account/usage/read`. A host-owned bridge could reduce polling, but quotabot
  does not spawn app-server against the host profile: managed authentication
  can refresh or persist credentials. Neither `refreshToken: false` nor a
  command called status proves a complete launch is host-write-free.
- Quota shape: the endpoint labels each shared pool by its reported duration.
  Current Pro responses can expose one weekly primary pool, an explicit null
  secondary pool, and a separate named GPT-5.3-Codex-Spark weekly pool. The
  named pool gates Spark only; it does not replace the shared account limit.
- Codex currently offers GPT-5.6 Sol, Terra, and Luna, plus the Pro-only
  GPT-5.3-Codex-Spark research preview. GPT-5.4 and GPT-5.4-Mini retired from
  ChatGPT-authenticated Codex on 2026-08-31. See the
  [current Codex model guide](https://learn.chatgpt.com/docs/models).
- The endpoint can also report `rate_limit_reset_credits.available_count`.
  OpenAI now calls these banked resets: promotional full resets of the active
  windows, not cash or API credit. quotabot keeps the stable JSON field
  `reset_credits_available` and labels the value as banked resets to users.
- quotabot reads: the ChatGPT usage endpoint, reusing the OAuth access token
  in the configured `CODEX_HOME/auth.json` (default `~/.codex/auth.json`), or a
  self-refreshing grant from `quotabot login codex`
  when that token is expired. The grant path is designed to keep an idle machine
  live. Inspect it there with `quotabot doctor`, and use scoped
  `quotabot verify --require-live` when automation must enforce freshness. Dated
  real-account idle validation remains a tracked 1.0 acceptance item. If no
  account-wide read succeeds, it fails closed with a login repair. It never opens
  Codex session files, which can contain prompts and responses, for quota
  evidence.

## Antigravity / Gemini (Google)

- Official docs: https://antigravity.google/docs/models/ ,
  https://antigravity.google/docs/plans/ , and
  https://antigravity.google/docs/cli/commands/usage .
- The CLI is `agy`. `agy --help` lists flags (`--print` for non-interactive,
  `--model`, `--project`, ...) and subcommands (`models`, `update`, ...). Inside
  the TUI, the Models & Quota panel shows per-model-group Weekly and Five Hour
  limits. Antigravity replaced the consumer Gemini CLI on 2026-06-18.
- Quota shape: two shared groups, each with Weekly and Five Hour limits: one
  for Gemini models and one for Claude/GPT models. Gemini 3.7 Flash, 3.6 Flash,
  3.5 Flash, and 3.1 Pro share the Gemini pool. Claude Sonnet 4.6, Claude Opus
  4.6, and GPT-OSS-120B use the separate non-Gemini pool. Provider model rows
  are gates onto those groups, not balances that can be added together.
- quotabot reads: the Cloud Code API (`loadCodeAssist`, `onboardUser`,
  `fetchAvailableModels`). It can reuse refresh material from a signed-in
  Antigravity IDE or from `agy` (OS keyring target `gemini:antigravity`);
  `quotabot login antigravity` is optional when a discovered account needs a
  separate refreshable grant or should be pinned. A signed-in `agy` CLI is
  enough even when the IDE's VS Code `state.vscdb` is absent. No manual Google
  Cloud project setup is required because the provider-required onboarding
  request is performed automatically. The live read is preferred; local
  Antigravity state is used for account discovery and offline fallback, where
  quotabot marks the result `per_machine`.

## Grok (xAI)

- Official docs: https://docs.x.ai, the
  [shared-pool FAQ](https://docs.x.ai/grok/faq), and the console at
  https://console.x.ai .
  Official Grok Build source: https://github.com/xai-org/grok-build .
- Check billing with `/usage` in the Grok TUI. The current
  [`grok usage <session-id>` implementation](https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/src/usage_cmd.rs)
  reads historical session token/cost totals. Those totals are not remaining
  included quota and can require session-content access, so quotabot does not
  invoke it. Never send `/usage` through a prompt or headless generation mode.
  See [current commands](https://docs.x.ai/build/modes-and-commands).
- Quota shape: the billing response reports included usage as a percentage and
  a typed weekly or monthly period. Prepaid and on-demand balances are separate.
- quotabot reads the first-party CLI proxy's JSON billing metadata. A supported
  host token starts independently of optional owned grants; `quotabot login
  grok` grants are discoverable even without a host file. Exact personal/team
  identity is required before joining credentials. Usage and account discovery
  enforce separate cooldowns. Legacy WebLogin records receive a re-login step.
  See the [source and compatibility contract](DATA_SOURCES.md#grok-xai) and
  [dated reliability review](research/2026-09-provider-reliability.md).

## NVIDIA NIM

- Official docs: https://build.nvidia.com/ and
  https://developer.nvidia.com/nim
- Check access yourself: create an API key on build.nvidia.com, set
  `NVIDIA_API_KEY` (or `nvapi`), then call the OpenAI-compatible
  `https://integrate.api.nvidia.com/v1/models` endpoint.
- Access shape: NVIDIA-hosted NIM APIs are free for development/testing with
  model-specific trial rate limits. NVIDIA does not publish a zero-cost numeric
  remaining-balance endpoint.
- quotabot reads: `GET /v1/models` only, to confirm the key works. It reports
  availability with unknown numeric quota and never calls inference.

## Passive and local

- **Cursor:** current plans use two separate monthly pools, Cursor Models and
  Other Models. Current Cursor 3.x state can identify a recognized, owner-bound
  plan but does not persist those current balances in supported local rows, so
  the plan is diagnostic and unroutable. Open Cursor Settings > Usage and its
  Spending tab to inspect them. See
  https://cursor.com/docs/models-and-pricing .
- **Windsurf / Devin:** Pro and Teams full seats use daily and weekly limits
  shared across Devin, Terminal, and Windsurf; Max uses a weekly limit without
  the daily limit. Prepaid on-demand credits can continue after included quota,
  can auto-reload, and can be shared at team scope. The provider documents that
  balance in Settings but no supported self-serve balance API, so quotabot does
  not scrape it or infer a paid ceiling from local plan state.
  quotabot reports only provider-owned, timestamped local evidence it can read
  opportunistically. See
  https://docs.devin.ai/admin/billing/self-serve .
- **Kiro:** plans use monthly credits that renew at the next billing cycle, and
  individual client displays can combine them with prepaid add-on credits.
  quotabot preserves supported provider-owned local rows as aggregate
  credit-based evidence and does not call them included quota or decompose a
  paid balance without field validation. Cross-check
  https://kiro.dev/docs/billing/add-on-credits/ and https://kiro.dev/pricing/ .
- **Ollama, LM Studio, Lemonade (and other OpenAI-compatible runtimes):**
  quotabot leads with models loaded now, their actual running context when the
  runtime reports it, and GPU-resident bytes when known. Installed count and
  disk size remain inventory detail. `loaded` means resident, not necessarily
  busy. Host RAM, GPU memory pressure, and optional supported host GPU activity
  are explicitly labeled as local-host evidence and are never attributed to one
  model. Locally
  executed models have no quota to spend, so a supported runtime is a fallback
  while its daemon is reachable. LM Studio must have its local server started
  (Developer tab, or `lms server start`); Lemonade desktop packages start their
  service automatically, default to port 13305, and honor `LEMONADE_HOST` and
  `LEMONADE_PORT`. Use `lemonade status` to check it; headless installations run
  `lemond`. Cloud routes exposed by Ollama or Lemonade are offloaded despite the
  loopback daemon and do not satisfy a local-only budget.
  `OLLAMA_HOST`, `LMSTUDIO_HOST`, and `LEMONADE_HOST` qualify as local capacity
  only for exact loopback destinations. quotabot does not contact
  credential-bearing, LAN, or public values supplied through those overrides.
