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
- Optional `plan`, `source`, `status`, `active`, `details`, `error`, and
  `models`.
- `kind` is `subscription` or `local`.
- `source` is an additive hint. When set to `manual`, the provider window is a
  local self-reported quota entry, not measured adapter telemetry.
- `windows` is always present. Local runtimes use an empty list because they have
  no spendable quota.

Window objects keep:

- `label`.
- Optional `used_percent` in the range `0..100`.
- Optional `used` and `limit` counts.
- Optional `resets_at` Unix epoch seconds.

The contract is additive. Unknown fields are allowed at the root, provider,
window, and model levels. Existing field meanings and types must not change
inside `quotabot.v1`; incompatible changes require a new schema id.

## Routing outputs

`quotabot suggest --json`, MCP `suggest_provider`, and local HTTP `/suggest`
emit `quotabot.suggest.v1` with:

- `schema`, `as_of`, and `risk_z`.
- `routing_policy`: `balanced` by default, or `local_first` when the caller
  explicitly requested local capacity before subscription quota.
- `recommended`: optional provider candidate.
- `reason`, `using_local_fallback`, `fallback`, and `ranked`.
- Per-candidate budget fields such as `headroom_percent`,
  `effective_headroom_percent`, optional `lease_discount_percent`,
  `burn_percent_per_hour`, `burn_se_percent_per_hour`, `strand_probability`,
  `confidence`, `resets_at`, `stale`, and `available`.

MCP `decide_now` emits `quotabot.decision.v1`, a cache-only decision with the
same routing fields plus `source`, `snapshot_as_of`, `snapshot_age_seconds`,
`snapshot_stale`, and `max_age_seconds`. It never forces a live provider collect.

## `quotabot.alert.v1`

`quotabot watch --json`, alert webhooks, and `quotas://alerts` emit alert objects
with:

- `schema`: always `quotabot.alert.v1`.
- `kind`: `low_quota` or `projected_waste`.
- `provider`, `window`, `severity`, `free_percent`, and `as_of`.
- For `low_quota`, optional `route_to`, `route_display_name`,
  `route_free_percent`, and `route_is_local`.
- For `projected_waste`, optional `projected_waste_percent` and
  `burn_percent_per_hour`.

Alert payloads are metadata only. They never contain prompts, generated text, or
source code. The contract is additive; consumers should ignore unknown fields.

## `quotabot.routed_requests.v1`

The desktop analytics screen uses this local summary shape for LiteLLM proxy
metrics read from `~/.quotabot/litellm-metrics.jsonl`:

- `schema`: always `quotabot.routed_requests.v1`.
- `total_requests`: served requests summarized from the bounded JSONL tail.
- `routed_requests`: requests whose requested model differed from the served
  model.
- `prompt_tokens`, `completion_tokens`, and `total_tokens`.
- `cost`: tracked LiteLLM response cost when present, otherwise zero.
- `first_at` and `last_at`: optional Unix epoch seconds from the summarized
  records.
- `top_served_models`: an array of `{model, count}` entries.

The source JSONL records are local metadata only: timestamp, requested model,
served model, token counts, and response cost. They never contain prompts,
responses, or source code.

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
