# Using quotabot

The widget, the CLI, and the machine interfaces in one place. For first-time
setup see [SETUP.md](SETUP.md); for agent integration see [../AGENTS.md](../AGENTS.md).

## The desktop widget

- **Header buttons** (left to right): refresh now, open Quota Analytics
  (bar-chart icon), collapse, the providers/settings menu, setup and help, and
  close. Hover for a tooltip on each.
- **Move it:** drag the header bar or the cards area (the control buttons on the
  right are excluded). The body scrolls and the window hugs its content.
- **Collapse:** shrink to a compact strip of provider logos with one status dot
  each; expand to restore the full view.
- **Menu:** hide or show individual providers, set the refresh cadence (smart,
  every 15 minutes, or every hour), choose the icon sort (default, alphabetical,
  most available, most used), choose or manage a named profile, and toggle
  always-on-top, taskbar visibility, notifications, and "Show account names".
  Account names auto-hide for single-account providers and show only when a
  provider has more than one account on screen.
- **Smart schedule:** refreshes more often as a reset nears or a cap fills, and
  relaxes to as little as twice a day when everything is healthy.
- **Reset countdowns** appear next to usage (e.g. "80%  3d12h").
- **Forecast at a glance:** when a provider is visibly burning, the card adds a
  plain-language line on the binding window ("about an hour of usage left", or
  "likely to run out before it resets" once that risk is material), the same
  forecast `quotabot top` shows. It appears only with a real burn signal.
- **Insights panel:** tap a card to expand a headroom sparkline, the p10/p50/p90
  distribution, how often it is usable, any trend, and the tightest hour of day.
- Your hidden providers, compact/expanded state, cadence, always-on-top, taskbar,
  notifications, account-names, active profile, and window position persist
  across restarts. Non-default profiles keep their own hidden-provider, sort,
  and theme preferences.

The header shows a radial "pool gauge" next to the "Quota" wordmark: it fills to
the average remaining headroom across visible providers, colored green (>=50%
free), amber (>=25%), orange (>0), or red (spent).

## Quota Analytics

Open it from the bar-chart button in the header. It takes over the window (a
Back button returns you to the strip) and scrolls like a phone, switchable by
time range:

- **Now:** pool-free and most-headroom chips, ranked headroom per provider with
  reset countdowns, a consumption-share donut, and LiteLLM routed-request totals
  when the proxy writes `~/.quotabot/litellm-metrics.jsonl`. Providers with no
  live data are listed so they do not silently disappear.
- **7d / 90d:** the free-% distribution (p10-p90 with a median tick), reliability
  and per-day trend, and a best-time-to-run weekday-by-hour heatmap.

(There is also one small easter egg in the header, derived from the fleet's own
numbers. Hover it.)

The same numbers are on the command line:

```bash
quotabot stats          # human-readable analytics per provider
quotabot stats --json   # the same numbers for scripts
quotabot report         # weekly quota-health markdown for sharing
```

quotabot keeps two tiers of local history, both zero-token: a short raw buffer of
recent checks (the "usually ~X% free" line and sparkline) and compact hourly
buckets retained 90 days (the analytics). No raw points are kept long term, and
only quota metadata is ever stored, never prompts or code.

## CLI reference

Run `quotabot help` for the live list. Every command is a local metadata read and
costs no usage tokens; add `--json` to any read command for machine output.

| Command                | What it does                                          |
|------------------------|-------------------------------------------------------|
| `status` (or `doctor`) | Every provider, its windows, and resets (the default).|
| `top`                  | Live dashboard that redraws in place (q quit, r now, s sort). |
| `models`               | Every model you can route to now, with budget + caps. |
| `calibration`          | How often quotabot's predictions come true (history). |
| `manual`               | List, set, or remove self-reported quota entries.     |
| `check <provider>`     | Whether one provider is usable now, and its reset.    |
| `suggest`              | Which subscription to use next, ranked.               |
| `stats [provider]`     | 90-day analytics: distribution, reliability, pace.    |
| `report`               | Weekly quota-health markdown export, or JSON with `--json`. |
| `json`                 | Full snapshot as `quotabot.v1` JSON.                  |
| `login <provider>`     | Connect grok or antigravity so it stays live.         |
| `logout <provider>`    | Disconnect a provider.                                |
| `help`, `version`      | Usage and version.                                    |

