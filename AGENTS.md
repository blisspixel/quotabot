# Using quotabot from an AI agent

quotabot reports how much quota is left across a user's AI coding subscriptions
(Claude, Codex, Antigravity/Gemini, Grok) and local runtimes (Ollama, LM Studio),
and recommends which one to send the next request to. Every call is a metadata
read: no model calls, no usage tokens, and no prompts or code ever read. Most
providers are read from local files; live providers may call their own quota or
model-list metadata endpoint with an existing local token or key.

If you are an agent or tool that picks a model/provider, use quotabot to route to
whichever subscription still has budget instead of stalling on a spent cap.

## Set it up from source (humans or agents)

From a fresh clone, one idempotent command builds and installs everything (the
CLI, the desktop app, and a Desktop/tray shortcut) and then verifies it with
`quotabot doctor`. It needs only Flutter/Dart on the machine, and no prompts,
code, or usage-token-spending requests leave the machine.

- Windows: `pwsh tools/setup.ps1`
- macOS / Linux: `bash tools/setup.sh`

Add `-CliOnly` (PowerShell) or `--cli-only` (bash) to skip the desktop build when
you only need the routing CLI. For end users who just want the prebuilt CLI, the
one-line installers in the README download a release binary instead. Build
details and prerequisites: [docs/BUILDING.md](docs/BUILDING.md).

## How to call it

Pick whichever transport you already speak. All return the same data.

- **MCP (preferred for agents).** Point an MCP client at `dart run
  bin/mcp_server.dart` (or a compiled `quotabot-mcp`) for stdio. For clients
  that need MCP Streamable HTTP, run `dart run bin/mcp_server.dart --http`
  (loopback only, optional bearer token flags). Tools:
  - `list_quotas` - full normalized snapshot for every provider.
  - `suggest_provider` - the provider to use next, with ranked alternatives and a
    local fallback when subscriptions are low. Pass `local_first: true` to
    prefer a local runtime before spending subscription quota when one is
    available.
  - `decide_now` - the same routing decision from the cheapest cached snapshot,
    with explicit `as_of`, age, and staleness so per-request routers do not force
    live collection. It accepts the same `local_first` routing policy.
  - `reserve_provider` - create a short local quota lease for a cloud provider
    before dispatching parallel work, reducing later effective headroom.
  - `release_provider` - idempotently release a local routing lease when the
    caller finishes or abandons the dispatch.
  - `provider_with_most_headroom` - the account with the most remaining budget.
  - `check_provider_availability` - whether a named provider is usable now and
    when it resets.
  - `list_models` - every model you can route to now across providers and local
    runtimes, each with its gating provider's live budget, capability hints, and
    tier. Accepts an optional capability filter (`task`, `min_context`,
    `require_tools`/`require_vision`/`require_reasoning`, `tier_floor`/
    `tier_ceiling`) plus `budget` (`local`, `quota`, or `any`) so you can ask
    for "a reasoning model with budget" without quotabot ever seeing the task.
    `budget: "quota"` means measured built-in quota plans plus local runtimes;
    it excludes self-reported manual quota and does not permit paid API spend.
    Local-runtime model entries include `local_readiness` (`loaded` or `cold`);
    prefer loaded local models when equivalent candidates are available.
  - `suggest_model` - one concrete model for a task profile (same filter as
    `list_models`): the cheapest model that meets it and has budget,
    local-first. Pass `use_expiring_quota: true` to let a measured quota-backed
    model beat local only when local analytics project meaningful included quota
    would otherwise expire unused soon.
  - Resource `quotas://current` - the same unfiltered live snapshot.
  - Resource `quotas://alerts` - the last MCP quota alerts fired by the
    subscription loop.
  - Snapshot-backed read, routing, reservation, and model tools accept optional
    `profile`, exact `account`, and one-request `exclude` filters to route
    inside a local named profile or one provider account while avoiding specified
    providers; resources stay unfiltered. `check_provider_availability` targets
    one named provider and accepts `profile` plus `account`.
  - MCP clients can subscribe to `quotas://alerts` or `quotas://current` with
    standard `resources/subscribe`; alert crossings emit
    `notifications/resources/updated` for `quotas://alerts`.
- **CLI.** `quotabot suggest --json` for the routing decision, `quotabot --json`
  for the full snapshot, `quotabot models --json` for per-model budget, and
  `quotabot stats --json` for analytics. Add `--local-first` to `suggest` when
  you prefer local capacity before spending subscription quota, and
  `--budget=local` or `--budget=quota` to `models`/profiled `suggest` calls
  when the model choice must stay inside a no-surprise spend envelope. Add
  `--exclude=A,B` to quota-reading commands after `--profile` when one request
  should avoid specific providers. Add `--use-expiring-quota` to a profiled
  `suggest` call only when you want soon-resetting included quota to outrank
  local capacity.
