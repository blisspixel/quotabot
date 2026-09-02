# Documentation

Start with the shortest path for what you need.

## Project status

The current verified stable release is 0.10.1. The current release candidate is
0.10.2-rc.1. The next work in the focused 0.10.x hardening line is to complete
its corrected stable-update lifecycle, then continue native field validation,
owner signing setup, and one signed lifecycle rehearsal before 1.0. The bounded
provider-ID cache coordinator passed ordinary hosted CI plus the complete
release, install, update, and source-setup lifecycle on Windows, macOS, and
Linux; the shipped alias map remains empty. Bounded local-resource visibility
is specified as the first post-stabilization product track.
Stable 0.10.1 retains the verified 0.10.0 updater foundation. Its release
discovery, exact-tag installation, transactional activation, installed-version
verification, explicit GitHub Latest contract, and canonical Latest installer
smoke join the existing cross-platform lifecycle gate. The 0.10.2 candidate
replaces oversized stable release-list discovery with GitHub's dedicated Latest
endpoint, shrinks preview pages, and makes stable-channel discovery part of the
three-OS Latest smoke. The repository now
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
