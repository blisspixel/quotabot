# Documentation

Start with the shortest path for what you need.

## Project status

The current verified stable release is 0.11.11. It shares recent successful
Claude captures without changing their age, makes local routing advice name a
concrete model and context shortfall, fixes absent-tool discovery, and includes
selected security updates. See the [changelog](../CHANGELOG.md) and
[October 11 issue review](research/2026-10-11-issue-review.md).

The release passed [three-OS main CI](https://github.com/blisspixel/quotabot/actions/runs/38153000563),
[Release workflow](https://github.com/blisspixel/quotabot/actions/runs/38155116920), and
[published Install smoke](https://github.com/blisspixel/quotabot/actions/runs/38159387701).
Immutable publication includes fourteen verified archive/checksum assets.
Published install smoke verifies clean installation, upgrade from 0.11.8,
persistent state, source setup, and stable-channel discovery on Windows,
macOS, and Linux. Desktop checks cover Windows/Linux startup and the macOS
installed bundle.

Native publisher signing, real-account idle-machine refresh, Claude Keychain
discovery, stronger execution-scope proof, and modern MCP compatibility remain
in [ROADMAP Next](../ROADMAP.md#next). Current Windows and macOS binaries remain
unsigned. Synthetic tests and automated startup are separate from native
screen-reader interaction and independently known provider-account usage.

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
- [Omarchy bar widget](../integrations/omarchy/README.md) maps quotabot JSON
  into a redacted Omarchy 4.0.4 panel. It does not write stock agent usage
  records. Unit fixtures are not an installed-shell proof.

- [ARCHITECTURE.md](ARCHITECTURE.md): code boundaries and data flow.
- [PRODUCT-STRATEGY.md](PRODUCT-STRATEGY.md): product choices and current
  external evidence, including the reason behind the roadmap order.
- [../ROADMAP.md](../ROADMAP.md): the sole immediate priority, ordered work, and
  release gates.
- [October 11 issue review](research/2026-10-11-issue-review.md): shared Claude
  captures, concrete local-model advice, primary sources, and validation scope
  for the verified 0.11.11 release. ROADMAP Next owns remaining work.
- September 30 evidence: [review and validation](research/2026-09-30-review.md),
  [subscription quota](research/2026-09-30-subscription-quotas.md),
  [provider policies](research/2026-09-30-provider-policy-updates.md),
  [local status](research/2026-09-30-local-runtime-status.md),
  [routing](research/2026-09-30-model-routing.md), and
  [code quality](research/2026-09-30-code-quality.md). These reports are evidence;
  ROADMAP Next owns the selected work and its acceptance criteria.
  Earlier September research: [local models](research/2026-09-local-models.md),
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
