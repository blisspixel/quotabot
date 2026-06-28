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
  most available, most used), and toggle always-on-top, taskbar visibility,
  notifications, and "Show account names". Account names auto-hide for
  single-account providers and show only when a provider has more than one
  account on screen.
- **Smart schedule:** refreshes more often as a reset nears or a cap fills, and
  relaxes to as little as twice a day when everything is healthy.
- **Reset countdowns** appear next to usage (e.g. "80%  3d12h").
- **Insights panel:** tap a card to expand a headroom sparkline, the p10/p50/p90
  distribution, how often it is usable, any trend, and the tightest hour of day.
- Your hidden providers, compact/expanded state, cadence, always-on-top, taskbar,
  notifications, account-names, and window position persist across restarts.

The header shows a radial "pool gauge" next to the "Quota" wordmark: it fills to
the average remaining headroom across visible providers, colored green (>=50%
free), amber (>=25%), orange (>0), or red (spent).

## Quota Analytics

Open it from the bar-chart button in the header. It takes over the window (a
Back button returns you to the strip) and scrolls like a phone, switchable by
time range:

- **Now:** pool-free and most-headroom chips, ranked headroom per provider with
  reset countdowns, and a consumption-share donut. Providers with no live data
  are listed so they do not silently disappear.
- **7d / 90d:** the free-% distribution (p10-p90 with a median tick), reliability
  and per-day trend, and a best-time-to-run weekday-by-hour heatmap.

(There is also one small easter egg in the header, derived from the fleet's own
numbers. Hover it.)

The same numbers are on the command line:

```bash
quotabot stats          # human-readable analytics per provider
quotabot stats --json   # the same numbers for scripts
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
| `top`                  | Live dashboard that redraws in place (q quit, r now). |
| `models`               | Every model you can route to now, with budget + caps. |
| `calibration`          | How often quotabot's predictions come true (history). |
| `check <provider>`     | Whether one provider is usable now, and its reset.    |
| `suggest`              | Which subscription to use next, ranked.               |
| `stats [provider]`     | 90-day analytics: distribution, reliability, pace.    |
| `json`                 | Full snapshot as `quotabot.v1` JSON.                  |
| `login <provider>`     | Connect grok or antigravity so it stays live.         |
| `logout <provider>`    | Disconnect a provider.                                |
| `help`, `version`      | Usage and version.                                    |

Color follows the terminal (honors `NO_COLOR`, `CLICOLOR`, `--color/--no-color`).

### Live view (`quotabot top`)

`quotabot top` is the htop view of your plans: one bar per rolling window for
every provider, each colored on the headroom scale (green healthy, amber
tightening, orange low, red spent) with a live reset countdown, your local
runtimes as always-on fallbacks, and a route line that names where to send the
next request. It redraws in place on the alternate screen, repaints countdowns
every second, and re-collects on an interval.

```bash
quotabot top                # refresh every 10s (default)
quotabot top --interval=2   # faster refresh (minimum 2s)
```

Press `q` (or Ctrl-C) to quit and `r` to refresh immediately. A spent longer
window collapses its provider to one line, the same binding-window rule the
widget uses. Piped or on a dumb terminal it prints a single plain frame and
exits, so `quotabot top | cat` still gives you a snapshot. On a truecolor
terminal the bars use a smooth gradient; it degrades to 256/16/no color.

### Models, calibration, and risk

`quotabot models` lists every model you can route to now across providers and
local runtimes, each with the live budget that gates it (headroom, window, reset)
and capability hints (context window, tools, vision) where known, most routable
first. Local-runtime models are read live; cloud capability hints come from a
refreshable catalog.

`quotabot calibration` grades quotabot's own strand predictions against your
recorded history and reports how often they come true, as a calibration
percentage, a Brier score, and a reliability diagram. It fills in over time, once
predictions' horizons have elapsed, and says plainly when there is not enough yet.

`quotabot suggest --risk=Z` opts into risk-adjusted ranking (the default `Z=0` is
the plain mean): a higher `Z` prefers providers whose recent burn is more certain.
The suggestion JSON carries, per candidate, `effective_headroom_percent`,
`confidence`, and `strand_probability`.

## Routing over MCP

The collector runs as an MCP server so agents can query quota as a primitive. It
speaks MCP over stdio and exposes five tools plus a resource:

- `list_quotas` - the full normalized snapshot for every provider.
- `provider_with_most_headroom` - the account with the most remaining budget.
- `suggest_provider` - the provider to route the next request to, with ranked
  alternatives and a local fallback when subscriptions are low.
- `check_provider_availability` - whether a named provider is usable now.
- `list_models` - every model you can route to now (cloud + local), each with its
  gating provider's live budget and capability hints.
- Resource `quotas://current` - the same snapshot.

Run it with `dart run bin/mcp_server.dart`, or compile a binary:

```bash
cd collector
dart compile exe bin/mcp_server.dart -o build/quotabot-mcp.exe
```

See [../AGENTS.md](../AGENTS.md) for the routing contract and a decision recipe,
and `collector/bin/example_routing_agent.dart` for a runnable example.

## Local HTTP endpoint

An optional loopback server for non-MCP consumers:

```bash
cd collector
dart run bin/local_server.dart [port]   # defaults to 8721
```

`GET /` returns the full snapshot as JSON; `GET /suggest` returns the routing
recommendation. Local only, zero tokens.

## Demo mode

Launch the widget with `QUOTABOT_DEMO=1` to populate it with synthetic,
account-free data covering every supported service. Nothing real is read and no
provider is contacted; it is meant for previews and screenshots.
