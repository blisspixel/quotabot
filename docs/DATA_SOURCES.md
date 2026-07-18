# Data sources

Exactly where each provider's numbers come from. Paths are shown for Windows;
the adapters resolve the user home directory cross-platform.

## Source classes

Treat the class as part of every number. It defines what quotabot can claim,
how the observation is verified, and how it participates in routing. Every
current producer emits the normalized `source_class` field. Its six wire values
are a stable additive contract:

| Human label | `source_class` | Current assignment | Routing treatment | Verification method | Failure or drift treatment |
|---|---|---|---|---|---|
| Authoritative | `authoritative_live` | Claude; live Codex; live Grok; live Antigravity | Eligible while fresh and its binding quota is usable | The provider registry permits the class; `quotabot verify` checks its account-wide shape, time, bounds, resets, drift, and provider-owned cross-check target | Preserve the last trusted snapshot as stale evidence; reject implausible changes and never call stale cloud quota available |
| This-machine fallback | `this_machine_fallback` | Codex session snapshot; Antigravity local state | Eligible only under normal freshness and binding rules; routing confidence is multiplied by `0.7`, and machine scope stays visible | The registry permits the fallback path; a successful measured window must carry `per_machine: true`, then passes the normal time, bounds, reset, and drift checks | State that another device can make the value incomplete |
| Passive local | `passive_local_evidence` | Cursor; Windsurf/Devin; Kiro | A measured normalized window can participate with routing confidence multiplied by `0.7`; detection-only state cannot | The registry and sanitized parser fixture pin the source; a successful measured window must carry `per_machine: true`, and `verify` checks its shape and honesty | Show no live data or last-trusted reader-drift evidence instead of inventing quota |
| Local runtime | `local_runtime` | Ollama; LM Studio; Lemonade | Admits reachable runtime-classified entries; an Ollama `-cloud` model is flagged `cloud_offloaded` and excluded from local-only and free budgets | The registry requires `kind: "local"`, no quota windows, live loopback reachability, and no cached availability | Never cache availability; keep a cloud-offloaded local model out of any local-only or free budget promise |
| Status only | `status_only` | NVIDIA NIM model-list access check | Visible for access diagnostics, never a model-budget route without measured quota | The registry requires a subscription observation with no quota windows; `verify` rejects quota or provider-drift claims on this class | Show access state with numeric quota unknown |
| Manual | `manual` | User-defined entries | Visible with the existing `0.35` self-reported confidence factor; excluded by `budget=quota` | The entry must carry both `source_class: "manual"` and the legacy `source: "manual"` marker; it cannot claim local-runtime, machine-scoped, or drift evidence | Never refresh or reinterpret what the user entered |

`source_class` is the normalized provenance contract. The older optional
`source` field remains a narrow origin hint and currently uses `"manual"` only;
it is not a substitute for `source_class`. Current snapshots, routing
candidates, model candidates, reports, checks, and verification records carry
the normalized class. Human surfaces use the concise labels in the first
column, without stacking redundant `this machine`, `local`, or `manual` tags.

The frozen `quotabot.v1` schema keeps `source_class` optional so snapshots from
earlier 0.5 releases remain valid. When reading one of those legacy documents,
quotabot deterministically infers the class from provider, `kind`, `source`, and
`per_machine`; that compatibility path does not admit a new provider. An
explicit unknown value is invalid. Every built-in adapter declares its allowed
class set in the compile-time registry, and `quotabot verify` fails its
`source_class` check when the class is missing from that registry, disallowed
for the provider, or inconsistent with the observation shape. Structurally
invalid class evidence is unavailable to routing and excluded from measured
history.

Source class is separate from freshness. For example, authoritative data can be
cached and stale, while a this-machine snapshot can be freshly captured but
still incomplete across devices.

Stale windows never roll forward speculatively. If a live read fails after a
cached window's reset boundary passes, quotabot preserves the last observed
percentage and original capture time. It does not infer 100% free capacity, and
the stale provider remains non-routable until a fresh read succeeds.

