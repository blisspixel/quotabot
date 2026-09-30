# Claude and Codex quota review

Observed 2026-09-30. This review uses fetched provider documentation and the
repository source. It did not read host credentials, contact authenticated
quota endpoints, or run inference. Public policy, implemented parsing, and
real-account validation remain separate evidence. Recommendations belong in
[ROADMAP.md](../../ROADMAP.md#next), not in another execution queue.

## Findings that change current guidance

1. Claude's announced separate Agent SDK monthly credits are paused. Current
   subscription-authenticated SDK, print-mode, and third-party app use still
   draws subscription limits. API-key billing remains separate.
2. The inspected catalog was refreshed September 2. Claude Opus 5.5 and Sonnet
   5.5, GPT-6 Astra/Sol/Luna, and GPT-6.1 Sol need a curated refresh.
   GPT-5.3-Codex-Spark is already retired from supported subscription clients.
3. Claude now documents optional limit resets that can refill a weekly balance
   without changing its normal reset schedule. Current monotonicity rules would
   quarantine that particular transition without additional evidence.
4. Current Codex policy explicitly has no five-hour limit on Pro. The shipped
   duration-based parser and observed weekly-only migration support match this;
   plan names must not manufacture missing windows.

## Claude billing correction

The current [Agent SDK plan article](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
is dated June 16 and begins with a June 15 pause notice. It says SDK,
`claude -p`, and third-party use continue to draw subscription limits, and the
previously announced monthly credit is unavailable. The rest of the article
preserves the old proposal and explicitly says it is no longer taking effect.
The pause notice governs; the historical credit table does not establish a
current allowance.

The following inspected locations read the superseded proposal as current:

| Location | Correction |
|---|---|
| `AGENTS.md`, opening harness advice, lines 19-23 | Remove the assertion that a separate SDK/headless credit balance currently exists. Keep actual authentication, supported provider access, and billing-surface checks. |
| `ROADMAP.md`, Next step 7, lines 219-222 | Replace separate headless-credit wording with verification of the harness's actual subscription or API authentication, account, and paid-continuation controls. |
| `docs/research/2026-09-13-next-review.md`, Claude row, line 76 | Add a dated correction pointing to the pause notice. Preserve the old record as superseded evidence. |

Suggested standing wording: "Match advice to the harness's supported access,
authentication, and billing surface. Anthropic's current notice pauses the
announced separate SDK credits; subscription-authenticated SDK and print-mode
use still draws subscription limits. API-key usage has separate API billing.
Quota advice does not establish credentials, account access, disabled paid
continuation, or permission to dispatch."

This correction does not justify using print mode for collection. The
collector still must never invoke a prompt-execution surface to fetch quota.

## Verified catalog fields

The following fields are suitable for the existing `ModelInfo` capability
catalog. Tier values are quotabot's comparative heuristic, not a provider
entitlement. Context/output figures describe published model specifications;
they do not establish account access, an actual client context setting, or
remaining subscription quota.

| Provider | ID and display name | Context | Max output | Tools | Vision | Reasoning | Suggested existing tier | Primary specification |
|---|---|---:|---:|---|---|---|---|---|
| Claude | `claude-opus-5-5`, Claude Opus 5.5 | 1000000 | 128000 | true | true | `adaptive` | `flagship` | [Opus 5.5](https://platform.claude.com/docs/en/models/opus-5-5/overview) |
| Claude | `claude-sonnet-5-5`, Claude Sonnet 5.5 | 1000000 | 128000 | true | true | `adaptive` | `standard` | [Sonnet 5.5](https://platform.claude.com/docs/en/models/sonnet-5-5/overview) |
| Codex | `gpt-6-astra`, GPT-6 Astra | 1050000 | 128000 | true | true | `reasoning` | `flagship` | [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) |
| Codex | `gpt-6.1-sol`, GPT-6.1 Sol | 1050000 | 128000 | true | true | `reasoning` | `flagship` | [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol) |
| Codex | `gpt-6-sol`, GPT-6 Sol | 1050000 | 128000 | true | true | `reasoning` | `flagship` | [GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol) |
| Codex | `gpt-6-luna`, GPT-6 Luna | 1050000 | 128000 | true | true | `reasoning` | `light` | [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) |

Anthropic's [models overview](https://platform.claude.com/docs/en/models/overview)
confirms tool use and vision for the current lineup. Opus 5.5 was released
September 22 and Sonnet 5.5 September 28, according to their specification
pages. Adaptive thinking is always on for Opus 5.5; Sonnet 5.5 supports
adaptive thinking. Keep the normal 128000 output ceiling; a 300000-token Batch
API beta ceiling is a different execution surface. Fable 5.1 and Haiku 4.5
remain in the current lineup.

The current [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
also recognizes both model IDs and requires v2.1.280 or later for Opus 5.5 and
v2.1.284 or later for Sonnet 5.5. These client minimums belong in harness
compatibility evidence, not an assumed account-wide allowance.

OpenAI's [changelog](https://learn.chatgpt.com/docs/changelog) dates GPT-6
Sol/Luna rollout to September 22 and GPT-6.1 Sol to September 29. CLI 0.159.1
made GPT-6.1 Sol the bundled default; CLI 0.159.2 was released September 29.
The same changelog confirms Spark's September 14 retirement.

OpenAI's [client model guide](https://learn.chatgpt.com/docs/models) retains
GPT-5.6 Sol/Terra/Luna during rollout. GPT-5.5 remains available until October
14 in ChatGPT, Work, and Codex; API availability is unaffected by that
retirement. GPT-6.1 Sol launches for paid plans, with Enterprise/Edu admin
enablement required; Free/Go are excluded at launch. Selecting a model does
not grant access. Do not remove GPT-5.6 merely because a successor exists, and
do not represent published rollout as per-account proof.

Unknown or out-of-scope fields stay unset: exact subscription allowance per
model, account/client enablement, throughput, quality scores, and future prompt
counts. Do not reuse `quotaIncludedUntil` to encode client retirement: it is a
spend-policy field. Add an explicit lifecycle seam if time-based retirement
exclusion is implemented.

The [GPT-6.1 Sol specification](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
requires Responses for tool calling; Chat Completions supports this model
without tools. [Sol](https://developers.openai.com/api/docs/models/gpt-6-sol)
and [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) restrict
Chat Completions function calling to no reasoning. A catalog `tools: true`
therefore still needs a compatible harness/transport. quotabot should not
attempt inference to discover this.

## Included quota, speed, and reset semantics

OpenAI's [pricing guide](https://learn.chatgpt.com/docs/pricing) states that
Work and Codex share usage, local messages and cloud chats share allowance,
and other priced agentic features can share it too. Pro currently has no
five-hour limit; Plus and Standard Business estimates still use that window,
and weekly limits can bind. Flexible Enterprise/Edu usage is credit-based.
Published message ranges are estimates, not exact quotas. Included Fast usage
is 2.5 times Standard and Astra Ultrafast is 8 times; purchased-credit
multipliers are 2 and 6 respectively. Keep those surfaces distinct and never
convert API prices or advertised credit rates into remaining included tasks.
The provider response and its reset timestamps remain authoritative for
quotabot's bars.

The supported [App Server rate-limit schema](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
separates the compatibility `rateLimits` view from optional
`rateLimitsByLimitId`. It identifies buckets, durations, next resets,
server-classified limit state, optional workspace `credits`, and optional
`rateLimitResetCredits`. Reset details can be absent or capped, so
`availableCount` governs the count. Detail records can include expiry.
Token-activity `account/usage/read` is a different interface and is not quota
headroom.

Shipped Codex behavior already normalizes duration instead of slot position,
accepts a null secondary window, gates matching scoped models, retains measured
headroom under admission denial, and displays banked reset counts without
redeeming them. The direct private `/wham/usage` response is not identical to
the App Server schema. No public page fetched here proves a replacement raw
shape or that starting App Server leaves host state untouched. Preserve the
existing collector until that boundary is verified.

Claude's [limit-reset guide](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset)
was labeled updated this week when fetched. Eligible offers can refill a
five-hour or weekly allowance immediately, preserve the usual weekly reset
schedule, and may expire. Redemption is irreversible and does not refund
usage-credit charges or change usage-credit balances. The documented action
is in web/Desktop Settings, with effects shared across the account.

Source-level mismatch: `drift.dart` rejects a Claude drop greater than its
tolerance while the future reset remains the same. A weekly refill matching
the newly documented behavior would therefore trigger "usage fell ... with
no reset". This is an inferred incompatibility, not a live-account reproduction.
Neither the reset guide nor the inspected usage parser establishes a reliable
reset marker. Do not add a blanket Claude re-rating exemption. Require a
sanitized before/after real-account metadata fixture, an authoritative event or
generation indicator, and unchanged-schedule tests before admitting this
transition. Keep ordinary unexplained gains quarantined.

Claude's [Fable plan guide](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan)
continues to separate Max/premium seats with included Fable sublimits from
Pro/standard seats using usage credits. The up-to-50-percent allowance draws
from the existing shared weekly cap, not additional quota. Fable 5.1 was never
part of the earlier Fable 5 promotion. Its historical end was July 19 at
23:59:59 PT. July 20 at 00:00 UTC in `plan_evidence.dart` is seven hours
earlier; do not claim those instants are identical. Current measured scoped
gates remain essential, and generic Enterprise metadata remains insufficient
to prove seat entitlement.

The [individual usage-credit guide](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans)
also now states that credits expire in certain jurisdictions, including Japan,
six months after purchase starting September 10. Credit expiry needs explicit
provider evidence if credit visibility is later added; do not assert that all
purchased credits never expire.

## Credential discovery and idle-machine status

Current [Claude authentication](https://code.claude.com/docs/en/authentication)
documents macOS Keychain, file fallback when Keychain writes fail, Linux and
Windows files, and `CLAUDE_CONFIG_DIR` scoping for both files and macOS entries.
The inspected `_readHostCredential()` and `currentCredentialGenerations()`
hardcode the default file. ROADMAP Next step 1 already identifies this gap.
One bounded injectable discovery seam must serve collection and identity
admission together. Discovering credentials does not prove plan entitlement.

Current [Codex authentication](https://learn.chatgpt.com/docs/auth#credential-storage)
supports file, keyring, auto, and ephemeral stores. The inspected adapter
respects `CODEX_HOME` but discovers only `auth.json`. That misses valid
keyring-only sign-ins. Ephemeral credentials should remain undiscoverable;
absence must yield honest repair guidance, not a search of unrelated state.
Keep host credentials read-only and refresh only quotabot-owned grants.

No host was independently validated during this research. Existing mocked
grant refresh and cache tests are not proof that a connected account stays
live on an idle machine after another machine consumes its allowance.

## Prioritized acceptance recommendations

| Priority | Concrete outcome | Acceptance evidence |
|---|---|---|
| Immediate documentation | Correct paused SDK-credit assertions and link this review from current evidence indexes. Preserve authentication/spend checks. | Search standing guidance for separate current SDK credits; verify only superseded historical text remains with an explicit correction. No collection path invokes print mode. |
| Immediate catalog maintenance | Remove retired Spark from curated dispatch; add verified current model rows, preserve still-available prior generations, and refresh catalog date. | Registry tests show no Spark suggestion; new IDs satisfy declared capability filters; Fable entitlement, admission, scoped-limit, stale, drift and paid exclusions remain unchanged. No added network or inference. |
| Immediate existing Next work | Finish Claude Keychain/config-directory discovery and idle-machine proofs. | Bounded mock coverage for default/custom scope, file fallback, locked/missing/malformed/timeout, credential replacement, disconnect and account mismatch; dated native read with host files unchanged. |
| Following compatibility work | Add honest Codex keyring discovery and per-account model-access evidence. | Auto/keyring/file behavior preserves configured account scope; unavailable or disabled model remains unavailable despite healthy provider quota; no session content is read and no host login is mutated. |
| Evidence-gated reset support | Recognize an authenticated Claude manual reset without weakening drift. | Real sanitized metadata proves the marker and the unchanged weekly schedule; malformed/absent markers and unexplained gains still quarantine; only redeemed scope regains headroom; no automatic redemption. |
| Scheduled maintenance | Handle October 14 GPT-5.5 client retirement explicitly. | A dated client-scoped lifecycle test excludes it from subscription advice after the boundary while API availability remains a separate fact. Do not turn expiry into a fabricated quota balance. |

The inspected README accurately separates shipped metadata collection from
planned stronger execution-scope evidence. Its core introduction does not need
fixed model names or fixed plan allowances. A short link to dated provider
research is more durable than duplicating changing price tables there.
