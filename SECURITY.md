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
  example `~/.codex/auth.json`, `~/.claude/.credentials.json`, the Grok CLI auth
  file, and the Antigravity `state.vscdb`). See
  [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) for the full list.
- It reuses those existing tokens to make bounded provider metadata requests.
  Antigravity can also perform the provider-required `onboardUser` request that
  provisions the account project needed for its quota read. Tokens are never
  logged; only resulting metadata is cached locally.
- Runtime code is covered by a no-surprise-cost contract test that rejects direct
  paid model, chat, image, and content-generation endpoints. Authenticated
  catalog maintenance is limited to model-list endpoints.
- Official release artifacts carry checksum sidecars and restricted workflow
  provenance. Repository rules block updates and deletion of `v*` tags, and
  GitHub release immutability locks an audited release's tag and assets when the
  draft is published.
  The current audited release is [v0.10.1](https://github.com/blisspixel/quotabot/releases/tag/v0.10.1).
  Its exact 14-asset set is locked after the native
  [stable release run](https://github.com/blisspixel/quotabot/actions/runs/33572003688)
  and three-OS
  [Latest install smoke](https://github.com/blisspixel/quotabot/actions/runs/33575042208)
  passed, including exact-tag installation and upgrade from the actual prior
  stable. Stable publication binds GitHub Latest; its follow-up smoke repeats
  the unversioned canonical install.
  Immutability is prospective from July 18, 2026; v0.9.2 and earlier releases
  were not changed retroactively.
- Any OAuth grant you create with `quotabot login` is stored separately from the
  host application credentials under your per-user config directory. New or
  rotated grants are written only after checked owner-only permission hardening
  succeeds on POSIX or Windows. If hardening fails for a credential file, that
  file is not written and login or refresh reports the failure. Each credential
  slot uses a cross-process file lock, and refresh replaces the slot only if its
  exact loaded generation is still current, so an older refresh cannot overwrite
  a completed login or account replacement. A multi-slot account save uses
  separate atomic file writes, not a cross-file transaction.
- Desktop preferences can contain an authenticated webhook URL. quotabot checks
  owner-only protection before reading or writing that secret-capable file and
  falls back to safe defaults if the protection cannot be established. The
  desktop check is asynchronous and bounded so a stalled platform helper cannot
  block startup indefinitely. A legacy file that cannot be protected is ignored
  but left untouched to avoid deleting user settings without approval; the app
  shows a persistent warning so the user can secure or remove it explicitly.
  Preference loads reject links, non-regular files, and files larger than 64 KiB
  before parsing them.
- The optional local HTTP and MCP servers enforce loopback binding. The shipped
  plain HTTP server also rejects non-loopback browser origins and originless
  same-site or cross-site subresource requests before provider collection.
  Normal non-browser clients without Fetch Metadata and explicit user-activated
  top-level navigations remain supported. The shipped LiteLLM example binds its
  separate proxy explicitly to loopback and requires a bearer key. LiteLLM is an
  external process, so removing either safeguard can expose provider-backed
  routes beyond quotabot's trust boundary. Plain HTTP reads pseudonymize
  email-shaped account labels unless the caller presents the owner-only bearer
  token. Both HTTP transports bound total request-body time. Plain HTTP also
  closes body-bearing requests rejected before parsing without waiting to drain
  them. The bundled LiteLLM router proves the exact loopback peer on the same
  connection before disclosing that bearer. MCP bounds bearer inputs, active
  requests, and sessions, rejects invalid credentials before reading a body,
  and promptly closes early rejections with incomplete bodies. The Python MCP
  example bypasses ambient HTTP proxy settings for its bearer-bearing loopback
  transport.
- Alert webhooks are loopback-only by default. Enabling an external host is an
  explicit disclosure of alert metadata, which can include provider, account,
  window, remaining percentage, reset, and suggested route. Prompts, source,
  model output, credential values, and raw transport exceptions are never
  webhook fields or delivery errors.

## Scope

In scope: token or credential exposure, path traversal or injection via provider
data, the local HTTP server or MCP server, the LiteLLM router, and the installer
scripts (checksum/verification handling).

Out of scope: vulnerabilities in the upstream provider apps or their APIs, and
issues that require an already-compromised local user account (quotabot trusts
the local filesystem and the credentials already present on the machine).