Color follows the terminal (honors `NO_COLOR`, `CLICOLOR`, `--color/--no-color`).
The frozen `quotabot.v1` contract is documented in [SCHEMA.md](SCHEMA.md).

### Deterministic simulation

For tests and reproducible integration checks, every quota-reading CLI command
can use one synthetic provider snapshot instead of real adapters:

```bash
quotabot --json --mock-provider claude --state exhausted
quotabot check claude --json --mock-provider=claude --state=blocked
quotabot suggest --json --mock-provider claude --state healthy
```

Supported states are `healthy`, `low`, `exhausted`, `blocked`, `signed-out`, and
`stale`. `blocked` is specifically for the binding-window rule: the short window
looks healthy, but the longer window is spent, so the provider is unavailable.
Simulation mode is separate from `QUOTABOT_DEMO=1`: it returns one exact provider
state for assertions, skips live adapter calls, ignores real burn history, and
does not read analytics buckets.

### Manual quota entries

For a tool quotabot does not read yet, add a local self-reported window:

```bash
quotabot manual set z-ai --display-name "Z.ai" --used 12 --limit 50 --reset 2027-01-01T00:00:00Z --window monthly
quotabot manual list
quotabot manual remove z-ai
```

`manual set` is an upsert, so rerun it with a new `--used` value whenever you
want to refresh the entry. These entries are stored only on your machine under
quotabot's config directory, appear in `status`, `json`, `top`, the widget, and
`suggest`, and carry `source: "manual"` in JSON. They are intentionally marked as
self-reported: quotabot does not record them into measured analytics history, and
routing confidence is lower than for live provider telemetry.

### Live view (`quotabot top`)

`quotabot top` is the htop view of your plans: one bar per rolling window for
every provider, each colored on the headroom scale (green healthy, amber
tightening, orange low, red spent) with a live reset countdown, your local
runtimes as always-on fallbacks (with their VRAM, context, installed models, and
disk detail), and a route line that names where to send the next request. When
recent history shows a window being drawn down, the binding window also carries a
forward-looking note:
a strand probability (the chance it is spent before it resets) when that is
material, otherwise a time-to-empty estimate. It redraws in place on the alternate
screen and repaints countdowns every second.

```bash
quotabot top                # adaptive refresh (the default)
quotabot top --interval=2   # pin a fixed rate instead (minimum 2s)
quotabot top --truecolor    # force 24-bit gradient meters
quotabot top --sort=headroom  # order providers by a routing metric
```

By default the collection cadence adapts to the same logic the desktop app uses:
it polls fast (down to 30s) when a window is near its cap or a reset is imminent,
and relaxes to hours when the whole fleet is healthy and resets are far off, so
it is responsive when it matters without hammering provider APIs. The footer
shows when the data was last collected. `--interval` pins a fixed rate.

Press `q` (or Ctrl-C) to quit, `r` to refresh immediately, and `s` to cycle the
ordering: `default` (collection order), `headroom` (most free first), `burn`
(fastest-burning first), `strand` (most likely to run out before reset), and
`reset` (soonest reset first). The active mode shows in the footer; `--sort=NAME`
(or `QUOTABOT_SORT`) sets the starting order.

Navigate and act with the keyboard: `j`/`k` (or the up/down arrows) move the
cursor, `x` (or `h`) hides the selected provider for the session and `u` brings
them all back, and `c` copies the recommended route (the provider to send the
next request to) to your clipboard via the terminal, so you can paste it straight
into a tool. The footer shows the hidden count and a brief "copied" confirmation.

A spent longer window collapses its
provider to one line, the same binding-window rule the widget uses. Piped or on a dumb terminal it prints a single plain frame and
exits, so `quotabot top | cat` still gives you a snapshot. On a truecolor
terminal the bars use a smooth gradient; it degrades to 256/16/no color.
Windows Terminal and common truecolor terminals are detected automatically;
`--truecolor` forces it where detection cannot.

