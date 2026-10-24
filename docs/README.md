# Documentation

Start with the shortest path for what you need.

## Project status

The current verified stable release is 0.11.18.

Version [0.11.18](https://github.com/blisspixel/quotabot/releases/tag/v0.11.18) sends
`User-Agent: claude-code/2.1` on Claude account usage reads, shares a
successful Claude capture for 20 minutes by default, and shows a remaining
percent as N% free. An Antigravity model table can carry a tighter models
window. The desktop first-run prompt stays dismissed after Skip or closing
the window. CI defaults to Python 3.14. Python 3.15 stays blocked. The
0.11.17 route line, theme files, and aged Omarchy display remain. The
0.11.16 hand-extracted desktop notice remains: that copy stays in place, and
the desktop dialog uses the installed CLI version. Managed desktop updates
from 0.11.15 remain. Earlier quota-readiness and bounded MCP contracts remain
in effect. See the
[changelog](../CHANGELOG.md) and
[quality review](research/2026-10-11-next-quality-review.md).

The release passed [three-OS main CI](https://github.com/blisspixel/quotabot/actions/runs/40111504334),
[Release workflow](https://github.com/blisspixel/quotabot/actions/runs/40115290859), and
[published Install smoke](https://github.com/blisspixel/quotabot/actions/runs/40120620919).
The immutable fourteen-asset set contains four CLI and three desktop
archive/checksum pairs. Publication verified exact workflow provenance and
fresh downloads. Unpinned Latest smoke covers clean install, upgrade from
0.11.17, persistent state, source setup, and stable-channel resolution on
Windows, macOS, and Linux. Desktop checks verify Windows/Linux startup and
the installed macOS bundle.

Current Windows and macOS artifacts remain unsigned transition artifacts.
Native publisher signing, supported Claude quota integration, real-account
idle-machine refresh, stronger local execution-scope evidence, and modern MCP
support retain their own acceptance criteria in [roadmap Next](../ROADMAP.md#next).
Expanded Claude credential discovery is deferred pending a supported path or
provider confirmation. The protected 0.11.12 candidate remains unpublished.
Automated checks do not establish native assistive-technology interaction or
provider-account truth. See [Building](BUILDING.md), [Security](../SECURITY.md),
and [Setup](SETUP.md).

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
- [October 11 next quality review](research/2026-10-11-next-quality-review.md):
  README-driven priorities, current credential and runtime contracts, and the
  bounded MCP maintenance increment. Preparation and native proof stay distinct.
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
