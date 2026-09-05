# pi advisory recipe

Reviewed against pi 0.85.0. pi has no built-in MCP client configuration. These
commands consult quotabot from the terminal; they do not start pi, change its
model, read a session, or send a prompt.
[Tagged README](https://github.com/badlogic/pi-mono/blob/v0.85.0/packages/coding-agent/README.md).

```text
quotabot suggest --json
quotabot models --budget=local --json
quotabot suggest --task=standard --budget=quota --json
```

Use `--budget=local` for on-device candidates, or `--budget=quota` for measured
included quota plus local execution. Cloud-offloaded models exposed through a
local daemon do not qualify as local. Inspect availability and staleness before
using a recommendation. A failed quotabot read leaves pi's current behavior
unchanged.

If the suggested target is already configured and authorized in pi, select it
with pi's existing `/model` picker. Model names and provider IDs must match pi's
catalog; the quotabot provider name alone does not identify the right pi account
or entitlement. A healthy subscription balance does not fund a separate paid
API route.

An optional explicit-selection extension is future work. The documented
`pi.setModel` API changes the current session through pi's own state management
and checks configured authentication. A supported integration would also need
exact target mapping, session model-scope checks, and tests proving it does not
read conversation content or invoke a model. This pack ships no such extension.
[Extension contract](https://github.com/badlogic/pi-mono/blob/v0.85.0/packages/coding-agent/docs/extensions.md).
