# Documentation

Start with the shortest path for what you need.

## Project status

The current verified stable release is 0.11.2. It adds reset confirmation,
provider-specific usage retry coordination, explicit admission evidence, and
current Grok CLI billing support. Fresh quota remains independent of advisory
analytics. Inspectable local models, conservative hardware evidence, and
versioned harness and Agent Plugins setup use the same normalized quota through
`quotabot mcp`.

The preceding 0.11.1
[release run](https://github.com/blisspixel/quotabot/actions/runs/33977671639)
and unpinned GitHub Latest
[install smoke](https://github.com/blisspixel/quotabot/actions/runs/33980712404)
passed exact-tag installation, prior-stable upgrade, source setup, stable-channel
discovery and desktop-run checks on Windows, macOS and Linux. Matching CLI and
desktop payloads were installed on Windows and verified against fresh downloads.
Each new release repeats those gates. Current Windows and macOS artifacts remain
unsigned; protected signing and notarization need provisioned publisher
identities and fresh signed native evidence before 1.0.

Next work addresses independent OAuth and MCP shutdown lifetimes, shared desktop
controls and identity, stronger execution-scope evidence, and installed harness
validation. The [roadmap Next section](../ROADMAP.md#next) owns execution order,
guardrails and completion criteria. Signing does not block useful product work.
Completed changes belong in [CHANGELOG.md](../CHANGELOG.md).

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

- [Agent harness setup](../integrations/harnesses/README.md) prints reviewed
  OpenClaw, Hermes, and OpenCode 1 configuration without opening a host config
  or reading a credential. It includes pi and NemoClaw CLI recipes and explicit
  version and transport limits.

- [ARCHITECTURE.md](ARCHITECTURE.md): code boundaries and data flow.
- [PRODUCT-STRATEGY.md](PRODUCT-STRATEGY.md): product choices and current
  external evidence, including the reason behind the roadmap order.
- [../ROADMAP.md](../ROADMAP.md): the sole immediate priority, ordered work, and
  release gates.
- September 2026 research: [local models](research/2026-09-local-models.md),
  [native platform quality](research/2026-09-platform-quality.md),
  [provider reliability](research/2026-09-provider-reliability.md), and
  [agent harness compatibility](research/2026-09-harnesses.md). Each records
  current evidence separately from proposed work and untested support.
- [../CONTRIBUTING.md](../CONTRIBUTING.md): contribution and validation rules.
- [../SECURITY.md](../SECURITY.md): trust boundaries and private vulnerability
  reporting.

For agent integration, also see [../AGENTS.md](../AGENTS.md),
[../integrations/mcp_clients/](../integrations/mcp_clients/), and
[../integrations/litellm/](../integrations/litellm/).
