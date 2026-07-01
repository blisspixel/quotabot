# Security policy

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue. Use
GitHub's [private vulnerability reporting](https://github.com/blisspixel/quotabot/security/advisories/new)
(Security tab > Report a vulnerability). Include steps to reproduce, the affected
version or commit, and the platform. You can expect an initial response within a
few days.

Please do not disclose the issue publicly until a fix is available.

## What quotabot touches

quotabot is local-first and makes no model/inference calls. Understanding what it
reads and writes helps scope any report:

- It reads usage and quota metadata from local state, cache, and credential files
  that each provider's own CLI or app has already stored on your machine (for
  example `~/.codex/sessions`, `~/.claude/.credentials.json`, the Grok CLI auth
  file, and the Antigravity `state.vscdb`). See
  [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) for the full list.
- It reuses those existing tokens only to make the same authenticated metadata
  requests the provider's own tools already make. Tokens are never logged; only
  the resulting usage numbers are written to the local snapshot cache.
- Runtime code is covered by a no-surprise-cost contract test that rejects direct
  paid model, chat, image, and content-generation endpoints. Authenticated
  catalog maintenance is limited to model-list endpoints.
- Any OAuth grant you create with `quotabot login` is stored separately from the
  host application credentials, under your per-user config directory, owner-only
  on POSIX and ACL-restricted on Windows.
- The optional local HTTP server and the LiteLLM router bind to loopback only.

## Scope

In scope: token or credential exposure, path traversal or injection via provider
data, the local HTTP server or MCP server, the LiteLLM router, and the installer
scripts (checksum/verification handling).

Out of scope: vulnerabilities in the upstream provider apps or their APIs, and
issues that require an already-compromised local user account (quotabot trusts
the local filesystem and the credentials already present on the machine).
