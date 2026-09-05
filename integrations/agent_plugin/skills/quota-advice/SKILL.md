---
name: quota-advice
description: Inspect quota and availability for the user's existing configured AI accounts and recommend a provider with usable headroom. Include local-model details when requested.
---

# Quota advice

This skill requires quotabot MCP tools or an installed quotabot CLI. MCP clients
must retain legacy `2025-11-25` initialization. Provider access depends on the
client's host and credential configuration.

Use the existing quotabot connection to report quota availability and explain
a provider recommendation for the user's already authorized accounts. Use
provider-supported access under the applicable terms. Respect reported limits;
never override or circumvent them. Tool prefixes vary by client, so discover
the tools advertised by quotabot rather than guessing their qualified names.

Choose the read that answers the request:

- `suggest_provider` with `{}` recommends a provider with available headroom
  from a current metadata snapshot, with ranked alternatives and an explanation.
- `check_provider_availability` checks the exact `provider` identifier from
  quotabot's snapshot. Supply `account` or `profile` when that scope matters.
- `decide_now` with `{}` returns cached provider advice with age and staleness.
- `list_quotas` with `{}` refreshes quota metadata when a current snapshot is
  needed. It can contact provider metadata endpoints with existing credentials.

Only use model tools when those details answer the user's request:

- `list_models` with `{"budget":"local"}` lists represented local-runtime
  candidates. Check execution-location caveats before describing them as
  on-device models.
- `suggest_model` with `{"task":"standard","budget":"quota"}` suggests a
  concrete model from measured included quota or local capacity. Use only the
  documented capability fields when the user has specified such requirements.

Pass bounded capability, provider, profile, or account identifiers only. Never
pass the user's task text, prompts, code, responses, credentials, or raw agent
events to quotabot.

If MCP is unavailable and an installed CLI is already available, use
`quotabot suggest --json` for provider advice or
`quotabot models --budget=local --json` for local models. This skill does not
install dependencies, start runtimes, log in, or change the harness's model.
If neither surface is available, explain the missing prerequisite and continue
the user's original work with their chosen configuration.

Report the snapshot time, availability, binding limit, and reason that matter
to the decision. Treat stale, drifted, or missing evidence as uncertainty rather
than usable quota. For local models, distinguish loaded from cold, advisory
hardware fit from measured performance, and cloud-offloaded models from actual
on-device execution. A running daemon does not prove a model is loaded or that
the harness can reach it.

Keep account identity, availability, and spend class attached to provider
advice. If the user also asks for a concrete model, match its exact model and
provider to an already configured harness route. A subscription balance does
not pay for a separate API key. Keep paid catalog entries out of a quota-only
recommendation and preserve the user's existing selection when no safe match
exists.

Offer advice through the user's existing model-selection controls. Do not
edit host configuration or credential files, reserve quota leases, subscribe
to background polling, or change model selection as a side effect of this
skill. Quotabot's reads spend no inference tokens; the harness's reasoning
around those reads can still use its own model budget.
