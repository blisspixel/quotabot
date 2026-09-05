# quotabot

[![CI](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml/badge.svg)](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**htop for your agentic-AI quota plans.**

quotabot shows how much included quota remains across AI coding subscriptions
and recommends where to send the next request. It also shows supported local
models, loaded state, context, and available hardware evidence, so you can use
on-device capacity directly or fall back when subscription caps are low.

> **Current stable:** 0.11.0. quotabot remains under active 0.x development.
> **Next:** make local-model choices easier to inspect, improve everyday native
> behavior on Windows, macOS, and Linux, and add tested advisory setup for named
> agent harnesses. Product development continues while release signing is
> provisioned. See [roadmap Next](ROADMAP.md#next) and the
> [documentation index](docs/README.md).

Release notes state each artifact's Windows and macOS signing status. Current
artifacts are unsigned; [signing readiness](docs/RELEASE-SIGNING.md) proceeds
alongside product development.

quotabot is a local advisor, not a proxy. Quota and routing reads make no model
calls, spend no usage tokens, and never read prompts or source code. The CLI
is the complete workflow; the desktop app is optional.

## What it looks like

<p align="center">
  <a href="docs/screenshot-top.png"><img src="docs/screenshot-top.png" alt="quotabot top CLI terminal dashboard using synthetic demo quota" width="760"></a>
</p>

<p align="center"><sub>The standalone <code>quotabot top</code> CLI, captured from the real terminal dashboard renderer with built-in synthetic demo data.</sub></p>

<p align="center">
  <a href="docs/quotabot-demo.gif"><img src="docs/quotabot-demo.gif" alt="quotabot CLI and optional desktop views using synthetic demo quota" width="520"></a>
</p>

<p align="center"><sub>Five generated demo views at 3 seconds per frame. <a href="docs/screenshot-widget.png">Desktop still</a> | <a href="docs/screenshot-analytics.png">Analytics still</a></sub></p>

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
available. Run `quotabot update` to keep the CLI current. If an older install
does not support that command or cannot discover the latest release, run the
installer once more. For inspect-before-run installation, login, updates,
rollback, and uninstall, use the [setup guide](docs/SETUP.md).

## Core commands

| Goal | Command |
|---|---|
| Show the full quota snapshot | `quotabot` or `quotabot --json` |
| Check one provider | `quotabot check claude` |
| Recommend an account with usable quota | `quotabot suggest` |
| Prefer a local runtime | `quotabot suggest --local-first` |
| Preserve an included-quota reserve | `quotabot suggest --quota-stretch` |
| Pick a model for a task | `quotabot suggest --task=hard` |
| Inspect model availability and budget | `quotabot models` |
| Watch quota and routing changes | `quotabot top` or `quotabot watch` |
| Require selected reads to be live | `quotabot verify --require-live` |
| Install the latest release for this channel | `quotabot update` |
| Connect an agent to quota advice | `quotabot mcp` |

Provider routing is balanced by default. `--local-first` prefers reachable
on-device capacity immediately. `--quota-stretch` keeps fresh measured included
quota above a reserve before preferring local capacity. Model suggestions use
included quota and local runtimes by default; paid or credit-backed catalog
entries require an explicit `--budget=any` opt-in.

See the [usage guide](docs/USAGE.md) for profiles, accounts, model capability
filters, alerts, analytics, drift recovery, routing receipts, and every command.

## Supported sources

Supported cloud and application sources include Claude, Codex, Antigravity /
Gemini, Grok, Cursor, Windsurf / Devin, Kiro, and optional NVIDIA NIM discovery. Cursor
3.x support passively detects an owner-bound local plan, but Cursor does not
persist its current quota pools in the supported local state, so quotabot cannot
yet route on Cursor headroom. Local sources are Ollama, LM Studio, and Lemonade. Their summaries
lead with what is loaded now, the active context limit, and runtime-reported GPU
residency when available; installed count and disk size remain secondary
inventory detail. Bounded host evidence can add RAM, VRAM, and supported GPU
activity without attributing shared machine load to a model. Manual entries
remain explicitly self-reported. Exact endpoints, evidence classes, credential
behavior, and limitations are in [Data sources](docs/DATA_SOURCES.md);
provider-owned cross-checks are in [Provider CLIs](docs/PROVIDER_CLIS.md).

## Desktop app

Portable desktop bundles are published for Windows, macOS, and Linux alongside
the CLI. The app is optional. Each local runtime's **Models** control opens its
inventory with loaded state, reported capabilities, context, and advisory
memory fit. See the [local-model view](docs/USAGE.md#the-desktop-widget).
Windows signing and macOS signing, notarization, and stapling remain pre-1.0
trust gates; each release states its artifacts' signing status.
The grouped Settings dialog includes the installed build and an explicit
**Check for updates** action. It contacts GitHub only after that action, shows
the latest candidate and latest stable release separately, and opens the chosen
release so signing status, checksums, assets, and update instructions stay
visible. Stable builds recommend stable updates without hiding newer previews;
release candidates follow the preview channel. The app never checks
automatically or prompts on launch.
Verification, launch, update, rollback, and uninstall belong in [Desktop
release bundles](docs/DESKTOP-DISTRIBUTION.md). Source setup and packaging are
in [Building from source](docs/BUILDING.md).

## Agents and integrations

Run `quotabot mcp` with a release CLI from 0.11.0 onward. The MCP server supports
stdio and authenticated loopback HTTP. Its complete
tool and schema contract is in [AGENTS.md](AGENTS.md). See the
[LiteLLM integration](integrations/litellm/) and
[minimal MCP clients](integrations/mcp_clients/) for working examples. The
[harness setup pack](integrations/harnesses/) prints versioned advisory
configuration for OpenClaw, Hermes, and OpenCode 1, with CLI recipes for pi and
NemoClaw. It checks configuration and the quotabot entrypoint; installed-harness
loading remains a separate compatibility check. The
[September harness review](docs/research/2026-09-harnesses.md) records the
versioned OpenClaw, NemoClaw, pi, Hermes, and OpenCode integration plan and its
current limits. Exposing MCP advice does not automatically switch a harness's
model or grant API access through a coding subscription.

For clients that support [Agent Plugins](https://agent-plugins.org/), the
[portable package](integrations/agent_plugin/) supplies the same quota advice
and MCP connection. quotabot reports which configured accounts have usable
included quota; a harness chooses through its supported access under provider
terms. Local-model suggestions are optional, and no integration overrides a
provider limit or silently enables paid fallback.

## Privacy and trust boundary

- No quotabot account, hosted service, advertising, or telemetry.
- No model calls or reads of prompts, code, model output, or other user content.
- Local metadata stays local. Live adapters contact only provider quota or
  model-list metadata endpoints; Antigravity may perform required onboarding.
- CLI and desktop update checks read public GitHub release metadata only after
  the user invokes them. They send no quota, account, history, prompt, or code
  data. `quotabot update` installs one exact tag with its required checksum.
- Plain loopback HTTP reads pseudonymize email-shaped account labels unless the
  caller supplies the server's owner-only bearer token. The bundled LiteLLM
  router proves the identity of the exact loopback server connection before it
  sends that token, so exact account routing remains available without trusting
  whichever process happened to bind the configured port first.
- Routing fails soft, so callers can continue if quotabot is unavailable.

Run `quotabot explain` to inspect files and network destinations used by each
adapter. The complete promises and verification methods are in
[Principles](docs/PRINCIPLES.md), [Security](SECURITY.md), and
[Architecture](docs/ARCHITECTURE.md).

## Release and project status

Stable 0.11.0 adds an inspectable local-model view, truthful Windows GPU fallback
evidence, Ollama reasoning metadata, and packaged quota advice for agent
harnesses and Agent Plugins. The release CLI now starts the MCP server directly
with `quotabot mcp`. The preceding audited 0.10.2
[release run](https://github.com/blisspixel/quotabot/actions/runs/33595583014)
published an immutable 14-asset set, and its unpinned GitHub Latest
[install smoke](https://github.com/blisspixel/quotabot/actions/runs/33598880949)
passed clean install, prior-stable upgrade, source setup, stable-channel
resolution, and desktop-run checks on Windows, macOS, and Ubuntu. A live Windows
installation also updated from 0.10.2-rc.1 to 0.10.2 and then reported no newer
stable release. Every release repeats the same three-platform quality,
packaging, provenance, and install gates.
The release uses GitHub's dedicated Latest endpoint for stable discovery and
keeps preview discovery within smaller bounded pages. Every release
repeats native build, archive, checksum, provenance,
fresh-download, install, upgrade, source-setup, and desktop-run checks. Current
Windows and macOS artifacts remain unsigned transition artifacts, so the
0.x line must repeat that evidence with platform-signed artifacts
before 1.0. See the [release
evidence](docs/BUILDING.md#baseline-release-evidence),
[roadmap](ROADMAP.md), [documentation index](docs/README.md),
[contributing guide](CONTRIBUTING.md), and [security policy](SECURITY.md).

## Disclaimer

quotabot is independent and unofficial. Quota metadata is best-effort; verify
billing and compliance against each provider. Provided "AS IS", without
warranty, under the [Apache License 2.0](LICENSE).
