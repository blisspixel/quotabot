# Schema contracts

quotabot's machine-readable quota snapshot is `quotabot.v1`. The frozen contract
lives in `collector/lib/schema_contracts.dart` as a JSON Schema 2020-12 document
plus a focused validator used by tests.

## `quotabot.v1`

The root object contains:

- `schema`: always `quotabot.v1`.
- `generated_at`: Unix epoch seconds.
- `profile`: optional local profile name when a filtered view produced the
  snapshot.
- `account_filter`: optional exact account label when a router narrowed a view.
- `error`: optional fail-soft error note.
- `providers`: an array of provider snapshots.

Provider snapshots keep these stable fields:

- `provider`, `display_name`, `account`, `kind`, `ok`, `as_of`, `stale`, and
  `windows`.
- Optional `plan`, `source`, `status`, `active`, `details`, `error`, `models`,
  `model_quotas`, `suspect`, `per_machine`, `pipe_health`, `http_status`, and
  `retry_after_seconds`.
- `kind` is `subscription` or `local`.
- `source` is an additive hint. When set to `manual`, the provider window is a
  local self-reported quota entry, not measured adapter telemetry.
- `suspect`, when present, is a non-fatal plausibility note from the drift
  canary: the fresh read was implausible versus the last cached one (a reset
  that moved earlier, or usage that fell with no reset). The reading is still
  shown; `suspect` only flags it for a human or agent to cross-check.
- `per_machine`, when true, means the read reflects only this machine's local
  usage (Cursor, Windsurf, Kiro, or the Codex session fallback) rather than the
  account across every device, so it can undercount when the account is used
  elsewhere. Authoritative server-side reads (Claude, Grok, Antigravity, Codex
  live) omit it.
- `pipe_health` is an optional native adapter diagnostic for metadata endpoint
  failures. It is one of `healthy`, `throttled`, `degraded`, or `no_data`;
  current native adapters set it only when a reliable HTTP response distinguishes
  throttling or provider-side degradation from generic no-data.
- `http_status` is an optional sanitized metadata-endpoint status code
  (`100..599`). `retry_after_seconds` is an optional non-negative delay parsed
  from `Retry-After`. These are metadata only and must not include response
  bodies, prompts, generated text, source code, or secrets.
- `windows` is always present. Local runtimes use an empty list because they
  have no spendable quota. Status-only cloud providers can also have an empty
  list when quotabot can verify availability but has no measured quota window;
  those providers may carry `status` and `details` instead of budget fields.

Window objects keep:

- `label`.
- Optional `used_percent` in the range `0..100`.
- Optional `used` and `limit` counts.
- Optional `resets_at` Unix epoch seconds.

`model_quotas` is present only for providers that meter each model family from
its own pool (Antigravity), and the `windows` summary stays the headline. Each
entry keeps:

- `model`, the provider's model name (pool-sharing effort/mode variants are
  rolled up to this base name).
- Optional `used_percent` in the range `0..100`.
- Optional `resets_at` Unix epoch seconds.
- Optional `category` (a provider speed label) and `note` (a provider badge).

The contract is additive. Unknown fields are allowed at the root, provider,
window, and model levels. Existing field meanings and types must not change
inside `quotabot.v1`; incompatible changes require a new schema id.

## Routing outputs

`quotabot suggest --json`, MCP `suggest_provider`, and local HTTP `/suggest`
emit `quotabot.suggest.v1` with:

- `schema`, `as_of`, `risk_z`, `waste_weight`,
  `waste_threshold_percent`, `waste_max_hours`, and `cost_weight`.
- `routing_policy`: `balanced` by default, or `local_first` when the caller
  explicitly requested local capacity before subscription quota.
- `recommended`: the picked provider candidate, or an explicit `null` when
  nothing is usable.
- `reason`, `using_local_fallback`, `fallback`, and `ranked`.
- Over MCP only, `active_leases`: the reservation discounts currently applied
  to ranked candidates. The CLI and loopback HTTP forms of the same schema id
  omit it (the lease ledger is local to the MCP server).
