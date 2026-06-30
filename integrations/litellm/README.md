# quotabot router for LiteLLM

Route every request through the AI subscription that still has budget, and fall
back to a local model (Ollama, LM Studio) when your paid caps run low. The
routing decision is a zero-token local read from a running quotabot; it never
calls a model to decide.

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
   pip install "litellm[proxy]" pyyaml
   cp config.example.yaml config.yaml
   cp quotabot-routing.example.yaml quotabot-routing.yaml
   ```

   Keep `config.yaml` in the same folder as `quotabot_router.py`; current
   LiteLLM proxy releases resolve custom callback modules relative to the config
   file. Edit `config.yaml` so each `model_name` points at a real deployment and
   key, and edit `quotabot-routing.yaml` so each `deployment` matches one of
   those `model_name`s. Set `provider` on each candidate to the quotabot provider
   id that gates it (codex, claude, grok, antigravity).

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
   budget. When all subscriptions are low it uses the `local: true` candidate.

## Steering specific agents

Use a LiteLLM key alias or user_id and add a rule in
`quotabot-routing.yaml`:

```yaml
agents:
  architect:        { pin: claude-sonnet }   # always the strong model
  bulk-summarizer:  { model: cheap-bulk }    # prefer local, spill to Claude
```

`pin` forces a concrete deployment and skips headroom routing; `model`
redirects the agent to a logical model that is then routed normally.

## Usage metrics

Set `metrics_path` in `quotabot-routing.yaml` to append one JSON line per served
request (requested model, served model, tokens, cost). The path is constrained to
`~/.quotabot`; relative paths are placed there. This closes the loop: LiteLLM
spend plus quotabot subscription headroom in one place.

Use the default `~/.quotabot/litellm-metrics.jsonl` path when you want the
desktop Quota Analytics screen to show the routed-request summary. The widget
reads a bounded tail of that local JSONL file and shows only metadata totals:
served requests, routed requests, tokens, tracked cost, top served models, and
last request age.

## Failure behavior

Routing is an optimization, never a dependency. If quotabot is unreachable, the
policy file is missing or invalid, or anything else goes wrong, the request
falls through to the model the client originally asked for. The proxy keeps
working; you just lose the quota-aware steering until quotabot is back.

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
