# Documentation

Start with the shortest path for what you need.

## Project status

The current verified stable release is 0.9.9. The current release candidate is
0.10.0-rc.13. The next work in the focused 0.10.x stabilization train is owner
signing setup and one signed lifecycle rehearsal. Its
[cross-platform install smoke](https://github.com/blisspixel/quotabot/actions/runs/33312529854)
passed install, upgrade, source-setup, and desktop-run checks. The repository now
contains fail-closed Windows and macOS signing paths for CLI and desktop assets.
They capture one signing policy per release, pin the Apple build toolchain, and
bind signed native-verification digests through final publication audit. The
manual macOS rehearsal is implemented but has not succeeded because owner
provisioning is absent. Current published artifacts remain unsigned; owner
identity provisioning, successful protected rehearsals, mode activation, and
signed fresh-download evidence remain. The
[roadmap Next section](../ROADMAP.md#next) owns the exact behavior, guardrails,
completion criteria, rationale, and place ahead of the remaining native 1.0
evidence gates.

Completed candidate detail, including the live-confirmed Claude OAuth recovery,
belongs in [CHANGELOG.md](../CHANGELOG.md).

## Install and first success

- [SETUP.md](SETUP.md): install, run `doctor`, connect providers, and recover
  from common first-run states.
- [BUILDING.md](BUILDING.md): build the CLI and desktop application from source.
- [RELEASE-SIGNING.md](RELEASE-SIGNING.md): provision, activate, rehearse, and
  verify the protected native signing environments.
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