The `0.7` machine-scoped factor is multiplicative, not a fabricated probability
that the number is correct. It discounts the routing confidence produced from
freshness and sample adequacy because this-machine fallback and passive local
evidence can miss usage on another device. It does not change raw headroom,
availability, or the provider's reported percentage.

Across measured source classes, the drift admission boundary compares only the
same provider/account evidence class. A reset that moves earlier, or usage that
falls without a completed reset, rejects the fresh observation. So does a
previously trusted window or model pool disappearing. A window with no
derivable percentage is no-data evidence, never free capacity. A missing,
non-positive, or materially future capture time is likewise rejected at live
admission and by direct routing guards. The last trusted windows stay visible as
stale evidence with additive `drift_reason` and
`drift_observed_at`; rejected values do not overwrite cache, enter measured
history or analytics, or participate in routing. A bounded local diagnostic
survives restarts and ordinary failed reads until a later clean observation for
the same identity establishes recovery. A migrated legacy `suspect` record has
no provable last-known-good windows, so quotabot exposes a non-routable error
quarantine until every retained quota reset advances or the evidence class
changes. `quotabot verify` reports both forms as a failed `provider_drift`
check: normal
last-trusted fallback keeps state `cached`, while the no-window legacy form uses
the existing `error` state.

A source-class transition starts a new drift baseline rather than comparing
unlike evidence. This prevents an account-wide live read and a machine-scoped
fallback from being treated as interchangeable history.

### Provenance design basis

This contract follows the W3C PROV guidance to make provenance explicit and
machine-readable, then apply domain-specific validation constraints. quotabot
uses a deliberately smaller quota-specific vocabulary and does not claim full
PROV-DM conformance.