Pick a palette with `--theme=<name>` (or `QUOTABOT_THEME`): `default`, `green`
(phosphor CRT), `dark`, `light`, or `synthwave`. Roll your own in one line with
`--theme=custom:HEALTHY-TIGHT-LOW-SPENT[-ACCENT]`, each a 6-digit hex color from
most free to least, e.g. `--theme=custom:39ff14-00cc5a-009946-005a32`. Palettes
apply on truecolor terminals; elsewhere the standard headroom colors are used.

## Named profiles

CLI quota-reading commands accept `--profile=NAME` to view and route within an
existing local profile. The profile filters the already-normalized snapshot by
provider, account, hidden providers, and routing policy before status, JSON,
`suggest`, `models`, `check`, `stats`, `watch`, or `top` render anything. The
implicit `default` profile keeps the zero-config fleet unchanged.

The desktop widget can create, edit, delete, and select the same profiles from
its menu. A profile can choose providers, specific accounts where quotabot has
account evidence, routing policy, and theme (`System`, `Light`, `Dark`, or the
high-contrast `Hacker` theme). Profile selection changes the
displayed providers, low-quota notifications, webhook alerts, and analytics
view. Hiding providers and choosing sort order are scoped to the active
non-default profile; the default profile keeps the app's legacy global
preferences.

## Proactive alerts (quotabot watch)

`quotabot watch` polls quota on the same adaptive cadence as `top` and raises a
low-quota alert the first time a provider's binding window crosses into red
(spent or nearly so), naming where to route next. It is edge-triggered: it fires
once per crossing and re-arms only after the window recovers, so a steady spent
window never spams. Alerts carry quota metadata only, never prompts or content.
Add `--waste-threshold=N` to also alert when the recent burn pace projects that
at least N percent of a paid window will expire unused at reset.
When a provider exposes account identity, both low-quota and projected-waste
alerts are keyed and serialized by that provider/account pair, including
same-provider sibling routes.

```bash
quotabot watch                                   # print alerts, adaptive cadence
quotabot watch --once                            # a single pass (cron-friendly)
quotabot watch --json                            # one quotabot.alert.v1 per line
quotabot watch --interval=120                    # pin the poll rate (seconds)
quotabot watch --waste-threshold=35              # use paid quota before it expires
quotabot watch --webhook http://127.0.0.1:9000/quota   # POST each alert
```

The `--webhook` URL must be loopback unless you add `--allow-external`, so an
alert can never reach an external service (Slack, Discord, a remote box) by
accident; a stray or stale URL is refused rather than silently sent. The desktop
widget raises the same low-quota alerts (as a notification) and can POST to the
same kind of webhook, set from its menu under "Alert webhook"; loopback is the
default there too, with an explicit "allow external host" checkbox.

## Exit codes

The CLI uses stable exit codes so a shell or agent can branch without parsing
output:

- `0` success: the command ran, and (for `check` and a piped `top`) at least one
  provider is usable right now.
- `64` usage error: a bad argument or an unknown provider name.
- `69` unavailable: the named provider (`check`), or the whole fleet (piped
  `top`), has no usable quota at the moment.

For example, `quotabot check claude || quotabot suggest --json` falls through to a
route only when Claude is spent.

### Models, calibration, and risk

`quotabot models` lists every model you can route to now across providers and
local runtimes, each with the live budget that gates it (headroom, window, reset),
capability hints (context window, tools, vision, reasoning), and the provider's own
tier (light/standard/flagship), most routable first. Local-runtime models are read
live; cloud capability hints come from a refreshable catalog. Local-runtime
entries carry `local_readiness` in JSON (`loaded` or `cold`), and concrete model
suggestions prefer loaded local models before installed-but-cold local models
when both meet the requested profile.

Filter to what a task needs with a coarse `--task=simple|standard|hard` profile or
explicit flags: `--min-context=200k`, `--require-tools`, `--require-vision`,
`--require-reasoning`, `--tier-floor=standard`, `--tier-ceiling=standard`. quotabot
never sees the task; you supply the requirements, and it returns the models that
meet them with budget. The same filters are arguments on the MCP `list_models`
tool. Tiers are the providers' own product tiers, not a quotabot quality ranking.
Add `--budget=local` for a hard cap to free local-runtime models, or
`--budget=quota` to allow local runtimes plus measured built-in quota plans while
excluding self-reported manual quotas. `quota` is not permission to use
request-metered paid APIs; those remain blocked by the LiteLLM guardrails unless
explicitly enabled in that integration.
For a task-profiled `suggest`, add `--use-expiring-quota` when you explicitly
want soon-resetting included quota to beat a local model. The signal is bounded:
it uses only local burn analytics, only measured quota-backed providers, and only
when at least 35 percent of included quota is projected to expire unused within
24 hours. When a provider exposes account identity, burn history is scoped to
that provider/account pair; legacy provider-only history is used only for an
unambiguous single-account snapshot. MCP `suggest_model` exposes the same policy
as `use_expiring_quota: true`.

