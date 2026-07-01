# Data sources

Exactly where each provider's numbers come from. Paths are shown for Windows;
the adapters resolve the user home directory cross-platform.

## Manual entries

- Source: the user's own local entries under quotabot's per-user config
  directory, managed with `quotabot manual set/list/remove`.
- Required fields: provider id, used count, limit, and reset time. Optional
  fields include display name, account, plan, and window label.
- These entries are self-reported. quotabot never invents or refreshes them, does
  not write them into measured analytics history, and marks their snapshots with
  `source: "manual"` so routers can treat their confidence differently from live
  adapter telemetry.

## Codex (OpenAI)

- Source: the newest `rollout-*.jsonl` under `~/.codex/sessions/<date>/`.
- The Codex CLI writes a `rate_limits` object to its session log on every turn:

  ```json
  "rate_limits": {
    "primary":   { "used_percent": 62.0, "window_minutes": 300,   "resets_at": 1781935855 },
    "secondary": { "used_percent": 98.0, "window_minutes": 10080, "resets_at": 1782335912 },
    "plan_type": "pro"
  }
  ```

- `primary` is the 5 hour window, `secondary` is the weekly window.
- No network or auth. The values are as of the last Codex session, so a reset
  time in the past simply means that window has rolled over.

## Claude (Anthropic)

- Source: `GET https://api.anthropic.com/api/oauth/usage`.
- Auth: the OAuth access token Claude Code stores in
  `~/.claude/.credentials.json` under `claudeAiOauth.accessToken`, sent as a
  bearer token with the `anthropic-beta: oauth-2025-04-20` header.
- Response provides `five_hour` and `seven_day` blocks (plus per-model weekly
  blocks) with a `utilization` percent and an ISO `resets_at`.
- This is live, and is the same data the in-CLI `/usage` command shows.
- The token can expire; Claude Code refreshes it during normal use. On a 401 the
  adapter reports the token as expired and the cache serves the last value.

## Grok (xAI)

- Account: `~/.grok/auth.json` (email).
- Auth: quotabot's own grant from `login grok` if present, otherwise the bearer
  token (`key`) the CLI currently holds. See "Authentication" below.
- Live usage: a gRPC-web POST to
  `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` with the
  bearer token and an empty request frame. The protobuf response carries the
  credit usage percent for the shared paid-plan weekly pool and the pool reset
  timestamp, parsed into a single weekly window. The usage page's Imagine, Chat,
  and Build percentages are category breakdowns inside that shared pool, not
  independent spendable buckets. This is a billing metadata call, not a
  model call, so it costs no tokens.
- Multi-account: every account object in `auth.json` is read. quotabot tries the
  matching account-scoped grant before the provider-default grant (primary
  account only) or that account's CLI token, and successful reads are cached per
  account.

## Antigravity (Google)

State lives in the Antigravity globalStorage SQLite database at
`~/AppData/Roaming/Antigravity/User/globalStorage/state.vscdb`, read with the
`sqlite3` package's hook-managed bundled native library.

- Account and plan: the `antigravityAuthStatus` key holds JSON with the email
  and a base64 `userStatus` protobuf; the adapter decodes the plan tier from it.
- Auth, in priority order: quotabot's own grant from `quotabot login antigravity`
  (preferred); otherwise the token the Gemini/Antigravity CLI stored in
  `~/.gemini/oauth_creds.json`, refreshed from its refresh token when the saved
  access token has expired; otherwise the IDE's access token from the
  `antigravityUnifiedStateSync.oauthToken` key (a protobuf wrapping a
  base64-encoded inner protobuf; `findEmbeddedToken` peels the layers).
- Live usage: the quota endpoint only accepts tokens minted by Antigravity's own
  OAuth client and an onboarded project, so `login antigravity` uses that public
  client and the adapter runs `:onboardUser` (retried) to provision the project,
  then calls the Cloud Code API
  (`https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`, then
  `:fetchAvailableModels`) for per-model `quotaInfo` with `remainingFraction`,
  `resetTime`, and `isExhausted`. These are quota metadata calls, not generation,
  so they cost no tokens. The per-model quotas are bucketed into windows by reset.
