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

## Bounded Python gate

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
