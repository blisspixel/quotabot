# Provider CLIs and usage commands

A quick reference to the AI coding CLIs quotabot tracks: each one's own
usage/quota command, and how quotabot reads the same numbers.

These tools change often. Treat this as a starting point and verify against each
vendor's official docs (linked per provider). For exactly where quotabot reads
each number, see [DATA_SOURCES.md](DATA_SOURCES.md).

**Last updated: 2026-07-10.**

## Claude (Claude Code)

- Official docs: https://platform.claude.com/docs and the rate-limit reference at
  https://platform.claude.com/docs/en/api/rate-limits
- Check usage yourself: `/usage` in a Claude Code session shows remaining quota,
  reset time, and burn rate. Related: `/cost`, `/stats`, `/context`.
- Windows: a rolling 5-hour window plus a weekly cap, shared across Claude Code,
  Claude.ai, and related products.
- quotabot reads: the OAuth usage endpoint, reusing the token Claude Code stores.
  Live when Claude Code has a valid signed-in token; no quotabot login.

## Codex (OpenAI)

- Official docs: https://developers.openai.com/codex/cli
- Check usage yourself: `/status` during a Codex CLI session shows your current
  limits.
- Windows: message quotas that reset every 5 hours, with weekly limits on some
  plans. Plus/Pro/Business plans get higher limits.
- quotabot reads: the ChatGPT usage endpoint, reusing the OAuth access token
  Codex stores locally. If the live read is unavailable, it falls back to the
  newest local session `rate_limits` snapshot and marks that data as this
  machine.

## Antigravity / Gemini (Google)

- Official docs: https://antigravity.google/docs/cli-overview ,
  https://antigravity.google/docs/cli-using ,
  https://antigravity.google/docs/cli-credits
- The CLI is `agy`. `agy --help` lists flags (`--print` for non-interactive,
  `--model`, `--project`, ...) and subcommands (`models`, `update`, ...). Inside
  the TUI, the Models & Quota panel shows per-model-group Weekly and Five Hour
  limits. Antigravity replaced the consumer Gemini CLI on 2026-06-18.
- Windows: per-model-group Weekly and Five Hour limits (Gemini models; Claude and
  GPT models), depending on plan (free, AI Pro, Ultra).
- quotabot reads: the Cloud Code API (`loadCodeAssist`, `onboardUser`,
  `fetchAvailableModels`). It can reuse refresh material from a signed-in
  Antigravity IDE; `quotabot login antigravity` is optional when a discovered
  account needs a separate refreshable grant or should be pinned. The IDE must
  have run on this machine so its account remains discoverable. No Google Cloud
  setup is required. The live read is preferred; local Antigravity state is used for
  account discovery and offline fallback, where quotabot marks the result
  `per_machine`.

## Grok (xAI)

- Official docs: https://docs.x.ai and the console at https://console.x.ai .
  Open-source coding CLI: https://github.com/superagent-ai/grok-cli
- Check usage yourself: `/usage` in the Grok TUI tracks token and credit use.
  Headless mode is `grok -p "..."`; ACP mode is `grok agent stdio`.
- Windows: paid-plan usage is a shared weekly usage pool. The Usage tab's
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
- Windows: NVIDIA-hosted NIM APIs are free for development/testing with
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