- The Code Assist tier field reports `free-tier` even for paid accounts, so it is
  not used as a plan signal; when the quota endpoint returns nothing the adapter
  says so honestly rather than mislabeling the account as free.
- The adapter constructs the SQLite path cross-platform (Windows APPDATA, macOS
  Library, Linux XDG) and scans Antigravity profile directories. Each active
  account gets its own live read when a matching account grant, active CLI token,
  or IDE token is available; per-account cache files are used only while the
  account remains present in the active local profile set.

## Authentication

Codex needs no auth (it reads a file). Claude reuses the token Claude Code
stores. Grok and Antigravity can run two ways:

- Opportunistic: reuse the token the CLI or IDE currently holds, read-only. This
  is live only while that app keeps the token fresh.
- Connected: after `login grok` or `login antigravity`, quotabot holds its own
  OAuth grant and refreshes silently. Both work with no cloud setup. Grok uses
  the device-code flow; Antigravity uses a loopback plus PKCE authorization-code
  flow against Antigravity's public client (override with
  `QUOTABOT_GOOGLE_CLIENT_ID`/`QUOTABOT_GOOGLE_CLIENT_SECRET` to use your own).
  These grants are independent of the host apps, so they never invalidate the
  CLI's or IDE's credentials. quotabot's tokens live under the per-user config
  directory, owner-only on POSIX and ACL-restricted on Windows. A grant can be
  stored as the provider default or in an account-scoped slot; the account slot
  filename uses a hash rather than the raw email. Grok derives the account slot
  from the device-login id token when present; Antigravity resolves it from
  Google's userinfo endpoint after OAuth exchange. Rotated refresh tokens are
  persisted on every refresh.

## Kiro (agentic CLI + IDE)

- Credit-based (interactions/credits). Local state in ~/.kiro or platform
  globalStorage (state.vscdb / data.sqlite3 like other VS Code forks).
- Opportunistic read of local credits/usage. Passive "installed" report even
  after subscription cancel (e.g. Kiro CLI left behind).
- Adapter falls back gracefully; no live API required for basic robustness.

## Cursor (agentic IDE)

- Current paid plans expose a monthly included-usage pool with optional
  pay-as-you-go overage; quotabot surfaces that pool as a `monthly` window when
  local state provides used/included values and a period reset.
- Local data primarily ~/.cursor (config + SQLite state like other forks).
- Usage often shown in-app Settings, but local state allows passive detection
  and opportunistic reads. The adapter scans usage/credit/plan/account rows in
  Cursor's `state.vscdb`, accepts JSON stored as either strings or blobs, and
  surfaces account and plan labels when the local state includes them.
- Account shown automatically for duplicate-provider cards so two accounts are
  never visually ambiguous. The global "Show account names" setting also shows
  non-default account labels for single-account providers.

## Windsurf / Devin (Codeium / Cognition)

- Now branded Devin Desktop (IDE) and Devin CLI. Agentic Cascade uses daily +
  weekly quota.
- Local passive (IDE/Desktop): ItemTable key
  `windsurf.settings.cachedPlanInfo` plus related Windsurf/Codeium/Devin
  usage, quota, account, and plan rows in `globalStorage/state.vscdb`.
- Paths covered: Windsurf, .codeium/windsurf, Devin (Roaming/Devin, Local/devin
  etc).
- The adapter accepts JSON state stored as strings or blobs, normalizes
  daily/weekly quota evidence from direct percent fields or nested quota maps,
  carries reset timestamps when present, and surfaces account/plan labels when
  local state includes them.
- CLI-only installs (devin CLI): passive detection via `config.json` /
  `credentials.toml` (no rich daily/weekly cache). Shows as "cli" or org
  snippet.
- The adapter does not invent usage from undecodable raw blobs; free tier, no
  subscription, missing cache, and CLI-only cases stay graceful detection-only
  results. For live numbers when only CLI: check app.devin.ai.

## Local runtimes (Ollama, LM Studio, ...)

