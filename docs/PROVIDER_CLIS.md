# Provider CLIs and usage commands

A quick reference to the AI coding CLIs quotabot tracks: each one's own
usage/quota command, and how quotabot reads the same numbers.

These tools change often. Treat this as a starting point and verify against each
vendor's official docs (linked per provider). For exactly where quotabot reads
each number, see [DATA_SOURCES.md](DATA_SOURCES.md).

**Last updated: 2026-06-27.**

## Claude (Claude Code)

- Official docs: https://platform.claude.com/docs and the rate-limit reference at
  https://platform.claude.com/docs/en/api/rate-limits
- Check usage yourself: `/usage` in a Claude Code session shows remaining quota,
  reset time, and burn rate. Related: `/cost`, `/stats`, `/context`.
- Windows: a rolling 5-hour window plus a weekly cap, shared across Claude Code,
  Claude.ai, and related products.
- quotabot reads: the OAuth usage endpoint, reusing the token Claude Code stores.
  Always live, no setup.

## Codex (OpenAI)

- Official docs: https://developers.openai.com/codex/cli
- Check usage yourself: `/status` during a Codex CLI session shows your current
  limits.
- Windows: message quotas that reset every 5 hours, with weekly limits on some
  plans. Plus/Pro/Business plans get higher limits.
- quotabot reads: the `rate_limits` snapshot Codex writes to its newest session
  rollout file. Always live, no setup.

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
  `fetchAvailableModels`) using Antigravity's own public OAuth client. Run
  `quotabot login antigravity` once and sign in with the account you want shown;
  no Google Cloud setup is required.

## Grok (xAI)

- Official docs: https://docs.x.ai and the console at https://console.x.ai .
  Open-source coding CLI: https://github.com/superagent-ai/grok-cli
- Check usage yourself: `/usage` in the Grok TUI tracks token and credit use.
  Headless mode is `grok -p "..."`; ACP mode is `grok agent stdio`.
- Windows: monthly credit usage for the billing cycle (SuperGrok / Premium+
  raise the limits).
- quotabot reads: the gRPC-web billing endpoint, reusing the token the Grok CLI
  stores. Live while that token is fresh; `quotabot login grok` keeps it live.

## Passive and local

- **Cursor, Windsurf, Kiro:** detected from their local state files; no usage
  command needed. quotabot reports what it can read opportunistically.
- **Ollama, LM Studio, Lemonade (and other OpenAI-compatible runtimes):**
  quotabot lists installed and loaded models from the local API. There is no
  quota to spend, so they act as an always-available routing fallback. LM Studio
  must have its local server started (Developer tab, or `lms server start`);
  Lemonade defaults to port 8000 and honors `LEMONADE_HOST`.