- Each candidate carries identity (`provider`, `account`, optional `plan`,
  `local`) and budget fields such as `headroom_percent`,
  `effective_headroom_percent`, optional `lease_discount_percent`,
  optional `pipe_discount_percent`, `burn_percent_per_hour`,
  `burn_se_percent_per_hour`, `strand_probability`, `confidence`,
  `runway_hours`, optional `projected_waste_percent`, optional `waste_boost`,
  optional `cost_penalty`, optional `cost_discount`,
  `routing_score`, `resets_at`, `stale`, and `available`.
  `runway_hours` is the risk-adjusted runway before confidence is applied;
  `projected_waste_percent` is included only when measured burn and a near reset
  show included quota would otherwise expire unused; `routing_score` is the
  additive runway score after confidence, any waste boost, and any explicit
  caller-supplied cost discount. `cost_penalty` is never inferred by quotabot;
  it appears only when a caller provided a cost policy. Local runtimes may omit
  these score fields because their placement is governed by the explicit fallback
  or local-first policy.
  `pipe_discount_percent` is a recent local LiteLLM pipe-health discount applied
  to `effective_headroom_percent` for ranking. It does not change
  `headroom_percent` or `available`; those remain quota availability evidence.

MCP `decide_now` emits `quotabot.decision.v1`, a cache-only decision with the
same routing fields (including `active_leases`) plus `source`,
`snapshot_as_of`, `snapshot_age_seconds`, `snapshot_stale`, and
`max_age_seconds`. It never forces a live provider collect.

## Single-provider answers

`quotabot check <provider> --json` and MCP `check_provider_availability` emit
`quotabot.check.v1`: `schema`, `as_of`, `provider`, then either `found: false`
(CLI, unknown name), an `error` note (MCP, unknown provider/account), or
`account`, `available`, `headroom_percent`, `resets_at`, and `stale`. This is
deliberately not a `quotabot.v1` snapshot: it answers for one provider and has
no `providers` array. `available` means usable from current evidence and above
the practical spent floor; stale cached cloud quota has `available: false` even
when `headroom_percent` still carries a last-known value. For metered providers,
1.5% or less remaining headroom is treated as unavailable so rounded near-zero
reads do not route work into an already exhausted cap.

MCP `provider_with_most_headroom` emits `quotabot.headroom.v1`: `schema`,
`as_of`, then `provider` (null with a `reason` when nothing is usable) plus
`account`, `headroom_percent`, `resets_at`, and `stale` for a pick.

Profile-aware MCP tools also echo `profile` and `account_filter` when the
caller supplied them, and set `error` for profile, filter, or argument
problems.

`quotabot models --json` and MCP `list_models` emit `quotabot.models.v1` with
`schema`, `generated_at`, `catalog_updated`, `budget_policy`, and `models`.
Each model entry includes provider/account, `local`, `available`, `stale`,
`quota_backed`, capability hints where known, and the gating quota budget when
the model is remote: `headroom_percent`, `resets_at`, and the binding
`gating_window` label. Stale remote entries keep last-known quota fields, and
remote entries at or below the spent floor keep their measured quota fields, but
both set `available: false`. Entries gated by a self-reported manual quota carry
`source: "manual"`. Status-only cloud providers with no measured quota windows
stay visible in `quotabot.v1` snapshots but do not contribute `models` entries.
Some provider models with temporary included-quota terms can include
`quota_included_until`; after that epoch, quotabot no longer marks the model
`quota_backed` for `--budget=quota` routing unless the provider exposes a normal
quota-backed path for it. Local-runtime entries also include
`local_readiness` (`loaded` or `cold`), `size_bytes`, loaded-model
`vram_bytes`, and `quant` when the runtime exposes them, so routers can
distinguish ready-now models from installed models that may need a cold start.
`budget_policy` is `any`, `quota`, or `local`.

