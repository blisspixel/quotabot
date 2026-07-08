# quotabot router for LiteLLM

Route every request through the AI subscription that still has budget, and fall
back to a local model (Ollama, LM Studio) when your paid caps run low. The
routing decision is a zero-token local read from a running quotabot; it never
calls a model to decide.

The router is no-surprise-billing by default. Normal API-key deployments
(`openai/*`, `anthropic/*`, `xai/*`, and similar) are request-metered paid APIs;
mark them `spend: paid_api` and they are skipped unless you deliberately set
`allow_paid_api: true`. Mark `spend: quota_plan` only for a deployment backed by
a real included quota plan, and also set `overages_disabled: true` or
`overages: disabled`; otherwise the router treats the route as unsafe.

This works the same on Windows, macOS, and Linux.

## How it works

```
  client / agent ---> LiteLLM proxy ---> quotabot_router (pre-call hook)
                                              |
                                              v
                                   quotabot /suggest  (local, 0 tokens)
                                              |
                          picks the freest provider with budget,
                          or a local model when subscriptions are low
                                              |
                                              v
                          request is sent to the chosen deployment
```

The hook reuses quotabot's own decision logic (the binding-window and
local-fallback rules live in the Dart collector and are exposed at `/suggest`),
so routing here stays consistent with the desktop widget and the MCP server.

## Setup

1. Start the quotabot local server so the proxy can read quota:

   ```
   cd collector
   dart run bin/local_server.dart        # serves http://127.0.0.1:8721
   ```

   Verify it: open `http://127.0.0.1:8721/suggest` and you should see a JSON
   recommendation.
   The router accepts only loopback `quotabot_url` values, so it cannot be
   pointed at arbitrary network or file URLs by policy.

2. Install LiteLLM and copy the example files:

   ```
   pip install -r requirements.txt
   cp config.example.yaml config.yaml
   cp quotabot-routing.example.yaml quotabot-routing.yaml
   ```

   Use Python 3.10 through 3.13; the currently tested LiteLLM proxy release does
   not support Python 3.14. The requirements file locks the proxy dependency and
   its transitive packages with hashes; Dependabot keeps those pins current.

   Keep `config.yaml` in the same folder as `quotabot_router.py`; current
   LiteLLM proxy releases resolve custom callback modules relative to the config
   file. Edit `config.yaml` so each `model_name` points at a real deployment,
   and edit `quotabot-routing.yaml` so each `deployment` matches one of those
   `model_name`s. Set `provider` on each candidate to the quotabot provider id
   that gates it (codex, claude, grok, antigravity), and set `spend` honestly:
   `quota_plan` for included quota with overages disabled, `paid_api` for
   request-metered API keys. Quota-plan candidates also need
   `overages_disabled: true` or `overages: disabled`.

3. Launch the proxy with that config:

   ```
   litellm --config config.yaml
   ```

4. Point any OpenAI-compatible client at the proxy and call a logical model:

   ```
   curl http://127.0.0.1:4000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"frontier-coder","messages":[{"role":"user","content":"hi"}]}'
   ```

   The hook rewrites `frontier-coder` to whichever candidate currently has
   budget and is allowed by the spend policy. When all safe subscription
   candidates are low or unavailable it uses the `local: true` candidate.

## Spend policy

The policy file has two billing guardrails:

```yaml
allow_paid_api: false
block_unsafe_passthrough: true
```

With these defaults, `spend: paid_api` candidates are ignored even if their
provider has headroom in quotabot, because API-key billing is separate from the
subscription quota quotabot tracks. If a managed logical model has no
`quota_plan` or `local` route, the hook fails closed instead of silently passing
through to a potentially expensive deployment. Unmanaged model names still pass
through unchanged.

Use `allow_paid_api: true` only when you intentionally want request-metered API
spend. To use a provider subscription quota safely, route to a deployment whose
cost is bounded by that quota plan and has overages disabled, then mark that
candidate `spend: quota_plan` plus `overages_disabled: true`.
When quotabot reports multiple accounts for the same provider, add
`account: <quotabot account label>` to a candidate to bind that LiteLLM
deployment to the matching account. Without an account binding, the router still
uses provider-level ranking, but it omits account from metrics when multiple
accounts would make attribution ambiguous.

## Steering specific agents

Use a LiteLLM key alias or user_id and add a rule in
`quotabot-routing.yaml`:

```yaml
agents:
  architect:
    pin: claude-sonnet
    pin_spend: quota_plan
    pin_overages_disabled: true
  bulk-summarizer:  { model: cheap-bulk }    # prefer local, spill to Claude
```

`pin` forces a concrete deployment and skips headroom routing, but it does not
skip the spend policy. Set `pin_spend: quota_plan` or `pin_spend: local` for a
safe pin; quota-plan pins also require `pin_overages_disabled: true` or
`pin_overages: disabled`. Enable `allow_paid_api: true` only intentionally for a
paid API pin. `model` redirects the agent to a logical model that is then routed
normally.

## Usage metrics

Set `metrics_path` in `quotabot-routing.yaml` to append one JSON line per
successful or failed request. Records contain routing metadata only: requested
model, served model, gated provider/account when known, selected spend class,
callback event, HTTP status, Retry-After seconds, callback latency, sanitized
exception class, tokens, and cost. They never contain prompts, responses,
exception messages, or source code. The path is constrained to `~/.quotabot`;
relative paths are placed there. The plugin applies owner-only permissions to
the metrics directory and file before writing local usage metadata. This closes
the loop: LiteLLM pipe health, spend, and quotabot subscription headroom in one
place.

Use the default `~/.quotabot/litellm-metrics.jsonl` path when you want the
desktop Quota Analytics screen to show the routed-request summary. The widget
reads a bounded tail of that local JSONL file and shows only metadata totals:
request attempts, routed attempts, tokens, tracked cost, spend-class counts, top
successfully served models, pipe health, throttled/failed requests, callback
latency, and last request age.
Recent provider/account pipe failures from this file feed back into local
`/suggest` ranking as a bounded `pipe_discount_percent`. Managed LiteLLM routes
consume that ranked response, so a funded route that is actively throttling or
failing can be skipped without hiding its raw quota headroom.

## Failure behavior

Routing is an optimization for unmanaged model names. For managed logical models,
the default no-surprise-billing policy is stricter: if quotabot is unreachable
and no local fallback is configured, or every configured route is `paid_api`
while `allow_paid_api` is false, the hook fails closed before a provider call.
The proxy keeps working for other routes, but that managed request is rejected
rather than silently spending API money.

## Testing

The unit tests cover policy parsing, precedence, local fallback ordering, and
loopback URL hardening. CI also runs a real LiteLLM proxy integration test:
it starts LiteLLM on loopback with the actual `async_pre_call_hook`, a fake
quotabot `/suggest` endpoint, and a fake OpenAI-compatible backend, then proves
that a logical model is rewritten to the provider with budget. The test spends
no model tokens and never leaves the machine.

## Using it from coding agents

Any OpenAI-compatible coding tool can sit in front of this proxy:

- OpenCode / Claude Code / aider: set the API base to the proxy
  (`http://127.0.0.1:4000`) and call the logical model names.
- The proxy then applies quota-aware routing transparently, so a single config
  balances all your agents across subscriptions and local models.
