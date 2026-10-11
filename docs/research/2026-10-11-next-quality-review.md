# Quality review after 0.11.11

Reviewed 2026-10-11 against main `1bce99a755d9e9d4c892594148b8dc7ae1e65c5f`,
after re-reading the README, roadmap, editing contract, credential discovery,
MCP entrypoint, SDK lockfiles, and subscription tests. The three original open
issues are closed in immutable 0.11.11. Its final documentation main also
passed [CI](https://github.com/blisspixel/quotabot/actions/runs/38163192658).
[ROADMAP Next](../../ROADMAP.md#next) owns implementation order and acceptance.
This report records evidence and decisions, not another work queue.

## What the README promises

The primary jobs are a truthful quota view and a usable next-route explanation.
The CLI is complete; desktop and harness integrations share the same evidence.
The most valuable improvements protect those jobs: recovery after credentials
expire, correct account and execution scope, bounded integration inputs, and
clear repair actions. More providers or speculative quality rankings would not
close these gaps.

The published 0.11.11 release has three-OS build and install evidence. This
Windows machine has the published CLI and desktop, with all 30 payload files
verified and persistent metadata preserved. Those checks do not establish a
Keychain-only login, an idle account's independent quota truth, assistive
technology behavior, or publisher signing.

## Current primary-source findings

| Finding | Source checked October 11 | Consequence |
|---|---|---|
| Claude stores macOS logins in Keychain, with a credential-file fallback when a Keychain write fails. `CLAUDE_CONFIG_DIR` scopes both. | [Claude Code authentication](https://code.claude.com/docs/en/authentication#credential-management) | Discovery must use one selected configuration scope across collection, current-account enumeration, and cache admission. Do not scan unrelated entries. |
| The adapter still hardcodes `~/.claude/.credentials.json` in collection and credential-generation discovery. | `collector/lib/adapters/claude.dart` | Both Keychain-only users and explicitly selected alternate directories need a shared discovery seam. A successful read must retain credential-generation and provider-proven account isolation. |
| MCP Dart SDK 2.4.2 bounds incoming stdio frames; 2.2.2 remains locked in the reviewed baseline. | [SDK changelog](https://pub.dev/packages/mcp_dart/changelog) | Take the bounded-input maintenance update before the larger protocol migration. |
| The upgraded SDK offers explicit initialization-only mode, but stricter parsing and schema rejection still apply. | [2.2 to 2.3 migration guide](https://github.com/leehack/mcp_dart/blob/v2.4.2/doc/migration-2.2-to-2.3.md) | Select legacy mode explicitly; adapt subscription parsing and verify rejection without side effects. An SDK upgrade alone is not modern MCP support. |
| LM Link can serve a remote device's model through localhost. | [LM Link API behavior](https://lmstudio.ai/docs/developer/core/lmlink) | Localhost and loaded state cannot establish on-device execution. |
| LM Studio lists loaded instances and their configuration separately from a model's maximum context. The documented response has no explicit producer-device field. | [Model-list contract](https://lmstudio.ai/docs/developer/rest/list) | Preserve the context distinction. Absence of a documented producer field is a research limit, not proof that every runtime lacks one. |

## Selected maintenance increment

Prepare 0.11.12 with MCP Dart SDK 2.4.2 in both native lockfiles, explicit legacy
server negotiation, and a 256 KiB incoming stdio frame ceiling. The ceiling
counts UTF-8 bytes before the newline, including incomplete frames. It applies
per frame rather than to the connection's total traffic. Oversized input closes
the transport and enters the existing bounded collection shutdown path.

The first upgrade trial exposed incomplete subscription envelopes in our
custom parsing wrappers. Use the SDK's typed parameter constructors instead.
Its invalid-argument tool errors must reject before collection, cache reads,
or lease writes. Retain the subscription and cancellation assertions; do not
disable them to make the dependency update pass.

Independent review also found that the SDK's default malformed-frame logs can
copy raw input and exception sources to stderr. The MCP entrypoint replaces
those runtime diagnostics with category-only messages; invalid subscription
errors no longer repeat the requested URI. Short malformed-frame and invalid
subscription sentinels must be absent from both runtime logs and error responses.

Required evidence includes exact-ceiling messages, multiple individually valid
frames, multibyte overflow with and without a newline, closure while stdin stays
open, no queued quota dispatch after overflow, protocol-only stdout, existing
HTTP admission controls, alert subscription delivery, EOF cleanup, all four
legacy revisions, and default modern-client fallback. Obtain independent
implementation review, then run the complete gates and release lifecycle.
Implementation and focused tests are preparation evidence until those gates pass.
The nine targeted boundary checks pass locally. Removing the diagnostic
correction makes the malformed-frame sentinel test fail; removing the configured
256 KiB ceiling makes the unterminated-frame test fail its unchanged 10-second
exit deadline. The source was restored after each isolated negative check.
The SDK also accepts `2024-10-07`, as the old lock did. Preserve and test that
existing negotiation behavior separately from the four documented plugin launch
revisions; it is not a new published-protocol support claim.

The complete local Windows gate passed with 2,359 collector tests, 455 desktop
tests, and line coverage of 92.82 and 87.52 percent respectively. Linux and
macOS PR gates also passed. Two hosted Windows attempts exposed process-exit
timeouts while stdin remained open: the HTTP signal fixture, and on the second
attempt, the newline-terminated oversized stdio case. Six isolated Windows HTTP
repetitions and the extracted native CLI's boundary and legacy-launch checks
passed. These results do not establish the timeout's cause or a correction.
Fixed fixture-only shutdown phases and bounded timeout diagnostics now separate
application return from final VM exit; the original deadlines and open stdin
remain. The collector gate stops on its first failure for earlier diagnosis,
while a successful gate still requires the complete suite and coverage floors.
Publication remains pending until the hosted lifecycle failure is resolved.

## Evidence still needed for exceptional everyday behavior

Credential recovery needs a native Keychain-only login and a selected alternate
configuration directory, including locked or missing Keychain, malformed data,
replacement, account mismatch, explicit disconnect, and own-grant fallback.
Keychain service/account derivation must be verified against an exact host
version; the general authentication page does not specify the complete lookup
algorithm. Bound the original secret-store operation, not only a caller wait.
Do not infer dated plan entitlement from a Keychain read's capture time.

Idle-machine proof needs the same account on two machines. Let the existing
host token expire on the idle one, observe naturally occurring usage on the
active one, and verify the idle machine refreshes only its quotabot-owned grant.
Record sanitized timestamps, reset windows, source, and scope. Collection must
make no model calls and leave host credential files unchanged.

For stronger local-only advice, collect bounded producer and endpoint-scope
evidence for direct, forwarded, WSL, LM Link, and composite cases. Unknown
execution must remain unknown; host RAM or GPU counters cannot fill that gap.
Modern MCP requires its own stdio/HTTP discovery, metadata, private caching,
subscription ownership, cancellation, and shutdown matrix against exact client
versions. Native keyboard, large-text, offline recovery, and signed fresh-install
evidence remain separate from synthetic widgets and hosted packaging.
