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