For one-off provider avoidance, add `--exclude=codex,grok` to quota-reading CLI
commands (`status`, `doctor`, `json`, `check`, `top`, `watch`, `stats`,
`report`, `calibration`, `models`, or `suggest`). The filter applies after
`--profile`, so you can temporarily ignore a provider without changing named
profiles. MCP routing and model tools accept the same idea as
`exclude: ["codex", "grok"]`, and the loopback HTTP server supports
`GET /suggest?exclude=codex,grok`.
For cost-sensitive dispatch, `quotabot suggest --local-first` keeps the normal
provider ranking visible but recommends a local runtime before subscription quota
when one is available. MCP `suggest_provider` and `decide_now` accept
`local_first: true`; the loopback HTTP equivalent is
`GET /suggest?local_first=true`.

For catalog maintenance, run the audit tool from the collector package:

```bash
cd collector
dart run bin/catalog_audit.dart --json
```

It calls provider-owned model-list endpoints only when the matching API key is in
the environment (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `XAI_API_KEY`, or
`GEMINI_API_KEY` / `GOOGLE_API_KEY`) and otherwise marks that provider skipped.
The output is a diff of model ids only; capability fields stay curated. Add
`--fail-on-drift` or `--fail-on-error` when using it as a maintenance CI gate.

`quotabot calibration` grades quotabot's own strand predictions against your
recorded history and reports how often they come true, as a calibration
percentage, a Brier score, and a reliability diagram. It fills in over time, once
predictions' horizons have elapsed, and says plainly when there is not enough yet.

`quotabot report` prints a shareable weekly quota-health markdown report with the
current recommendation, provider headroom, reset times, seven-day history
metrics, and current sampled-day usable/spent streaks where enough local history
exists. Add `--json` for the structured `quotabot.report.v1` shape. It is still
local metadata only.

The desktop analytics screen also reads optional LiteLLM proxy metrics from
`~/.quotabot/litellm-metrics.jsonl`, the default path used by the shipped
LiteLLM router. It summarizes served requests, routed requests, tokens, tracked
cost, spend-class counts, top served models, and the last request age. The file
is local JSONL only; quotabot reads a bounded tail of it and never reads prompts
or response content.
The router treats request-metered API keys as `spend: paid_api` and skips them
unless `allow_paid_api: true` is set. Use `spend: quota_plan` only for included
quota plans with overages disabled, and set `overages_disabled: true` or
`overages: disabled` so the router can enforce that claim. Managed logical
models fail closed when no safe route exists.

`quotabot suggest --risk=Z` opts into risk-adjusted ranking (the default `Z=0` is
the plain mean): a higher `Z` prefers providers whose recent burn is more certain.
The suggestion JSON carries, per candidate, `effective_headroom_percent`,
`confidence`, and `strand_probability`, plus a top-level `routing_policy`
(`balanced` or `local_first`).

Pass a task profile to `suggest` and it recommends a concrete model instead of a
provider: `quotabot suggest --task=hard` (or any of the `--require-*`/`--tier-*`/
`--min-context`/`--budget` filters) returns the cheapest model that meets the need
and has budget, local-first. With `--use-expiring-quota`, a qualifying measured
quota-backed model may outrank local when the reset is soon and the included
quota would otherwise expire unused. The MCP `suggest_model` tool does the same
for agents.

## Routing over MCP

The collector runs as an MCP server so agents can query quota as a primitive. It
speaks MCP over stdio by default, can opt into MCP Streamable HTTP on loopback,
and exposes nine tools plus two resources:

- `list_quotas` - the full normalized snapshot for every provider.
- `provider_with_most_headroom` - the account with the most remaining budget.
- `suggest_provider` - the provider to route the next request to, with ranked
  alternatives and a local fallback when subscriptions are low. Pass
  `local_first: true` to prefer a local runtime before subscription quota.
