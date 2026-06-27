# Using quotabot from an AI agent

quotabot reports how much quota is left across a user's AI coding subscriptions
(Claude, Codex, Antigravity/Gemini, Grok) and local runtimes (Ollama, LM Studio),
and recommends which one to send the next request to. Every call is a local
metadata read: no model calls, no usage tokens, no prompts or code ever read.

If you are an agent or tool that picks a model/provider, use quotabot to route to
whichever subscription still has budget instead of stalling on a spent cap.

## How to call it

Pick whichever transport you already speak. All return the same data.

- **MCP (preferred for agents).** Point an MCP client at `dart run
  bin/mcp_server.dart` (or a compiled `quotabot-mcp`). Tools:
  - `list_quotas` - full normalized snapshot for every provider.
  - `suggest_provider` - the provider to use next, with ranked alternatives and a
    local fallback when subscriptions are low.
  - `provider_with_most_headroom` - the account with the most remaining budget.
  - `check_provider_availability` - whether a named provider is usable now and
    when it resets.
  - Resource `quotas://current` - the same snapshot.
- **CLI.** `quotabot suggest --json` for the routing decision, `quotabot --json`
  for the full snapshot, `quotabot stats --json` for analytics.
- **HTTP (loopback).** `GET http://127.0.0.1:8721/suggest` and `GET /` (start it
  with `dart run bin/local_server.dart`).

## The routing contract

1. Prefer the metered subscription with the most remaining headroom, as long as
   it is above a comfort threshold.
2. If every subscription is low, fall back to a local runtime (a free model is a
   safety net, not the default winner).
3. **Binding-window rule:** a spent longer window overrides a healthy shorter
   one. If the weekly cap is gone, ignore a green 5-hour bar; that provider is
   not usable.
4. **Fail soft.** If quotabot is unreachable or returns nothing, proceed with the
   model the user originally asked for. Routing is an optimization, never a hard
   dependency.

## Decision recipe

```
snapshot = call list_quotas        # or GET /, or quotabot --json
best     = call suggest_provider   # or quotabot suggest --json
if best.provider and best.headroom_percent > comfort_threshold:
    route to best.provider
elif a local runtime is available:
    route to the local runtime
else:
    wait for the soonest reset (check_provider_availability) or use the default
```

## Output schema

JSON outputs carry `"schema": "quotabot.v1"` and a `generated_at` epoch. Treat
unknown fields as additive. Headroom is a remaining-percent value (0..100);
higher means more budget left.

## What quotabot does not do

- It makes no model/inference calls and spends no usage tokens.
- It reads only quota/usage metadata, never prompts, code, or other content.
- It stays local: no account, no cloud, nothing leaves the machine.

A turnkey example of routing a fleet through quotabot is the LiteLLM proxy plugin
in [integrations/litellm/](integrations/litellm/); a minimal Dart example is in
`collector/bin/example_routing_agent.dart`.
