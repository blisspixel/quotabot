# Provider CLIs and usage commands

A quick reference to the AI coding CLIs quotabot tracks: each one's own
usage/quota command, and how quotabot reads the same numbers.

These tools change often. Treat this as a starting point and verify against each
vendor's official docs (linked per provider). For exactly where quotabot reads
each number, see [DATA_SOURCES.md](DATA_SOURCES.md).

**Last updated: 2026-07-18.**

The provider command is only one part of the trust statement. quotabot also
emits a normalized `source_class`: Claude and live Codex, Grok, and Antigravity
are `authoritative_live`; Antigravity local fallback is
`this_machine_fallback`; Cursor, Windsurf/Devin, and Kiro are
`passive_local_evidence`; Ollama, LM Studio, and Lemonade are `local_runtime`;
NVIDIA NIM is `status_only`; and user entries are `manual`. The exact routing
and verification rules are in [DATA_SOURCES.md](DATA_SOURCES.md#source-classes).

## Claude (Claude Code)

- Official docs: https://platform.claude.com/docs and the rate-limit reference at
  https://platform.claude.com/docs/en/api/rate-limits
- Check usage yourself: `/usage` in a Claude Code session shows current-window
  usage bars and reset times. Its separate contribution breakdown can be based
  only on local sessions and does not prove account balance or cross-device
  burn. quotabot derives burn rate from its own bounded local quota history.
  Related: `/cost`, `/stats`, `/context`.
- Do not automate this as `claude -p /usage` or `/quota`. Print mode is a
  prompt-execution surface, not a stable quota API, and `/quota` is not a
  documented built-in command. quotabot calls the account-wide usage metadata
  endpoint directly so collection remains content-blind and uses zero inference.
- Quota shape: a rolling 5-hour window plus a weekly cap, shared across Claude
  Code, Claude.ai, and related products.
- The live response may also include a model-scoped weekly cap. Beginning July
  20, 2026, Anthropic says Fable 5 is a standard included benefit at 50% of
  limits for Max and Team Premium. Pro and Team Standard retain Fable through
  usage credits and receive a one-time $100 credit. This is a dated plan policy,
  not a value quotabot hardcodes. `budget=quota` therefore requires both a live
  scoped Fable row and a Max or Team Premium entitlement carried by current
  provider usage or profile metadata read with the same credential on or after
  July 20, 2026 UTC. The
  `subscriptionType` in the local Claude credential is
  labeled `host_credential` evidence and never proves included spend after a
  plan change. Positive included-quota and credit-backed labels both require
  current provider plan evidence. Unknown, host-label-only, and credit-backed
  plans remain visible only under the unrestricted budget. See the
  [July 17 announcement](https://x.com/claudeai/status/2078302415804379218).
- quotabot reads: the OAuth usage and profile metadata endpoints, reusing the
  token Claude Code stores.
  Live with no quotabot login when Claude Code has a valid signed-in token here;
  `quotabot login claude` adds a self-refreshing grant designed to keep the
  account-wide read live on a machine you have not opened Claude Code on
  recently. Confirm the result with `quotabot doctor`; real-account evidence
  after an idle interval remains a tracked 1.0 acceptance item.
- The usage endpoint does not return a stable account id, but the profile
endpoint returns account and organization ids. quotabot hashes those ids to
form the stable live snapshot, cache, drift, and lease identity and to collapse
two credentials for the same subscription. If identity cannot be proven for
every successful credential, at most one remains routable and an irreversible
local credential fingerprint is the fallback boundary. Switching credentials
cannot lend a new login an old 100% reading. No raw credential or provider
account id enters quota output.

## Codex (OpenAI)

- Official docs: https://developers.openai.com/codex/cli
- Check usage yourself: `/status` during a Codex CLI session shows your current
  limits.
- Quota shape: the endpoint labels each shared pool by its reported duration.
  Current Pro responses can expose one weekly primary pool, an explicit null
  secondary pool, and a separate named GPT-5.3-Codex-Spark weekly pool. The
  named pool gates Spark only; it does not replace the shared account limit.
- quotabot reads: the ChatGPT usage endpoint, reusing the OAuth access token
  Codex stores locally, or a self-refreshing grant from `quotabot login codex`
  when that token is expired. The grant path is designed to keep an idle machine
  live and must be confirmed there with `quotabot doctor`; dated real-account
  idle validation remains a tracked 1.0 acceptance item. If no account-wide read
  succeeds, it fails closed with a login repair. It never opens Codex session
  files, which can contain prompts and responses, for quota evidence.

## Antigravity / Gemini (Google)

- Official docs: https://antigravity.google/docs/cli-overview ,
  https://antigravity.google/docs/cli-using ,
  https://antigravity.google/docs/cli-credits
- The CLI is `agy`. `agy --help` lists flags (`--print` for non-interactive,
  `--model`, `--project`, ...) and subcommands (`models`, `update`, ...). Inside
  the TUI, the Models & Quota panel shows per-model-group Weekly and Five Hour
  limits. Antigravity replaced the consumer Gemini CLI on 2026-06-18.
- Quota shape: per-model-group Weekly and Five Hour limits (Gemini models;
  Claude and GPT models), depending on plan (free, AI Pro, Ultra).
- quotabot reads: the Cloud Code API (`loadCodeAssist`, `onboardUser`,
  `fetchAvailableModels`). It can reuse refresh material from a signed-in
  Antigravity IDE; `quotabot login antigravity` is optional when a discovered
  account needs a separate refreshable grant or should be pinned. The IDE must
  have run on this machine so its account remains discoverable. No manual Google
  Cloud project setup is required because the provider-required onboarding
  request is performed automatically. The live read is preferred; local
  Antigravity state is used for account discovery and offline fallback, where
  quotabot marks the result `per_machine`.

## Grok (xAI)

- Official docs: https://docs.x.ai and the console at https://console.x.ai .
  Open-source coding CLI: https://github.com/superagent-ai/grok-cli
- Check usage yourself: `/usage` in the Grok TUI tracks token and credit use.
  Headless mode is `grok -p "..."`; ACP mode is `grok agent stdio`.
- Quota shape: paid-plan usage is a shared weekly usage pool. The Usage tab's
  Imagine, Chat, and Build percentages are category breakdowns inside that
  shared pool (SuperGrok / Premium+ raise the limits).
- quotabot reads: the gRPC-web billing endpoint, reusing the token the Grok CLI
  stores. `quotabot login grok` can keep a matching account live with a separate
  grant, but the local Grok account file must still exist for discovery.

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

- **Cursor, Windsurf, Kiro:** detected from their local state files; no usage
  command needed. quotabot reports what it can read opportunistically.
- **Ollama, LM Studio, Lemonade (and other OpenAI-compatible runtimes):**
  quotabot lists installed and loaded models from the local API. Locally
  executed models have no quota to spend, so a supported runtime is a fallback
  while its daemon is reachable. LM Studio must have its local server started
  (Developer tab, or `lms server start`); Lemonade desktop packages start their
  service automatically, default to port 13305, and honor `LEMONADE_HOST` and
  `LEMONADE_PORT`. Use `lemonade status` to check it; headless installations run
  `lemond`. Ollama cloud models are offloaded despite the loopback daemon and
  must not be assumed to satisfy a local-only budget.
  `OLLAMA_HOST`, `LMSTUDIO_HOST`, and `LEMONADE_HOST` qualify as local capacity
  only for exact loopback destinations. quotabot does not contact
  credential-bearing, LAN, or public values supplied through those overrides.
