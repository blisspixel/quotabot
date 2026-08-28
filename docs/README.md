# Documentation

Start with the shortest path for what you need.

## Project status

The current verified stable release is 0.9.9. The current release candidate is
0.10.0-rc.12. The next work in the focused 0.10.x stabilization train is
field-discovered correctness, recovery and quality-of-life refinement, and
native validation. Signed release readiness follows once that inventory is
quiet, without weakening existing checksums or provenance. The
[roadmap Next section](../ROADMAP.md#next) owns the exact behavior, guardrails,
completion criteria, rationale, and place ahead of the remaining native 1.0
evidence gates.

Claude OAuth recovery is confirmed end to end in
[issue #77](https://github.com/blisspixel/quotabot/issues/77). Release
candidate 5 keeps HTTP 429 labeled as throttling instead of an expired login.
Release candidate 6 covers exact transport identity and retry keys,
profile/account isolation, transactional install and uninstall, explicit
quotabot-only logout, duplicate-option handling, supplemental manual evidence,
first-run deferral, and reset-reminder privacy and delivery lifecycle.
Release candidate 7 carries the field round after rc.6: Grok and NVIDIA
live-read diagnostics, Ollama cloud-offload honesty, compact first-run and
200px recovery, exact `check`/`login`/`logout` identities, MCP Streamable HTTP
401/413 admission, POSIX space-safe Flutter, LiteLLM fail-closed leases, and
stacked pull-request CI. Release candidates 8 through 12 add grouped desktop
settings, source-install recovery, durable OAuth storage, account-label privacy,
bounded HTTP sessions and request admission, exact LiteLLM account routing,
authenticated loopback server identity, proxy-independent MCP clients, and
native desktop connection-state consistency. Changelog detail is in
[CHANGELOG.md](../CHANGELOG.md).

## Install and first success

- [SETUP.md](SETUP.md): install, run `doctor`, connect providers, and recover
  from common first-run states.
- [BUILDING.md](BUILDING.md): build the CLI and desktop application from source.
- [RELEASE-SIGNING.md](RELEASE-SIGNING.md): provision and operate the protected
  native signing environment.
- [DESKTOP-DISTRIBUTION.md](DESKTOP-DISTRIBUTION.md): verify, run, update,
  roll back, and uninstall native desktop release bundles.

## Use the product

- [USAGE.md](USAGE.md): desktop, terminal, routing, alerts, reports, MCP, and
  HTTP reference.
- [PROVIDER_CLIS.md](PROVIDER_CLIS.md): cross-check quotabot against each
  provider's own usage surface.

## Understand and trust the result

- [PRINCIPLES.md](PRINCIPLES.md): what quotabot refuses to do - no account,
  subscription, telemetry, or inference - why each refusal exists, and the
  command that verifies it.
- [DATA_SOURCES.md](DATA_SOURCES.md): source, auth, scope, and limitations for
  every provider class.
- [SCHEMA.md](SCHEMA.md): stable JSON and MCP output contracts.
- [ROUTING-MATH.md](ROUTING-MATH.md): implemented routing factors, assumptions,
  and research directions.

## Build and extend

- [ARCHITECTURE.md](ARCHITECTURE.md): code boundaries and data flow.
- [PRODUCT-STRATEGY.md](PRODUCT-STRATEGY.md): product choices and current
  external evidence, including the reason behind the roadmap order.
- [../ROADMAP.md](../ROADMAP.md): the sole immediate priority, ordered work, and
  release gates.
- [../CONTRIBUTING.md](../CONTRIBUTING.md): contribution and validation rules.
- [../SECURITY.md](../SECURITY.md): trust boundaries and private vulnerability
  reporting.

For agent integration, also see [../AGENTS.md](../AGENTS.md),
[../integrations/mcp_clients/](../integrations/mcp_clients/), and
[../integrations/litellm/](../integrations/litellm/).
