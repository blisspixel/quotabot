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

The [exact-main Windows gate](https://github.com/blisspixel/quotabot/actions/runs/38174988308/job/114575378069)
at `5fc3831a6cbafd8b0ae9afe42eacb45b96dac609` subsequently timed out on
unterminated UTF-8 overflow after ten seconds. The fixed diagnostic confirmed
the real CLI main function had returned. That does not establish whether the VM,
its launcher, or the parent's exit-notification delivery was still active.
Publication remains held. The fixture now records its VM PID and captures a
bounded Windows process snapshot before teardown on an exit timeout. Inspection
reports only selected PIDs, parent PIDs, executable names, and observed presence;
it does not close target stdin, extend the original exit deadline, or print
arguments, environment, credentials, or raw inspection errors. Inspection has
its own short deadline and kills and reaps its owned helper on timeout. A native
test checks the same observation against an owned live child and after its exit.

The [first process-snapshot run](https://github.com/blisspixel/quotabot/actions/runs/38177021457/job/114581447175)
at `90830cfe5e652f64813b280f6cfd6351416602e6` captured both the launcher
and its VM child still present after CLI main returned on unterminated overflow.
This excludes a launcher-only or parent-notification-only explanation for that
observation. It does not identify the remaining VM resource. The diagnostic
fixtures now enable the pinned VM's fixed `--trace-shutdown` phases. Timeout
reporting starts at the last fixture main-returned marker so earlier launcher
cleanup cannot obscure the child VM's later phases. A trace before global
cleanup and one within global cleanup have different implications; neither is
automatically proof of a stdin defect. The
[pinned trace implementation](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/vm/dart.cc#L599-L755)
reports shutdown phases without a debug service, heap dump, or application data.
Windows retains untraced controls for both oversized-input forms and HTTP signal
shutdown alongside the traced cases. They use the same assertions, open stdin,
and exit deadlines. Passing only with tracing would be diagnostic evidence of
an instrumentation-sensitive result, not proof that the lifecycle is fixed.

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

## Tagged release recurrence

The [comparison PR gate](https://github.com/blisspixel/quotabot/actions/runs/38180972710)
and [exact-main gate](https://github.com/blisspixel/quotabot/actions/runs/38183206726)
passed with both traced and untraced open-stdin controls. The protected
`v0.11.12` tag points directly to `b00cb743b8a1b412b454cc30e826378827bb98e0`.
Its [tagged Windows gate](https://github.com/blisspixel/quotabot/actions/runs/38185720265/job/114607519058)
then timed out in the traced HTTP signal fixture after its unchanged twenty-second
exit deadline. Both launcher and VM remained present after fixture main returned.
No post-main shutdown phase was captured. The tag remains unpublished, and
0.11.11 remains the verified Latest release. No failed job was rerun.

The absence of later trace output does not establish that cleanup was never
entered: pinned [`StartCleanup`](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/vm/dart.cc#L101-L115)
precedes the first shutdown trace and may wait for active API calls. The remaining
lifetime still needs direct evidence. Passing
native AOT checks cannot establish the state of the source-JIT kernel path.

An [upstream June 22 change](https://github.com/dart-lang/sdk/commit/dd8cd808fac16a61908ad5a1569bc1fa0f6b1c52)
waits for asynchronous VM service and kernel startup before transitioning into
cleanup. The pinned path lacks that wait. Its stated startup/cleanup race is a
candidate, but the failed runs did not capture the required startup state or
later cleanup phases. The change spans both newer runtime-service and legacy
service paths. A matching shutdown symptom alone does not establish its trigger
here; no toolchain change or speculative application workaround was taken.

The next diagnostic keeps existing traced no-service cases and untraced controls,
and runs separate service-enabled cases first so fail-fast cannot skip their
comparison. Service startup is awaited and can change the race; instrumented
success alone is not a correction. A parent-owned, owner-only temporary directory
holds the authenticated numeric-loopback URI, expected VM PID, and main-isolate
ID. DDS and service URL output are disabled. The handoff is removed when consumed.

After the original exit deadline fails, native process and VM inspection start
together. VM reads use only the pinned protocol's
[`getVM`, `getIsolate`, and `getPorts`](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/vm/service/service.md),
with PID verification before isolate requests, one three-second request/body
budget, a 64 KiB response cap, direct connections, disabled redirects, and owned
client closure. Output contains fixed booleans, capped counts, allowlisted pause
kinds, and port categories. It excludes names, IDs, URI/authentication, source,
allocation locations, raw errors, and objects. No heap or object RPC is used.
Partial verified metadata remains visible if a later inspection request fails.
The original process timeout remains a failure even if inspection cannot connect
or the target exits during observation.

A native negative probe deliberately retains receive ports after main returns.
It checks port detection and private-name suppression. Additional tests cover
invalid endpoint scope, VM PID mismatch, redirects, oversized responses, and
stalled bodies. A socket category can narrow shared native socket ownership;
it cannot identify stdin rather than HTTP or prove a particular leaked handle.

### Captured main-isolate retention

The [instrumented Windows gate](https://github.com/blisspixel/quotabot/actions/runs/38188588751/job/114616209351)
failed on source `15bc90b2a6f8d0dda96ae0531e0700a0fbefbdd1` in the
unterminated UTF-8 overflow case. After the original ten-second deadline and
main-return marker, the PID-verified VM reported one application isolate, two
system isolates, and a runnable main isolate with exactly one live socket event
port. No timer port or debugger pause was present. This occurrence is therefore
main event-loop retention, before isolate shutdown, rather than later global
cleanup. It does not establish the state of the earlier HTTP failures.

Stdin is the leading ownership inference in this fixture: no quota collection
runs, stdout and stderr are synchronous file consumers, and the service owns
its sockets in its system isolate. The port category itself does not identify
the descriptor. The pinned SDK's
[`_Socket` cancellation](https://github.com/dart-lang/sdk/blob/3.12.2/sdk/lib/_internal/vm/bin/socket_patch.dart)
requests receive shutdown through a callback returning `void`. The native close
completion is separate and is not exposed by public `Stdin`. The transport
already awaits subscription cancellation, so repeating that await is not a fix.

Windows [`FileHandle::IsClosed`](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/bin/eventhandler_win.cc#L438-L439)
withholds the destroyed notification while a read or write remains pending.
Its synchronous stdin reader posts completion after `ReadFile` returns.
[`CancelIoEx`](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex)
requests cancellation and does not wait for completion. These source boundaries
justify observing native read completion next; they do not establish a specific
cancellation race or justify a speculative runtime patch.

The exact signed tree passed the complete local Windows gate: 2,374 collector
tests, 455 desktop tests, and line coverage of 92.86 and 87.52 percent. Hosted
Linux and macOS passed. Local success does not override the captured hosted Windows
failure, and publication remains held.

The next narrow discriminator closes the parent's owned stdin writer only after
the original Windows deadline has failed and passive process/VM snapshots have
completed. Writer closure and subsequent exit observation share one second.
Only fixed observation categories and an exit code are reported. The test
always throws the original timeout, even if EOF is followed by process exit.
Recovery would support dependence on the open pipe, without distinguishing a
blocked native read from delayed socket-close delivery. Non-recovery is
inconclusive. Real-child tests cover both an EOF-released process and a process
that consumes EOF but retains a receive port. Final teardown still owns killing
and reaping the process. This is diagnosis, not a production correction.

### EOF follow-up and next ownership probes

The [EOF follow-up Windows job](https://github.com/blisspixel/quotabot/actions/runs/38190677639/job/114622577157)
failed on source `ea33fd55995cceefd3c13b58c630cae38e107f17` in the
untraced, unterminated UTF-8 overflow control. Main returned, but the launcher
and VM remained present after the unchanged ten-second deadline. The parent's
writer closed after process observation; no exit was observed in the subsequent
one-second budget. This negative result is inconclusive. No VM service was
enabled in this control, so the earlier captured socket state cannot be assigned
to this occurrence. Its instrumented comparisons passed, further limiting what
a passing instrumented case alone establishes.

That exact signed tree passed the full local Windows gate: 2,376 collector
tests and 455 desktop tests, with one environment-related skip in each package,
clean formatting and analysis, and 92.86 and 87.52 percent line coverage. Hosted
Linux and macOS passed. Hosted Windows failed; no failed job was rerun and the
release remains held.

The next JIT-only fixture wrappers register one fixed authenticated service
extension. Only after failure, the parent can request a projection of known
stdin ownership and closure booleans. The handler validates the exact method
and matching isolate parameter before inspecting anything, catches exceptions
without serializing them, reads no stdin contents, retains no reflected objects,
and adds no timer. The mirrors import stays outside existing compiled fixture
graphs. The pinned [socket fields](https://github.com/dart-lang/sdk/blob/3.12.2/sdk/lib/_internal/vm/bin/socket_patch.dart)
can distinguish closure not requested, destruction still pending, and stdin
already closed. They cannot expose native pending reads or prove cancellation
completion. Existing VM-only, traced, and untraced controls remain separate.

For failed Windows controls without a service endpoint, an optional bounded
native debugger inspects only the VM identified as the owned launcher's child
by the process snapshot. Microsoft's [`-pvr` mode](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/cdb-command-line-options)
does not suspend the target; explicit `qd` leaves it running. The initial
additional `-pd` option was removed after the compatibility check below.
A fresh owned working directory, fixed command file, local empty symbol path,
disabled network symbols, and disabled shell commands isolate startup. The fixed
[`kc` stack view](https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/k--kb--kc--kd--kp--kp--kv--display-stack-backtrace-)
contains function labels without arguments. Startup and output share three
seconds; both output streams share a 64 KiB ceiling, and bounded cleanup owns
late helper processes. Raw debugger output is never persisted or reported.
Only bounded, allowlisted label-category counts survive. The end marker means
the command sequence completed, not that every stack unwound successfully.
Missing symbols, moving threads, and nearest-export attribution make these
labels suggestive. Missing or incomplete inspection remains inconclusive.

Both observations precede the existing post-failure EOF experiment and always
preserve the original exit timeout. No production lifecycle change is included.

### Fixture clock failure before observation

The [Windows job for signed source `3af8177`](https://github.com/blisspixel/quotabot/actions/runs/38193114323/job/114629913993)
stopped before reaching the MCP cases. The six-adapter Claude sharing test froze
its gate clock during setup, while the adapter captured real time later. Slow
setup made the capture appear future-dated, and the production gate correctly
refused to save a sharing receipt. This run supplies no new shutdown evidence.

The test now aligns its gate clock when the first mocked usage request arrives,
after the adapter has captured its timestamp. Later explicit advances remain
controlled. A deliberate 60-second initial skew reproduces the old failure
without waiting; the corrected seven-test file passes, retaining expiry,
credential replacement, and drift assertions. Production clock admission is
unchanged. Independent review found no concrete flaw in this correction.

The preceding exact signed tree passed the complete local Windows gate: 2,388
collector tests with two environment-related skips, 455 desktop tests with one
skip, clean formatting and analysis, and 92.90 and 87.52 percent line coverage.
The fixture correction requires its own full and hosted gates. Publication
remains held.

The pinned SDK also creates a
[`FILE_FLAG_OVERLAPPED` child stdin handle](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/bin/process_win.cc#L230-L252),
then wraps stdin in a
[`StdHandle` without overlapped support](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/bin/eventhandler_win.h#L319-L320)
and calls
[`ReadFile` with a null `OVERLAPPED`](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/bin/eventhandler_win.cc#L320-L343).
Microsoft's [documented contract](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-readfile)
requires a valid `OVERLAPPED` for an overlapped-opened handle. This source
mismatch deserves upstream investigation, but is not proof of the observed hang.
An isolated local named-pipe experiment observed pending input immediately
after handle closure, then completion before its sole writer closed. A transient
pending-I/O flag therefore does not establish persistent retention or EOF
dependence. Native runtime attribution still requires the failed-run ownership
observations or a minimal pinned-Dart reproduction.

### Confirmed pending stdin destruction

The [Windows job for signed source `ab6215e`](https://github.com/blisspixel/quotabot/actions/runs/38195096487/job/114635882527)
passed the former Claude fixture failure point, then failed the mirrored
unterminated UTF-8 overflow control at its unchanged ten-second exit deadline.
After fixture main returned, the PID-verified VM retained a runnable main
isolate with one socket event port. The stdin projection reported
`controllerClosed: true`, `isClosing: true`, `isClosed: false`, both directions
closed, and `event_port_present: true`. This identifies native stdin destruction
still pending after stream cancellation. It does not distinguish a pending
native read from missing destruction delivery. Native stack inspection was
incomplete. Closing the parent's writer afterward did not produce an observed
exit within one second.

That exact signed tree passed the complete local Windows gate: 2,388 collector
tests with two environment-related skips, 455 desktop tests with one skip,
clean formatting and analysis, and 92.86 and 87.52 percent line coverage.
Hosted Linux and macOS passed; Windows failed. No failed job was rerun.

The unshipped 0.11.13 source now integrates a Windows pipe-only input reader,
retaining the SDK's parser and output transport. One worker turn owns a unique
read buffer and `OVERLAPPED`; an explicit delivery permit bounds read-ahead.
On stop, cancellation retries retain the exact worker thread and storage until
I/O settles. The worker then waits for the parent to revoke cancellation before
releasing resources and returning normally. The original stdin handle is never
closed, and no isolate or process is forced to exit.

The initial direct-FFI prototype was rejected when a multi-chunk JIT trial
reported a failed Windows call with error zero. Eager symbol resolution was
insufficient: the [Dart runtime's documented error-capture limitation](https://github.com/dart-lang/sdk/issues/38832)
allows native error state to change across the FFI boundary. A narrow C bridge
captures the read result and error before returning, keeping blocking calls
non-leaf. Its trials do not establish production acceptance. Complete native
pipe, JIT/AOT, startup, cancellation, late-cleanup, dependency, bundle, checksum,
signing-inventory, missing-library, installation, and hosted evidence is required
before publication. The protected 0.11.12 tag remains unchanged and
unpublished; Latest remains 0.11.11.

### Owned Windows input acceptance

The revised primitive passed JIT and AOT trials against overlapped named pipes
and synchronous anonymous pipes, preserving 256 KiB byte order across delivery
pauses. A deterministic seam pauses the worker after its stop check but before
native read registration. Cancellation first misses; retry cancellation then
settles the registered read while the writer remains open. Disabling retries in
a separate negative control leaves the process alive past its original five-second
deadline. A startup failure with a retained chunk reports a fixed error and
delivers no retained bytes. These are primitive results, separate from release
acceptance.

The maintained Windows suite contains eleven ownership scenarios, with EOF
explicitly closing its writer and cancellation cases keeping theirs open. All
eight existing oversized-input controls pass locally with their original deadlines
and tracing/inspection flags. Independent review corrected early HTTP-fixture
allocation and preserved failure reporting on an internal permit violation.

The native bridge uses a Windows-only [Dart build hook](https://dart.dev/tools/hooks),
with the build dependencies already resolved by each package promoted to direct
collector dependencies. Their compatible constraints retain the original
collector and Flutter lock versions. The compiled CLI bundle includes the bridge
alongside SQLite. Native metadata-only tests pass legacy negotiation, EOF,
unterminated and terminated overflow over both pipe kinds, and a copied bundle
with its bridge deliberately missing. Source-shim fallback now validates native
hooks before replacing any launcher.

The Windows desktop release build also passes locally. Source 0.11.13 remains
pending full contributor gates, installation, hosted platform checks, and
immutable publication. The protected
0.11.12 tag is unchanged. Latest and the installed verified version remain 0.11.11.

### Native Mac baseline

On October 12 UTC, the attested published 0.11.11 arm64 CLI was checked on a
signed-in macOS 27.0 host using Claude Code 2.1.296. A targeted fresh Claude
metadata read succeeded through the existing credential-file fallback. It
reported authoritative live, account-wide evidence, with `stale: false` and
`per_machine: false`. The host credential file was byte-for-byte unchanged.
The isolated temporary CLI and metadata directories were removed afterward;
this was not a global Mac installation or a 0.11.12 artifact check.

The selected default Keychain item was visible, but its bounded secret read
over SSH returned exit 36 without a recognized error category. This does not
prove a locked store, Keychain-only discovery, or idle-machine refresh. No
credential value or account identifier was persisted in the verification
receipt, and no inference request or host-state write was made.

The user confirmed that the Mac and Windows sign-ins use the same subscription
and requested skipping further Keychain validation. That check remains skipped.
A fresh login and the successful credential-file read do not prove refresh after
idle credential expiry, so the idle-machine acceptance boundary remains open.

## October 7 billing update

Rechecked October 11. The [current SDK notice](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) adds monthly API
credits for eligible Max and Team plans; it preserves subscription-authenticated
SDK and print-mode access through plan limits. The separate June SDK-credit
proposal remains unavailable. This supersedes treating the June pause as the
whole current policy.

The [credit guide](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans) distinguishes linked-Console API-key execution
from subscription authentication. Interactive Claude Code and extra usage are
outside this credit pool. Purchased balances, auto-reload, or invoicing can
continue spending after included credits run out.

The [Platform contract](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers) gives Max 5x $100 and Max 20x $200 monthly;
Team receives $20 per Standard or $100 per Premium seat, pooled up to $500.
Credits expire each billing cycle, monthly on annual plans, without rollover
and belong to one linked organization. Auto-reload follows the purchased balance
and can charge even while included credits remain. Eligibility alone is not a measured balance or execution grant.

The existing OAuth usage collector does not collect Console API credits. Keep
those balances separate from subscription headroom. Future support requires
bounded provider-owned balance and expiry metadata, exact organization and
credential scope, and explicit continuation controls before any spend advice.
This research changes documentation, not routing eligibility or collector calls.

## October 12 credential-policy review

Rechecked October 12 UTC with independent review. The current
[credential-use policy](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)
restricts third-party Claude.ai login and collecting, storing, or intermediating
credentials/tokens. The [authentication page](https://code.claude.com/docs/en/authentication#credential-management)
describes Claude Code's own storage and configuration scope; it does not grant
external-reader access. No explicit quota-only exception was found.

Current collection reuses a host OAuth token or refreshes a locally stored grant
obtained through Claude Code's public OAuth client. The default grant requests
`user:profile user:inference`; its storage being quotabot-owned does not prove a
separately authorized third-party client. Reads make no inference calls, but
compatibility with the credential policy remains unresolved. This is evidence
and an implementation-planning limit, not a legal determination or a silent
authentication change. It supersedes the earlier unconditional proposal to
expand Keychain discovery; ROADMAP Next now gates that work on a supported
metadata path or provider confirmation.

Claude Code documents credential-free [status-line quota fields](https://code.claude.com/docs/en/statusline#rate-limit-usage):
five-hour and seven-day used percentages and reset epochs, present for Pro/Max
after an existing session response. Each window may be independently absent and
is dropped after reset. Gateway spend limits are separate. This is a research
alternative, not a shipped collector or a Team/Enterprise entitlement claim.
Never start a model request merely to populate the fields. A future user-configured
projection must exclude session titles, prompt identifiers, transcript/workspace
paths, and raw payloads before quotabot ingestion. Repeated script execution
cannot invent a fresh provider capture; source age and account binding must be
resolved before routing. Session-fed evidence cannot satisfy idle-machine proof.

### Windows desktop checkout paths

The pinned app lock resolves `native_toolchain_c` 0.19.2. Its MSVC invocation
passes absolute source and output paths through `cmd.exe`; the official
[0.19.3 changelog](https://pub.dev/packages/native_toolchain_c/versions/0.19.3/changelog)
identifies and fixes the resulting space-path defect. Existing SDK remapping
does not remap checkout or hook-output paths. BUILDING now requires a space-free
absolute checkout for Windows desktop compilation and names the portable release
fallback. This does not establish a defect in a built desktop artifact. The
collector lock already resolves 0.19.3; overriding Flutter's dependency constraints
or changing its pinned toolchain is not part of this maintenance release.

### Isolated source-smoke compiler discovery

The clean signed `25c389d` local gate passed all 2,399 collector tests with
three platform/environment skips and 91.63 percent line coverage, plus all 455
desktop tests with one skip and 87.52 percent coverage. It then failed the
source MCP harness smoke: the sanitized child environment made `vswhere` report
no installed compiler for the native build hook. A controlled probe found zero
instances with the original environment and one when either `ProgramData` or
`SYSTEMDRIVE` was restored. This was a compiler-discovery failure before MCP
initialization, not evidence of a runtime shutdown failure.

The harness now retains those two machine installation roots while keeping
user, provider, cache, and temporary directories isolated. Its 26 focused tests
pass with the original response and exit deadlines. Independent review found
no weakened catalog assertions or restored user credential scope. The full
corrected-tree gate remains required; the earlier failed receipt is preserved.

### Bounded native debugger compatibility

The [Windows diagnostic smoke on `25c389d`](https://github.com/blisspixel/quotabot/actions/runs/38199697382/job/114650136776)
failed after the MCP lifecycle cases: the optional CDB helper returned incomplete
inspection instead of projected labels. An isolated probe using Microsoft-signed
CDB 10.0.26100.7705 reproduced successful debugger exit without either command
marker. Its fixed startup error rejected detach-on-exit. Removing only `-pd`
retained the documented noninvasive, nonsuspending
[`-pvr` mode](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/cdb-command-line-options)
and explicit [`qd`](https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/qd--quit-and-detach-).
The owned target remained alive.

The corrected probe still exceeded the helper's three-second cumulative budget.
A separate exploratory observation completed in 4.465 seconds, with exit zero,
one exact begin and end marker, 65 accepted export-label frames, and 7,948 output
bytes. That observation establishes parser compatibility for this debugger
version; it is not a pass under the maintained three-second deadline or proof of
the hosted debugger's version. Only fixed counts and outcomes were retained.

The maintained helper keeps its original three-second budget and output cap.
An internal discriminator identifies only its own cumulative deadline; unrelated
timeout exceptions remain ordinary failures. The real smoke requires either
valid projected labels or that exact deadline outcome, then verifies inspector
exit, temporary-directory removal, bounded completion, and target survival.
Nonzero exits, malformed markers, overflow, and launch failure remain rejected;
deterministic successful inspection still requires projected JSON. A real-host
deadline pass proves containment and cleanup, not successful stack inspection.

All 13 focused diagnostic checks passed locally with the isolated Microsoft
debugger present and no skips; the real debugger case reported the deadline
outcome. Formatting and strict analysis passed. Full local and hosted gates on
the corrected signed tree remain required before publication.

### Legacy migration fixture isolation

The clean `f6f5d7f` local gate stopped at the four-length legacy filename test:
the first migration returned `partial` instead of `complete` after approximately
16 seconds. That receipt records 2,395 passed collector tests, three skips, and
one failure; subsequent coverage, desktop, and integration gates did not run.
The test did not retain migration report fields, so the exact reason for that
partial result is unproven. The failed gate remains evidence, not a passing run.

The unchanged test passed separately. A second focused run with coverage also
passed and measured 12.790 seconds for its initial four-record migration, with
four carried records, no invalid or quarantined records, and no truncation.
That shows little margin beneath the unchanged 15-second production budget.
It supports budget-pressure susceptibility without proving the earlier cause.

The filename contract now runs independently for lengths 161, 170, 200, and 220.
Each case still requires completion under the default production limits, one
carried record, canonical hashed filenames, both exact legacy/current lock
domains, no oversize substitution, one quarantined conflict, and unchanged
canonical bytes. Report fields and elapsed time appear only in assertion failure
reasons. Dedicated bulk, bounded-duration, and resumable-progress tests remain
unchanged. Independent review confirmed that all per-account assertions remain.
All six focused checks passed with coverage: the four filename cases plus the
unchanged resumable-progress and bounded-duration cases. Strict analysis and
formatting passed, as did the 24 release-handoff checks. Full corrected-tree
local and hosted gates remain required before publication.

The active setup and strategy documents now distinguish the existing Claude
implementation from unresolved provider-policy compatibility and defer new
grants and expanded discovery. Release 0.11.13 notes explicitly include the
unpublished 0.11.12 MCP maintenance so publication includes its compatibility
and validation changes. The stable release designation remains 0.11.11.