- [W3C PROV Overview](https://www.w3.org/TR/prov-overview/), W3C Working Group
  Note, published 2013-04-30, accessed 2026-07-10.
- [W3C PROV Primer](https://www.w3.org/TR/prov-primer/), W3C Working Group Note,
  published 2013-04-30, accessed 2026-07-10.

## Manual entries

- Source: the user's own local entries under quotabot's per-user config
  directory, managed with `quotabot manual set/list/remove`.
- Required fields: provider id, used count, limit, and reset time. Optional
  fields include display name, account, plan, and window label.
- These entries are self-reported. quotabot never invents or refreshes them, does
  not write them into measured analytics history, and marks their snapshots with
  `source_class: "manual"` plus the legacy `source: "manual"` hint so routers
  can treat their confidence differently from live adapter telemetry.

## Codex (OpenAI)

- Source (authoritative, cross-device): `GET
  https://chatgpt.com/backend-api/wham/usage`, the same endpoint the CLI's own
  status view polls. Auth is tried in priority order: the OAuth access token
  Codex stores in `~/.codex/auth.json`, then quotabot's own refreshable grant
  from `quotabot login codex` when that token is expired (the idle-machine path).
  The `chatgpt-account-id` header is read from `auth.json` either way - it is a
  stable identifier that does not expire - and quotabot never writes that file.
  The response's
  `rate_limit.primary_window` is the 5 hour window and `secondary_window` the
  weekly, each with `used_percent` and `reset_at`; `plan_type` and `email`
  identify the account. This is a metadata read, so it costs no tokens.
- Reset credits: the same response carries
  `rate_limit_reset_credits.available_count` - redeemable off-cycle resets that
  refresh the rate limit early. quotabot exposes this as the structured
  `reset_credits_available` field and surfaces it prominently: a green
  "N resets available ... redeem now" line in `doctor` and `top`, a green banner
  on the desktop card, and a "Reset available" notification. It is a fresh-read
  signal (never asserted from stale or drifted evidence), and it is display only;
  quotabot never redeems one.
- Window restructure: OpenAI has been observed collapsing the separate 5 hour and
  weekly buckets into a single weekly window. A Codex window disappearing is
  treated as a provider restructure rather than silent drift, so a fresh
  single-window read is admitted instead of being held behind the
  pre-restructure snapshot (which would keep reporting a spent old window as
  current). A surviving window's own value still passes the reset-monotonicity
  and re-rating checks, so an implausible number is still caught.
- Fallback (this machine only): the newest `rollout-*.jsonl` under
  `~/.codex/sessions/<date>/`, where the CLI writes a `rate_limits` object with
  `primary` (5 hour) and `secondary` (weekly) buckets on every turn. Used only
  when the live read is signed out or offline. It reflects this machine's
  sessions alone, so its snapshot is classified `this_machine_fallback`, marked
  `per_machine`, and can undercount
  when the account is used on another device; a reset time in the past means
  that window has rolled over since the last session here.

## Claude (Anthropic)

- Source: `GET https://api.anthropic.com/api/oauth/usage`.
- Auth, in priority order: the OAuth access token Claude Code stores in
  `~/.claude/.credentials.json` under `claudeAiOauth.accessToken` (used while its
  `claudeAiOauth.expiresAt` is still in the future), then quotabot's own
  refreshable grant from `quotabot login claude` when the host token is missing
  or expired. Both are sent as a bearer token with the
  `anthropic-beta: oauth-2025-04-20` header. quotabot never writes the host
  credentials file.
- Response provides `five_hour` and `seven_day` blocks (plus per-model weekly
  blocks) with a `utilization` percent and an ISO `resets_at`.
- This is live, and is the same data the in-CLI `/usage` command shows.
- The host token only refreshes while Claude Code runs on this machine, so on an
  idle machine it eventually expires. quotabot then refreshes its own grant if
  connected; if neither token works it reports the token as expired (pointing at
  `claude` or `quotabot login claude`) and the cache serves the last trusted
  value marked stale.

## Grok (xAI)

- Account: `~/.grok/auth.json` (email).
- Auth: quotabot's own grant from `login grok` if present, otherwise the bearer
  token (`key`) the CLI currently holds. See "Authentication" below.
- Live usage: a gRPC-web POST to
  `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` with the
  bearer token and an empty request frame. The protobuf response carries the
  used percent of the shared paid-plan weekly pool plus the window start and
  end timestamps; quotabot reads the percent and window end by their known
  fields and parses them into a single weekly window. The usage page's Imagine,
  Chat, and Build percentages are category breakdowns inside that shared pool,
  not independent spendable buckets, and while the response matches the known
  shape a breakdown is not mistaken for the total (if the shape ever drifts, a
  schema-less scan is the best-effort fallback). This is a billing metadata
  call, not a model call, so it costs no tokens.
- Not monotonic: xAI can revise the pool percent downward mid-window without a
  reset (observed live: 100 to 73 under the same reset time, consistent with
  re-rated compute charges or a grown allowance). quotabot mirrors the number
  Grok's own usage page shows; burn analytics treat a decrease as recovery, so
  it cannot poison burn-rate or runway estimates.
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
- Auth, in priority order: quotabot's own grant from `quotabot login
  antigravity` (preferred); otherwise the Antigravity IDE's own refresh token,
  recovered from the `antigravityUnifiedStateSync.oauthToken` key (a protobuf
  wrapping a base64-encoded inner protobuf; `findEmbeddedToken` peels the layers)
  and refreshed via Antigravity's public OAuth client, so a live read works
  whenever the IDE is signed in without any explicit `login antigravity`; then
  the IDE's short-lived access token; then the Gemini CLI token in
  `~/.gemini/oauth_creds.json`. The quota endpoint only accepts a token minted by
  Antigravity's own client, so the Gemini-CLI token returns 403 and is a last
  resort; the IDE refresh token uses the right client and is the path that makes
  Antigravity "just work" from a signed-in IDE.
- Live usage: the quota endpoint only accepts tokens minted by Antigravity's own
  OAuth client and an onboarded project, so `login antigravity` uses that public
  client and the adapter runs `:onboardUser` (retried) to provision the project,
  then calls the Cloud Code API
  (`https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`, then
  `:fetchAvailableModels`) for per-model `quotaInfo` with `remainingFraction`,
  `resetTime`, and `isExhausted`. These are quota metadata calls, not generation,
  so they cost no tokens. The per-model quotas are bucketed into windows by reset.
- The local `userStatus` cache is this-machine state. It is used for account and
  plan discovery, and as an offline last-known fallback when live quota is
  unavailable. A successful live read is preferred and is not overridden by local
  settings data; local fallback snapshots are classified
  `this_machine_fallback` and marked `per_machine`.
- The Code Assist tier field reports `free-tier` even for paid accounts, so it is
  not used as a plan signal; when the quota endpoint returns nothing the adapter
  says so honestly rather than mislabeling the account as free.
- Antigravity's Cloud Code endpoint reports each model's single binding limit -
  `{remainingFraction, resetTime}`, its tightest cap across the plan's weekly
  allowance and its short-term burst limit - with no field naming which window
  that is. quotabot surfaces the account's most-constrained binding limit as a
  single weekly window (the cap a subscription user tracks) with its true reset,
  rather than guessing the window type from the reset delta, which mislabeled a
  weekly whose reset happened to fall within a few hours as a "5h" window. The
  separate burst limit and the per-model-group breakdown that Antigravity's own
  CLI shows are not exposed by this endpoint; per-model detail is carried by the
  model quotas. A reset beyond eight days out (a week plus a day of buffer) is
  treated as an indeterminate balance and not asserted as a window.
- The adapter constructs the SQLite path cross-platform (Windows APPDATA, macOS
  Library, Linux XDG) and scans Antigravity profile directories. Each active
  account gets its own live read when a matching account grant, active CLI token,
  or IDE token is available; per-account cache files are used only while the
  account remains present in the active local profile set.

## Authentication

Codex reuses the OAuth access token Codex stores locally for the ChatGPT usage
endpoint and falls back to local session snapshots when unavailable. Claude
reuses the token Claude Code stores. All four of Claude, Codex, Grok, and
Antigravity can run two ways:

- Opportunistic: reuse the token the CLI or IDE currently holds for the bounded
  provider operations documented above. This is live only while the credential
  remains usable.
- Connected: after `login claude`, `login codex`, `login grok`, or
  `login antigravity`, quotabot holds its own OAuth grant and refreshes silently.
  All work with no cloud setup. Grok uses the device-code flow; Antigravity and
  Codex use a loopback plus PKCE authorization-code flow against the provider's
  public client (Codex on a fixed loopback port); Claude uses a PKCE
  authorization-code flow whose console callback shows a code to paste back.
  Override the public client id with `QUOTABOT_ANTHROPIC_CLIENT_ID`,
  `QUOTABOT_OPENAI_CLIENT_ID`, or
  `QUOTABOT_GOOGLE_CLIENT_ID`/`QUOTABOT_GOOGLE_CLIENT_SECRET`. Claude and Codex
  both rotate single-use refresh tokens, and these grants are independent of the
  host apps: quotabot refreshes only its own grant and never writes the host
  credential files, so a refresh here never consumes or invalidates the host
  app's token. quotabot's tokens live under the per-user config
  directory. A new or rotated grant is not written unless owner-only directory
  and file permission hardening succeeds on POSIX or Windows. A grant can be
  stored as the provider default or in an account-scoped slot; the account slot
  filename uses a hash rather than the raw email. Grok derives the account slot
  from the device-login id token when present; Antigravity resolves it from
  Google's userinfo endpoint after OAuth exchange. Rotated refresh tokens are
  persisted on every refresh.

Connected grants do not replace provider account discovery. Grok still
discovers accounts from its local auth file, and Antigravity discovers accounts
from local IDE/profile state. Run the provider on this machine first and retain
that local identity state; a quotabot grant is selected only after a matching
account has been discovered.

## Kiro (agentic CLI + IDE)

- Source class: `passive_local_evidence`.
- Credit-based (interactions/credits). Local state in ~/.kiro or platform
  globalStorage (state.vscdb / data.sqlite3 like other VS Code forks).
- Opportunistic read of local credits/usage. Passive "installed" report even
  after subscription cancel (e.g. Kiro CLI left behind).
- Adapter falls back gracefully; no live API required for basic robustness.

## Cursor (agentic IDE)

- Source class: `passive_local_evidence`.
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

- Source class: `passive_local_evidence`.
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

Locally executed runtimes have no remaining budget to spend, so they carry no
quota windows and are never shown as a usage bar. Instead the adapter reports
what the runtime has: the number of installed models, which models are loaded in
memory, and an in-use flag (a model being loaded is the available proxy for
activity).
They are marked `kind: local`, sort below the cloud services, and are used as a
reachable routing fallback while the daemon is up. A local runtime is
shown only when reachable; when it is off the provider is dropped, and it is
never served from cache (a cached "available" would mislead when the daemon is
actually down). All three built-in runtime adapters emit
`source_class: "local_runtime"`.

When at least one reachable runtime exposes an on-device model, the collector
also reads passive machine memory metadata. Linux uses `/proc/meminfo`; Windows
uses `Win32_OperatingSystem` through the system Windows PowerShell executable;
macOS uses `/usr/sbin/sysctl hw.memsize` and `/usr/bin/vm_stat`. On Windows and
Linux, an installed NVIDIA driver can add its largest single GPU through a
bounded `nvidia-smi` memory query. Separate GPU pools are never summed. The read
is cached for 30 seconds, has bounded output and deadlines, and fails soft. It
does not load a model, reserve memory, execute inference, or measure throughput.

For a cold model with an installed byte size, quotabot estimates required memory
as the file size plus the larger of 25 percent or 512 MiB. Each observed memory
pool retains a reserve of the larger of 10 percent, 2 GiB for system RAM, or 1
GiB for GPU memory. `comfortable` means the estimate fits current availability
after that reserve; `tight` means it fits total capacity after the reserve but
not comfortably now; `constrained` means it exceeds the conservative capacity
of every single observed pool; `unknown` means size or capacity evidence is
missing. A loaded model reports `loaded`, which is direct runtime evidence.
These states rank cold on-device candidates but never change runtime
availability. A runtime may split work across RAM and VRAM, and context or model
format overhead can differ from the estimate.

- Ollama: `GET /api/tags` (installed) and `GET /api/ps` (loaded). `/api/ps` also
  reports each running model's `context_length`, which quotabot reads for the
  loaded model's context window, so no `/api/show` call is needed. Honors
  `OLLAMA_HOST`, default `http://127.0.0.1:11434`.
- LM Studio: `GET /api/v1/models` (the current native REST API, 0.4.0+), which
  reports loaded instances with the running context length, on-disk size,
  object-shaped quantization, a real parameter size (`params_string`), and
  capabilities. Falls back to the older native `GET /api/v0/models` (a per-model
  loaded/not-loaded `state`), then the OpenAI-compatible `GET /v1/models` (names
  only, no load state). Honors `LMSTUDIO_HOST`, default `http://127.0.0.1:1234`.
  The LM Studio local server must be started (Developer tab, or `lms server
  start`); loading a model in the chat window does not start it. Metadata only;
  never loads or invokes a model. The v0 shape carries `arch` (architecture), not
  a parameter count, so quotabot does not fill the parameter-size slot from it.
- Lemonade: the AMD/lemonade-sdk OpenAI-compatible server. `GET /api/v1/models`
  (falling back to `/v1/models`). Honors `LEMONADE_HOST` and `LEMONADE_PORT`;
  the default is `http://127.0.0.1:13305`.
- Other runtimes: anything exposing an OpenAI-style `/v1/models` endpoint (Jan,
  llama.cpp / llamafile, GPT4All, text-generation-webui, KoboldCpp) can be added
  with the same shared `localRuntimeQuota` helper; only the discovery URL and
  load-state field differ.

Current compatibility limits:

- Ollama can expose cloud-offloaded models through its local daemon (a `-cloud`
  tag suffix, e.g. `qwen3-coder:480b-cloud`); these execute on ollama.com, not
  on-device. quotabot detects the suffix, flags the model `cloud_offloaded`, and
  excludes it from `--budget=local` and free budgets, so a cloud model reached
  through the local daemon is never treated as local-only or free. It stays
  listed (reachable via the local runtime) but only under `--budget=any`.
- LM Studio's native `GET /api/v1/models` (0.4.0+) is now the preferred read,
  with `/api/v0/models` and the OpenAI-compatible `/v1/models` as fallbacks. The
  v1 shape is pinned by a fixture captured from a real 0.4.0+ server. Remaining:
  thread v1's `capabilities` (vision, tool use) onto local model entries so the
  capability gates apply to local models too.

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

The audit follows provider pagination tokens and reports model-id drift:
`missing_from_catalog` and `catalog_only`. It also reports two freshness signals,
kept separate from drift and errors: `catalog_age_days` (how long since the
curated `kCatalogUpdated` date) and `elapsed_included_quota` (any per-model
`quotaIncludedUntil` window that has already passed, so a stale included-quota
claim is surfaced for re-verification even when every provider audit is skipped
for lack of a key). Context window, tool support, vision, reasoning, and tier
remain curated because provider list endpoints are inconsistent and often
account-scoped. Missing API keys are reported as skipped, not failures, unless
the caller opts into `--fail-on-error`.

The Currency workflow runs this audit daily and on manual dispatch with
`--summary --fail-on-drift --fail-on-error`, after exercising the drift canary,
catalog audit, and no-surprise endpoint contract tests. It grants only read
access to repository contents. Hosted live catalog checks are enabled only for
the provider secrets present in GitHub Actions; absent secrets remain skipped
and do not trigger provider network calls. Summary mode logs drift counts
without publishing provider model ids, which can be account-scoped.

The runtime cost boundary is intentionally narrow: authenticated catalog audits
may call only model-list endpoints such as `https://api.x.ai/v1/models`. Runtime
sources are covered by a no-surprise-cost contract test that rejects direct
model, chat, image, and content-generation endpoints, including xAI image APIs.

## Google (Antigravity)

Gemini CLI (consumer) and related Code Assist for individuals transitioned to Antigravity CLI around June 18, 2026. Antigravity (the VS Code fork + CLI) is the current Google agentic platform. See the Antigravity section above for local state.vscdb + live Cloud Code quota (already covers the unified offering, including multi-account). Legacy ~/.gemini paths may linger but are no longer primary for consumer quota.

Free tier users typically see "free tier" (no hard tracked % windows) or 100% availability on reported buckets. There are still per-minute rate limits, but no weekly spend cap like paid tiers for the quotas quotabot tracks. Plan/tier is extracted from local state or responses when available.

## NVIDIA NIM (build.nvidia.com / integrate.api.nvidia.com)

NVIDIA offers free hosted NIM API access for development and testing through
build.nvidia.com. The API is OpenAI-compatible at
`https://integrate.api.nvidia.com/v1`.

- Source: when `NVIDIA_API_KEY` or `nvapi` is present, quotabot performs
  `GET https://integrate.api.nvidia.com/v1/models` to confirm the key works.
  This is model discovery only, not inference, and is classified
  `source_class: "status_only"`.
- Numeric quota: no local state file or zero-cost API endpoint for remaining
  trial balance/rate-limit headroom is known. NVIDIA now describes trial usage
  as model-specific rate limits rather than a published credit counter, so
  quotabot reports availability with no quota windows instead of showing 0
  percent or inventing a balance.
- Routing: because no measured quota windows are known, NVIDIA NIM availability
  is not treated as a routable model-budget candidate.
- Users who want to track a manually observed balance or reset can use
  `quotabot manual set nvidia ...` with self-reported values.

## A note on secrets

quotabot reads existing tokens only to make the same authenticated requests the
provider's own tools already make on your behalf. Tokens are never logged; only
the resulting usage numbers are written to the snapshot cache. quotabot's own
OAuth tokens are stored separately from the host applications' credentials.

Agnostic tools (Aider, Cline, etc.) typically use your existing API keys
(Codex, Claude, etc.) so their usage is covered by the underlying provider
adapters already present. Detection reports them as using tracked providers.
