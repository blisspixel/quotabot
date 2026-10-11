# October 11 README and open-issue review

Reviewed 2026-10-11 against README, ROADMAP Next, source, and GitHub issues.
The execution queue remains [ROADMAP Next](../../ROADMAP.md#next).

## Scope and decisions

| Issue | README promise | 0.11.11 response |
|---|---|---|
| [155](https://github.com/blisspixel/quotabot/issues/155) | Truthful discovery and actionable doctor guidance | Retain the reviewed passive-install fix and first-party security pins; absent applications are undetected. |
| [156](https://github.com/blisspixel/quotabot/issues/156) | Quick-start commands and integrations should compose reliably | Share recent successful Claude account captures under the existing credential read guard and canonical cache. |
| [157](https://github.com/blisspixel/quotabot/issues/157) | Local models, loaded context, and fit should make routing actionable | Attach concrete model advice and explain context shortfalls without silently changing provider eligibility. |

All three directly support the two product jobs: truthful quota evidence and
usable routing advice. Avoid coupling this maintenance release to native signing,
new providers, or a protocol migration. Those retain their existing acceptance
criteria in ROADMAP Next.

## Primary-source research

- [Claude Code cost and usage guidance](https://code.claude.com/docs/en/costs)
  acknowledges usage-endpoint rate limiting and distinguishes last-known bars
  from fresh reads. Its this-machine activity attribution is separate from
  account-wide quota. No print-mode or inference command is a collector.
- [Ollama running models](https://docs.ollama.com/api/ps) exposes running models,
  GPU residency bytes, and running `context_length`. These metadata fields
  support context advice; they do not establish active generation, model quality,
  startup duration, or independently verified on-device execution.
- [GitHub commit mutation](https://docs.github.com/en/enterprise-cloud%40latest/graphql/reference/commits)
  documents authenticated-user authorship and automatic GitHub signatures for
  `createCommitOnBranch`. Use this existing owner-authenticated surface when a
  local signing key is unavailable. Preserve required signatures and branch
  protection; do not bypass them to merge the unsigned original PR.

## Implementation boundaries

Claude sharing requires current credential discovery and provider-proven pool
identity. The default window is 30 seconds, configurable from 0 through 60.
The existing guard serializes original work across processes. A small sharing
receipt stores capture time and a canonical SHA-256 digest, never another quota
payload, token, or account identifier. The existing pending/cooldown state remains
wire-compatible with older binaries. A preceding failure prevents receipt reuse
even after its backoff expires. A new attempt invalidates the old receipt first.
Drift quarantine, expired resets, changed canonical evidence, and changed
credentials prevent sharing. Shared reads preserve age and create no new burn
sample. Other providers and unproven account reads keep their existing behavior.

Local advice reuses the normalized registry, execution exclusions, admission,
and capability filters. Default provider advice uses a 32K context heuristic,
then advisory fit, declared tier, loaded state, and ID. It does not infer model
quality from names or select the largest parameter count. A cold model's maximum
context may require runtime configuration when loaded. No load-time estimate is
invented. Explicit profiles and concrete-model selection retain their existing
contracts. Structured fields carry the same advice across machine interfaces.

## Verification scope

The unpublished 0.11.9 release candidate passed main CI but failed the Windows
Omarchy lifecycle test in the tagged Release workflow. Repeated local tests
reproduced the defect: Windows text-mode writes expanded random newline bytes
inside the 32-byte alias key. Binary-mode creation preserves the exact bytes
and stable aliases. A deterministic control-byte regression failed before the
fix and passes afterward. The 0.11.10 candidate retained that correction and
passed all three tagged quality gates, but metadata preparation mistook the
scoped MCP npm package name in its changelog for an account mention. The
corrected notes use the SDK product name, and a regression now runs the actual
current changelog through metadata preparation early in CI. The regression
failed before the wording fix and passes afterward without weakening the
attribution or mention guard. Release 0.11.11 supersedes both unpublished
candidates. Their protected tags are preserved unchanged.

Regression coverage targets independent processes, sequential adapter instances,
concurrent adapters, exact capture fingerprints, drift, resets, expiry, forced
refresh, mixed-version cooldowns, optional receipt storage, truthful absence,
local execution exclusions, insufficient loaded context, and explicit profiles.
Independent review is required for the concurrency and spend boundaries.

Contributor gates, hosted three-platform CI, release archive checks, publication,
and published install smoke must each be recorded against their actual source.
Synthetic tests do not prove real-account idle-machine refresh, Keychain-only
discovery, native screen-reader interaction, publisher signing, or execution
scope behind forwarding and LM Link. Those remain open and must not be marked
complete when this maintenance release ships.