- **Push alerts.** `quotabot watch --json` streams a `quotabot.alert.v1` line
  the moment a provider's binding window goes red, naming where to route next, so
  a long-running agent can react to a crossing instead of polling. Add
  `--waste-threshold=N` to also alert when at least N percent of paid quota is
  projected to expire unused at reset. Add `--webhook URL` to have each alert
  POSTed for you (loopback unless `--allow-external`).
- **HTTP (loopback).** `GET http://127.0.0.1:8721/suggest` and `GET /` (start it
  with `dart run bin/local_server.dart`). Add `?exclude=codex,grok` to ignore
  providers for one recommendation, or `?local_first=true` to prefer local
  capacity.

## The routing contract

1. Prefer the metered subscription with the most remaining headroom, as long as
   it is above a comfort threshold.
2. If every subscription is low, fall back to a local runtime (a free model is a
   safety net, not the default winner).
3. **Binding-window rule:** a spent longer window overrides a healthy shorter
   one. If the weekly cap is gone, ignore a green 5-hour bar; that provider is
   not usable.
4. **Fail soft.** If quotabot is unreachable or returns nothing, proceed with the
   model the user originally asked for. Routing is an optimization, never a hard
   dependency.

## Decision recipe

```
snapshot = call list_quotas        # or GET /, or quotabot --json
best     = call suggest_provider   # or quotabot suggest --json
if best.provider and best.headroom_percent > comfort_threshold:
    route to best.provider
elif a local runtime is available:
    route to the local runtime
else:
    wait for the soonest reset (check_provider_availability) or use the default
```

## Output schema

Snapshot, routing, and availability JSON outputs carry a versioned `schema` id
and a timestamp (`stats --json` is the one exception: a provider-keyed insight
map with no envelope); treat unknown fields as additive. Headroom is a
remaining-percent value (0..100); higher means more budget left. The shapes:

- The snapshot is `quotabot.v1` (`generated_at`, `providers`, each provider's
  `windows` and, when known, `models`).
- `suggest` is `quotabot.suggest.v1`: `recommended`, `ranked`, `reason`, a
  guaranteed `fallback`, `routing_policy`, and `as_of`/`risk_z` provenance. Each
  candidate carries
  `headroom_percent`, `effective_headroom_percent` (headroom after discounting
  recent burn and active local leases), optional `lease_discount_percent`, and,
  when estimable, `burn_se_percent_per_hour`, `strand_probability` (0..1), and
  `confidence` (0..1). Rank on `effective_headroom_percent`; treat low
  `confidence` or high `strand_probability` with appropriate caution.
- `decide_now` is `quotabot.decision.v1`: a cache-only routing decision with
  `source`, `snapshot_as_of`, `snapshot_age_seconds`, `snapshot_stale`,
  `routing_policy`, ranked
  candidates, fallback, and active local leases. It never forces a live collect.
- `reserve_provider` is `quotabot.reserve.v1`: a local metadata write returning
  `reserved`, `lease`, and the chosen candidate when a cloud provider can be
  reserved. It does not call a model or contact the provider.
- `release_provider` is `quotabot.release.v1`: an idempotent local release result
  for a lease id.
- `list_models` is `quotabot.models.v1`: every routable model with its gating
  provider's budget and capability hints.
- `quotabot watch` emits `quotabot.alert.v1`: `kind` (`low_quota` or
  `projected_waste`), `provider`, `window`, `severity` (`amber`/`red`),
  `free_percent`, `as_of`, and, when a better route exists, `route_to` with
  `route_free_percent`/`route_is_local`. Projected-waste alerts add
  `projected_waste_percent` and `burn_percent_per_hour`. Metadata only.
- `quotas://alerts` is `quotabot.alerts.v1`: `generated_at`, `last_alert_at`,
  and the last fired `quotabot.alert.v1` objects. Subscribe to it to react to
  amber/red crossings without polling.

## What quotabot does not do

- It makes no model/inference calls and spends no usage tokens.
- It reads only quota/usage metadata, never prompts, code, or other content.
- It has no quotabot account, cloud, or telemetry. Provider metadata calls, when
  needed, send only provider credentials and quota-discovery requests, never
  prompts, code, or other user content.
- Runtime code is guarded against direct paid model, chat, image, and
  content-generation endpoints; model-list catalog audits are maintenance-only.

A turnkey example of routing a fleet through quotabot is the LiteLLM proxy plugin
in [integrations/litellm/](integrations/litellm/). Minimal clients are in
`collector/bin/example_routing_agent.dart` for Dart and
[integrations/mcp_clients/](integrations/mcp_clients/) for Python and
TypeScript MCP transports.

The LiteLLM plugin is no-surprise-billing by default: candidates marked
`spend: paid_api` are skipped unless `allow_paid_api: true` is set, while
`spend: quota_plan` should be used only for real included quota plans with
overages disabled and now requires `overages_disabled: true` or
`overages: disabled` in the routing policy. Managed logical models fail closed
when no safe route exists. Its local routed-request metrics include the selected
spend class so the desktop analytics view can flag local, quota-plan, and
paid-API traffic separately.
The model-router `budget: "quota"` filter follows the same goal: verified quota
plans and local runtimes only, never request-metered paid API passthrough.
