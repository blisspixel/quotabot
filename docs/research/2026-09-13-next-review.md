# Project review and next product increment

Reviewed 2026-09-13 against stable 0.11.5, commit
`4c502b777389003f1a25f5a0556e234db3b369b6`, and current primary documentation.
The review covers the current README, roadmap, editing and architecture
contracts, release history, manifests, lockfiles, analysis and test settings,
CI, and representative collection, auth, routing, MCP, and desktop source.
Independent research covered provider policy, runtimes and native platforms,
and MCP, Agent Plugins, and named harnesses. No open issues or pull requests
were listed during the review. [ROADMAP.md](../../ROADMAP.md#next) remains the
execution queue; this report records dated evidence and decisions.

The leading priority remains provider correctness. The useful next increment
lets a person already signed into Claude on macOS obtain a truthful quota result
without depending on a credential file that their host application need not
create. Idle-machine recovery evidence follows because every route depends on
the freshness and account scope of the underlying observation. Native signing
provisioning can proceed alongside this work.

The architecture is appropriate for this product: one Dart evidence and
decision core, thin transport and provider adapters, and an optional Flutter
desktop consumer. No reviewed requirement justifies a language or framework
change. The useful quality gains are stronger evidence boundaries, native
validation, and current protocol integration, not another abstraction layer.

## Findings that affect the next change

| Finding | Evidence | Consequence |
|---|---|---|
| Claude host discovery is file-only in both collection and current credential enumeration | `collector/lib/adapters/claude.dart`, `_readHostCredential()` and `currentCredentialGenerations()` | Changing only collection leaves the identity and cache admission paths inconsistent. Share one bounded, injectable discovery path. |
| Current Claude storage behavior includes Keychain, a macOS file fallback, and configuration-directory scope | [Claude authentication](https://code.claude.com/docs/en/authentication), accessed 2026-09-13 | Verify both storage shapes and `CLAUDE_CONFIG_DIR`. Do not search unrelated profiles or treat finding a credential as evidence of plan entitlement. |
| The OS secret reader exists, but Claude does not use it | `collector/lib/auth/os_secret_store.dart`; its production caller is Antigravity | Reuse the established boundary while requiring bounded reads and deterministic missing, locked, malformed, and timeout outcomes. The existing synchronous subprocess helper alone is not a deadline guarantee. |
| LM Link exposes remote models through the usual local REST endpoint | [LM Studio REST API with LM Link](https://lmstudio.ai/docs/developer/core/lmlink), accessed 2026-09-13 | A localhost endpoint and loaded state cannot establish on-device execution. Host memory fit must be attached only when host scope is established. |
| MCP 2026-07-28 changes initialization, sessions, discovery, and request metadata | [Official release announcement](https://blog.modelcontextprotocol.io/posts/2026-07-28/), published 2026-07-28, accessed 2026-09-13 | Preserve the shipped 2025-11-25 behavior while validating a separate revision path. A dependency update or protocol label does not establish compatibility. |
| Windows signing still requires owner identity validation | [Microsoft Artifact Signing setup](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart), accessed 2026-09-13 | Provisioning and native rehearsal remain separate from repository implementation. Public identity validation requires the portal and applicable eligibility. |

## Evidence needed to close the leading increment

- Collection, current-account enumeration, and credential-generation cache
  admission resolve the same scoped host credential.
- Fixtures cover Keychain-only and file-only sign-ins, configuration-directory
  isolation, malformed and missing credentials, denied or locked Keychain,
  bounded timeout, replacement credentials, account mismatch, explicit
  disconnect, and fallback to a quotabot-owned grant.
- A native signed-in Mac yields current account-wide quota matching the
  provider-owned view. Record the host version, source, timestamp, comparison,
  and remaining uncertainty without retaining secrets or user content.
- Host credentials remain read-only. Missing current plan evidence cannot
  qualify credit-backed model use as included quota.
- Idle-machine evidence separately demonstrates that an expired host token
  does not prevent quotabot's own grant from refreshing the intended account.
- Required collector and desktop coverage floors remain 90 and 80 percent,
  with the complete contributor and three-OS release gates on the actual change.

## Documentation findings

The strategy document called local-model choices the immediate priority while
the roadmap led with provider truth. The README also placed native identity in
a sequence that could imply signing blocked stronger product evidence. The
review aligns these statements: provider correctness leads, execution scope
precedes stronger local-only advice, and signing remains a parallel 1.0 gate.

The older claim that every normally signed-in macOS user sees an error was too
broad. A usable quotabot-owned grant can supply quota, and current Claude
documentation describes a file fallback. The narrower affected case is a
Keychain-only host sign-in without a usable independent grant.

## Provider policy and evidence refresh

All sources below were reviewed on September 13. Public policy is not an
account's remaining balance. Source observations and metadata experiments are
identified separately from implemented behavior.

| Provider | Current evidence and consequence |
|---|---|
| Claude | [Authentication](https://code.claude.com/docs/en/authentication) documents Keychain, fallback files, and config-directory scope. Share discovery across collection, account enumeration, and cache admission. [Agent SDK billing](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) changed June 15: Agent SDK, print mode, Actions, and third-party SDK use separate per-user credits. Interactive weekly headroom cannot authorize headless quota-plan dispatch. |
| Claude Fable | The [plan guide](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan) confirms scoped limits and plan-dependent spend. Shipped source already gates the measured Fable pool. Its historical promotion ends July 19 at 23:59:59 PT, while the code's policy boundary is July 20 00:00 UTC. Review that seven-hour provenance discrepancy with historical fixtures; it does not establish current misrouting. Do not infer remaining quota from the advertised 50 percent allowance. |
| Codex | [Credential storage](https://learn.chatgpt.com/docs/auth#credential-storage) includes file, keyring, auto, and ephemeral modes. The current adapter respects `CODEX_HOME` but discovers files only. [Account rate-limit metadata](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt) distinguishes named limits and admission from token activity. Starting an app-server is not yet proven to preserve host state, so it is not an automatic collector replacement. |
| Antigravity | [Plans](https://antigravity.google/docs/plans) give free accounts weekly limits and paid accounts five-hour/weekly limits, with possible credit overages. Preserve September 8 known-consumption evidence for the daily-host grouped summary. Public plans do not document that private endpoint or prove every tier uses identical pools. Free/Ultra native evidence remains separate from the tested Pro account. |
| Grok | Current [billing source](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-shell/src/extensions/billing.rs) still distinguishes included percentage and typed periods from prepaid/on-demand fields. Preserve account/team scope and fail-closed parsing. The [Cursor acquisition announcement](https://cursor.com/blog/joining-spacex) does not establish shared billing or credential pools. |
| Cursor | [Current pricing](https://cursor.com/docs/models-and-pricing) separates Cursor Models and Other Models pools. Preserve owner-bound passive detection. The [Admin API](https://cursor.com/docs/account/teams/admin-api) reports spend, not purchased funds or disabled overages; it does not justify inventing remaining quota. |
| Windsurf / Devin | [Self-serve billing](https://docs.devin.ai/admin/billing/self-serve) distinguishes Pro daily/weekly limits from Max weekly-only limits. Teams Automations and Review use shared on-demand credits. The adapter already models separate windows; next fixtures should cover weekly-only Max and prevent shared credits increasing seat quota. |
| Kiro | [Add-on credit rules](https://kiro.dev/docs/billing/add-on-credits/) combine plan and purchased credits in the displayed total and consume plan first. Preserve timestamped passive evidence and the current budget exclusion. Require real add-on/no-add-on shapes before decomposing an aggregate. |
| NVIDIA | A bounded public `/v1/models` read returned HTTP 200 with 82 rows both without Authorization and with a synthetic invalid bearer. Catalog reachability cannot establish account access or trial eligibility. The adapter and regression tests now remove those claims, retaining `status_only` and no budget route. The [catalog quickstart](https://docs.api.nvidia.com/nim/re/docs/api-quickstart) is not a remaining-balance interface. |

For idle-machine acceptance, keep the host application idle while independently
known usage changes elsewhere. Prove current account selection, owned-grant
refresh and rotation across restart, denial with positive measured headroom,
and no stale-reset resurrection. Synthetic settlement tests remain necessary
but do not close that account-level gate.

Provider expansion remains after typed-pool correctness. [Copilot's dedicated
usage API](https://docs.github.com/en/rest/billing/usage#get-billing-ai-credit-usage-report-for-a-user)
now supports a user Plan-read scope, but excludes organization-billed seats and
does not prove live admission. [Individual billing](https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing)
has base and variable flex credits; [organization billing](https://docs.github.com/en/copilot/concepts/billing-and-usage/organizations-and-enterprises/billing)
uses pooled allowances and different paid-continuation controls. Reassess it
alongside GLM without relaxing today's credit exclusion.

[GLM plan rules](https://docs.z.ai/devpack/overview) include token-weighted credits,
tool charges, five-hour/weekly limits, and off-peak discounts. The official
[quota script](https://github.com/zai-org/zai-coding-plugins/blob/0446d0bb0bc537d97d3ab3664c4b8b9c4a0e1254/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)
is evidence of a metadata path, but its older period labels do not establish
today's complete binding pools. Require exact regional destinations and current
sanitized shapes before admission. OpenRouter's [ordinary-key metadata](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key)
describes a spending ceiling; [funded account credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits)
require a management key. Positive key headroom is not funded balance or
included subscription quota. Its display-first `paid_api` treatment remains right.

## Local runtimes and native platforms

Current local eligibility uses a negative veto in `registry.dart`: a model is
local and has no reported execution veto. That correctly rejects declared
cloud/upstream routes, but absence of a veto is not positive host-scope proof.
Use one normalized execution-location and evidence-basis contract across model
budgets, provider fallback, policies, readiness, cache, and hardware fit.

- **Ollama:** [cloud guidance](https://docs.ollama.com/cloud) confirms remote
  execution behind localhost. [Versioned wire types](https://github.com/ollama/ollama/blob/b79067b0db7417f20108363bc22adb97f35c966a/api/types.go)
  expose upstream host/model metadata. Preserve existing declared/unresolved
  vetoes and keep private upstream identity separate from public-cloud cost.
- **LM Studio:** [LM Link](https://lmstudio.ai/docs/developer/core/lmlink) can
  serve a remote device through the usual endpoint. The SDK's [device field](https://github.com/lmstudio-ai/lmstudio-js/blob/main/packages/lms-shared-types/src/ModelInfoBase.ts)
  is promising evidence, but missing differs from null, and server-local differs
  from collector-local. Prove endpoint and exact instance scope before adopting
  it. [Authenticated servers](https://lmstudio.ai/docs/developer/core/authentication)
  also need bounded configuration and useful 401/403 repair states instead of
  the current generic `not running` result. Preserve configured instance context
  separately from the model maximum.
- **Lemonade:** [router collections](https://lemonade-server.ai/docs/dev/router-policy/)
  can mix local and cloud components. The current parser recognizes top-level
  cloud recipes but not every composite's execution scope. Keep ambiguous
  composites out of stronger local-only claims. Routing validation can execute
  helper models, so it cannot be used as a metadata probe.
- **llama.cpp:** keep a new adapter behind the shared scope work. The official
  [server contract](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
  says model-selecting router reads can auto-load. Require `autoload=false`
  where applicable and never `reload=1`. `/props` contains templates/paths and
  `/slots` can expose prompt-related fields. Start with narrow admitted
  inventory/health metadata and leave unsupported capabilities unknown.

Acceptance needs forwarded endpoints, LM Link null/missing and mixed instances,
WSL, cloud aliases, Lemonade composites, cache migration, and stale/conflicting
scope fixtures. Spy transports must prove bounded metadata-only reads with no
load, download, wake, generation, or credential-bearing redirect.

The Windows GPU name-only correction and coalesced foreground recovery already
exist. Do not rebuild them. [DXGI video-memory information](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo)
is process budget/usage, not another runtime's free VRAM. [NVIDIA WSL guidance](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)
adds `/usr/lib/wsl/lib/nvidia-smi` and documents incomplete utilization queries;
retain memory when optional utilization is unavailable. Apple [unified memory](https://developer.apple.com/documentation/metal/mtldevice/hasunifiedmemory)
and [working-set guidance](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize)
must not be added as independent RAM and VRAM pools.

Native acceptance still needs Linux tray-host absence/loss with a reachable
window and Quit, real sleep/wake, mixed DPI and monitor removal, keyboard-only
use, large text, and platform screen readers. [Flutter lifecycle events](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)
can be skipped; widget simulations do not prove operating-system recovery.
[Accessibility guidance](https://docs.flutter.dev/ui/accessibility) informs the
native matrix, not a new UI framework.

Signing code is implemented; owner provisioning and exact signed-artifact
install/update/rollback/uninstall evidence remain. [Microsoft prerequisites](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
require Individual billing type for individual validation, while organization
validation does not require Organization billing type. The signing guide now
reflects that distinction. [Apple Developer ID guidance](https://developer.apple.com/developer-id/)
supports direct distribution without store admission; required identities and
native trust validation remain release gates.

## Persistent engineering guidance

Preserve the deliberate split: `CLAUDE.md` governs editing and `AGENTS.md`
documents using quotabot. The refinement adds source-first orientation,
current-source research, existing async seams, explicit evidence boundaries,
toolchain preflight, review and verification loops, and durable continuation.
The existing ignored local `docs/dev/` quality guide now points to the canonical contract and full gate
instead of defining an incompatible 80-percent core target and doctor-only
adapter validation. Product principles now distinguish provider network reads
from telemetry and the dry-run manifest from actual observation.

The toolchain pin is supported by [Flutter 3.44.6 DEPS](https://github.com/flutter/flutter/blob/3.44.6/DEPS)
and its pinned Dart [3.12.2 VERSION](https://github.com/dart-lang/sdk/blob/d684a576a6aa954ae107a03b2b4e1d61c3bebe93/tools/VERSION).
Both packages enable all three [strict Dart analysis modes](https://dart.dev/tools/analysis).
The TypeScript snippets enable [strict checking](https://www.typescriptlang.org/tsconfig/strict.html),
with declaration checking skipped. Python currently has Ruff and integration
tests, not a static type gate; [Ruff explicitly distinguishes the two](https://docs.astral.sh/ruff/faq/#how-does-ruff-compare-to-mypy-or-pyright-or-pyre).
A future Python typing increment should establish a baseline in the maintained
router and boundary modules without broad ignores or weakening existing tests.

## Dependency currency

Release preflight found three open Hono alerts in the MCP example lockfile.
The first-party patch updates only transitive Hono 4.13.3 to 4.13.7, covering
the [4.13.5 advisory fixes](https://github.com/honojs/hono/releases/tag/v4.13.5)
and [4.13.7 escaping fix](https://github.com/honojs/hono/releases/tag/v4.13.7).
Native npm regeneration changed only version, resolved URL, and integrity;
clean installation, strict TypeScript checking, and 14 Python helper tests
passed. npm audit reported zero known vulnerabilities for this dependency tree.
GitHub alert closure still depends on indexing the merged default-branch lock.

Current stable versions do not justify bulk upgrades. As of this review,
[`http` 1.6.0](https://pub.dev/api/packages/http) and
[TypeScript 7.0.2](https://registry.npmjs.org/typescript) match the locks.
Other reviewed direct Dart runtime dependencies also match current stable
registry releases. [`sqlite3` 3.5.2](https://pub.dev/packages/sqlite3/changelog)
and [Flutter notifications 22.3.1](https://pub.dev/packages/flutter_local_notifications/changelog)
are newer than the locks; review their native packaging and affected APIs as
separate updates. No active subtitle-handling defect was demonstrated because
the app does not supply that optional macOS field.

The pinned LiteLLM 1.92.2 is explicitly a patched backport in the
[August credential advisory](https://github.com/BerriAI/litellm/security/advisories/GHSA-3cv6-jpf6-8222),
despite its broad affected-version field. It also exceeds the
[user-config SSRF fixed version](https://github.com/BerriAI/litellm/security/advisories/GHSA-hx8v-g79f-8w5f).
The newer [1.100.1 release](https://pypi.org/pypi/litellm/1.100.1/json) merits
normal hash-lock, proxy-startup, lease-callback, and spend-policy validation.
These two advisory checks are not an exhaustive security clearance.

Two declared-runtime gaps need a bounded follow-up: the collector advertises
Dart `^3.6.0`, while its exact [SQLite dependency requires at least 3.10](https://pub.dev/api/packages/sqlite3/versions/3.5.0);
the MCP snippets allow Node 20, now outside the supported
[Node release lines](https://nodejs.org/en/about/previous-releases), and CI does
not explicitly pin Node. Align advertised minima, supported CI runtimes, and
dependency declarations without silently changing the pinned Flutter toolchain.

Python MCP snippet tests compile source and inspect helpers/imports, but CI does
not install and exercise their documented SDK transports. Add a reproducible
installed-SDK interoperability lane. Maintained Python [1.30.0](https://github.com/modelcontextprotocol/python-sdk/releases/tag/v1.30.0)
includes redirect, issuer, and idle-session protections; modern [2.2.0](https://github.com/modelcontextprotocol/python-sdk/releases/tag/v2.2.0)
needs separate API and wire-path tests. The proxy's transitive 1.28.1 lock must
not be silently replaced by a snippet dependency update. The
[MCP report](2026-09-13-mcp-agent-plugins.md) defines the compatibility scope.

## Verification record and limits

The [baseline CI run](https://github.com/blisspixel/quotabot/actions/runs/34366922878)
passed all three operating systems and static quality on the reviewed commit.
Its reported line coverage was:

| Platform | Collector | Desktop |
|---|---:|---:|
| Windows | 92.73% | 87.24% |
| Linux | 92.33% | 87.27% |
| macOS | 92.55% | 87.31% |

At the research checkpoint, local Ruff lint and formatting, release-version
consistency, collector format and analysis passed. The Python tools suite ran
282 tests with 12 skips. The NVIDIA and registry regression run passed 87 tests.
An independent review extended the NVIDIA correction to desktop setup and the
runtime manifest and caught a cache-expiry/deadline distinction in the guidance.

The first local full-gate attempt used an unpinned host toolchain. A subsequent
attempt uses an isolated exact Flutter 3.44.6 checkout, Dart 3.12.2, Python 3.13,
Ruff 0.15.16, and fresh coverage directories. It encountered a five-second
loopback-auth timeout before token exchange. The identical test passed without
changes in an isolated checkout; standalone Node and Dart loopback probes also
passed. No deterministic auth regression was established and no timeout or
assertion was weakened. Retain that failed-run evidence alongside subsequent
full-gate and per-commit CI results. Baseline coverage is not evidence for a new
tree; integration and release decisions require their own exact-commit gates.

No native macOS account experiment, signed-artifact rehearsal, or installed
harness validation was performed in this review. The follow-up acceptance
criteria above distinguish published interfaces, source observations, live
evidence, and unverified assumptions before any support claim expands.

Separately billed API or service spend for this review is $0. Research and
verification made no model calls and read no real provider credentials.

The follow-up [MCP and Agent Plugins review](2026-09-13-mcp-agent-plugins.md)
records current protocol and package versions, fresh native legacy launch
checks, SDK security-update impact, and the confirmed modern discovery gap.
