# Documentation

Start with the shortest path for what you need.

## Project status

The current verified stable release is 0.11.1. It separates fresh quota from
slower advisory analytics and excludes upstream-configured models from
local/quota advice. It retains inspectable model detail, conservative hardware
evidence, and versioned harness and Agent Plugins setup through `quotabot mcp`.
Further work
improves everyday Windows, macOS, and Linux behavior and verifies each named
harness on its installed version. The bounded
provider-ID cache coordinator passed ordinary hosted CI plus the complete
release, install, update, and source-setup lifecycle on Windows, macOS, and
Linux; the shipped alias map remains empty. The current line includes bounded
local readiness and host-pressure refinement. Further local insight and native
validation proceed through the roadmap's product increments. Explicit paid
fallback balance visibility retains its typed-pool and admission prerequisites.
The completed 0.11.0
[release run](https://github.com/blisspixel/quotabot/actions/runs/33956459889)
and unpinned GitHub Latest
[install smoke](https://github.com/blisspixel/quotabot/actions/runs/33959135481)
cover exact-tag installation, transactional activation, installed-version
verification, stable-channel discovery, canonical acquisition, and the existing
cross-platform lifecycle gate. A live Windows self-update from 0.10.3 to 0.11.0
and matching desktop installation passed fresh-download payload checks. Stable
discovery uses GitHub's dedicated Latest endpoint. The repository
contains fail-closed Windows and macOS signing paths for CLI and desktop assets.
They capture one signing policy per release, pin the Apple build toolchain,
enforce exact unsigned-to-signed tree deltas, and bind signed native-verification
and release-metadata digests through final publication audit. The manual Windows
and macOS rehearsals and their reviewed `main` and `v*` environment policies are
configured, but neither rehearsal has succeeded because publisher identities,
environment values, and Apple secrets are absent. Current published artifacts
remain unsigned; owner identity and credential provisioning, successful
protected rehearsals, mode activation, and signed fresh-download evidence
remain. The
[roadmap Next section](../ROADMAP.md#next) owns the exact behavior, guardrails,
completion criteria, and rationale. Owner-dependent signing remains a 1.0
release gate while useful product development continues.

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
  [native platform quality](research/2026-09-platform-quality.md), and
  [agent harness compatibility](research/2026-09-harnesses.md). Each records
  current evidence separately from proposed work and untested support.
- [../CONTRIBUTING.md](../CONTRIBUTING.md): contribution and validation rules.
- [../SECURITY.md](../SECURITY.md): trust boundaries and private vulnerability
  reporting.

For agent integration, also see [../AGENTS.md](../AGENTS.md),
[../integrations/mcp_clients/](../integrations/mcp_clients/), and
[../integrations/litellm/](../integrations/litellm/).
