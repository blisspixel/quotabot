# Provider reliability review, September 2026

Reviewed 2026-09-05. The synthetic audit used prepared 0.11.1 source at
`8b75e34c90f922985da5e1d307464f82c02b7baa`. Findings below describe that baseline;
the [changelog](../../CHANGELOG.md) records which corrections have shipped.
No real provider requests, host-account inspection, inference, or purchases were
needed to reproduce these cases. They establish defects and cadence limits, not
the exact cause of an individual user's stale display.

The [roadmap Next section](../../ROADMAP.md#next) owns execution order. The
immediate objective is accurate recovery across manual refresh, foreground
return, reset boundaries, CLI reads, and long-running advisory clients.

## Reproduced behavior and acceptance

| Baseline behavior | Correction must establish |
|---|---|
| Codex explicit admission denial with 50 percent remaining still becomes available after serialization. | Preserve measured balance and bounded admission evidence; deny provider or matching model requests across every advice and lease surface. |
| A configured `CODEX_HOME` selects the unrelated legacy file instead. | Collection and cache identity discovery share one file resolver; an explicit home never borrows a different account. |
| A fresh response still naming a just-expired weekly pool can defer another read for one hour, or twelve hours beside a healthy provider. | A bounded confirmation period checks renewal without fabricating quota or overriding that provider's cooldown. |
| Weekly-only quota can wait twelve hours between automatic reads. | Make the freshness policy visible and observe off-cycle resets within a deliberate bounded interval while the dashboard is active. |
| An imminent reset schedules the fleet in 30 seconds despite a sibling's 7,200-second Retry-After; a server cache expires after five seconds. | Enforce each supported credential/account's absolute retry boundary below transport caches while other accounts remain independently eligible. |
| Claude malformed 200 followed by 429 loses the second status and retry header. | Both responses share classification; one parse retry maximum, with no immediate throttle or permission fallback. |
| Claude profile identity survives only in isolate memory; a cold isolate loses the last-known card during failures. | Persist a bounded credential-generation association or adopt a reviewed stable cache key; sign-out and replacement never recover another account's data. |
| Optional Grok grant failure or delay suppresses a usable host token. An owned login without a host file is undiscoverable. | Discover independently owned accounts and isolate credential failures, with exact account/principal proof before fallback. |
| Recovery copy promises a two-minute retry while the scheduler chooses twenty minutes. | Separate a metadata throttle from plan exhaustion; show a retry time only when it comes from the actual schedule. |

Expired old windows already remain unavailable, and a newly observed advanced
Codex reset restores measured headroom. Keep both controls. A provider denial
must not become a parse error that revives an older open state. A scoped denial
must not spend or block unrelated model pools.

## Current provider interfaces

OpenAI documents `account/rateLimits/read` and change notifications, separate
from account token activity. Re-read after a redeemed reset. A host-owned bridge
is promising, but automatic app-server startup needs separate proof that it
does not modify the host's authentication state.
[App-server contract](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).
File credentials belong under the configured `CODEX_HOME`; keyring and automatic
credential storage require additional platform support.
[Authentication](https://learn.chatgpt.com/docs/auth#credential-storage).

Claude's status-line metadata can expose current quota windows after an existing
session receives a response. That is a possible opt-in metadata bridge, not
permission to read transcripts or generate a request to populate missing data.
[Status-line contract](https://code.claude.com/docs/en/statusline).
Interactive `/usage` is a human cross-check; authentication status and session
token totals do not establish remaining included quota.
[CLI reference](https://code.claude.com/docs/en/cli-reference).

At `xai-org/grok-build@72a61251fcffb464bcc687aeb5a998e5a98ec0c9`, the official
billing handler uses `GET /billing?format=credits` through its CLI proxy with
bearer authentication and a same-record user id. Included usage, prepaid
balances and on-demand values remain distinct. This differs from quotabot's
existing gRPC-web route; the source does not prove the old route has retired.
[Billing source](https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/extensions/billing.rs).
The auth gate admits first-party sessions, not every API-key or customer-OIDC
record in the host file. Validate issuer, scope and personal/team principal
before implementing the new transport. Email alone cannot identify a pool.
[Auth model](https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/auth/model.rs).

## Shared retry and diagnostic contract

Store only bounded local retry metadata, keyed to the exact supported identity:
attempt category, status, attempt time and absolute earliest next request. A
credential generation is a narrower claim than a proved subscription pool.
Unknown identity must not authorize joining credentials or borrowing quota.

Use one owner per in-flight read across processes. A caller timeout does not
prove that its underlying request ended. Keep ownership until confirmed
settlement or cancellation. Manual refresh, focus recovery and cache expiry
must not bypass a valid provider deadline. Retry-After is a lower bound, not a
promise about when a particular UI will run.
[HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3).

Deferred reads retain last-known quota as stale and unavailable, with its original
capture time and no new analytics sample. A successful eligible read clears its
own cooldown. Another healthy account can refresh independently. Tests must
cover concurrent callers, long headers, clock changes, invalid local records,
credential replacement, a late raw request, and zero requests before a deadline.

A future explicit diagnostic-copy action should expose the running version,
last attempt versus last successful capture, cadence, next due reason and bounded
failure. It should copy existing metadata without collection or telemetry, and
exclude credentials, account labels, provider bodies and arbitrary exceptions.

## Remaining lifecycle work

Synthetic OAuth settlement and MCP shutdown are implemented in unreleased
source. Claude, Codex, Grok, and Antigravity token POSTs keep the refresh
guard until the original request settles, persist a late 200 rotation, and
leave publication deadlines with the adapter. Desktop close and MCP shutdown
drain those grant transactions with original adapters and metadata read gates.
MCP also stops new snapshot admissions and retires the shared HTTP client so a
late continuation cannot open a new pool; a bounded drain timeout does not skip
that retirement.

Real idle-machine and original display-disagreement evidence remain distinct
from these reproducible regressions. Whole-process exit still releases native
ownership; that is not a substitute for the isolate-local retirement path.
