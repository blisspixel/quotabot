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
- It reuses those existing tokens to make bounded provider metadata requests.
  Antigravity can also perform the provider-required `onboardUser` request that
  provisions the account project needed for its quota read. Tokens are never
  logged; only resulting metadata is cached locally.
- Runtime code is covered by a no-surprise-cost contract test that rejects direct
  paid model, chat, image, and content-generation endpoints. Authenticated
  catalog maintenance is limited to model-list endpoints.
- Any OAuth grant you create with `quotabot login` is stored separately from the
  host application credentials under your per-user config directory. Owner-only
  permission narrowing is attempted best-effort on POSIX and Windows; a
  hardening failure currently does not abort the write.
- The optional local HTTP and MCP servers enforce loopback binding. The shipped
  LiteLLM example binds its separate proxy explicitly to loopback and requires a
  bearer key. LiteLLM is an external process, so removing either safeguard can
  expose provider-backed routes beyond quotabot's trust boundary.
- Alert webhooks are loopback-only by default. Enabling an external host is an
  explicit disclosure of alert metadata, which can include provider, account,
  window, remaining percentage, reset, and suggested route. Prompts, source,
  model output, and credential values are never webhook fields.

## Scope

In scope: token or credential exposure, path traversal or injection via provider
data, the local HTTP server or MCP server, the LiteLLM router, and the installer
scripts (checksum/verification handling).

Out of scope: vulnerabilities in the upstream provider apps or their APIs, and
issues that require an already-compromised local user account (quotabot trusts
the local filesystem and the credentials already present on the machine).