`quotabot suggest --json` with a model profile and MCP `suggest_model` emit
`quotabot.suggest_model.v1` with `schema`, `generated_at`, `budget_policy`,
optional `recommended`, `reason`, and ranked model candidates. When the caller
opts into expiring-quota routing, the response adds `use_expiring_quota`,
`expiring_quota_threshold_percent`, `expiring_quota_max_hours`, and, when the
pick used that signal, `expiring_quota` with provider, account, projected waste
percent, reset epoch, and burn percent per hour. For providers with specific
account identity, the burn evidence behind the signal is account-scoped.

`quotabot stats --json` emits a provider-keyed object of local history insight
fields. Each provider insight includes distribution fields, sampled-day streaks,
`contribution_calendar`, `best_time_windows`, optional `schedule_hint`, and
optional pace. When the caller supplies explicit tier-plan candidates to
`quotabot stats`, each provider can also include optional `tier_fit` with
`max_breach_probability`, `sample_count`, nullable `recommended`, and `options`.
Each tier option contains `name`, `cap_percent_of_current`,
`breach_probability`, `sample_count`, `meets_risk_tolerance`, and optional
caller-supplied `monthly_price` plus `monthly_delta`. quotabot never infers plan
prices or caps for this object. Calendar entries use the same sampled-day shape
described below.

`quotabot report --json` emits `quotabot.report.v1` with `schema`,
`generated_at`, `recommended_provider`, `recommendation_reason`,
`fallback_kind`, and `providers`. Provider rows include state, headroom/reset metadata, weekly p50
free percent, weekly reliability, weekly sampled-day counts, current
usable/spent day streaks, `weekly_contribution_calendar`,
`weekly_best_time_windows`, optional `weekly_schedule_hint`, and pace when
history is available. Calendar entries are sampled local days with `day_start`,
`samples`, `mean_free_percent`, `spent_samples`, `state` (`usable`, `mixed`, or
`spent`), and `intensity` (0..4). Best-time entries are sampled local
weekday/hour cells with `day_of_week` (0 = Monday), `day_label`, `hour_local`,
`samples`, `mean_free_percent`, and a display `label`. When enough neighboring
weekday/hour cells exist, best-time entries also include additive smoothing
evidence: `smoothed_free_percent`, `support_samples`, and `support_cells`.
Schedule hints include `scheduled_at`, `wait_seconds`, `resets_at`, `label`,
`summary`, and the selected `window` object.

## `quotabot.calibration.v1`

`quotabot calibration --json` emits `schema`, `generated_at`, `overall`, and
`by_provider`. Each calibration report carries `samples`, `brier_score`,
`expected_calibration_error`, `calibration`, `span_days`, `horizon_hours`, and
`bins` (each bin: `mean_predicted`, `observed_frequency`, `count`). Computed
entirely from local history; empty history yields zero samples, never an
invented score.

## `quotabot.catalog_audit.v1`

The maintenance tool `dart run bin/catalog_audit.dart` (not the `quotabot`
binary) emits `schema`, `generated_at`, `catalog_updated`, and `providers`.
Each provider row carries `provider`, `endpoint`, `auth_env`, `ok`, `skipped`,
optional `error`, `catalog_models`, `endpoint_models`,
`missing_from_catalog`, and `catalog_only`. Its process exit codes (0/1 with
`--fail-on-drift`/`--fail-on-error`) are the tool's own, outside the
`quotabot` CLI's documented exit-code contract.

## `quotabot.verify.v1`

`quotabot verify --json` emits the record of one honesty-check run:

- `schema`: always `quotabot.verify.v1`.
- `generated_at`, `os`, and the run-level `passed` verdict.
- `providers`: one record per provider account, with `provider`,
  `display_name`, `account`, `state` (`live`, `cached`, `out_of_quota`,
  `no_data`, `error`, `local`, or `undetected`), optional `plan`, `source`,
  `as_of`, and `staleness_seconds`, `stale`, a window summary (label, used
  percent, effective used percent, reset time, and seconds to reset), a
  `passed` verdict, `checks`, and an optional `cross_check` naming the
  provider's own usage surface to confirm the numbers against.
