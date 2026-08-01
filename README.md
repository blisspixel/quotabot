# quotabot

[![CI](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml/badge.svg)](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**htop for your agentic-AI quota plans.**

quotabot shows how much included quota remains across AI coding subscriptions
and recommends where to send the next request. It also reports supported local
runtimes, so work can fall back locally when subscription caps are low.

> **Current stable:** 0.9.8. quotabot remains under active 0.x development.
> **Next:** sign Windows release binaries and Developer ID-sign, notarize, and
> staple the macOS bundle. See the [roadmap criteria](ROADMAP.md#next).

quotabot is a local advisor, not a proxy. Quota and routing reads make no model
calls, spend no usage tokens, and never read prompts or source code.

<p align="center">
  <img src="docs/quotabot-demo.gif" alt="quotabot demo showing the widget, compact strip, analytics, and terminal dashboard" width="620">
</p>

## Quick start

Install the latest checksum-verified CLI release.

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
```

**Windows PowerShell**

```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
```

Restart the terminal, then run:

```bash
quotabot doctor
quotabot suggest
```

`doctor` explains stale or unavailable evidence and gives a repair command.
`suggest` ranks usable subscriptions and supplies a local fallback when one is
available. For inspect-before-run installation, login, updates, rollback, and
uninstall, use the [setup guide](docs/SETUP.md).

## Core commands

| Goal | Command |
|---|---|
| Show the full quota snapshot | `quotabot` or `quotabot --json` |
| Check one provider | `quotabot check claude` |
| Pick the next provider | `quotabot suggest` |
| Prefer a local runtime | `quotabot suggest --local-first` |
| Preserve an included-quota reserve | `quotabot suggest --quota-stretch` |
| Pick a model for a task | `quotabot suggest --task=hard` |
| Inspect model availability and budget | `quotabot models` |
| Watch quota and routing changes | `quotabot top` or `quotabot watch` |
| Require selected reads to be live | `quotabot verify --require-live` |

Provider routing is balanced by default. `--local-first` prefers reachable
on-device capacity immediately. `--quota-stretch` keeps fresh measured included
quota above a reserve before preferring local capacity. Model suggestions use
included quota and local runtimes by default; paid or credit-backed catalog
entries require an explicit `--budget=any` opt-in.

See the [usage guide](docs/USAGE.md) for profiles, accounts, model capability
filters, alerts, analytics, drift recovery, routing receipts, and every command.

## Supported sources

| Source | Evidence |
|---|---|
| Claude | Account-wide quota metadata from a current host token or local quotabot grant |
| Codex | Account-wide ChatGPT quota metadata from a host token or local quotabot grant |
| Antigravity / Gemini | Live Cloud Code quota metadata, with labeled local fallback evidence |
| Grok | Live billing metadata from a current local login |
| Cursor, Windsurf, Kiro | Passive local plan or credit state when available |
| Ollama, LM Studio, Lemonade | Reachable runtime plus installed or loaded model metadata |
| NVIDIA NIM | Optional key validation and safe model-list discovery; no invented numeric quota |
| Manual entries | User-supplied limits, usage, and reset time, always labeled self-reported |

Fresh host credentials usually make Claude and Codex work without another
login. An idle machine can create a separate local grant with `quotabot login`.
quotabot never refreshes, rewrites, or deletes a host application's credential
files. Exact endpoints, evidence classes, and limitations are in
[Data sources](docs/DATA_SOURCES.md); provider-owned cross-check commands are in
[Provider CLIs](docs/PROVIDER_CLIS.md).

## Desktop app

Portable desktop bundles are published for Windows, macOS, and Linux alongside
the CLI. They include checksum sidecars and GitHub build provenance. Windows and
macOS application signing is still the next release gate, so do not treat a
checksum or provenance result as permission to bypass an operating-system
warning.

See [Desktop release bundles](docs/DESKTOP-DISTRIBUTION.md) for asset names,
verification, launch, update, rollback, and uninstall. To build and install the
CLI and desktop app from source, use:

- Windows: `pwsh tools/setup.ps1`
- macOS / Linux: `bash tools/setup.sh`

Add `-CliOnly` or `--cli-only` to skip the desktop build. Build prerequisites
and packaging details are in [Building from source](docs/BUILDING.md).

## Agents and integrations

The MCP server exposes live snapshots, cache-only decisions, provider and model
suggestions, availability checks, alerts, and short local routing leases. It
supports stdio and authenticated loopback HTTP. The complete agent contract and
schemas are in [AGENTS.md](AGENTS.md).

The [LiteLLM integration](integrations/litellm/) demonstrates atomic provider
leases and no-surprise spend classes. Minimal Python and TypeScript clients are
in [integrations/mcp_clients](integrations/mcp_clients/).

## Privacy and trust boundary

- No quotabot account, hosted service, advertising, or telemetry.
- No model or inference calls, so quota reads spend zero usage tokens.
- No prompt, source-code, model-output, or other user-content reads.
- Local cache, history, preferences, profiles, grants, and leases stay local.
- Live adapters may present an existing credential only to that provider's
  quota or model-list metadata endpoint. Antigravity may also perform its
  provider-required account onboarding request before reading quota.
- Routing fails soft. If quotabot is unavailable, the caller can continue with
  its original provider.

Run `quotabot explain` to inspect files and network destinations used by each
adapter. The complete promises and verification methods are in
[Principles](docs/PRINCIPLES.md), [Security](SECURITY.md), and
[Architecture](docs/ARCHITECTURE.md).

## Release and project status

The immutable [v0.9.8 release](https://github.com/blisspixel/quotabot/releases/tag/v0.9.8)
passed its exact 14-asset native audit and the Windows, macOS, and Linux install
and upgrade matrix. The evidence links and release checklist are in
[Baseline release evidence](docs/BUILDING.md#baseline-release-evidence).

Project direction and completion criteria live in the [roadmap](ROADMAP.md).
The [documentation index](docs/README.md) links setup, usage, trust, design, and
maintenance references. Development guidance is in
[CONTRIBUTING.md](CONTRIBUTING.md), and private vulnerability reporting is in
[SECURITY.md](SECURITY.md).

## Disclaimer

quotabot is an independent, unofficial tool. It is not affiliated with,
endorsed by, or sponsored by any provider it reports. Product names and
trademarks identify the service whose quota is displayed.

Quota metadata is best-effort and may be incomplete, delayed, or wrong. Verify
billing and compliance information against the provider's official dashboard.
You are responsible for ensuring that credential reuse, metadata access, and
automated routing comply with each provider's terms and your account policy.

Provided "AS IS", without warranty, under the [Apache License 2.0](LICENSE).