Local runtimes have no remaining-budget to spend, so they carry no quota
windows and are never shown as a usage bar. Instead the adapter reports what the
runtime has: the number of installed models, which models are loaded in memory,
and an in-use flag (a model being loaded is the available proxy for activity).
They are marked `kind: local`, sort below the cloud services, and are used as an
always-available routing fallback while the daemon is up. A local runtime is
shown only when reachable; when it is off the provider is dropped, and it is
never served from cache (a cached "available" would mislead when the daemon is
actually down).

- Ollama: `GET /api/tags` (installed) and `GET /api/ps` (loaded). Honors
  `OLLAMA_HOST`, default `http://127.0.0.1:11434`.
- LM Studio: `GET /api/v0/models` (native REST, includes a per-model `state` of
  loaded or not-loaded), falling back to the OpenAI-compatible `GET /v1/models`
  when the native API is unavailable. Honors `LMSTUDIO_HOST`, default
  `http://127.0.0.1:1234`. The LM Studio local server must be started (Developer
  tab, or `lms server start`).
- Lemonade: the AMD/lemonade-sdk OpenAI-compatible server. `GET /api/v1/models`
  (falling back to `/v1/models`). Honors `LEMONADE_HOST`, default
  `http://127.0.0.1:8000`.
- Other runtimes: anything exposing an OpenAI-style `/v1/models` endpoint (Jan,
  llama.cpp / llamafile, GPT4All, text-generation-webui, KoboldCpp) can be added
  with the same shared `localRuntimeQuota` helper; only the discovery URL and
  load-state field differ.

## Cloud model catalog audit

The runtime model registry does not call cloud model-list endpoints. It combines
live provider quota with the committed capability catalog in
`collector/lib/model_catalog.dart`, keeping normal quota reads local-first and
zero-extra-network.

For maintenance, `collector/bin/catalog_audit.dart` can diff that committed
catalog against provider-owned model-list endpoints:

- Codex/OpenAI: `GET https://api.openai.com/v1/models` with `OPENAI_API_KEY`.
- Claude/Anthropic: `GET https://api.anthropic.com/v1/models` with
  `ANTHROPIC_API_KEY` and the `anthropic-version` header.
- Grok/xAI: `GET https://api.x.ai/v1/models` with `XAI_API_KEY`.
- Antigravity/Gemini: `GET
  https://generativelanguage.googleapis.com/v1beta/models` with
  `GEMINI_API_KEY` or `GOOGLE_API_KEY`.

The audit follows provider pagination tokens and reports model-id drift only:
`missing_from_catalog` and `catalog_only`. Context window, tool support, vision,
reasoning, and tier remain curated because provider list endpoints are
inconsistent and often account-scoped. Missing API keys are reported as skipped,
not failures, unless the caller opts into `--fail-on-error`.

The runtime cost boundary is intentionally narrow: authenticated catalog audits
may call only model-list endpoints such as `https://api.x.ai/v1/models`. Runtime
sources are covered by a no-surprise-cost contract test that rejects direct
model, chat, image, and content-generation endpoints, including xAI image APIs.

## Google (Antigravity)

Gemini CLI (consumer) and related Code Assist for individuals transitioned to Antigravity CLI around June 18, 2026. Antigravity (the VS Code fork + CLI) is the current Google agentic platform. See the Antigravity section above for local state.vscdb + live Cloud Code quota (already covers the unified offering, including multi-account). Legacy ~/.gemini paths may linger but are no longer primary for consumer quota.

Free tier users typically see "free tier" (no hard tracked % windows) or 100% availability on reported buckets. There are still per-minute rate limits, but no weekly spend cap like paid tiers for the quotas quotabot tracks. Plan/tier is extracted from local state or responses when available.

## A note on secrets

quotabot reads existing tokens only to make the same authenticated requests the
provider's own tools already make on your behalf. Tokens are never logged; only
the resulting usage numbers are written to the snapshot cache. quotabot's own
OAuth tokens are stored separately from the host applications' credentials.

Agnostic tools (Aider, Cline, etc.) typically use your existing API keys
(Codex, Claude, etc.) so their usage is covered by the underlying provider
adapters already present. Detection reports them as using tracked providers.
