# Code quality and defensive behavior review

Reviewed 2026-09-30 against the 0.11.6 source tree and current working changes.
This is an evidence record. [ROADMAP.md](../../ROADMAP.md#next) owns priorities.

## Actual verification baseline

The collector and desktop already enable Dart `strict-casts`,
`strict-inference`, and `strict-raw-types`, together with recommended ecosystem
lints and correctness rules for unawaited futures, thrown values, and finally
blocks. CI requires no analyzer findings and line coverage of 90 percent for
the collector and 80 percent for the app. The small TypeScript MCP project
already sets `strict: true` and runs `tsc --noEmit`. These checks should remain
in place. Dart's [analysis documentation](https://dart.dev/tools/analysis) and
TypeScript's [strict option reference](https://www.typescriptlang.org/tsconfig/strict.html)
describe the actual checks; a strict setting does not validate incoming JSON.

Python previously had Ruff, integration tests, and release-policy tests without
a static typing gate. Ruff explicitly documents that it is a
[linter rather than a type checker](https://docs.astral.sh/ruff/faq/).
An exploratory mypy run on `tools/` and `integrations/` reported 389 findings
across 43 of 62 files. That inventory used `--follow-imports=skip` to bound the
survey, so it is a debt estimate rather than a proposed passing gate. Many
findings are untyped test helpers and raw collections; production tools and
LiteLLM also contain typing debt. It would be inaccurate to call all Python
strictly checked.

## Findings and disposition

| Finding | Evidence and consequence | Disposition |
|---|---|---|
| LiteLLM runtime pin is in a newly disclosed affected range | The September 30 [provider advisory](https://github.com/BerriAI/litellm/security/advisories/GHSA-7hp6-4w63-5g45) lists 1.92.2 in the affected range for proxy privilege escalation. Configured internal users and the vulnerable authentication path are required; this review did not exploit a deployed proxy. | Update to patched stable 1.102.2 and regenerate the universal hashed lock. This line preserves MCP v1 while latest 1.103.1 forces MCP v2. Preserve Python compatibility and run the installed fake proxy and routing suite before completion. Existing deployments are not updated by a repository edit. |
| Python MCP v1 dependency and snippet floor admit affected versions | September 28 upstream advisories affect the old 1.28.1 lock and documented 1.29 minimum: [external schema references](https://github.com/modelcontextprotocol/python-sdk/security/advisories/GHSA-rwrf-2pqf-9j8j) and [OAuth issuer confusion](https://github.com/modelcontextprotocol/python-sdk/security/advisories/GHSA-qx49-fqc8-xw99). The supplied snippets use owned loopback/stdio servers and bearer auth rather than OAuth. | Pin the existing dependency to patched 1.30.0 and require at least 1.30 for snippet installs, preserving v1 compatibility. Do not claim a demonstrated exploit against the minimal example. |
| Fixed LiteLLM deployments could lease a different account | A candidate without `account` sent a provider wildcard; the server could select account B while the unchanged deployment authenticated as A. Local metadata would then claim B's headroom and discount B's lease. | Working-tree fix binds a provider-only candidate to the single observed account and sends an exact account target. Multiple or unknown accounts require an explicit deployment mapping; owned mismatched or missing-account leases are released and rejected. |
| Python helper boundaries admitted unchecked types | Plugin configuration returned raw `dict`; parsed templates were `Any`; harness executable selection could reach a statically optional path. A truthy non-container MCP `content` value could raise during iteration. | Working-tree fix uses `object` at JSON boundaries, validates the plugin's required object layers, accepts MCP text content only from list or tuple containers, and gives MCP summaries a `TypedDict`. Malformed content returns an empty result while direct structured content still wins. A maintained five-file strict gate rejects explicit `Any` and needs no new ignores. |
| Windows contributor gate accepted a different toolchain | SDK discovery checked paths and snapshots, while `python` came from PATH without a runtime comparison. | Working-tree version preflight now checks the canonical Windows gate; discovery alone must not be called pinned-toolchain evidence. |
| Local read timeouts retained connections | `LmStudioAdapter._get` and Ollama metadata calls used `Future.timeout` around requests on the shared client. A deadline stopped the caller waiting but did not abort the request. | Confirmed with an isolated stalled loopback socket: LM Studio left three active connections after one collection and six after the second. Working-tree fix extracts the existing cooperative HTTP cancellation implementation into the shared HTTP seam and uses it for these local reads. Tests prove stalled-header and partial-body requests close, the client remains usable, and LM Studio still recovers through its v0 fallback. |
| Lease weight accepted non-finite configuration | `Policy(lease_weight_percent=math.nan)` returned a policy containing NaN because range comparisons alone cannot reject it. | Working-tree finite-number validation rejects NaN and infinity at the existing bounded-number parser, with regression tests. This was configuration correctness debt, not evidence of a paid dispatch: the server still rejected the invalid mutation. |

The deployment-to-credential relationship remains the operator's configuration
responsibility. An exact account label or digest is a quota identifier, not
cryptographic proof that a LiteLLM credential belongs to that account. The
single-account convenience does not switch credentials. Grouped aliases,
fallbacks, and retries also require consistent execution and spend policy.

## Current tooling and dependency maintenance

Primary package and release sources were checked on the review date. The
tested toolchain and latest upstream releases are separate facts.

| Component | Checkout and current upstream evidence | Decision |
|---|---|---|
| Flutter / Dart | Pinned 3.44.6 / 3.12.2; upstream stable Flutter 3.47.5 and standalone Dart 3.13.5 | Preserve the tested pair. The independently current versions do not establish a bundled pair. [Flutter stable](https://api.github.com/repos/flutter/flutter/commits/stable), [Dart metadata](https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION) |
| Dart HTTP | Pin and latest 1.6.0 | Its abortable API is the existing cancellation seam. [Changelog](https://pub.dev/packages/http/changelog) |
| MCP Dart | Locked 2.2.2; latest 2.4.2 | Keep the queued protocol migration deliberate: protocol defaults and tool-error behavior change, while 2.4.2 bounds incoming frames. [Changelog](https://pub.dev/packages/mcp_dart/changelog) |
| SQLite Dart | Locked 3.5.0; latest 3.7.0 published September 30 | Review native SQLite, platform compatibility, and packaging separately. No SQLCipher exposure was established. [Changelog](https://pub.dev/packages/sqlite3/changelog) |
| TypeScript and MCP TS | Compiler pin/latest 7.0.2; SDK pin 1.30.0, maintained v1 latest 1.31.0 | Keep the verified v1 client contract. New server-body and OAuth changes do not establish an exposure in direct bearer clients. [Compiler registry](https://registry.npmjs.org/typescript/latest), [SDK release](https://github.com/modelcontextprotocol/typescript-sdk/releases/tag/1.31.0) |
| LiteLLM | Baseline 1.92.2; selected patched 1.102.2; latest 1.103.1 | Preserve MCP v1 during security maintenance; the newer dependency line requires MCP v2. [Selected metadata](https://pypi.org/pypi/litellm/1.102.2/json) |

The selected hashed runtime also updates existing AnyIO to 4.14.2, PyJWT to
2.14.0, OAuthLib to 4.0.0, and RestrictedPython to 8.5. Maintainer evidence covers
[AnyIO TLS handling](https://github.com/agronholm/anyio/security/advisories/GHSA-82r6-8w77-94w6),
[JWT validation](https://github.com/jpadilla/pyjwt/security/advisories/GHSA-w2cx-738m-mc7w),
[OAuth fixes and provider-side changes](https://github.com/oauthlib/oauthlib/blob/v4.0.0/CHANGELOG.rst),
and [RestrictedPython escape handling](https://github.com/zopefoundation/RestrictedPython/security/advisories/GHSA-hp3v-5vw7-fx9w).
Eight existing pins change and six packages required by LiteLLM are added;
unrelated versions remain fixed. The published OAuthLib 4.0.0 is used because
the advisory's named 3.3.2 patch is absent from PyPI. Provider-side OAuth features
are not used by the example and need separate validation if enabled.

Hash-enforced installation, `pip check`, all 59 router/proxy tests, SDK transport
imports, and byte-identical lock regeneration passed. Real SDK 1.30.0 calls to
the compiled CLI also validated three quota/routing tool results using synthetic
data and isolated configuration. These are compatibility and maintenance checks,
not an exploit reproduction or a comprehensive security audit.

## Original 0.11.7 bounded Python gate

`mypy.ini` checks these maintained boundaries with normal import analysis,
`strict = True`, Python 3.10 syntax compatibility, and
`disallow_any_explicit = True`:

- Harness configuration rendering.
- Agent Plugins configuration preparation.
- Shared Python MCP response and routing-summary handling.
- Coverage-floor verification.
- Release-version consistency verification.

This scope supplies a real baseline without suppressing existing findings or
claiming the router, transport SDKs, release toolchain, and tests are fully
typed. `disallow_any_explicit` prevents explicit `Any` annotations; it does not
prohibit the implicit `Any` returned by SDK reflection or `json.loads`.
Required object layers and content containers are validated before use, and
MCP results cross into `object` before field narrowing. Extend the scope by
validating and typing coherent subsystems as they
are changed. Mypy's [existing-code guidance](https://mypy.readthedocs.io/en/stable/existing_code.html)
supports bounded adoption; its [dynamic-typing guidance](https://mypy.readthedocs.io/en/stable/dynamic_typing.html)
explains why unchecked `Any` can otherwise conceal mistakes.

[Mypy 2.3.1](https://pypi.org/project/mypy/) is the current stable release,
published August 15, 2026. Development requirements pin it and Ruff 0.15.16
separately from the integration's runtime dependencies. The universal hashed
lock uses the repository's existing requirements format, verified against
[uv's lock compilation documentation](https://docs.astral.sh/uv/pip/compile/)
and the installed tool's help. Regenerate it from the repository root with:

```text
uv pip compile --universal --generate-hashes --no-header --python-version 3.10 --output-file tools/requirements-dev.txt tools/requirements-dev.in
```

The normal gate installs and checks it with:

```text
python -m pip install --require-hashes -r tools/requirements-dev.txt
python -m mypy
```

## Evidence and practical limits

The reviewed helper changes pass the normal strict gate, Ruff lint and format,
20 harness configuration tests, 15 MCP snippet tests, 16 Agent Plugins tests,
and 14 coverage/version tests. The account-boundary fix passes 58 router tests,
including direct reservation tests that reject ambiguous inventory before any
credential read or mutation, preserve explicit-account priority, bind the
single-account target, and release an owned lease returned for another or
missing account. Explicit blank account declarations now fail configuration
validation rather than silently becoming wildcard targets. The same router
suite verifies non-finite lease-weight rejection. These checks make no
inference request.

The local connection-retention reproduction uses a disposable loopback TCP
listener, the pinned Dart toolchain, and only the LM Studio metadata paths. It
does not read host credentials, install models, or invoke inference.
The cancellation extraction passed 49 focused HTTP, provider-read-gate, LM
Studio, and Ollama tests, including the existing test that an abort-ignoring
client retains its guard until original settlement. An additional native LM
Studio fallback regression passes, and the collector analyzer reports no
issues. Caller-supplied clients remain caller-owned and may ignore abort;
the adapters retain a bounded caller timeout while the real shared client
cooperatively cancels its original request and response body.
Native provider-account validation, deployment credential ownership, cross-OS
packaging, and hosted CI are separate evidence. The root verification receipt
must record their actual outcome after the complete tree is integrated.

## Architectural guidance supported by this review

Keep [CLAUDE.md](../../CLAUDE.md) as the canonical editing contract and the
transport usage guide in [AGENTS.md](../../AGENTS.md). Existing normalized
models, pure parsing and routing, injected I/O, request cancellation, read
coordination, temporary test state, schema contracts, and lease ownership are
the correct seams. Strengthen their invariants with focused tests instead of
adding parallel configuration, HTTP, persistence, or policy implementations.
The remaining Python typing scope and local deadline evidence should be visible
in the existing roadmap, with no second execution queue in this report.

## Second round against 0.11.7

The follow-up reviews the released source
`c8aab69b3f2aefea2b07f59d7495248992034073`. Its
[main CI](https://github.com/blisspixel/quotabot/actions/runs/36741772919),
[immutable release](https://github.com/blisspixel/quotabot/releases/tag/v0.11.7),
and [published install smoke](https://github.com/blisspixel/quotabot/actions/runs/36761142909)
passed. That evidence establishes the starting release, not the new patch.

| Confirmed defect | Correction and regression evidence |
|---|---|
| Explicit provider model requirements bypassed local fallback; an unrelated loaded model could supply readiness | Shared capability gates now include local entries only for explicit requirements and derive readiness from matching available models. Policy and live/cache MCP regressions preserve unfiltered compatibility and negative admission evidence. |
| Sparse shared and scoped spent gates could report an earlier recovery reset | Select the latest spent reset, with unknown recovery dominating, while keeping minimum measured headroom. Tests cover unequal percentages within the spent floor and both unknown-reset orders. |
| LM Studio loaded context fell back to advertised maximum and depended on first-instance order | Preserve model maximum separately; loaded instances contribute their declared context only. Missing or malformed context remains unknown, and coherent instances use the conservative minimum in display and routing. The [official model list](https://lmstudio.ai/docs/developer/rest/list) documents the distinct fields. |
| Lemonade collections could hide remote components | Bounded traversal validates exact declared component identities against embedded model metadata. Known cloud scope vetoes local budgets; unresolved scope is omitted with a count-only diagnostic. The [tagged serializer](https://github.com/lemonade-sdk/lemonade/blob/v2026.39.1/src/cpp/server/server.cpp) and [recipe registry](https://github.com/lemonade-sdk/lemonade/blob/v2026.39.1/CMakeLists.txt) establish these fields. Complete supported non-cloud components retain legacy classification, not positive physical-device proof. |
| Local metadata could follow redirects outside its loopback scope or accumulate an unbounded body | All three local adapters disable redirects and cap streamed bodies at 4 MiB. Real socket tests prove cancellation and reusable clients. Lemonade now shares the process client and abortable request seam, including retirement during fallback. |
| Ollama partially accepted malformed capability arrays | Invalid siblings invalidate capability evidence as a whole; independent upstream exclusions remain. Pure and adapter regressions preserve valid empty declarations and prevent malformed arrays from qualifying a model. |
| LiteLLM socket idle timeout could be extended indefinitely by trickling headers or bodies | One strict-checked standard-library transport owns the connection and cumulative deadline, including proof, TLS, framing and body. Native tests exercise slow reads, bounded caller wait, socket closure, cancellation, fallback and fail-closed managed routes. |
| Reserve and release loaded credentials on the async event loop before their deadline | Credential preflight runs in the bounded worker. Heartbeat and expired-preflight regressions preserve responsiveness; rejected owned leases use the original credential for cleanup. |
| Installed-proxy teardown depended on process enumeration and could leave a child holding its log | Test-only Windows job ownership starts before CLI work and checks descendant termination and exclusive log release. The [Windows job contract](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) establishes inheritance and kill-on-close behavior. Native cleanup regressions retain the actual proxy authentication, routing and lease assertions. |
| Release creation immediately depended on a second listing and upload tag lookup | Validate the POST creation response, then upload by numeric release ID. Preserve all exact owner/source, asset identity, fresh download and provenance gates. The [release API](https://docs.github.com/en/rest/releases/releases#create-a-release) returns the draft and the [asset API](https://docs.github.com/en/rest/releases/assets#upload-a-release-asset) accepts raw binary uploads for that ID. Regressions cover delayed listings, malformed draft identity, safe resume, and RC Latest preservation. |
| Missing optional analytics storage made otherwise valid HTTP advice return 500 | The shared per-account history boundary retains an unknown fit on filesystem failure, preserving fresh measured quota and limited-confidence receipts. Synthetic unavailable-owned-storage tests retain quota, admission, drift and lease gates. |
| Tests reached default user analytics storage and recursively listed generated caches | Local-server fixtures isolate per-case config. The audit prunes exact derived directories before descent, still detects violations across all maintained roots and extensions, and propagates maintained-source read failures. |

The strict Python gate grows from five to six modules by extracting the actual
loopback transport, replacing the previous implementation rather than adding
a parallel client. Normal import analysis and explicit-`Any` rejection remain
enabled. The SDK-facing router and other Python tooling still have typing debt;
this is not whole-project strict typing.

Independent review reran the release, transport and parser regressions. Tests
use disposable local listeners and synthetic metadata, with no inference or
host-credential mutations. Full-tree gates, native packaging, hosted CI, and
published installation are subsequent evidence. Native runtime producer
identity and live provider-account recovery remain open in ROADMAP Next.

The suite passes 78 router tests, one installed fake-proxy test, and two
Windows cleanup regressions on Python 3.13.15 and the supported Python 3.10.11
floor with the unchanged hashed runtime. The proxy test copies both modules
and isolates its import path. Three startup regressions confirmed that
delayed token preflight or TLS context setup could start a fresh deadline after
the caller expired. One absolute deadline now propagates through the worker and
starts before transport construction; expired initialization cannot connect or
dispatch. Reserve and release also keep token-file reads off the event loop.
Independent review passes all 27 transport and lease tests, plus both Windows
cleanup regressions and the installed proxy. Bundled SDK cost metadata avoids
an unrelated network bootstrap in these synthetic fixtures.

An OS filesystem or resolver call can outlive its asynchronous caller. The
worker rejects later initialization and closes any expired eventual socket
before TLS, metadata, or bearer dispatch. Active sockets are owned and closed
by the cumulative deadline. This limit is distinct from bounded routing wait;
Python threads cannot forcibly cancel that operating-system work.

### Second-round local verification

The frozen Unreleased source passed with Flutter 3.44.6, Dart 3.12.2, and
Python 3.13.15. Dependency resolution used cached packages with enforced
lockfiles because the managed network blocked the normal advisory request.
The full portable script did not complete in that environment; its native
analysis, test and coverage steps ran separately with unchanged checks.

| Check | Result |
|---|---|
| Collector | Format and strict analysis clean; 2,183 passed, one Windows directory-link skip; 92.74 percent line coverage (16,710/18,019) |
| Desktop | Format and strict analysis clean; 420 passed, one existing skip; 87.25 percent line coverage (5,521/6,328) |
| Python static checks | Ruff lint and format clean; six strict modules with explicit `Any` forbidden; installed dependency checks pass |
| Tools and release policy | 338 tests with 12 platform skips; final affected release/version/coverage checks pass 69 tests with one platform skip |
| MCP snippets and plugin | Strict TypeScript no-emit check; 15 client tests; 17 plugin tests with one opt-in native-launch skip |
| Compiled CLI and harness | Windows CLI build; isolated doctor, capability-filtered provider advice and local model schemas; real MCP 1.30.0 snapshot/provider/model calls; 26 harness tests |

The full run found unisolated local-server history reads and generated audit
directory traversal. The correction isolates owned test state, preserves every
maintained source root, and makes optional failed account history explicit
unknown evidence. Windows file-lock regressions exercise canonical buckets,
legacy buckets, migration metadata and ownership markers, then prove recovery.
The desktop regression retains incomplete storage and routed metrics while
requiring exact-account zero samples, null burn and null uncertainty.

Hosted three-OS CI, release packaging and published installation remain separate
evidence. Stable is still 0.11.7. Preparation for 0.11.8 remains in ROADMAP Next:
artifact downloads failed and the Sigstore verifier could not initialize in
this environment. The canonical owner publisher must retain its fresh-download,
attestation and immutable-publication gates.

## October 1 integration follow-up

The final load-certainty and desktop-polish pass preserves inventory eligibility
independently of residency. Failed or incomplete observations remain unknown;
they cannot establish cold state, context, or hardware fit. Positive partial
observations retain loaded state while withholding unproven context. Matching
model requirements constrain both advice and fallback. The frozen source passed
2,283 collector tests with 92.78 percent line coverage and 444 desktop tests with
87.38 percent coverage, each with one existing Windows link-permission skip.
Both strict analyzers and formatters passed. Five rendered real-font desktop
scenarios, including narrow layouts at 2x text, were inspected. These are widget
and synthetic runtime checks, separate from native account validation.

Hosted [PR 151](https://github.com/blisspixel/quotabot/pull/151) found an implicit
TLS policy in the extracted Python metadata transport. The fix explicitly
requires TLS 1.2 or newer while retaining certificate and hostname verification,
socket ownership, and the cumulative deadline. Its regression coverage checks
the real context and explicit policy assignment; the 79 router tests passed on
Python 3.10 and 3.13.

The October 1 dependency review selected compatible stable security patches:

- [PyJWT 2.15.0](https://github.com/jpadilla/pyjwt/releases/tag/2.15.0) repairs
  malformed pre-verification payload handling described in
  [GHSA-42vr-xj54-vc7v](https://github.com/jpadilla/pyjwt/security/advisories/GHSA-42vr-xj54-vc7v).
- [urllib3 2.8.0](https://github.com/urllib3/urllib3/releases/tag/2.8.0) repairs
  chunk-size buffering, Deflate streaming, and HTTPS proxy TLS configuration.
  Its proxy trust separation is intentional; the quotabot metadata helper uses
  direct loopback sockets.
- [fast-uri 3.1.8](https://github.com/fastify/fast-uri/releases/tag/v3.1.8) repairs
  percent-encoded host normalization.
- [ip-address 10.7.3](https://github.com/beaugunderson/ip-address/releases/tag/v10.7.3)
  includes corrected family and link-local classification and bounded parsing.

Native lock regeneration changed only those four package records and the
explicit urllib3 input. LiteLLM 1.102.2, MCP 1.30.0, and unrelated pins remain.
Fresh hash-locked Python 3.10 and 3.13 installations each passed all 82 router
and real proxy tests with no skips, plus dependency consistency and malformed
JWT controls. Audits covered all applicable locked rows, 111 and 109
respectively, with no reported vulnerabilities or skipped packages. The MCP
examples passed strict TypeScript checking, 15 tests, focused URI and address
controls, and an npm audit reporting no vulnerabilities. These results establish
compatibility and known-advisory remediation, not absence of undisclosed issues.

Source preparation for 0.11.8 keeps the published stable markers at 0.11.7
until owner publication. A single exact pending-publication marker admits that
bounded preparation state without relaxing source, build, stable-coherence, or
tag checks. Hosted CI, the native release matrix, immutable owner publication,
and published installation remain separate completion gates.

The macOS job in [CI run 36957253600](https://github.com/blisspixel/quotabot/actions/runs/36957253600)
passed strict analysis, coverage, and native packaging before exposing a
timing-sensitive shared-deadline fixture. Its sleeps could exhaust the budget
before the second request. The replacement charges a controlled transport clock
before each real HTTP response while retaining proof and authenticated metadata
requests. An over-budget case and successful control verify the single deadline
without depending on runner scheduling. All 79 router tests pass on Python 3.10
and 3.13; 20 focused repetitions pass on each, and a temporary per-phase deadline
reset is rejected. Real socket, drip, TLS, and initialization timeout regressions
remain unchanged. This is a fixture correction, not a production deadline change.

The same run's Windows job passed native packaging and desktop readiness, then
exposed certificate-store initialization consuming a late-TCP fixture's short
budget before connection. That fixture now prepares its trusted context first,
establishes a real TCP socket, and advances only the transport clock past its
deadline. It requires socket closure with no TLS wrapping. The active-handshake
fixture also prepares its trusted context before timing the real handshake.
Both runtime suites pass; 20 late-TCP repetitions pass on each Python version,
and removing the pre-TLS deadline check is rejected. Constructor and worker
preflight deadline regressions continue to test initialization separately.

### Settings interaction follow-up

The October 1 settings review rendered the actual dialog with synthetic data
and real fonts. Its provider block consumed most of a normal window, leaving
display, alert, and update controls below the visible area. Large text truncated
action labels. A focused layout now uses typed Providers, Display, Alerts, and
Updates categories, a narrow-window selector, fixed navigation and Close, and
an owned visible scrollbar. Existing preference and update handlers remain in
the dashboard; the presentation lives in `app/lib/settings_dialog.dart`.

The pinned Flutter 3.44.6 analyzer and formatter pass. The full desktop suite
passes 449 tests, with one existing Windows link-permission skip, and 87.46
percent line coverage (5,627/6,434). Category selection, keyboard activation,
resize continuity, one desktop scrollbar, scroll reset, narrow
260x360 and 320x520 layouts at 2x text, account privacy, notification recovery,
and manual update behavior retain regression coverage. Real-font dark, light,
wide, hacker, and narrow renders were inspected. These are widget and synthetic-data
checks, separate from native keyboard and screen-reader validation.

The interaction choices follow current Flutter guidance for
[single category selection](https://api.flutter.dev/flutter/material/ChoiceChip-class.html),
[owned visible scrollbars](https://api.flutter.dev/flutter/material/Scrollbar/thumbVisibility.html),
and [accessible targets and text scaling](https://docs.flutter.dev/ui/accessibility).
The implementation uses the pinned toolchain rather than changing framework
versions for this layout work.

The native Windows release package also builds successfully. Its isolated
readiness check reports a ready window and tray, stops the test process, and
confirms the complete bundle stayed unchanged. This proves packaged startup,
not Narrator behavior or native interaction on every supported platform.

Canonical source setup installed CLI 0.11.8 and desktop 0.11.8+63 on the
Windows review host. The first activation encountered a file lock and retained
the previous desktop. Closing the installed app before retry allowed setup to
activate both payloads and restart the new desktop. Saved preferences and the
default profile hashes stayed unchanged. This installation smoke does not
establish account-consumption accuracy or native screen-reader behavior.

After immutable publication, canonical installation replaced both source-built
payloads with the official 0.11.8 release. Fresh checksum and workflow
attestation checks passed for the Windows CLI and desktop archives. All four
installed CLI files and all 20 desktop files match those archives. The same two
saved settings files remained unchanged, `doctor` passed, and desktop 0.11.8+63
restarted successfully.