- `decide_now` - the same routing decision from the cheapest cached snapshot,
  with explicit snapshot source, age, and staleness. It never forces a live
  collect, and accepts the same `local_first` policy.
- `reserve_provider` - create a short local quota lease for a cloud provider
  before dispatching parallel work, reducing later effective headroom.
- `release_provider` - idempotently release a local routing lease when the
  caller finishes or abandons the dispatch.
- `check_provider_availability` - whether a named provider is usable now.
- `list_models` - every model you can route to now (cloud + local), each with its
  gating provider's live budget and capability hints.
- `suggest_model` - one concrete model that meets the supplied capability filter
  and has budget. Add `use_expiring_quota: true` to let soon-resetting included
  quota outrank local capacity when projected waste is high.
- Resource `quotas://current` - the same unfiltered live snapshot.
- Resource `quotas://alerts` - the last MCP quota alerts fired by the
  subscription loop.

Snapshot-backed read, routing, reservation, and model tools accept an optional
`profile` argument to filter the snapshot through a local named profile before
routing or model selection, an optional exact `account` argument to route inside
one account after profile filtering, and an `exclude` provider-id list for
one-request routing decisions after profile and account filtering.
`check_provider_availability` answers for one named provider and accepts
`profile` plus `account`, not `exclude`. Missing profiles or malformed
exclusions fail soft: the tool returns a structured `error` field with an empty
provider list instead of throwing. Resources remain unfiltered snapshots for
clients that only consume MCP resources.

`suggest_provider` and `decide_now` include active local leases in the response
and expose each candidate's `lease_discount_percent` when a concurrent caller has
reserved the same provider/account. `reserve_provider` and `release_provider`
write only local metadata under quotabot's application-data directory. They do
not contact a model provider, read prompts, or enter the request data path.
Both routing responses include `routing_policy`, so clients can verify whether a
decision used the default `balanced` mode or the opt-in `local_first` mode.

MCP clients can subscribe to `quotas://alerts` with standard
`resources/subscribe`. The server runs the same edge-triggered alert scan as
`quotabot watch`; when a provider crosses amber or red, it sends
`notifications/resources/updated` for `quotas://alerts`, and the client can read
that resource to get `quotabot.alerts.v1` with the fired `quotabot.alert.v1`
metadata. Subscribing to `quotas://current` sends resource-updated notifications
after live subscription-loop reads.

Run stdio with `dart run bin/mcp_server.dart`, or compile a binary:

```bash
cd collector
dart compile exe bin/mcp_server.dart -o build/quotabot-mcp.exe
```

Run MCP Streamable HTTP only when a client cannot use stdio:

```bash
cd collector
dart run bin/mcp_server.dart --http --port 8722 --path /mcp
```

The HTTP transport binds only to `localhost`, `127.0.0.1`, or `::1`, enables
DNS-rebinding host/origin checks, rejects batch JSON-RPC payloads, and uses the
same tool/resource factory as stdio. Add `--token-file PATH`, `--token-env NAME`,
or `--token TOKEN` to require `Authorization: Bearer ...`; prefer a local
owner-only token file for normal use. The endpoint is MCP Streamable HTTP, not
the plain JSON endpoint below.

See [../AGENTS.md](../AGENTS.md) for the routing contract and a decision recipe,
`collector/bin/example_routing_agent.dart` for a Dart routing example, and
[../integrations/mcp_clients/](../integrations/mcp_clients/) for Python and
TypeScript MCP client snippets covering stdio and Streamable HTTP.

## Local HTTP endpoint

An optional loopback server for non-MCP consumers:

```bash
cd collector
dart run bin/local_server.dart [port]   # defaults to 8721
```

`GET /` returns the full snapshot as JSON; `GET /suggest` returns the routing
recommendation, `GET /suggest?exclude=codex,grok` ignores those providers for
that recommendation, and `GET /suggest?local_first=true` prefers local capacity.
Local only, zero tokens.

## Demo mode

Launch the widget with `QUOTABOT_DEMO=1` to populate it with synthetic,
account-free data covering every supported service. Nothing real is read and no
provider is contacted; it is meant for previews and screenshots.