- `checks` entries carry `id`, `status` (`pass`, `fail`, or `info`), and a
  plain-language `detail`. Provider check ids are `identity`,
  `read_or_reason`, `percent_bounds`, `as_of_sane`, `stale_honesty`, and
  `reset_sanity`; fleet check ids are `schema_contract`, `unique_accounts`,
  `manual_entries`, and `claimed_coverage`. An undetected claimed provider
  carries `claimed_coverage` as its single provider-level check as well.
- `fleet_checks`: run-level checks, including validation of the live snapshot
  against the frozen `quotabot.v1` contract above.

The record is quota metadata only and follows the same additive rule as every
other contract here. A truthful absence (a signed-out account or a local
runtime that is not running) passes; the failing states are lying numbers,
silent failures, and contract drift. The CLI exits 65 when any check fails.

## `quotabot.alert.v1`

`quotabot watch --json`, alert webhooks, and `quotas://alerts` emit alert objects
with:

- `schema`: always `quotabot.alert.v1`.
- `kind`: `low_quota` or `projected_waste`.
- `provider`, `account`, `window`, `severity`, `free_percent`, `as_of`, and
  `route_is_local`.
- For `low_quota`, optional `route_to`, `route_display_name`,
  `route_account`, and `route_free_percent`.
- For `projected_waste`, optional `projected_waste_percent` and
  `burn_percent_per_hour`.

Alerts are edge-triggered by provider/account identity when a provider exposes a
specific account label, so two accounts on the same provider can warn and
recover independently.

Alert payloads are metadata only. They never contain prompts, generated text, or
source code. The contract is additive; consumers should ignore unknown fields.

## `quotabot.routed_requests.v1`

The desktop analytics screen uses this local summary shape for LiteLLM proxy
request-attempt metrics read from `~/.quotabot/litellm-metrics.jsonl`:

- `schema`: always `quotabot.routed_requests.v1`.
- `total_requests`: request attempts summarized from the bounded JSONL tail.
- `routed_requests`: requests whose requested model differed from the served
  model.
- `successful_requests`, `failed_requests`, `throttled_requests`, and
  `degraded_requests`: counts grouped by LiteLLM callback result. HTTP 429
  failures are throttled; other failures are degraded.
- `pipe_health`: `no_data`, `healthy`, `throttled`, or `degraded`.
- `prompt_tokens`, `completion_tokens`, and `total_tokens`.
- `cost`: tracked LiteLLM response cost when present, otherwise zero.
- `local_requests`, `quota_plan_requests`, `paid_api_requests`, and
  `unknown_spend_requests`: counts grouped by the LiteLLM route's spend class.
- `paid_api_cost`: tracked cost for records marked `paid_api`.
- `average_latency_ms`: optional rounded mean over records that include callback
  timing.
- `max_retry_after_seconds`: optional largest Retry-After delay observed on
  failed records.
- `first_at` and `last_at`: optional Unix epoch seconds from the summarized
  records.
- `top_served_models`: an array of `{model, count}` entries counted from
  successful records only.
- `provider_pipe_health`: an array of recent provider/account pipe-health rows
  with `provider`, optional `account`, request counts, `pipe_health`,
  `routing_penalty_percent`, optional `max_retry_after_seconds`, and optional
  `last_problem_at` and `last_at`. The local router can apply this bounded
  metadata as `pipe_discount_percent` in routing outputs.

The source JSONL records are local metadata only: timestamp, requested model,
served model, gated provider/account when known, selected spend class,
success/failure event, HTTP status, Retry-After seconds, callback latency,
sanitized exception class, token counts, and response cost. They never contain
prompts, responses, exception messages, or source code.

## Provider fixture registry

Every built-in adapter has one compile-time row in
`collector/lib/provider_adapters.dart`. Each row names the provider id, display
name, adapter class, cache behavior, multi-account behavior, fixture parser kind,
and required sanitized fixture file under
`collector/test/fixtures/provider_shapes/`.

The registry tests enforce:

- Every built-in adapter appears exactly once.
- Every adapter owns exactly one committed provider-shape fixture.
- Every fixture file is claimed by the registry.
- The provider-shape parser test iterates the registry, so adding a provider
  without a parser fixture fails locally and in CI.
