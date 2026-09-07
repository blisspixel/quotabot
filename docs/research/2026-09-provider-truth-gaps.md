# Provider truth gaps and market currency, September 2026

Reviewed 2026-09-06 and 2026-09-07 against shipped 0.11.2 and the 0.11.3 line at
`47fe6ec2dffd3ead78b12bbb2cc5f1717b80968b`. Unlike the synthetic audit in
[provider reliability](2026-09-provider-reliability.md), the first two findings
here came from live reads against real signed-in accounts on Windows and a
native Apple Silicon host, so they record account-specific evidence rather than
reproducible fixtures alone. The [changelog](../../CHANGELOG.md) records what
has shipped; the [roadmap Next section](../../ROADMAP.md#next) owns execution
order.

## 1. Antigravity reads an allowance the user is not spending

**Open. Mitigated in 0.11.3, not solved.**

The adapter calls
`https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`. Against a
correctly authenticated account whose grant had refreshed hours earlier, every
one of 21 models returned `remainingFraction: 1.0` with one shared `resetTime`
that advanced in step with the clock. Three reads 40 seconds apart:

```
as_of=1788702413  resets_at=1788720421  delta=5.0022h  used=0.0
as_of=1788702451  resets_at=1788720455  delta=5.0011h  used=0.0
as_of=1788702490  resets_at=1788720497  delta=5.0019h  used=0.0
```

The account owner confirmed the account was not at full quota. Every other
explanation was eliminated: identity is bound to the token rather than to local
state and fails closed on mismatch, the credential was current, `parseReset`
correctly reads an absolute epoch, and the read was live rather than cached.

The remaining explanation is that this endpoint reports the Cloud Code and
Gemini Code Assist allowance while Antigravity usage lands in the `agy` shared
pool. Google moved free, Pro and Ultra users off Gemini CLI on 2026-06-18 and
onto the closed-source Antigravity CLI, which draws one shared quota that drains
faster than the previous split arrangement
([The New Stack, accessed 2026-09-06](https://thenewstack.io/google-antigravity-cli/)).
quotabot's own passive read already disagrees with the live one and says so:
"Local Antigravity status reports higher rate limits."

0.11.3 rejects the reading rather than routing on it. **A drifted Antigravity
card is the expected state on 0.11.3 and later, not a regression.** Closing this
needs an endpoint that reports the pool `agy` actually spends; the roadmap
already records that no machine-readable Antigravity balance API is documented.
Any candidate must be validated against an account whose consumption is known
before admission.

## 2. Claude is undiscoverable on macOS

**Open.**

On a native Apple Silicon host with Claude Code signed in, `doctor` reports "no
usable Claude login". On macOS, Claude Code stores its OAuth credentials in the
login Keychain under service `Claude Code-credentials`;
`~/.claude/.credentials.json` does not exist there. The Claude adapter hardcodes
that file as its only host credential source, so every normally signed-in macOS
user sees Claude as an error.

`collector/lib/auth/os_secret_store.dart` already implements macOS Keychain
reads through `/usr/bin/security find-generic-password`, but it is wired only to
Antigravity. The plumbing exists; the Claude path does not use it.

This is invisible to hosted CI and only appears on a real signed-in Mac, which
is why the roadmap keeps native macOS provider evidence as a 1.0 gate.

## 3. Unsigned macOS artifacts fail Gatekeeper as designed

Measured on the same host against the shipped 0.11.2 bundle. The distinction
matters for the signing work: integrity passes while trust fails.

| Check | Result |
|---|---|
| `codesign --verify --deep --strict` | valid on disk, satisfies its Designated Requirement |
| `codesign -dv` | ad hoc signature (`flags=0x2(adhoc)`) |
| `spctl --assess --type execute` | **rejected** |
| `xcrun stapler validate` | no ticket stapled |

The bundle is well formed; it is simply not Developer ID signed. Note also that
`curl` does not attach `com.apple.quarantine`, so a curl-based download silently
skips Gatekeeper and overstates how smoothly an unsigned artifact installs. Any
acquisition evidence must come from a browser download.

The same host also confirmed the read-only host contract: 480 files under
`~/.claude`, `~/.claude.json` and `~/.ollama` were byte-identical before and
after a real `doctor` run, and quotabot created only its own config directory.

## 4. Market currency

Verified against primary sources on 2026-09-06 unless noted. Items marked
secondary need first-party confirmation before any support claim, per the
repository rule that model or API compatibility alone is insufficient.

| Change | Evidence | Bearing on quotabot |
|---|---|---|
| Claude Fable models draw on the same weekly allowance capped at 50 percent, on Max and premium Team and Enterprise seats; Pro and standard seats use credits instead | [Anthropic help centre](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan) | The spend classification in `plan_evidence.dart` matches this and is dated correctly to 2026-07-20. The 50 percent sub-cap itself is not modelled, so a Fable ceiling can bind while the shared weekly window still reports headroom |
| Amazon Q Developer reached end of support; new subscriptions blocked 2026-05-15, full end of support 2026-04-30-2027, Kiro is the replacement | [AWS DevOps blog](https://aws.amazon.com/blogs/devops/amazon-q-developer-end-of-support-announcement/) | quotabot already supports Kiro. No Q Developer work should be started |
| SpaceX acquired xAI (2026-02, rebranded SpaceXAI in July) and then Cursor, closing 2026-08-14. Grok Bot eligibility is gated by Cursor's subscription ladder rather than an xAI plan | [cursor.com](https://cursor.com/blog/joining-spacex), [9to5Mac](https://9to5mac.com/2026/08/14/spacex-lands-deal-to-likely-purchase-claude-code-and-openai-codex-competitor/) | quotabot treats `grok` and `cursor` as independent providers with separate accounts. Those entitlement stacks are converging; watch before the account model goes stale |
| GitHub Copilot moved from premium requests to AI Credits on 2026-06-01, priced by tokens consumed; usage splits across Copilot, Spark and coding-agent SKUs | [GitHub docs](https://docs.github.com/en/billing/concepts/product-billing/github-copilot-premium-requests) | The largest installed base in the category and the clearest unsupported provider. No documented per-user remaining endpoint; the workable path is the billing usage endpoint filtered by SKU against plan allowance |
| Meta Muse Code launched 2026-08-06 and exited beta with subscription tiers around 2026-09-01: 5 USD, 15 USD and 50 USD, the base tier quoted at roughly 10 to 50 requests per five hours | Secondary only ([The New Stack](https://thenewstack.io/muse-code-sdk-pricing/)) | A five-hour rolling window is a primitive quotabot already models. Whether any machine-readable quota surface exists is unverified |
| Windsurf switched from credits to daily and weekly quotas on 2026-03-19 and rebranded as Devin Desktop on 2026-06-02 | Secondary | quotabot lists the provider, but the metering model changed underneath the adapter |

## 5. Local runtime metadata is less portable than assumed

Researched from runtime source and official documentation, 2026-09-06. Relevant
to the local-resource work in the roadmap, which should not promise a field that
only one runtime reports.

| Signal | Ollama | LM Studio | llama-server | Lemonade |
|---|---|---|---|---|
| Model list, disk size, max context | yes | yes | yes | yes |
| Running context of a loaded model | yes | yes | per slot | yes |
| Per-model VRAM residency | **only here** | no | no | no |
| Keep-alive expiry | **only here** | no | no | no |
| Busy or streaming now | no | CLI only | yes | yes |
| Host GPU and VRAM | no | no | no | **only here** |

The portable subset is the model list, on-disk size, maximum context, the
currently configured running context, and loaded state. **Available VRAM is not
portable.** Only Ollama reports what a loaded model occupies; for the others it
must come from the operating system keyed on the runtime's process, and that
path is hostile: `nvmlProcessInfo_t.usedGpuMemory` always returns unavailable
under Windows WDDM by documented design, and macOS has no per-process GPU memory
API at all. On Apple Silicon there is no VRAM; the real ceiling is Metal's
`recommendedMaxWorkingSetSize`.

The strongest portable capacity primitive is the running context length, present
in all four at zero cost, with the caveat that llama-server reports it per slot
and it must be read alongside `total_slots`.

## Acceptance for the open items

- An Antigravity balance source is admitted only with dated evidence from an
  account whose consumption is independently known, and only after the reading
  survives the never-approaches rule.
- The macOS Claude credential path is proven on a native signed-in host, with
  fixtures for both the Keychain-present and file-present cases, and without
  writing any host credential file.
- A Fable sub-cap is modelled only from a provider-reported scoped pool, never
  inferred from the published 50 percent figure.
- Any newly named provider is verified from first-party documentation, with a
  documented metadata-only endpoint, before it appears in a support claim.
