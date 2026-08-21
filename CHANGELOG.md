# Changelog

Notable changes to quotabot. Newest first.

## Unreleased

### Fixed

- `quotabot logout` now stays disconnected for Claude, Codex, Grok, and
  Antigravity even when their host applications remain signed in. A safe
  provider-wide marker blocks host and quotabot credentials for every account
  without changing host state, and only a successful explicit quotabot login
  clears it.
- First-run readiness now keeps the best account for each provider and never
  calls stale, drifted, suspect, or expired quota live. The source installers
  apply the same conservative readiness rule, and macOS/Linux setup once again
  receives and renders the CLI snapshot it was meant to summarize.
- MCP Streamable HTTP startup now rejects repeated or conflicting bearer-token
  sources instead of silently choosing one by argument precedence.
- Reset countdowns below one hour now use useful minute labels instead of `0h`.
- Explicit CLI-only source setup no longer downloads or installs the desktop
  app, or opens an interactive dashboard. Automatic desktop-toolchain failures
  can still use the verified portable desktop fallback during a normal full
  setup.
- MCP provider and account selectors now use one bounded exact-identity
  validator across quota, routing, model, availability, and reservation tools.
  Blank, control-bearing, and oversized identities fail before quota
  collection, cache reads, or lease access instead of silently widening or
  truncating a request.
- Lease idempotency keys now require an exact 8 to 120 character ASCII key at
  every MCP, local HTTP, in-memory, and file-backed boundary. Distinct long
  keys can no longer alias after truncation.
- Cache-only `decide_now` responses now derive snapshot timestamps and ages
  from the providers remaining after profile, account, and exclusion filters,
  so their provenance describes the actual routing evidence.
- Named desktop profiles now retain their exact current provider and account
  selections when every known option is selected, hidden accounts can be
  restored after a sibling account leaves, and ambiguous multi-account
  analytics no longer reuse legacy provider-only history.
- Portable desktop fallback installs now consume the selected release on every
  run and use the same rollback-protected activation as source-built payloads,
  so exact updates and rollbacks cannot silently reopen an older app.
- Windows, macOS, and Linux uninstall now stop only processes launched from
  quotabot install roots, remove guarded CLI and desktop generation stores,
  preserve config unless purge is requested, and fail visibly if payloads
  remain. The Windows install smoke also rejects any nonzero `doctor` exit
  before parsing its JSON.
- CLI value options and singleton local HTTP `/suggest` query parameters now
  reject repeated values before quota collection. HTTP snake-case and
  kebab-case aliases are treated as the same option, so conflicting aliases
  cannot silently select the last value. Repeatable `exclude` and
  `cost_penalty` collections retain all distinct values, while duplicate cost
  keys are rejected after provider normalization.
- A valid manual quota with the exact same provider and specific account as one
  built-in subscription is now retained as explicit supplemental provenance on
  the built-in row instead of creating a competing route, analytics identity,
  or desktop card. Measured windows, status, availability, routing, and
  analytics remain authoritative; ambiguous, local-runtime, placeholder, and
  non-exact identities stay separate for verification and account selection.
- Desktop reset reminders now arrive 15 minutes before reset, reconcile stale
  or privacy-obsolete owned requests without touching unrelated notifications,
  serialize disablement with in-flight scheduling, and use a bounded durable
  ledger to prevent the same reset from being delivered twice.
- "Skip for now" in first-run setup now defers the walkthrough only for the
  current process instead of permanently marking setup complete.

### Documentation

- Ordered the remaining 0.10.x work so field-discovered correctness,
  quality-of-life refinement, and native validation finish before platform
  signing activation, and added the complete Windows and macOS publisher
  enrollment and rehearsal checklist without changing the project's Apache 2.0
  license.

## 0.10.0-rc.5 - 2026-08-21

### Fixed
- Claude usage throttling and other non-authentication HTTP failures no longer
  claim that a locally known-expired Claude Code login caused the response.
  HTTP 401 keeps the login recovery guidance, while HTTP 429 retains its exact
  status, throttled pipe health, and bounded retry metadata.

## 0.10.0-rc.4 - 2026-08-21

### Changed
- Updated the optional LiteLLM proxy integration to 1.92.2 with `aiohttp`
  3.14.3 and `cryptography` 50.0.0. Updated the TypeScript MCP client examples
  to SDK 1.30.0 with patched `fast-uri`, Hono, and `ip-address` versions,
  removing the known vulnerable transitives from both reproducible locks. The
  Python MCP example guide now pins the current maintained v1 release while
  identifying v2 as the stable breaking line.
- Replaced the exportable-PFX Windows release contract with a protected
  `release-signing` environment, short-lived GitHub OIDC authentication, and
  the pinned Azure Artifact Signing action. The signer receives an exact
  full-tree-validated file catalog, SHA-256 file and RFC 3161 timestamp digests,
  and no private-key material. Credential-free build and publication jobs
  exchange immutable candidates with the isolated signing jobs, so dependency
  resolution, compilation, packaging, attestation, and upload cannot obtain the
  Azure signing identity.
- Windows signature verification now binds platform trust to the Artifact
  Signing Public Trust marker and the owner's durable subscriber identity EKU,
  while recording but not pinning the service's daily rotating leaf subject and
  thumbprint. Exact downloaded draft assets are reverified before publication.
- Added explicit release signing modes and a mandatory release-note disclosure.
  The transition `unsigned` mode preserves checksums and provenance without
  claiming platform identity; signed mode fails closed without the protected
  Azure profile configuration. Published v0.9.9 artifacts remain unsigned.

### Fixed
- Made fresh-download verification, exact asset audit, and publication use
  explicit `always()` conditions with exact-success requirements for every
  direct prerequisite. GitHub's implicit status condition propagated the
  intentionally skipped unsigned signer through successful Windows packaging,
  so the `v0.10.0-rc.3` workflow skipped verification after uploading 12 draft
  assets. The incomplete draft and partial assets were removed; its immutable
  tag and workflow logs remain.
- Checked out the tagged source before extracting curated release notes from
  `CHANGELOG.md`. The `v0.10.0-rc.2` release quality gate passed, but draft
  creation correctly stopped before any asset build because the release job had
  no workspace checkout. Its immutable tag has no GitHub release.
- Added the two fully pinned Azure signing action repositories to the GitHub
  Actions allowlist. GitHub validates every referenced action before evaluating
  job conditions, so the missing allowlist entries prevented even an unsigned
  release workflow from starting. The rejected `v0.10.0-rc.1` tag remains
  immutable and has no GitHub release.
- Cursor 3.x now passively detects a recognized current local plan only when its
  bounded membership owner matches the subject of the existing Cursor access
  token. The plan remains unroutable diagnostic evidence because Cursor does
  not persist current Cursor Models and Other Models quota balances in the
  supported local state, and credentials and owner identifiers are never
  exposed.
- `quotabot login claude` now sends a 32-byte, 43-character OAuth state value
  accepted by Anthropic's authorize POST and encodes the scope separator as an
  unambiguous `%20`. The prior 22-character state could show a valid-looking
  consent page and then fail with "Invalid request format" after authorization.
- Logout now removes every exact account grant slot, including malformed and
  legacy records that cannot be discovered by their embedded account marker,
  without following symbolic links or touching similarly prefixed files.
- OAuth login now rejects successful HTTP responses that omit a nonempty access
  token. Background refresh remains fail-soft and preserves the stored grant
  when Google, xAI, Anthropic, or OpenAI returns an unusable token response.
- Healthy subscriptions with a known reset time now keep the fail-soft
  passthrough fallback instead of also telling callers to wait for the selected
  provider. Only an unavailable subscription can produce a wait-for-reset
  fallback in CLI, MCP, HTTP, receipt, and desktop output.
- Cache-only routing now skips an individual snapshot whose metadata or contents
  cannot be read and continues loading healthy sibling providers, rather than
  silently stopping at the first filesystem error.
- Windows source setup and the new one-command contributor gate now share the
  space-safe Dart invocation for collector and Flutter native-asset commands,
  including Flutter installs located under a user profile containing spaces.
- Windows release signing now passes the RFC 3161 timestamp URL before the
  SHA-256 timestamp digest option, as required by SignTool, and refuses to sign
  when any file in the candidate tree differs from its unsigned inventory.
- Tagged Windows release jobs now download the exact draft CLI and desktop
  archives, re-inventory and independently verify every embedded signature,
  and retain bounded verification receipts before publication can continue.
- `quotabot login claude` now uses Anthropic's current platform OAuth callback
  and token hosts (`platform.claude.com`). The retired
  `console.anthropic.com` generation rejected the public Claude Code client
  with "Invalid request format", so an idle machine could not mint a
  refreshable usage-metadata grant.
- `quotabot login claude` now POSTs the token exchange as JSON, matching
  Claude Code's current `platform.claude.com/v1/oauth/token` contract.
  Form-urlencoded bodies on that host can fail with no grant written. A
  rejected exchange now prints the HTTP status and Anthropic's bounded error
  text instead of a generic "token exchange failed".
- Linux desktop release verify now downloads, checksums, and attests the
  draft archive before installing GTK and xvfb. CI and release share a
  time-bounded apt helper, and the verify job budget is 45 minutes, so a
  stalled hosted Ubuntu mirror fails that step instead of cancelling the
  whole job.

### Documentation
- Recorded the immutable v0.9.9 14-asset lock and three-OS install smoke,
  including upgrade from v0.9.8.

## 0.9.9 - 2026-08-19

### Fixed
- Windows `dart build cli` now hardlinks or copies the Dart SDK into a
  space-free directory before native-asset hooks run, so source setup works when
  the Flutter install lives under a profile such as `C:\Users\First Last`.
  Junctions, subst drives, and 8.3 short names are not enough, because Dart
  reports the long path.
- Source setup no longer exits when Dart is missing or this checkout cannot
  compile. It installs the checksum-verified release CLI, then a dart-run shim
  if a download is also unavailable. Desktop OS build tools that are missing,
  or a desktop build that fails, still skip the tray app and leave the CLI
  installed. Flutter desktop targets are enabled before a desktop build.
- `bash tools/setup.sh` on Windows now launches `pwsh tools/setup.ps1` instead
  of exiting.
- Source setup now prints a first-run login checklist from the live snapshot,
  installs the portable desktop app when a source desktop build was skipped, and
  opens quotabot (the tray app, or `quotabot top` if no GUI is available).
- The desktop first-run walkthrough now shows what is already live on this
  machine, lets the user check the tools they actually use, and only offers
  setup for those. Unchecked providers stay hidden. A Claude account whose live
  `/usage` read fails as an invalid response still counts as signed in.
- Claude live `/usage` reads no longer fail the whole observation when a
  leftover `five_hour` / `seven_day` block next to a complete `limits` array is
  unusable. The account 5 hour and weekly windows from `limits` still parse.
- Codex live usage now admits a weekly window at 100% used when ChatGPT still
  reports `allowed: true`. Those flags are admission, not a second meter.
  Internally contradictory flags still reject the payload.
- A Claude 200 whose usage body does not parse now finishes the companion
  profile read, keys the error with that pool identity, and retries the usage
  GET once, so last-known cache can attach instead of a hard ERROR on a
  different digest.
- `quotabot top` keeps a spent live observation in the active band. CACHED is
  only stale, drifted, unverified, or a failed fetch.
- Antigravity now treats a signed-in `agy` CLI as installed on Windows, macOS,
  and Linux. It reads the OS keyring grant (`gemini` / `antigravity`) without
  writing host credentials, so machines without the IDE `state.vscdb` or
  `~/.gemini/oauth_creds.json` still get a live Cloud Code quota read. An
  installed but unsigned-in copy says so instead of "not installed".
- Expanded desktop cards now show extra usage-view details from the same
  metadata those tools' `/usage` panels already expose: Grok's category split
  inside the weekly pool, and Claude extra-usage / credit spend when present.
  Those lines are display-only and never become routing windows. Collection
  still uses the existing adaptive refresh; host CLI print or prompt commands
  such as `claude -p /usage` or `grok usage` are never spawned.
- Claude no longer shows two cards for one Max login when the host token and
  quotabot grant both fail, or when a second success has no pool identity.
- Antigravity Connect now discovers the grant it just saved, so a signed-in
  account is collected even without the IDE `state.vscdb` or `agy` keyring.
- Ollama local hardware details name the GPU. Windows reads
  `Win32_VideoController` when `nvidia-smi` is absent, so AMD and Intel
  adapters appear next to RAM.
- macOS and Linux source setup and the one-line CLI installer now add
  `~/.local/bin` to the user's shell profile when it is not already on PATH, so
  `quotabot` is found in a new terminal.
- Windows draft-release lifecycle verification now retries temporary extraction
  cleanup for up to ten attempts when a stopped desktop process briefly
  retains a filesystem handle. The last failure still blocks publication.
- README screenshot generation now clears build state containing an obsolete
  absolute Flutter SDK path and restores dependencies from the committed
  lockfile before capturing current UI and terminal views.
- The desktop quota header now keeps its timestamp visible at the documented
  narrow window width by stacking its action controls.
- Windows source setup now runs `quotabot doctor` while the desktop app remains
  stopped, then restarts it, preventing setup from creating a competing local
  history writer during its own verification pass. Provider findings remain
  non-blocking, while failure to launch the installed CLI now fails setup.

### Documentation
- SETUP, BUILDING, and AGENTS now name `tools/setup.ps1` / `tools/setup.sh` as
  the from-clone path, and document the all-OS desktop skip, PATH persistence,
  and spaced-profile compile mapping.
- Advanced the immutable release and three-OS install evidence to v0.9.8.
- Reduced the README to a concise install, usage, support, and trust overview;
  detailed provider, recovery, routing, packaging, and lifecycle guidance now
  stays in the linked documentation.
- Regenerated the README terminal dashboard and the closing GIF frame from
  current synthetic demo data, including Grok's usage-view split and Ollama
  GPU capacity. Widget and analytics stills keep the previous Flutter desktop
  capture.

## 0.9.8 - 2026-08-01

### Changed
- `quotabot suggest --help`, `quotabot help suggest`, `quotabot models --help`,
  and `quotabot help models` now show focused, side-effect-free references for
  routing modes, budget defaults, valid policy combinations, metadata-read
  boundaries, and examples instead of the full unrelated option list.
- CLI and Windows/macOS desktop packagers now expose mutually exclusive
  build-only and package-only phases. A signing workflow can build once, modify
  and verify the native candidate, then create the existing atomic archive and
  checksum pair without an intervening rebuild. Windows CI now exercises that
  phased seam; other native CI packaging remains unchanged.
- Windows CLI and desktop builds now capture a bounded PE inventory after the
  build-only phase, package without rebuilding, verify and extract the archive,
  and require an exact manifest match before attestation or publication. The
  deterministic manifest binds every regular file, rejects links, malformed PE
  files, and architecture mismatches, exposes no absolute build path, and is
  retained with workflow evidence.
- A credential-free Windows verifier can now prove that every PE in an exact
  post-signing inventory has one valid embedded Authenticode signature from the
  owner-supplied publisher identity, a SHA-256 file digest, and an RFC 3161
  timestamp whose TSTInfo message imprint uses SHA-256 and binds the publisher
  signature. Its deterministic receipt covers candidate, inventory, native tool,
  signer, timestamp, and per-file evidence without exposing absolute candidate
  paths or raw native diagnostics. A first-class receipt path atomically retains
  canonical success or bounded failure evidence, preserves prior complete
  evidence when publication fails, and identifies the surface, architecture,
  and allowlisted failure stage. Success and failure receipts expose an exact
  comparison-only body digest, clearly separated from artifact identity,
  authenticity, attestation, and independent workflow provenance. Output
  validation rejects candidate paths,
  manifest aliases, alternate streams, and non-regular targets. It remains
  outside release publication until the signing identity and credential-bearing
  workflow are owner-approved.

### Fixed
- Windows signature verification now permits up to 60 seconds for one native
  tool invocation while retaining the 300-second whole-candidate deadline. This
  prevents cold PowerShell security-module startup on hosted runners from
  causing a false timeout without making verification unbounded.
- Concrete-model suggestions now reject provider-only `--local-first`,
  `--risk`, `--tuned-burn`, and `--prefer` policies instead of silently ignoring
  them. Add `--provider-route` when those provider policies must accompany model
  requirements.
- Local-runtime fallback explanations now state the action directly while
  retaining the warning that adapter reachability does not independently prove
  execution location or cost.
- Unsigned Windows launch guidance no longer implies that checksum or GitHub
  provenance verification authorizes bypassing SmartScreen.

### Documentation
- Advanced every public release marker and the release-version consistency gate
  to v0.9.8, while retaining v0.9.7 as the completed prior release and install
  rehearsal evidence.
- Acquisition guidance now names checksum verification and GitHub build
  provenance at first mention instead of using language that could be mistaken
  for Authenticode or Developer ID signing.
- Release-signing scope now explicitly includes every shipped Windows PE module,
  the standalone macOS CLI, the app, nested Mach-O code, and native code bundles
  without claiming that current artifacts are signed or notarized.
- Added ElevenLabs as a post-1.0, admission-gated quota-source candidate. Any
  first integration is quota visibility only and remains outside coding routes,
  model selection, leases, and projected-waste policy until typed shared pools
  and an explicit audio-domain decision exist.

## 0.9.7 - 2026-07-27

### Fixed
- Ollama capability enrichment now rotates its bounded probe window across
  unresolved models. Failed or digest-less entries at the front of a library can
  no longer starve every model after the 48-model per-read cap forever.
- Lemonade cloud routes are no longer labeled as free on-device capacity. The
  extended `recipe: "cloud"` and `cloud_provider` evidence now produces
  `cloud_offloaded: true`, which keeps those models visible under `budget=any`
  while excluding them from local, quota, local-first, and quota-stretch routes.
- A reachable Lemonade server with an empty downloaded-model list now reports
  `0 installed, idle` instead of `not running`.
- Calibration output no longer presents `1 - ECE` as individual-forecast
  accuracy. Casual percentage headlines wait for 40 resolved forecasts and name
  the value as calibration agreement; provisional JSON remains available with
  its exact sample count.
- Burn-lookback self-tuning no longer selects and evaluates a candidate on the
  same history. It fits on earlier resolved forecasts, leaves a horizon gap, and
  requires improvement on a later 25 percent holdout using matched provider and
  timestamp pairs.
- Malformed Lemonade execution-location and download-state fields now fail
  closed instead of allowing an ambiguous entry to prove local capacity.

### Changed
- Lemonade model reads now carry the server's declared maximum context, tool,
  vision, and embedding labels, plus loaded state and running context from the
  optional health read. They omit entries explicitly marked as not downloaded
  unless those entries are declared cloud routes.
- `quotabot.calibration.v1` adds headline readiness and minimum-sample evidence,
  plus fit, temporal-validation, and holdout sample counts for tuning.

### Documentation
- Updated the README, agent guide, source inventory, schema, usage, setup,
  architecture, routing math, provider guide, and product strategy for Lemonade
  execution-location evidence, fair Ollama refresh behavior, statistically honest
  calibration language, and the completed v0.9.6 release and install evidence.
  Removed the stale product-strategy statement that quota stretch was still the
  next code item after it shipped in 0.9.6.

## 0.9.6 - 2026-07-27

### Added
- An opt-in `quota_stretch` provider-routing policy now keeps fresh measured
  included quota while effective headroom is at or above a 25 percent reserve,
  then prefers a reachable on-device runtime. The existing `balanced` and
  `local_first` policies remain unchanged.
- CLI `--quota-stretch`, MCP `quota_stretch`, loopback HTTP `quota_stretch=true`,
  and the desktop profile editor expose the same policy. CLI
  `--stretch-threshold=N` and the matching MCP and HTTP fields accept an explicit
  reserve from 20 through 50 percent.
- Provider suggestions and decision receipts now expose
  `quota_stretch_threshold_percent`; local route candidates expose
  `local_readiness` so a loaded runtime can win before an otherwise equivalent
  cold runtime.

### Safety
- Quota stretch can be satisfied only by fresh measured included quota. Stale,
  drifted, manual, and non-quota metered candidates remain inspectable but cannot
  hold the subscription side of the policy. Ollama cloud-offloaded models remain
  outside local and free budgets.
- User-facing transports reject ambiguous `local_first` plus `quota_stretch`
  inputs and out-of-range thresholds. When no on-device runtime exists, routing
  fails soft to the best usable included-quota candidate below the reserve.

### Documentation
- Updated the README, agent guide, usage, schema, architecture, setup, product
  strategy, documentation index, changelog, and roadmap for the shipped policy
  and 0.9.6 release contract.
- Made release signing the sole next action because the unsigned Windows and
  macOS artifacts are the largest acquisition gap and final native install,
  accessibility, and provider evidence should run against signed artifacts.

## 0.9.5 - 2026-07-26

### Changed
- Release-version consistency now covers the current-stable statements in the
  README, agent guidance, documentation index, and setup guide, including the
  setup guide's release link. A patch cannot pass CI while those public markers
  still name an older installer.

### Fixed
- LiteLLM success and failure callbacks now emit bounded warnings when local
  metrics or lease cleanup fails instead of suppressing all evidence. The
  callbacks remain fail-soft and never log exception text, account identifiers,
  prompts, code, or paths; lease cleanup still falls back to bounded TTL expiry.

### Documentation
- Synchronized the README, agent guidance, setup, building, desktop
  distribution, architecture, security, product strategy, documentation index,
  and roadmap with the published v0.9.4 release audit and three-OS install
  smoke. The docs now distinguish the current immutable release evidence from
  the signing, notarization, native accessibility, provider, and exact-candidate
  evidence still required for 1.0.
- Defined the single next code item as an opt-in quota-stretch routing policy,
  including why it comes next, what existing behavior it must preserve, its
  no-surprise-spend boundaries, and the deterministic acceptance matrix. The
  roadmap now owns the only immediate-priority claim so supporting docs cannot
  drift into competing queues.

## 0.9.4 - 2026-07-25

### Added
- Local models now carry the capabilities their runtime declares, so a
  capability filter can finally select one. Ollama declares tool use, vision,
  and the model's maximum context per model through `POST /api/show`, and LM
  Studio declares them in its native model list (v1 as capability flags, v0 as
  a tool-use array plus the `vlm` model type). Until now no local model
  declared anything, so `--require-tools`, `--require-vision`, and
  `--min-context` silently rejected every one of them, including under
  `--budget=local`. An OpenAI-compatible listing such as Lemonade's declares
  nothing and still cannot satisfy a capability requirement, because an
  undeclared capability is never assumed. The Ollama capability read is bounded
  and cached by the runtime's own content digest, so a refresh loop re-probes
  nothing and a re-pulled tag is probed again; it reads model metadata only and
  never loads or runs a model. `quotabot explain --network` lists the new
  endpoint.
- `quotabot top` now groups the fleet into active, cached, and idle bands so
  usable routes lead and providers with nothing to act on stop competing for
  attention. Headings appear only when more than one band is present, so a
  uniform fleet still reads as a plain list, and a failed, drifted, or
  rejected read is never treated as idle.
- An interactive fleet read now streams progress on standard error: a header,
  one committed line per provider as it settles, and a status line carrying the
  running count, elapsed time, and which providers are outstanding. It is
  written only when standard error is a terminal, so piping standard output
  stays clean, and it covers every command that performs a fleet read.
- `docs/PRINCIPLES.md` states what quotabot refuses to do - no account, no
  subscription or paid tier, no telemetry of any kind, no advertising, no
  inference call, and no hosted service to depend on - along with why each
  refusal exists and the command that verifies it rather than asking to be
  believed. The README carries a short version.
- Seven more `top` palettes so the live view can match the terminal it sits in:
  gruvbox, nord, dracula, catppuccin, tokyonight, a monochrome phosphor matrix,
  and a full-spectrum rainbow. Select with `--theme=NAME`.

### Fixed
- A reachable Ollama runtime no longer disappears from fleet snapshots when
  installed-model metadata takes just over two seconds to answer. The essential
  `/api/tags` inventory now has a five-second deadline, while optional loaded
  state and capability detail remain on their shorter bounded deadlines.
- One-shot CLI reads no longer wait about 15 seconds after their output is
  complete. The pooled HTTP client that keeps fleet requests reliable now
  closes when the CLI, stdio MCP server, or routing example exits, while the
  desktop and long-running servers retain connection reuse for their lifetime.
- An embedding model can no longer be recommended as a route. Ollama declares
  `completion` for every model that can generate text and LM Studio types a
  model `embedding`, so a model declared that way is now excluded from model
  suggestions, with a reason that says so when nothing else is reachable. It
  stays listed by `quotabot models`, labeled `embedding`, because listing is
  inspection. Previously a small embedding model could outrank a real coder
  model on hardware fit and win a local suggestion it could never serve. A
  runtime that states no kind keeps its models routable: requiring a capability
  fails closed, but excluding a model fails open.
- Windows consoles are now assumed to support 24-bit color. Neither conhost nor
  `cmd.exe` advertises truecolor through `COLORTERM` or `TERM`, so detection
  downgraded them to sixteen flat colors, which silently discarded the gradient
  meters and made every palette render identically.
- A provenance tag no longer shrinks the meter to a stub. The tag was budgeted
  against the bare minimum bar, so a mid-width terminal could render a worse
  frame than a narrow one where the tag simply did not fit. At 100 columns or
  more the tag that repeats identically on every healthy row is dropped so the
  meter can use the width; rows with something to disclose always keep theirs.
- `quotabot uninstall --purge` removed only the cache directory on Windows,
  targeted a macOS path quotabot does not use so it silently removed nothing,
  and ignored `XDG_CONFIG_HOME` on Linux. OAuth grants, profiles, manual
  entries, and leases could survive a purge that reported complete removal. It
  now resolves the same per-user data root the rest of the product uses and
  reports when something could not be deleted.
- Lease and pipe-health discounts printed a literal `(-% reserved)` and
  `(-% degraded)` on the route glance line instead of the discount amount.
- The desktop dashboard could sit permanently empty while reporting a failed
  refresh. Advisory analytics notices were computed in a second isolate with no
  fallback after quota had already been collected, so an isolate that could not
  spawn discarded a good fleet read; on a cold start there was no previous
  snapshot to retain. The same refresh also loaded history and buckets from disk
  inside its `setState` callback, where a throw mutated state without ever
  scheduling a rebuild. Analytics now fall back to the calling isolate and then
  to no notices, are bounded by their own deadline, and all analytics loading
  happens before state is touched, guarded per provider.
- The whole-collect deadline was shorter than a realistic slow fleet read, so
  every refresh timed out and a cold start never displayed anything.
- Refresh results were applied without `setState` whenever tracked window
  visibility said hidden, so a desynced flag froze the dashboard on its first
  frame with no recovery. Window visibility now follows the events the platform
  actually emits, including a window shown by the single-instance doorbell,
  which emits `show` rather than `restore`.
- A fresh install with nothing connected counted every poll as a failed read and
  backed off to a multi-hour interval, so a provider connected outside the app
  stayed invisible until a manual refresh. Nothing configured is now treated as
  a setup state.
- Window resizing after a refresh could be deferred to a frame that was never
  scheduled, leaving content clipped until unrelated activity forced a repaint.
- Listing profiles no longer throws out of desktop startup when the per-user
  config directory is missing or unwritable; it degrades to the default profile,
  matching how preference loading already handles that failure.
- Owner-only hardening no longer repeats work that cannot change its outcome.
  The account identity is resolved once per process rather than once per
  hardened file, and a metadata directory is enforced once rather than on every
  write into it. Enforcement shells out synchronously, so the repeats blocked
  the event loop and serialized provider reads that are otherwise concurrent; a
  full fleet read is now roughly twice as fast. Files are still hardened
  individually, because each write replaces them through a temporary path.

### Changed
- Scoped mixed-version Analytics recovery now previews whether raw history or
  aggregate buckets have one exact checkpoint-proven merge or require
  archive-and-reset. Confirmed exact merges archive both originals first. Raw
  history validates every row and ordered branch before installing the capped
  chronological union. Aggregate recovery validates ordering, retained suffixes,
  additive dominance, histograms, moments, exhausted counts, and extrema before
  installing canonical plus legacy minus the shared checkpoint. Evidence
  manifests record the installed row or bucket count and SHA-256. Ambiguous or
  malformed evidence retains the fail-closed reset behavior.
- Desktop widget tests now enforce labeled controls, 28 by 28 desktop targets,
  and text contrast across expanded, compact, and Analytics surfaces in light,
  dark, and Hacker themes. Native keyboard and screen-reader evidence remains a
  separate release gate.
- Packaged desktop readiness now writes a bounded v3 report for both passing and
  failing runs. Failure evidence names the completed stage without retaining raw
  errors, logs, or filesystem paths, and CI and release workflows preserve the
  report even when readiness fails.
- Compact desktop mode now pins the shared routing answer as a `Next` provider
  or explicit `No route` control, including the selected account when account
  labels are enabled. Pointer, keyboard, and assistive activation open the same
  explanation and selectable decision id as expanded mode, and explicit widget
  focus order keeps every horizontally clipped provider chip reachable.
- The expanded desktop recommendation now has a visible, keyboard-accessible
  details control for the shared reason, evidence freshness and scope, spend
  class, fallback, and selectable decision id. First-run provider review now
  records completion after the Providers dialog closes; explicit Dismiss still
  completes immediately.
- Packaged Windows readiness is now isolated from the user's installed tray
  instance, and every packaged readiness run uses isolated local quotabot
  configuration. The v3 harness report retains a UTC timestamp, launch PID, and
  narrow runner executable SHA-256 plus a bounded deterministic digest, entry
  count, and byte count for the complete Flutter bundle. The bundle is hashed
  before launch and after cleanup, so the gate fails if product code, plugins,
  or assets change during readiness. Native window and tray results and
  confirmed process cleanup remain part of the report, while archive checksum,
  provenance, signing, and accessibility evidence stay separate release claims.

### Fixed
- Light theme muted copy and Analytics status, routing, token, cost, and trend
  text now use contrast-safe display colors instead of low-contrast dark-theme
  accents on white cards. Chart fills retain their existing visual palette.
- Desktop startup now reapplies rendered-content sizing after native window
  setup finishes, preventing the initial fixed height from cutting off the quota
  list on cold starts, including at large text sizes.
- MCP Streamable HTTP now requires a bearer token of at least 32 characters and
  rejects POST bodies without a declared length or above 256 KiB before the
  pinned transport can buffer them. This closes a local unauthenticated memory
  exhaustion path while leaving stdio unchanged.
- `quotabot watch` no longer writes configured webhook URLs to diagnostics.
  External-host rejection and the startup banner now report delivery state
  without persisting secret-capable path or query values.
- Compact desktop sizing now reserves room for the visible route label and, when
  enabled, duplicate-provider account identity. Large-text compact controls stay
  visible, provider interactions honor reduced-motion settings, and window
  chrome targets retain at least a 28 by 28 logical-pixel hit area.
- Continuous `quotabot watch` now rejects malformed intervals and reports one
  actionable failure edge plus one recovery edge while retrying with bounded
  backoff. JSON standard output remains reserved for alert records.
- If native tray initialization fails, the desktop app now shows a bounded
  warning that Close will exit instead of silently changing window behavior.
- Default quota snapshots now include a bounded
  `quotabot.analytics-incident-inventory.v1` object. Mixed-version analytics
  incidents remain visible when an account is no longer in the current
  snapshot, while profile and exclusion views inspect only their visible rows.
  Complete, partial, truncated, invalid, and unverifiable scan outcomes are
  explicit. Incident records contain no unavailable account, account digest,
  path, or recovery authority; a current incident carries only its safe
  provider-row index for automation joins.
- Mixed-version analytics warnings now lead to a scoped local recovery path.
  `verify --recover-analytics=PROVIDER --account=EXACT_ACCOUNT
  --tier=history|buckets` performs a no-write inspection; adding `--yes`
  archives only that exact tier into an owner-only, digest-verified evidence
  bundle. It exactly merges raw history when the ordered checkpoint uniquely
  proves both valid branch deltas; ambiguous history and aggregate buckets
  restart empty. The command makes no provider call, preserves unrelated quota
  and local state, and keeps any unselected tier quarantined. Recovery holds both
  legacy and canonical evidence locks, refuses legacy files shared by colliding
  account identities, and returns the retained evidence receipt on retry. The
  desktop warning now states that recovery requires the separately installed
  CLI instead of implying that the desktop can perform it.
- `check <provider>` now invokes only that built-in adapter instead of refreshing
  the full fleet. Filtered `verify --require-live` runs only the adapters allowed
  by its profile, exclusions, and local-only policy, and its observed runtime
  access names that exact contact scope. Account filters remain post-collection
  because multi-account adapters must return their account set first.
- CLI `check` now accepts `--account=EXACT_ACCOUNT`, identifies automatic
  multi-account selection, and adds capture age, simulation origin, live-read
  result, bounded transport diagnostics, and runtime-access evidence to
  `quotabot.check.v1`.
- Deterministic simulation now ignores ambient route leases and passive
  installed-tool detection, marks every human quota surface as synthetic, and
  records `snapshot_source: "simulation"` on CLI snapshots. A mock run now
  produces the same route on machines with different local lease state.
- Weekly Markdown reports now anonymize account labels by default, distinguish
  multiple accounts with local report labels, and require
  `--include-accounts` before provider-visible labels are included. The report
  also names its decision id and evidence source.
- `doctor` is now described consistently as the truthful inspection and repair
  view. Setup guidance points strict automation to scoped
  `verify --require-live` instead of implying that a successful `doctor` exit
  proves every adapter read is fresh.
- The README now puts the verified install, `doctor`, and `suggest` path before
  provider internals, and its screenshots and animation are regenerated from the
  current card, analytics, compact-strip, and terminal surfaces.
- Fresh provenance now reads "captured just now" instead of "captured 0s ago"
  across CLI, desktop, and reports. The interactive terminal says "copy
  requested" after sending OSC 52 because terminals do not acknowledge whether
  they accepted the clipboard request, and global CLI help now describes the
  current machine-readable output surface accurately.
- Temporary provider pushback now reads as "provider slow - retrying" for a
  request timeout, "rate limited - retrying" for HTTP 429, or "provider error -
  retrying" for HTTP 5xx across desktop, `quotabot top`, and trust detail. The
  amber recovery state remains distinct from a broken login or bad response.
- The adaptive refresh cadence now leans gentle by default (fast only when a reset
  is imminent, about twenty minutes at the healthy baseline, up to twice a day as
  resets recede) because quota moves slowly and a cloud read can be rate-limited.
  When provider pushback continues, the back-off escalates each consecutive
  retry cycle - twenty minutes, then forty, then ninety - and honors an
  explicit retry-after, so quotabot stops checking a provider that keeps pushing
  back instead of re-hitting it. An imminent reset is still caught promptly.
- Desktop card interactions were polished: a hover accent edge and click cursor on
  expandable cards, a rotating expand chevron, an eased pill quota meter with a lit
  gradient fill, and the plan shown as a subtle chip badge.

### Fixed
- Provider quota rows no longer truncate common window names such as `monthly`
  or actionable far reset times at narrow widths and 200 percent text. Large
  text reflows the label and value above a full-width meter, while ordinary
  layouts give reset text safe wrap points instead of replacing the time with
  ellipsis. Unusual provider-supplied labels retain complete tooltip and
  assistive text.
- Compact resizing now clamps and repositions the strip inside its active
  display work area. README capture also reapplies the mode-specific native
  minimum and rendered-content geometry before each frame, so compact media is
  content-hugged and the first expanded image cannot omit a later provider.
- The expanded desktop no longer drops its routing answer when no provider is
  safe. It shows an explicit fail-soft fallback and keeps the full no-route
  reason inspectable, while stale evidence remains unroutable. Signed-out
  Claude, Codex, Grok, and Antigravity `doctor` rows now name their exact login
  command, and shared no-data copy delegates provider-specific recovery to
  `doctor` instead of listing only two providers. Throttled and degraded reads
  remain automatic retry states.
- The expanded desktop quota window now sizes from the rendered provider cards
  instead of trusting a hand estimate, so wrapped status and recovery rows no
  longer leave the final provider partially hidden. Growth is reconciled with
  the active display work area, and an explicit scrollbar appears only when the
  complete list cannot fit on screen. Returning from Analytics resumes the same
  content-hugged, display-bounded quota layout.
- Analytics incident inventory now rejects a directory, link, or other
  non-regular evidence-lock path before invoking permission helpers. Corrupt or
  hostile local lock state therefore fails soft without an avoidable Windows ACL
  delay.
- Analytics quarantine no longer disappears or falls back to ordinary warming
  copy solely because the affected account is unavailable. Existing valid
  markers are upgraded under the identity evidence lock with explicit conflict
  state, a stable random incident reference, and a first-recorded timestamp.
  Desktop Analytics and `doctor` use neutral account-availability wording,
  explain the reconnect requirement, preserve the CLI-install handoff, and warn
  when a bounded inventory scan cannot prove a clean result.
- Mixed-version writes can no longer silently split account-scoped analytics
  between canonical and legacy filenames. Versioned, permission-hardened
  checkpoints
  detect divergence, preserve both generations, and exclude only the affected
  history tiers from displayed analytics. Divergent legacy data cannot affect
  routing; a frozen last-trusted account baseline, or the already eligible
  compatibility series for one unambiguous account, remains available with an
  hourly-boundary conservative burn estimate enforced after cross-provider
  pooling. Healthy competitors retain the current-offset pooled result, so
  quarantine cannot improve relative route rank as evidence ages or when
  collection occurs between hour boundaries.
- Quota Analytics now distinguishes quarantined local history from a new
  installation that is still warming up. Historical ranges show one accessible
  warning, `doctor` prints every affected tier, and bucket-affected `stats
  --json` rows carry a bounded `storage_notice`; the current quota and **Now**
  views remain available.
- The TypeScript MCP client lockfile now resolves `fast-uri` 3.1.4, closing the
  host-confusion issue in GHSA-v2hh-gcrm-f6hx without changing the direct MCP
  SDK dependency.
- Antigravity Cloud Code failures now retain the bounded request stage, HTTP
  status, and parsed `Retry-After` delay instead of collapsing every non-200
  response into missing live quota. Authorization failures keep the documented
  local fallback and reconnect guidance, while rate limits and service errors
  feed the existing stale-evidence and adaptive-backoff paths without storing
  response bodies.
- Desktop and terminal retry notices now distinguish a slow timeout, an HTTP
  rate limit, and a provider service error instead of labeling all three as
  quota throttling. First-read failures lead with recovery timing, retain the
  bounded diagnostic in details, and do not offer reconnection for temporary
  provider pushback.
- Quota Analytics now grows a short content-hugged quota window into a useful
  display-bounded viewport on entry, keeps a visible scrollbar when its cards
  exceed the available height, stacks card headings at large text sizes, and
  returns to quota or compact-strip sizing on Back.
- Provider-card disclosure chevrons now align with the trailing card padding
  instead of drifting inward beside short plan badges such as `AI Pro` or `Pro`.
- Strict `verify --require-live` now fails closed when filters select no provider
  adapters. The JSON record includes `selected_adapter_count` and
  `live_read_scope_valid`, and human output names the empty scope instead of
  displaying a green vacuous result.
- A known provider hidden by a profile is now described as filtered rather than
  unknown, and check fallback guidance distinguishes unavailable exit 69 from
  usage errors.
- Antigravity reads now use an existing Cloud Code project returned by
  `loadCodeAssist` instead of repeating account onboarding in every new process.
  Already-onboarded accounts avoid an unnecessary mutation and its extra
  timeout or provider-throttle boundary. Cloud Code requests now use a
  15-second deadline under the existing 30-second whole-adapter ceiling, which
  avoids reporting ordinary 10-second response variance as throttling.
- The TypeScript MCP client sample now pins the transitive Hono Node adapter to
  a patched 2.0 release, closing the Windows static-file path traversal reported
  in GHSA-frvp-7c67-39w9 without changing the sample's MCP SDK version.
- `quotabot.report.v1` now retains the selected account, decision code, complete
  content-blind receipt, capture time and age, stale and machine scope, plus
  bounded error, drift, pipe-health, HTTP, and retry evidence. Stored reports
  can now be correlated with the same routing decision on other surfaces.
- README demo capture now uses an isolated single-instance guard, resolves the
  discovered Flutter executable before changing build directories, builds from
  the existing locked package resolution, and carries normalized loaded models
  in its synthetic local-runtime data. Maintainers can regenerate truthful demo
  media while the installed tray app remains open.
- Live reads no longer time out spuriously during a fleet poll. Each provider read
  used the top-level `http` helpers, which open and discard a fresh connection per
  call, so a concurrent poll opened many cold DNS/TLS connections at once and the
  heavier endpoints (Codex behind Cloudflare, Antigravity's load-then-fetch
  sequence) missed their deadline even though the same call is fast in isolation.
  Reads now share one pooled, keep-alive client so connections are reused, and the
  ChatGPT usage endpoint gets more timeout headroom for its slower cold connect.
  Antigravity and Codex read live again.
- Claude live `/usage` reads no longer fail as an invalid response when Anthropic
  ships additive non-account blocks alongside the authoritative `limits` array
  (usage-credit `spend`, `extra_usage`, per-model and rotating codenamed weekly
  windows). The account 5 hour and weekly windows and the scoped Fable row parse
  as before; the strict unknown-root-block guard now applies only to the older
  response shape that has no `limits` array.
- Antigravity live quota windows are no longer discarded when the Cloud Code
  model table includes non-metered helper models (tab-completion and chat models
  that carry no reset window). Those rows are skipped instead of rejecting the
  whole table, while a genuinely malformed metered row still fails closed.
- Adaptive refresh no longer polls a provider every few minutes when it is spent
  but its reset is days away. A near-empty window is watched closely only while
  its binding window's own reset is near; otherwise it relaxes to the slow
  cadence, so a long-spent provider cannot pull the whole fleet into fast polling
  or trip provider rate limits.

### Changed
- The desktop provider card defaults to a tight view (the binding windows and
  reset time). Clicking a card expands it to reveal the full provenance line,
  model-specific quota, and analytics. The failure, drift, and last-known signals
  stay visible in the tight view because they are always actionable.
- A provider whose live read failed and that supports quotabot's own login
  (Grok, Antigravity) shows an inline Connect action on its card, so the account
  can be reconnected from the app without a terminal.

## 0.9.3 - 2026-07-19

### Security
- Cursor and Windsurf now query exact provider-owned metadata rows and project
  only approved quota, reset, capture-time, and identity fields. Prompt,
  conversation, code-context, and unrelated SQLite rows cannot become quota or
  account evidence even when their text contains quota-like keys.
- Claude and Codex cache, drift, history, and profile identities are isolated by
  irreversible credential-generation fingerprints. Codex account identity and
  quotabot-owned grant identity survive access-token and refresh-token rotation.
  Claude also hashes current provider profile account and organization ids into
  a stable snapshot, cache, drift, and lease key, collapsing host and quotabot
  credentials for the same subscription. If profile identity is unavailable,
  only one successful Claude credential remains routable. This can under-route
  but cannot count one plan twice. Codex response email is ignored as an
  identity source.
- OAuth token refreshes now load credentials and their owner as one immutable
  record, serialize writers and refresh side effects with per-slot
  process-and-isolate guards, and replace only the exact generation that was
  loaded. The claim-backed native guard releases the native lock before its
  owned claim, so a stale refresh cannot overwrite a completed login or account
  replacement.
- Draft release publication is bound to the exact audited GitHub release id and
  a digest of its complete asset manifest, then rechecks the tag, release, and
  current `main` tip immediately before publishing.
- The loopback HTTP server now limits writes to authenticated lease reserve and
  release operations. It creates a stable owner-only bearer token before
  startup, never prints it, rejects unbounded or malformed bodies before quota
  collection, and accepts only bounded provider-routing metadata.
- The plain loopback HTTP server rejects external or null browser origins and
  originless cross-site or same-site subresource requests before collection.
  Normal non-browser clients without Fetch Metadata and explicit user-activated
  top-level navigations remain supported.
- Credential and loopback mutation-token readers now reject symlinks and other
  non-regular files before permission hardening or content reads, so a planted
  link cannot redirect quotabot into an unrelated file.

### Changed
- Concrete CLI and MCP model suggestions now default to the no-surprise `quota`
  budget. Model listing remains unrestricted for inspection, while selecting a
  credit-backed or paid catalog entry requires explicit `budget=any` and states
  that included quota is not proven.
- Saved profile provider preferences now apply consistently to recommendations
  in `doctor`, `top`, `watch`, and weekly reports, matching `suggest` and MCP.
- CLI, desktop, loopback HTTP, MCP, alerts, and reservations now build routing
  decisions from the same capability, preference, burn, pipe-health, and active
  lease context.
- The deprecated `subscriptionsFirst` profile value remains readable as a wire
  alias but is saved and shown as the single honest cloud-first policy.
- Release builds now verify exact CLI archive paths before attestation and
  upload. Four clean native runners redownload the draft archives, reverify
  restricted provenance, and require both the tagged version and demo-mode
  doctor schema to work before publication.
- CI now builds and validates native CLI archives alongside desktop packages.
  CI, currency checks, and release builds enforce committed Dart and Flutter
  lockfiles instead of allowing dependency resolution to repair them silently.
- CI and release workflows bootstrap the audited official Flutter 3.44.6 source
  commit through a repository-owned helper. The build no longer executes a
  nested mutable marketplace action for its toolchain.
- Source setup and packaging helpers now enforce the same committed lockfiles,
  and desktop builds disable implicit dependency resolution after that check.
- Prerelease version tags are published with GitHub's prerelease classification,
  and a resumed draft must already have the matching classification. The
  published install smoke resolves GitHub's canonical latest stable release
  instead of relying on release-list ordering.
- Release creation now verifies the existing remote tag, and both draft resume
  and publication recheck that its peeled commit still matches the workflow
  commit. Checkout credentials are not persisted in jobs that execute candidate
  binaries. The official repository also blocks `v*` tag updates and deletion
  and enables GitHub release immutability for publications after the setting
  was activated on July 18, 2026.

### Fixed
- Claude account-wide reads no longer become a false 100% free after a cached
  reset passes. Invalid percentages are rejected, model-scoped Fable limits
  remain scoped, and same-plan host or grant replacements cannot borrow another
  credential generation's cache or drift identity. Legacy Claude profile
  filters that used a plan as the account remain exact and surface for repair
  instead of being silently broadened.
- Claude admits each live usage body atomically. A valid session row cannot
  survive a missing or malformed binding weekly row, and valid Fable or other
  model rows cannot survive a malformed recognized scoped sibling. Present
  known legacy blocks are validated with the same fail-closed rule, while an
  explicit null optional legacy Opus block and unknown additive fields remain
  compatible.
- Claude Fable 5 no longer carries the obsolete temporary catalog cutoff. It is
  quota-backed only when the current provider response contains a live scoped
  Fable pool and current provider usage or profile metadata read with the same
  credential confirms a Max or Team Premium entitlement on or after the
  announced July 20, 2026 UTC policy boundary. A
  locally stored Claude `subscriptionType` is explicitly marked
  as host-credential evidence and cannot prove inclusion after an entitlement
  change or positively classify credit-backed spend. Pro, Team Standard,
  host-label-only, and plan-unknown rows stay visible
  under the unrestricted model budget but cannot enter the no-surprise quota
  budget. Doctor and desktop scoped rows state whether spend is included,
  credit-backed, or unproven. The dated July 20
  plan policy never substitutes for a measured balance.
- A whole desktop or interactive refresh failure now preserves the last trusted
  values with their original capture time and marks every retained row stale and
  unroutable. One failed fleet read can no longer present old evidence as live.
- Explicit provider reservations validate and write under one interprocess
  transaction. Parallel dispatch cannot reserve stale eligibility or overstate
  remaining headroom, including parallel isolates in one POSIX process. Lease
  generations use exclusive random temporary files flushed before rename. A
  process that loses an exclusive claim creation now retries when the winner
  releases the claim before its follow-up probe, instead of reporting the lease
  store unavailable under Windows load. Only known file-exists errors retry;
  permission and path failures remain fatal. Claim ownership is published before
  hardening, failed setup removes only its own generation, and claim reads stay
  bounded and revalidate the path generation. Codex provider health also treats
  99% used as available; the router's comfort buffer no longer masquerades as
  provider exhaustion.
- Strict verification now distinguishes a valid exhausted live reading from a
  failed adapter. Unknown Claude and Codex quota-shaped binding pools are
  rejected atomically while benign additive metadata remains compatible.
- Added explicit provider/account-scoped drift baseline recovery through
  `quotabot verify --recover-drift=PROVIDER --account=EXACT_ACCOUNT --yes`.
  Recovery requires a fresh targeted live verification plus atomic generation
  checks, refuses failed, stale, malformed, duplicate, or superseded evidence,
  and leaves history and other accounts untouched. Provider text is sanitized
  before diagnostics or persistence, confirmation guidance never renders a
  provider-controlled shell command, and injected test clocks are bounded
  against real time before collection.
- First-run loopback mutation-token creation is process- and isolate-safe. Two
  servers starting together publish one complete owner-only token and cannot
  overwrite one another.
- Desktop setup preserves every Claude and Codex account row. A live host login
  cannot hide a failed grant, and bounded opaque account labels make each repair
  action target clear without exposing credentials.
- Desktop connection recovery now succeeds only when the selected exact account
  becomes live. Provider cards, setup actions, plan labels, and long reset
  guidance remain bounded at a 320 pixel window and 2x text scale.
- Grok fallback grants now require an exact stamped account owner. A legacy
  unowned default grant is never used or refreshed for a requested account.
- POSIX installer transaction tests canonicalize their temporary root so the
  macOS `/var` alias cannot bypass injected activation-failure assertions. The
  harness also loads its marked production functions through a checked regular
  file, keeping them available under the system Bash 3.2 shipped by macOS.
- Windows hardware-fit discovery reads physical memory through the local
  `ComputerInfo` API and falls back to CIM inside the same bounded PowerShell
  process. Values are integer KiB with invariant formatting. A host metadata
  command can still fail soft to unknown, and the live smoke test now honors
  that documented advisory contract instead of intermittently failing CI.
- Concurrent credential-refresh tests now isolate operating-system permission
  subprocesses from serialization, while dedicated security tests retain real
  owner-only enforcement. They always release their test gate and perform a
  bounded drain before temporary-directory cleanup. The multi-process
  manual-quota doctor test has an explicit integration-test allowance, and
  Windows test-suite fanout is capped to keep process and file-lock integration
  checks deterministic on high-core hosts.
- Codex no longer reads mixed-content rollout files for a this-machine quota
  fallback. It uses account-wide metadata or fails closed with a login repair,
  preserving the promise that quota collection never reads prompts or responses.
- Codex accepts the current Pro response shape with a weekly primary window and
  an explicit null secondary window. Labels follow the provider's duration, and
  named `additional_rate_limits` such as GPT-5.3-Codex-Spark remain sparse
  model-scoped gates instead of replacing or blocking the shared account limit.
  Live windows now require a bounded minute-aligned duration and positive reset,
  sparse rows are admitted atomically, and each scoped gate preserves its
  provider window identity through cache, JSON, MCP, routing, drift checks, and
  the desktop. Window identities are bounded and validated before they can
  influence routing or presentation.
- Codex plan and email labels no longer key cache or drift evidence. Legacy
  provider-wide cache and old profile account labels fail closed until a fresh
  credential-scoped read or explicit profile repair.
- Quota adapters now reject impossible fractions, preserve exhausted binding
  windows, normalize timestamp units, merge duplicate pools conservatively,
  validate Grok trailers, and fail closed on malformed provider responses.
- Antigravity admits its live model quota table atomically, so one malformed or
  incomplete sibling rejects the whole response instead of hiding a binding
  pool. Kiro projects quota only from the exact
  `kiro.resourceNotifications.usageState` child and ignores unrelated agent
  state.
- Passive Cursor, Windsurf, and Kiro quota now requires a row-owned capture
  timestamp before routing. Unrelated SQLite or WAL writes cannot renew old
  quota evidence; missing-time values remain visible as unverified.
- Ollama, LM Studio, and Lemonade refuse non-loopback host overrides without
  contacting them. Cloud-offloaded or errored runtimes cannot become a local
  fallback, while their configuration problem remains visible for repair.
- Desktop refresh copy distinguishes when evidence was checked from when it was
  captured, preserves the last observed value on failure, explains account-wide
  versus this-machine scope, and never forecasts from suspect evidence.
- Interactive `top` serializes collections, coalesces repeated refresh keys,
  owns one refresh timer, rejects late results after exit, and never recommends
  a provider hidden from the current view.
- Routing no longer revives a cloud candidate whose burn, lease, or pipe-health
  adjustments depleted its effective headroom. Provider-only availability
  checks in CLI, MCP, and HTTP choose the best current account deterministically
  instead of trusting the first account returned.
- The LiteLLM hook now atomically reserves from its complete eligible remote
  target set before dispatch. Parallel requests see each other's local lease
  discounts, completion and failure callbacks release their leases, and TTL
  expiry covers abandoned callbacks. Missing mutation authentication falls back
  locally or fails a managed route closed.
- Desktop route details name only adjustments that actually applied. Alert
  delivery is single-flight under slow webhooks, legacy Codex filters get the
  same repair path as Claude, and an empty profile now renders its actionable
  state even when account labels are hidden.
- Compact provider chips are keyboard-focusable and scroll the focused item into
  view. Analytics sparklines and heatmaps expose assistive semantics, custom
  charts honor composed text scaling and repaint when it changes, and native
  low-quota, scheduled-reset, and reset-available notifications apply the
  account-name preference consistently to their body and Windows subtitle.
- The loopback HTTP, webhook, LiteLLM, and MCP client boundaries now cap work and
  response sizes, validate exact loopback origins, resist routing metadata
  spoofing, coalesce collection, and remain responsive during slow reads.
- Provider OAuth helpers no longer retain default HTTP connection pools across
  calls. Injected clients remain caller-owned and refresh-token persistence is
  unchanged.
- CLI installers and source setup now activate one complete versioned payload
  generation, so a concurrent launch cannot combine a new executable with an
  old native library. Activation is serialized, a failed replacement restores
  the prior target, and uninstall guidance removes the private generation store
  without deleting quota data. Full macOS and Linux source setup stages both CLI
  and desktop generations before activation and restores both stable payload
  targets if either activation fails. Windows source setup also restarts a
  desktop app that it stopped even when activation fails and restores the prior
  bundle. Full Windows source setup now stages and validates both candidates,
  activates them under paired locks, and restores both prior payloads if either
  activation fails.

## 0.9.2 - 2026-07-18

### Security
- Python and TypeScript MCP examples now validate an exact loopback HTTP URL
  before reading a bearer token or creating a transport. External hosts,
  lookalikes, numeric aliases, credentials, fragments, whitespace, and
  backslash-confused URLs are rejected.
- Managed LiteLLM routes now fail closed when policy, availability, target, or
  spend evidence is missing or malformed. Runtime access reports also identify
  credential-exchange metadata accurately and use the real history paths.

### Changed
- CLI, loopback HTTP, and MCP validation now rejects unknown or misplaced
  options, extra positionals, invalid task/model/risk values, inverted tiers,
  unknown query names, and malformed model quota evidence before live provider
  collection. `--` now ends CLI option parsing as documented.
- Account-scoped cache, drift, history, analytics, lock, and lease filenames now
  use collision-resistant opaque keys. Exact-account legacy data migrates on a
  one-way upgrade, while ambiguous legacy aggregate ownership fails closed.
- Tagged releases now run CI, CodeQL, and secret scanning against the exact tag
  commit and reject tags outside `main`. SQLite is updated to 3.5.0 and the
  hash-locked LiteLLM integration to 1.92.0.
- Claude source guidance now records Anthropic's July 17 plan announcement:
  beginning July 20, Fable 5 is included for Max and Team Premium at 50% of
  limits, while Pro and Team Standard use credits. Runtime quota values still
  come from the provider response and are never hardcoded.

### Fixed
- Claude collection now falls through malformed host credentials to an
  independent quotabot grant, and a failed grant loader no longer suppresses a
  stale host token's last-chance account-wide read. Invalid legacy percentages
  are rejected instead of being clamped into plausible quota.
- Desktop quota and analytics views exclude stale, drifted, missing-time, and
  future-dated evidence from live totals. Account privacy mode now hides account
  labels and grouping, while chart semantics, contrast, and keyboard behavior
  are clearer for assistive technology.
- Connecting a provider during another refresh now waits and then performs a
  post-login collection. Profile edits preserve routing preference order,
  failed deletes keep the profile visible, and new profiles support autofocus
  and keyboard submission.
- Desktop startup now restores windows across removed or rescaled monitors,
  centers first-run windows, preserves runtime taskbar preferences on a second
  launch, and acknowledges the single-instance handoff only after the existing
  window is actually shown.
- Cached provider envelopes and scoped model quota rows with impossible ages,
  resets, or percentages are quarantined instead of routed. Verification keeps
  cached reset language distinct from a trusted fresh reset.
- Provider reservation selection and creation now share one storage lock.
  Idempotent reuse is limited to the current profile, account, and exclusion
  scope, preventing parallel dispatches from silently reusing an ineligible
  provider.
- Loopback HTTP reads are coalesced while in flight and timestamped after slow
  collection, and OAuth callback listeners close when browser launch fails.
- Release and source installers now stage complete CLI payloads beside the live
  install, serialize activation, and restore the previous payload if activation
  fails. A validated exact-tag selector uses the same path for rollback. Windows
  downloads use a unique temporary workspace, and package helpers serialize the
  archive/checksum swap and restore the last good pair if either activation
  fails. Source setup installs desktop bundles at stable per-user locations on
  every platform, so launchers no longer depend on the source checkout.

## 0.9.1 - 2026-07-18

### Added
- Local model routing now includes a passive hardware-fit signal. Reachable
  on-device models are ranked by direct loaded state, then conservative
  `comfortable`, `tight`, `unknown`, or `constrained` RAM/GPU fit. JSON and MCP
  expose the model estimate, selected memory pool, available and total bytes,
  and observation time. Linux, Windows, macOS, and multi-GPU parsers are pinned
  by tests; probes are bounded, cached, fail soft, and never load or invoke a
  model. Cloud-offloaded daemon entries remain outside the hardware-fit path and
  sort behind on-device entries.
- Tagged releases now build native portable desktop archives for Windows x64,
  macOS Apple Silicon, and Linux x64. Every archive gets a matching SHA-256
  sidecar, bundle-shape validation, build-provenance attestation, and a
  draft-release barrier. Clean native runners download the exact uploaded
  archive, reverify it, exercise side-by-side update, rollback, and
  data-preserving uninstall mechanics, and repeat Windows/Linux window and tray
  readiness before publication. A final exact-set audit blocks missing or stale
  release assets and reverifies every checksum and provenance attestation.
- Provider routing now emits one content-blind `quotabot.receipt.v1` decision
  receipt through CLI JSON, MCP, loopback HTTP, desktop, and integration-facing
  responses. It carries a deterministic decision id, snapshot provenance,
  policy, binding pool, spend classification, raw and effective headroom, every
  adjustment, confidence reasons, winner qualification, rejection verdicts for
  alternatives, and the fail-soft fallback. The human surfaces share one full
  explanation covering the pick, evidence freshness and source, spend class,
  and fallback.

### Fixed
- Claude now reads Anthropic's current `limits` array, including live
  model-scoped weekly allowances such as Fable, while retaining compatibility
  with the older top-level usage fields. Scoped limits gate and display only the
  matching model, so exhausting Fable cannot incorrectly block every Claude
  model while the shared session or weekly plan still has headroom. Older cache
  snapshots that stored a scoped family as a provider window migrate without a
  false drift quarantine.
- Cached cloud quota no longer becomes a misleading 100% free when its reset
  boundary passes after a failed live read. Stale windows retain their original
  capture time and last observed percentage across CLI, desktop, `top`, alerts,
  verification, routing, and MCP output, and remain unavailable for routing.
- Claude now identifies a definitively expired saved login in failed-read
  diagnostics while preserving HTTP throttle metadata and pointing at both
  recovery paths. Claude and Codex also resolve their optional quotabot grants
  only after a fresh host token fails, so an unavailable grant cannot suppress a
  valid account-wide host-token read or cause needless token refreshes.
- Adaptive polling ignores stale, drifted, manual, and local-runtime evidence
  when choosing urgent fleet refreshes, so an old low-quota snapshot cannot
  force repeated fast provider reads.
- The Python and TypeScript MCP client examples now require both routing tools.
  Python summaries also reject booleans and non-finite headroom values and never
  serialize non-standard `NaN` JSON.
- MCP `suggest_provider`, `decide_now`, and auto `reserve_provider` now apply a
  named profile's `preference_order` the same way the CLI does. Profile
  filtering already limited which providers were visible, but the preference
  reorder among viable candidates was CLI-only, so an agent calling MCP with
  `profile` could get a different winner than `quotabot suggest --profile`.
  Cache-only `decide_now`, reserve auto-select, and the MCP alert subscription
  poll also route through the shared `decide` front door so they cannot drift
  from live suggestion inputs.
- `quotabot report --json` now includes each provider's `spend_class` when
  known, matching the Trust column already shown in the markdown report.
- The shared routing explanation says evidence was captured "just now" when
  the age is under one second, instead of the stilted "captured 0s ago".
- The `report` health surface now labels a provider that is showing a
  held-during-drift snapshot as "provider drift", matching `top` and the desktop
  app. Its read-state classifier omitted the drift check, so a drifted provider
  could read as an ordinary live or cached number in the report only.
- A passive-local metered read (Kiro, Cursor, Windsurf, from a VS Code-fork
  `state.vscdb`) whose window's reset has already passed is no longer shown as a
  confident 100% free. The local file predates the reset and quotabot never
  observed the refresh, so the post-reset usage is unknown; such a read is now
  marked stale with a caveat ("local usage predates its reset (Nd ago); open
  <provider> to confirm current headroom"), routing declines to rely on it, and
  the glance shows it as a last-known value rather than a live one.
  A fresh successful provider read can still establish a rolled window; a
  cached fallback from any source preserves only what was last observed.

## 0.9.0 - 2026-07-13

### Security
- Hardened parsing of a VS Code-fork `state.vscdb` (Cursor/Windsurf/Kiro local
  state, written by another app and not owned by quotabot): the value blob is now
  size-capped before decode and the JSON key-walk is depth-bounded, so a
  pathological or malicious same-user-written value cannot exhaust memory or
  overflow the stack. A defense-in-depth pass over the credential, network,
  loopback, webhook, OAuth, path, injection, and permission surfaces found no
  exploitable issues.
- Antigravity now fails closed when an account without its own stored grant
  borrows the provider-default grant (whose slot is not owner-stamped and may
  belong to another account) and the token's email cannot be verified: rather
  than risk showing another account's quota under this account's label, it
  reports the read as this-machine-only and unverified. An account-specific
  grant is trusted for its account without the cross-check.

### Added
- Provider preference for routing (ROADMAP 0.9). `quotabot suggest
  --prefer=codex,claude` orders the recommendation by your stated preference, but
  only among candidates already viable (available and above the comfort
  threshold), so it never revives an unavailable, spent, or spend-blocked route.
  It persists per profile as `preference_order`; an explicit `--prefer` overrides
  the saved order. The reason names it ("first by your preference") only when it
  actually decided the pick.
- The desktop app fires a "Reset available" notification the moment a provider
  offers a redeemable off-cycle reset (Codex reset credits). It fires once and
  re-arms only on a fresh account-wide read that genuinely reports none, so a
  live read flapping to its this-machine session fallback never re-notifies about
  the same reset.

### Changed
- The redeemable-reset escape hatch is now a first-class, prominent signal.
  Codex's reset credits became a structured `reset_credits_available` on each
  provider (in the JSON too), and `doctor`, `top`, and the desktop card render it
  prominently ("N resets available in Codex - redeem now") so a spent or tight
  provider's way out stands out. It is never asserted from stale or drifted
  evidence, nor served from the cache.
- `quotabot suggest`'s candidates list no longer prints the model's internal
  scores (`conf`, `strand`) on the plain glance - they read as jargon and, on the
  recommended provider, were alarming without explanation. The glance shows only
  headroom, usability, and trust; `suggest --json` still carries
  `strand_probability`, `confidence`, `routing_score`, and `runway_hours`.

### Fixed
- `quotabot suggest` no longer labels a viable-but-unroutable provider "spent": a
  provider with headroom but no catalog model meeting the capability floor reads
  "no capable model", and one whose model-budget gate is closed reads "model
  budget spent", matching the suggest reason.
- `quotabot doctor` no longer shows an unconfigured optional provider as a red
  `ERROR`. NVIDIA NIM without an API key reads as `no live data` with a hint to
  set the key; a present-but-rejected key still fails loudly. A no-window row now
  shows its status instead of a blank.
- `quotabot top` shows provider detail lines on quota cards, including the reset
  escape hatch on a spent card - both the spent-collapse and normal paths dropped
  them - so a spent card shows an available reset, not only a wait time.
- An Ollama `-cloud` model is no longer treated as on-device and free: snapshot
  sanitizing dropped the `cloud_offloaded` flag, so a billable cloud model could
  satisfy `--budget=local` and free budgets. The flag now survives.
- Kiro and Cursor no longer discard every parsed window when a breakdown's
  `resetDate` is a numeric epoch rather than a string, and a numeric reset given
  in milliseconds is rescaled to seconds instead of rendering thousands of years
  out.
- Low-quota alerts and the decision ALERT view no longer fire on stale or drifted
  evidence, and an alert's window label and free-percent now describe the same
  window.
- The loopback HTTP server no longer stops draining if a client disconnects
  before its response is flushed: the response close and error-path write are now
  guarded, so one ill-timed disconnect can no longer hang every later request.
- `quotabot login`/`logout` with a missing or unknown provider now exits with the
  documented usage code (64) instead of 0, and a failed `login grok` reports
  cleanly instead of an unhandled exception.
- The desktop app keeps its last data and shows a failure message when a refresh
  throws an `Error` (not just an `Exception`) instead of failing silently.
- Hardening: a failed token-store write no longer discards a just-refreshed
  access token; the Lemonade adapter no longer leaks an HTTP client per refresh;
  a malformed Codex session `primary` no longer drops the weekly window.
- A profile name that is a Windows reserved device name (`nul`, `con`, `com1`,
  ...) is now rejected, since as a filename it resolves to a device and would
  silently discard the profile's writes.
- The LiteLLM router caches an empty availability result for its TTL instead of
  making a fresh synchronous loopback fetch on every proxied request (a latency
  regression when only local runtimes were connected).
- One provider or account failing no longer takes down an entire fleet read.
  Each provider's collect/admission/fallback pipeline and each Grok account's
  fetch are isolated, so an unexpected throw degrades to a single fail-soft
  error for that provider or account instead of discarding every other result
  gathered in the same fan-out.
- A concurrent desktop app and CLI can no longer lose an analytics sample:
  the long-term headroom bucket update now takes the per-evidence lock around
  its read-modify-write instead of racing on a torn update.

## 0.8.1 - 2026-07-12

### Fixed
- Codex now reflects an off-cycle reset instead of pinning stale scarcity. When
  OpenAI restructured the Codex Pro plan from separate 5-hour and weekly buckets
  into a single weekly window, the vanished 5-hour window tripped the
  fail-closed drift guard, which held the last trusted pre-reset snapshot - so a
  freshly reset account at 5% used kept reading as 93% used, and routing avoided
  a provider that in fact had full headroom. A provider whose window set is
  defined by the provider and can restructure (Codex) is now exempt from the
  window-disappeared drift check; a surviving window's own value is still held to
  the monotonicity and re-rating checks, so an implausible number is still
  caught. The carve-out is scoped to Codex and does not relax any other provider.

### Added
- Codex surfaces redeemable rate-limit reset credits. The live usage response
  carries `rate_limit_reset_credits.available_count` - the off-cycle resets you
  can redeem to refresh your limit early - which quotabot previously dropped. It
  now shows as an actionable line ("N rate-limit reset credits available - redeem
  in Codex to refresh your limit early") wherever provider details render.

## 0.8.0 - 2026-07-12

The first three milestones of the reframed version ladder to 1.0, released
together: 0.6 (truthful substrate), 0.7 (one forecast, one engine), and 0.8
(the calibration moat). See ROADMAP.md.

### Added
- `quotabot calibration` now self-tunes: it fits the burn lookback that makes the
  strand predictor best-calibrated on your own recorded history (lowest Brier
  score), degrading to the shipped default unless enough predictions have resolved
  and a candidate genuinely beats it - it never overfits a thin history. Reported
  as an advisory `tuning` block (fitted lookback plus the Brier improvement over
  the default). `quotabot suggest --tuned-burn` opts in to applying the fitted
  lookback to the burn feeding the routing decision; default behaviour is
  unchanged.
- `quotabot doctor` shows the calibration headline ("N% calibrated over M
  predictions") under the routing suggestion, once enough predictions have
  resolved.
- LM Studio: prefer the current native `GET /api/v1/models` (0.4.0+), which
  exposes loaded-instance context, on-disk size, quantization, and a real
  parameter size, with the older `/api/v0/models` and OpenAI-compatible
  `/v1/models` as fallbacks.
- Provider identity aliases: a rename that changes a provider's id no longer
  silently orphans profiles, hidden-provider choices, filters, manual entries,
  leases, or routing resolution. A one-way alias map (empty until a real rename
  ships, so identity today) is funnelled through every identity seam and guarded
  by tests.
- A single pure decision core, `decide(observations, now, context) -> Decision`,
  that the MCP, HTTP, and CLI suggest surfaces now source from. SEE, ROUTE, and
  ALERT are views of one object, and `replay(frames)` folds the core over
  recorded history deterministically. Behaviour is unchanged; this makes the
  engine one named, replayable object (the substrate for calibration).

### Fixed
- Antigravity now shows its weekly allowance correctly. Its Cloud Code endpoint
  reports each model's single binding limit (its tightest cap across the weekly
  allowance and the short-term burst limit) with only a remaining fraction and a
  reset, and no window type. quotabot was labeling that by reset delta, so a
  weekly whose reset fell within a few hours (the common case near a refresh) was
  mislabeled a "5h" window. It now surfaces the account's most-constrained binding
  limit as a single weekly window with its true reset. The separate burst limit
  and per-model-group breakdown that Antigravity's own CLI shows are not exposed
  by this endpoint; per-model detail stays in the model quotas.
- `quotabot doctor` no longer shows a fully-available short window (a 5-hour rate
  limit at 0% used) next to the longer window that is the real constraint; a
  window is shown once it has been drawn on, and an all-fresh account still shows
  its picture.
- The recent-burn estimate is now reset-aware: it fits only the current draw-down
  run, segmenting at a window refill (a large single-step headroom jump, a
  scheduled or redeemed reset). Previously a reset inside the lookback could make
  the burn read as "recovering" and skew the runway. A rolling window's gradual
  give-back stays well under the threshold and is not segmented.
- An Ollama cloud model (a `-cloud` tag suffix, e.g. `qwen3-coder:480b-cloud`)
  runs on ollama.com, not on-device, but was tagged plain local, so it could
  satisfy `--budget=local` and free budgets. Such models are now flagged
  `cloud_offloaded` and excluded from local-only and free budgets, closing a
  no-surprise-bills / local-only-honesty gap. They stay listed under
  `--budget=any`.
- Antigravity's live response distinguishes no resettable weekly window from a
  persistent baseline balance, and the bucketer labeled any reset more than 36
  hours out as "weekly" with no upper bound, so a far-future or static balance
  was shown as a resetting weekly window. The window horizon is now capped at
  eight days; a further-out balance stays visible per-model without a fabricated
  cadence.
- The LM Studio parser no longer puts the model architecture (`arch`, e.g.
  "llama") into the parameter-size slot; that field is left null because LM
  Studio's v0 shape exposes no parameter count.

### Added
- Ollama now reads the running model's context window from `/api/ps`
  (`context_length`), which it already returns, so no extra call is made.
- The catalog audit reports two freshness signals: `catalog_age_days` and
  `elapsed_included_quota` (any curated `quotaIncludedUntil` window that has
  already passed), so a stale included-quota claim is surfaced for
  re-verification. Freshness prompts, separate from drift and errors.

## 0.5.18 - 2026-07-11

### Fixed
- A long absolute reset in a provider card's right column no longer wraps
  mid-value and drops a lone "PM" onto the next line. The day and clock time now
  render as one unit, so a spacious reset like "Fri 11:14 PM" either fits beside
  the headroom or wraps cleanly beneath it ("37% free" over "Fri 11:14 PM"),
  while a compact countdown such as "100% free  4h53m" stays on one line as
  before. The reset column also gained a little breathing room.

## 0.5.17 - 2026-07-11

### Changed
- The desktop "Next" routing line is now a concise glance ("Next: Claude - 80%
  free") that fits on one line, with the full pipe-joined detail (source class,
  scope, runway) moved to the hover tooltip. It previously overflowed the card
  with a long single line the user could not read on screen.
- A spent window's card now leads with when it is usable again. A near-term
  recovery reads as a precise countdown ("available in 59m") and a far-out cap
  (a weekly window days out) reads as its absolute day and clock time
  ("available Mon 5:00 PM", with the date added beyond a week), instead of a
  terse "resets 2d7h" that was harder to act on. The dense `quotabot top`
  terminal table keeps its compact countdown, where horizontal space is scarce.

## 0.5.16 - 2026-07-11

### Fixed
- Codex's weekly quota window no longer trips provider-drift detection when its
  used-percent legitimately falls without a hard reset (a rolling or re-rated
  window). The fresh lower value is shown as the latest quota and routing stays
  enabled, instead of holding a stale higher value and disabling the provider.
  The exemption is window-specific: Codex's 5 hour window is unchanged and still
  flags a genuine unexplained drop.

### Changed
- Quieted the desktop provider-drift indicator. It now shows a single compact
  line ("provider drift - showing last trusted") with the full explanation and
  reason on hover, instead of a multi-line banner that told the user to run a
  command. The drift diagnostic already clears itself on the next clean read, so
  no action is required.
- Shortened the desktop storage and webhook "settings not saved" warnings to
  compact one-liners, so a rare secure-storage failure no longer floods a clean
  UI with a paragraph of text.

## 0.5.15 - 2026-07-10

### Added
- Added `quotabot login claude` and `quotabot login codex` connected grants.
  Claude and Codex already read account-wide usage endpoints, but the host app's
  token only refreshes while its app runs on a given machine, so an idle machine
  could show a frozen number. Each adapter now resolves auth in order: the host
  token while unexpired, then quotabot's own refreshable grant, then the last
  trusted cache marked stale. The grants self-refresh (both providers rotate
  single-use refresh tokens) without reading or writing the host apps' credential
  files, and remain zero-cost metadata reads.
- Added a normalized six-value provider provenance contract across snapshots,
  routing and model candidates, alerts, reports, single-provider checks, MCP
  schemas, and verification records. Every built-in adapter declares its
  allowed `source_class`; contradictory evidence and unregistered cache
  identities fail closed before routing or measured history, machine-scoped
  telemetry receives an explicit `0.7` confidence factor, and concise human
  labels distinguish authoritative, fallback, passive, runtime, status-only,
  and manual evidence without duplicating scope tags.
- Added a dated product-strategy document and documentation index, and replaced
  the historical roadmap narrative with evidence-based 1.0 gates, dependency-
  ordered work, provider admission criteria, and explicit product measures.
- Added inspect-before-run installation guidance plus distinct update,
  data-preserving uninstall, rollback, and destructive reset documentation.
- Added a scheduled and manually dispatchable three-OS install smoke workflow
  that verifies release checksums and provenance, exercises a clean one-line
  install, upgrades the previous published 0.x release, runs CLI-only and full
  source setup, preserves a persistent-state sentinel, and verifies native
  desktop artifacts plus demo doctor output.
- Added Windows and Linux CI launch gates for packaged desktop window setup and
  supported tray-registration calls, including an independent Windows shell
  registration check, plus a bundle-aware macOS harness for interactive hosts.

### Fixed
- A spent short quota window no longer hides a healthy longer window. When a
  five-hour window is spent under a weekly cap that still has room, `quotabot
  top` and the desktop provider card now show the weekly window's remaining
  percent and reset alongside the collapsed "spent" line, so the difference
  between "wait a few hours" and "the weekly cap is gone" is visible. A spent
  long window still correctly hides a healthy shorter one.
- The desktop app now enforces a single running instance. A second launch
  surfaces the existing window instead of starting another process and adding a
  duplicate tray icon.
- The desktop first-load animation no longer stalls. The provider collect now
  runs on a background isolate so its synchronous work (SQLite reads, protobuf
  decode, JSON parsing) does not block the UI isolate and freeze the loading
  spinner; it falls back to the main isolate if the background isolate cannot
  run the collector, so collection always works.
- Corrected the committed Claude Haiku 4.5 model catalog output-token cap, and
  the model catalog audit now reports how many days old the committed catalog is
  as a maintenance signal.
- Provider drift now fails closed at the evidence-admission boundary: an
  implausible fresh read cannot overwrite last-known-good cache or enter routing,
  history, or measured analytics. Missing quota dimensions, unknown usage, and
  pre-reset forward timestamps cannot erase a binding cap. The stale trusted
  snapshot remains visible with additive `drift_reason` and
  `drift_observed_at`, `verify` emits a failed `provider_drift` check while
  preserving `state: "cached"`, and a bounded local diagnostic survives restarts
  and failed reads until clean recovery. Exact local observation generations
  prevent same-second and interleaved writers from hiding newer drift. Legacy
  `suspect` caches remain non-routable, no-window quarantines until every
  retained quota reset advances, while provider and model routing candidates
  expose the drift diagnostic explicitly. Wrong-identity, missing-time, and
  materially future live or cached evidence is rejected, direct routing applies
  the same timestamp guard, and an unavailable admission lock cannot expose
  unlinearized fresh evidence as routable capacity.
- Secret-bearing desktop webhook preferences now fail closed before read or
  write when owner-only storage protection cannot be established. Permission
  checks are asynchronous and bounded, and storage failures remain visible in
  expanded and compact desktop views instead of silently losing settings after
  restart. Saves debounce and coalesce movement bursts, flush on normal Quit,
  and reject malformed, non-regular, or oversized preference inputs with
  accurate guidance.
- The LiteLLM quotabot client now closes rejected HTTP redirect responses,
  preserving fail-soft behavior without leaking response resources.
- Concurrent cold MCP reads now share one in-progress quota collection, failed
  collections remain retryable, the plain HTTP server rejects non-loopback bind
  addresses, and sanitized operator logs expose internal failure types.
- quotabot-owned OAuth grants now fail closed before secret persistence when
  owner-only directory or file permission hardening cannot be applied; cache and
  history metadata retain their documented fail-soft behavior.
- Default loopback webhook delivery no longer follows redirects or exposes raw
  transport exceptions, preventing an allowed local endpoint from redirecting
  quota alerts externally or leaking secret-bearing error details.
- The shipped LiteLLM example now binds its proxy explicitly to loopback,
  requires an environment-backed bearer key, sends that key in the client
  example, and has a regression guard for both boundaries.
- Trust documentation now distinguishes zero-inference quota reads from bounded
  credential reads and local metadata writes, documents the explicit external-
  webhook exception, aligns provider authentication guidance, and avoids
  treating reachable, cloud-offloaded Ollama models as proven local capacity.
- Routing documentation now labels the shipped score as an auditable heuristic
  rather than an unproven Whittle index or near-optimal policy, and separates
  implemented behavior from research analogies.
- Local-runtime model recommendations no longer call every reachable model
  free; the result now tells callers to verify execution location and cost
  separately when no subscription window is tracked.
- MCP tools that perform live collection now advertise non-read-only,
  non-idempotent behavior because collection can refresh local metadata, rotate
  OAuth state, or perform Antigravity onboarding. Cache-only `decide_now` also
  reports local mutation accurately because reading leases can compact expired
  ledger records.
- The Windows installer no longer recommends deleting the entire quotabot data
  root during uninstall; it links to the data-preserving PATH and bundle cleanup
  procedure instead.
- Release installers now fail closed when a checksum sidecar is missing instead
  of silently continuing with transport security alone; a CI regression test
  pins the required-sidecar policy on Windows, macOS, and Linux scripts.
- Linux desktop tray initialization no longer calls the dependency's unsupported
  tooltip method before registering its context menu.
- Desktop alert settings now expose bounded webhook delivery status and flag
  notification delivery failures instead of silently discarding them; raw
  transport and exception details remain hidden.
- Operator docs now call out literal MCP token exposure and that the
  unauthenticated plain loopback HTTP endpoint can expose account identifiers.
- Setup now starts with an install-and-doctor fast path, explains that missing
  providers are diagnostic rather than fatal, and distinguishes CLI release
  installers from full source desktop setup.

## 0.5.14 - 2026-07-09

### Added
- CI now rejects disagreement among the collector package, CLI, MCP server,
  desktop package, desktop lockfile, changelog, and roadmap release versions;
  the release workflow also rejects a tag that does not exactly match them.
- Desktop widget coverage now exercises the production dashboard, profile
  editor, theme, analytics, terminal, demo, logo, and gauge surfaces; CI blocks
  regressions below 80% app line coverage.
- Added a daily and manually dispatchable Currency workflow that runs drift and
  catalog audit tests plus the provider catalog audit with optional Actions
  secrets and summary-only logs.
- Claude and NVIDIA native metadata reads now preserve sanitized HTTP status,
  parsed `Retry-After`, and pipe-health classification for reliable throttled or
  degraded responses in `quotabot.v1`.
- Fresh native provider pipe diagnostics now feed the same bounded
  `pipe_discount_percent` route discount as recent LiteLLM pipe health without
  changing raw quota availability.
- Model routing now uses matched model or model-family quota headroom when a
  provider exposes it, preventing a capable but exhausted model pool from
  inheriting the provider account's broader headroom.
- Default provider routing now applies an agentic-coding capability floor from
  the model catalog, so a provider with broad account headroom does not win when
  its capable model pool is exhausted.
- Provider-level suggestions can now accept caller-supplied task or capability
  context while keeping provider output, covering CLI `--provider-route`, MCP
  `suggest_provider`/`decide_now`, and loopback HTTP `/suggest`.
- `quotabot explain --reads --network` now emits a dry-run
  `quotabot.explain.v1` runtime access manifest naming local read paths,
  loopback runtime endpoints, provider metadata hosts, and the zero-token privacy
  boundary.
- `quotabot verify --json` now attaches a runtime access observation for the
  provider adapters invoked by the read, including local metadata writes and a
  fleet-level zero-token boundary check.

### Fixed
- LiteLLM tests now use unambiguous module imports and explicit suppression for
  expected process-exit races, clearing four test-only CodeQL quality alerts.
- Lemonade local-runtime discovery and its runtime access manifest now use the
  current server default at loopback port 13305, honor both `LEMONADE_HOST` and
  `LEMONADE_PORT`, and share endpoint resolution so the manifest always names
  the destination used by collection.
- The four-process manual-quota CLI integration test now has an explicit
  integration-test timeout budget, preventing false failures under full-suite
  coverage instrumentation on slower runners.
- Profile editing no longer permits a non-empty provider catalog to be saved
  with every provider deselected, which previously reloaded as unrestricted.
- An initial desktop refresh failure now leaves the loading state and exposes a
  sanitized retryable error, and the alert-webhook dialog owns its text
  controller for the full route lifetime instead of disposing it during exit.
- Schema docs now distinguish individual `quotabot.alert.v1` alert payloads from
  the MCP `quotas://alerts` resource envelope (`quotabot.alerts.v1`).

## 0.5.13 - 2026-07-08

### Changed
- Local route suggestions and LiteLLM managed routes now discount providers with
  recent LiteLLM provider/account pipe failures or throttles, exposing
  `pipe_discount_percent` on ranked candidates without changing raw quota
  availability.

## 0.5.12 - 2026-07-08

### Added
- LiteLLM routed-request metrics now include local-only pipe-health metadata for
  failures, throttles, Retry-After delays, and callback latency without storing
  prompts, responses, or exception messages.

## 0.5.11 - 2026-07-08

### Fixed
- Metered cloud quota at or below 1.5% remaining is now treated as spent, so
  rounded near-zero reads such as `1% free` do not route work into an exhausted
  provider.

## 0.5.10 - 2026-07-08

### Changed
- Updated desktop app Flutter notification/window dependencies and migrated
  local notification calls to the current named-parameter API.

## 0.5.9 - 2026-07-08

### Fixed
- Roadmap current-line copy now matches the shipped 0.5.8 release.
- Stale cached cloud quotas now remain visible as last-known evidence but no
  longer report as available capacity in routing, model, `check`, MCP, or `top`
  surfaces.

## 0.5.8 - 2026-07-07

### Fixed
- Compact desktop chrome controls now have tooltip and assistive-technology
  labels for the expand and close buttons.
- Desktop refresh failures now show a quiet sanitized "showing previous data"
  note instead of failing silently.
- Provider setup dialogs now label their icon-only close and help buttons for
  tooltip and assistive-technology users.
- No-quota routing guidance now says `quotabot login` only applies to Grok and
  Antigravity, avoiding misleading recovery advice for Claude, Codex, and other
  providers.
- Antigravity live reads no longer get labeled "(this machine)" or overridden by
  local `userStatus` cache data. The local cache remains an offline fallback and
  is the only Antigravity path marked `per_machine`.
- The desktop and terminal views now show status-only providers, such as
  NVIDIA NIM trial access, as available with unknown numeric quota instead of
  flattening them into generic no-live-data rows.
- NVIDIA NIM setup and no-key messages now name both supported environment
  variables: `NVIDIA_API_KEY` and `nvapi`.
- Status-only cloud providers with no measured quota windows are excluded from
  model-budget routing, so NVIDIA NIM availability cannot be mistaken for a
  spendable quota-backed route.
- Long no-live-data setup messages now ellipsize inside desktop provider cards
  instead of risking overflow on narrow windows.
- Schema docs now clarify that status-only cloud providers can have empty
  `windows` and do not contribute model registry entries without measured quota.
- Setup docs now include the optional NVIDIA NIM key path and explain why it is
  status-only rather than a model-budget route.
- Desktop setup/help now keeps dashboard-hidden setup states reachable, so
  NVIDIA NIM can explain the missing `NVIDIA_API_KEY` or `nvapi` key without
  cluttering the main quota view.
- Windows source setup now restarts an already-running source-built desktop app
  after rebuilding it, so the tray app does not keep showing old code.
- NVIDIA NIM key lookup now ignores blank key values before falling back to the
  alternate `nvapi` or `NVIDIA_API_KEY` alias.

### Changed
- Clarified agent, setup, and usage docs so no-token/no-content claims match the
  current mix of local files and provider metadata endpoint reads.
- Clarified source setup script help to match the same no-token/no-content
  metadata-read guarantee.
- Desktop setup help now describes Codex live usage reads, Codex this-machine
  fallback, and NVIDIA NIM key-based availability instead of generic local-data
  setup copy.
- Aligned Codex README and provider docs with the current ChatGPT usage endpoint
  plus this-machine session fallback.
- Clarified Antigravity docs around live Cloud Code quota versus local fallback.

### Added
- NVIDIA NIM trial availability as an opportunistic provider. With
  `NVIDIA_API_KEY` or `nvapi`, quotabot performs only safe `/v1/models`
  discovery and reports availability without inventing quota windows.

## 0.5.7 - 2026-07-03

### Fixed
- Antigravity now reads live, cross-device quota without an explicit
  `login antigravity`. The Cloud Code quota endpoint rejects the Gemini-CLI
  token (403, wrong OAuth client), so quotabot had been falling back to the
  stale local cache. It now refreshes the Antigravity IDE's own stored refresh
  token (Antigravity's OAuth client) into a fresh, endpoint-accepted access
  token, so a live authoritative read works whenever you are signed into the
  Antigravity IDE, with the short-lived IDE access token as a further fallback.
  This is a metadata read that spends no usage tokens.

## 0.5.6 - 2026-07-03

### Security
- Refreshing the Grok provider-default grant in place now keeps its owner
  stamp. A plain save dropped the stamp, so the cross-account lending guard
  (which reads the stamp) silently reopened after the first default-slot
  refresh. An empty `refresh_token` in a token response is also now treated as
  absent, so a blank value cannot overwrite a still-valid refresh token.
- OAuth token grants and the desktop prefs file are now written atomically (to
  a temp file, then renamed over the target), like every other local metadata
  file. Previously they were truncate-written in place, so a crash or a
  concurrent read during the write could leave a truncated file: for the token
  store that means losing the rotated refresh token the next refresh depends
  on, the one durability the code explicitly calls critical.
- The LiteLLM plugin now fails closed on a managed logical model that is
  declared with an empty candidate list, instead of passing the request through
  to the caller's original (possibly paid) model. Previously a declared-but-
  empty entry was indistinguishable from an unmanaged model, so a policy
  misconfiguration could reopen the passthrough that the no-surprise-billing
  default is meant to prevent. A model truly absent from the policy still
  passes through.
- The Grok provider-default grant is now stamped with the account it belongs to
  at login, and is only lent to a fallback account when it is unclaimed (a
  legacy grant, already limited to the sole account) or owned by that same
  account. Previously a single Grok CLI account that differed from the
  quotabot-logged-in account could be read using the other account's default
  grant and shown under the wrong account (the Grok billing response carries no
  identity to cross-check, unlike Antigravity), and that misattribution
  persisted into per-account burn history.
- The zero-config `default` profile is now always available even if its file
  exists but is corrupt or oversize. Previously only an absent file fell back to
  the built-in default; a torn or hand-edited `default.json` returned null,
  which surfaced as "no profile named default" and failed the run.
- A single malformed element in a bucket history file no longer discards the
  whole file. `loadBuckets` now drops only the bad element, keeping up to 90
  days of analytics history, matching how the lease and manual stores already
  behave. The bucket histogram is also normalized to its fixed bin count on
  load, so a truncated array (or a future change to the bin count) cannot make
  a sample fold throw and silently drop that hour's data.
- A corrupt or hostile local cache/history file can no longer crash the CLI or
  MCP server. Non-finite numbers (an `Infinity` or `NaN` that JSON allows but
  `jsonEncode` rejects) read back from a quota snapshot or an analytics bucket
  are now dropped or bounded at the load boundary, instead of surviving to
  throw when `stats`/`report`/`suggest --json`, `list_quotas`, or the MCP
  routing tools serialize their output. A bad analytics bucket degrades to a
  harmless empty bucket rather than losing the whole history file.
- Grok no longer lends the ownerless provider-default grant across multiple
  accounts. When `~/.grok/auth.json` lists more than one account, an account
  without its own grant is read only from its own CLI token, never from the
  default grant, which could otherwise fetch a different account's usage and
  display it under the wrong account's label (the Grok billing response carries
  no identity to cross-check, unlike Antigravity). The default grant still
  stands in for a lone single account.
- A background token refresh no longer overwrites the provider-default grant
  with the refreshed account's tokens. Previously every account refresh
  rewrote the default slot, so which account the default represented depended
  on refresh order, and a later default-slot fallback for a different account
  could return the wrong account's token. Refreshes now persist only to the
  slot they were loaded from; login still establishes the default slot
  deterministically.
- `quotabot logout` now clears the account-scoped grant as well as the
  provider-default grant. Login persists both (the account slot is keyed by the
  email in the id token), so clearing only the default left a live,
  self-renewing refresh token on disk that the next collect would refresh and
  keep using despite the disconnect.
- Profile files (which carry account emails and hidden provider/account
  targets) are now written owner-only, matching every other local metadata
  writer. They were previously created with the default umask, leaving them
  group- and world-readable on POSIX.
- The local quota JSON server (`quotabot serve`) now rejects requests whose
  Host header is not loopback, closing the DNS-rebinding hole that let a web
  page the user merely visited read provider account identities and quota
  state as same-origin. This mirrors the MCP HTTP server's existing guard.
- The schema-less protobuf walkers (Grok billing scan, embedded-string scan)
  now reject hostile length varints near 2^62 that wrapped an addition-form
  bounds check negative and threw inside sublist. The throw was contained by
  the adapter's blanket catch, but it degraded every Grok account to a generic
  read error; malformed frames now degrade to a truthful null parse instead.
- `protoStrings` gained the same recursion-depth cap the other schema-less
  protobuf walkers already carry, so a deeply nested untrusted local-state
  payload cannot exhaust the stack.
- `install.ps1` now fails closed on checksum verification: only a genuinely
  absent sidecar falls back to HTTPS-only, while any parse or hash error after
  the sidecar is fetched aborts the install. The prior structure could misread
  an IO or lock error as "no checksum" and proceed unverified.
- `tools/setup.ps1` no longer falls back to `C:\flutter` or `C:\src\flutter`
  when locating the Dart toolchain. Those roots are world-creatable on Windows,
  so a local user could plant a `dart.bat` the source build would then run;
  only PATH and per-user locations are trusted now.
- Provider-sourced strings (window labels, accounts, plans, statuses, error
  notes, model ids) are now stripped of terminal control bytes when snapshots
  are collected, and the `top` renderer strips them again at the draw
  boundary. Previously a malicious provider response or rogue local-runtime
  endpoint could embed ANSI/OSC escape sequences into `top`, `doctor`,
  `check`, or `verify` output and rewrite the terminal or write the clipboard
  via OSC 52.

### Fixed
- `quotabot models`/`suggest` no longer crash with an unhandled exception on an
  overflowing `--min-context` (for example `1e309`, which parses to infinity):
  the value now falls back to no filter, matching every other numeric flag.
- `quotabot top`'s hide key (`x`) now hides only the selected account's row, not
  every account of that provider. Selection was already per account, so hiding
  one account of a duplicated provider previously removed its other accounts
  too.
- The Antigravity in-process CLI-token cache is now keyed by the refresh token
  it was minted from, so switching the active `~/.gemini` account within a
  long-running desktop session cannot return the previous account's token.
- `login antigravity` no longer appears to hang for five minutes when consent
  is denied. The loopback callback handler now surfaces a provider `error=`
  response (with a matching state) at once instead of ignoring it and waiting
  out the capture timeout.
- `login grok` no longer crashes with an uncaught cast error if the device
  authorization endpoint returns a 200 without a device code; it reports a
  plain failure. The device poll interval is also clamped so a zero or hostile
  interval cannot drive a tight poll loop.
- The file-backed routing lease store now fails soft on a lock or IO error:
  `active` degrades to no leases and `reserve`/`release` report the store
  unavailable, instead of throwing the error into the read-only routing tools
  (`suggest_provider`, `decide_now`) that consult leases. Leases are advisory,
  so a lease-file problem must never break routing.
- MCP `reserve_provider` now honors an idempotency key when the target is
  auto-selected. Previously an idempotent retry re-ran the ranking, whose
  ordering had shifted because of the first lease's own discount, so the retry
  reserved a second provider under the same key (a double discount and an
  orphaned first lease). The retry now reuses the existing lease for that key
  before re-selecting. Explicit-provider retries were already matched by the
  store and are unchanged.
- The desktop alert webhook no longer depends on the local-notification plugin.
  It was posted only after the notification call inside a shared try, so on
  Windows (where the notification plugin has no implementation and throws) the
  webhook never fired, and toggling notifications off also silenced it. The
  webhook now posts independently of the notification result and of the
  notifications toggle, and a notification failure no longer skips the rest of
  the alert batch.
- Desktop low-quota notifications and reset reminders are now keyed by account,
  not just provider, so two accounts of the same provider crossing into red no
  longer overwrite each other's notification.
- The desktop window now restores its saved position on multi-monitor layouts.
  A tight on-screen bounds check discarded legitimate coordinates for a monitor
  to the left or above (large negatives) or a wide arrangement (large
  positives), re-centering on the primary display every launch. The bounds are
  now generous enough for real multi-monitor setups while still re-centering on
  a corrupt value.
- Saving or switching a desktop profile no longer re-fires a low-quota alert for
  a provider that was already alerting and is still red. The edge-trigger state
  is no longer cleared on a profile change, since the alert engine already drops
  providers that leave the visible set and fires for newly-visible red ones.
- A spent provider with more than one spent window now reports when it is
  actually usable again (the window that resets last), not the soonest window's
  reset. Previously, if a 5h cap and a weekly cap were both spent, the provider
  was reported as freeing when the 5h reset even though the weekly cap kept it
  spent, so `check`/`doctor`/`top`/MCP understated the wait and the all-spent
  routing advice could name the wrong provider to wait for (and doctor's own
  window detail contradicted its suggestion line). A spent window whose reset
  is unknown is treated as furthest out, so quotabot never promises a reset it
  cannot see.
- Grok: the weekly pool percent and reset are now read from their known fields
  in the billing protobuf (pool total from the config message, reset from the
  window end) instead of the first plausible float and the nearest future
  timestamp. A per-product breakdown percent (Chat, Build, Imagine) can no
  longer pose as the pool total, and the reset can no longer point at the
  window start. The schema-less scan remains as a drift fallback, and the
  live-captured response shape is pinned as the provider fixture. Also
  documented: xAI can revise the pool percent downward mid-window without a
  reset (observed live, 100 to 73 under the same reset time); quotabot mirrors
  Grok's own number and burn analytics already treat decreases as recovery.
- One hung provider can no longer wedge the whole fleet: every adapter collect
  now runs under a hard 20s deadline and degrades to a truthful per-provider
  "timed out" error while the rest of the snapshot proceeds. The desktop
  refresh loop adds its own 45s ceiling and always reschedules the next poll,
  so a thrown or hung refresh cannot silently stop auto-polling.
- `--budget=quota` now enforces an explicit quota-plan provider allowlist, so
  a future catalog entry for a credit-pool provider (Cursor, Kiro,
  Windsurf/Devin) can never silently widen the no-surprise spend envelope.
  Previously the exclusion relied on those providers having no catalog models.

### Changed
- The collector package now ships an `analysis_options.yaml` enabling
  `strict-casts` plus the recommended lint set (and a few load-bearing extras),
  so the documented "strict analyzer, zero warnings or infos" bar is
  machine-enforced by CI rather than left to convention.
- The desktop widget no longer groups the fleet under account-email headers just
  because different providers are signed in with different emails (the common
  case). It groups by account only when a provider is genuinely signed into more
  than one account (a real work/personal split on the same service); otherwise
  it stays one clean list. An account label now appears only to disambiguate a
  duplicated provider, consistently across the widget, `top`, and `doctor` - a
  single-account fleet shows no emails at all.
- Added a server-side secret-scan CI job (gitleaks, pinned and checksum
  verified) on every push and pull request, reusing the repository config,
  alongside the existing local scan, GitHub secret scanning, and CodeQL.
- The release workflow now creates the GitHub release as a draft, attaches a
  signed SLSA build provenance attestation to every platform archive, and only
  publishes (flipping `releases/latest`) after all build legs succeed. A tag
  whose matrix had a failing leg stays a draft instead of exposing a
  missing-asset release. All CI, CodeQL, and release workflow actions are now
  pinned to commit SHAs so a repointed tag cannot inject a compromised action
  into the artifact build path.
- `quotabot check --json` and MCP `check_provider_availability` now emit their
  own `quotabot.check.v1` schema id with an `as_of` timestamp. They previously
  claimed `quotabot.v1` while not conforming to it (no `providers` array).
  MCP `provider_with_most_headroom` gains `quotabot.headroom.v1` plus `as_of`
  the same way.
- MCP output schemas now declare the `profile`, `account_filter`, and `error`
  fields that profile-aware tools inject, plus model-entry `source` and
  `loaded`; SCHEMA.md documents `active_leases`, the single-provider answer
  shapes, `quotabot.calibration.v1`, `quotabot.catalog_audit.v1`, and other
  emitted-but-undocumented fields found by the 1.0 contract audit.

## 0.5.5 - 2026-07-01

### Added
- A silent-drift canary now validates each fresh read against the last cached
  one at the point it is persisted, and flags an implausible read as `suspect`
  instead of trusting it blindly: a window whose reset moved earlier, or usage
  that fell with no reset for a provider that only ever consumes. It is
  fail-soft (the number is still shown, only annotated), the concern rides
  through `quotabot json`, `doctor`, and MCP, and it is provider-aware, so
  xAI's legitimate Grok pool re-rating and Antigravity's max-over-models window
  are not false-flagged. The same monotonicity runs per model for providers
  that meter each model separately (Antigravity), where the single window is a
  synthetic artifact and the real drift signal lives in the per-model pools.
  This is the first use of stored history to check a
  fresh reading, closing the gap where a provider that starts reading wrong
  without failing was previously trusted, which the 1.0 promise of "reads
  correctly or fails plainly" did not otherwise enforce.
- Antigravity now reads the full per-model quota table it caches in local state
  (`antigravityUnifiedStateSync.userStatus`), so every model family it meters
  from its own pool (Gemini, Claude, GPT-OSS, and others) is captured with its
  own remaining headroom and reset. The authoritative source is the live Cloud
  Code endpoint, so the table reflects usage from every device the account runs
  on, not just this machine; the local `userStatus` cache (which adds a speed
  category and badge) is a last-known fallback, shown only when the live read is
  signed out. Pool-sharing effort and mode variants roll up to their base model. The compact window summary stays the headline: `doctor` prints a
  one-line "N models tracked, most used: ..." summary, and the full table ships
  in `quotabot json` and over MCP as `model_quotas`. Previously the adapter
  collapsed the models into a single derived window and kept only the
  most-constrained model per reset bucket, so a wide-open capable model (an
  available Claude Opus while Gemini was spent) was hidden from view and from
  routing.
- Codex quota now reads the authoritative live usage endpoint
  (`chatgpt.com/backend-api/wham/usage`, the same data the CLI's own status
  view polls), reusing the token Codex already stores, so it reflects usage
  from every device instead of only this machine's session logs. The local
  session read - which undercounts when the account is used elsewhere, by its
  own admission - is now a fallback used only when the live read is signed out
  or offline. It is a metadata read that spends no usage tokens, and the account
  is identified by the endpoint's email rather than only the plan name.
- Local-only quota reads are now labeled honestly. Cursor, Windsurf, Kiro, and
  the Codex session fallback see only this machine's usage, so they can
  undercount when the same account is used on another device; their snapshots
  now carry `per_machine: true` (shown as a dim "(this machine)" note in
  `doctor` and exposed over MCP), while the authoritative cross-device reads
  (Claude, Grok, Antigravity, Codex live) omit it.
- `quotabot verify`: mechanical honesty checks over one live read, for the 1.0
  release-candidate provider verification matrix. Classifies each provider's
  read state (live, cached, out of quota, no data, error, local, undetected),
  checks bounds, capture times, staleness labels, reset plausibility, and
  account uniqueness, validates the live snapshot against the frozen
  `quotabot.v1` contract, and names each provider's own usage surface for the
  human cross-check. `--json` emits a `quotabot.verify.v1` record; exit code is
  0 when every snapshot is reading correctly or failing with a plain reason and
  65 when any check fails. Truthful absences (a local runtime that is not
  running, a signed-out account that says so) pass; lying or silent numbers
  fail.

### Fixed
- The `quotabot.v1` schema and validator now cover the `quota_included_until`
  model field that model JSON was already emitting, closing a contract-drift
  gap.
- The desktop analytics history views (7d/90d) now find burn history stored
  under account-scoped keys. Previously any provider with a known account
  identity, which includes most signed-in providers, showed "history is still
  warming up" even when weeks of history existed.
- Local runtimes no longer form their own account groups in the desktop quota
  view: a runtime's account field is a model summary ("3 models"), not an
  identity, so headers like "3 models - 1 provider" no longer appear and
  locals group under "default and local".

### Changed
- Quota Analytics now renders inside the main dashboard under the exact same
  header, actions, and menu as the quota view: the analytics button becomes a
  back arrow, the title switches between Quota and Analytics, and the window
  is never resized or re-chromed by the switch. The separate analytics
  toolbar is gone.
- Demo mode now shows a readable fleet of five metered plans plus two local
  runtimes, and its synthetic history includes occasional spent afternoons so
  the analytics reliability, calendar, and trend cards show believable
  texture. The README screenshots and demo GIF are regenerated from it, and
  the CLI `top` frame in them is now drawn inside a real terminal window with
  a title bar and prompt.
- `quotabot top` polish pass: narrow terminals now drop whole columns in a
  stable order (forecast first, then the reset countdown) instead of clipping
  text mid-word, and the footer keymap yields whole key hints under width
  pressure; the reset column is padded so forecasts and tags align vertically;
  cached rows carry the age of the cache ("(cached 8h)"); multi-account fleets
  label duplicate-provider rows with their account and the cursor marks only
  the selected account's row; the selected provider name takes the palette
  accent; the route line drops its redundant "Use <provider>" prefix and trims
  a long reason at a word boundary with an ellipsis; a long local-runtime
  status keeps its text and yields the "[always on]" tag when the row is
  tight.
- Quota Analytics now uses the main quota view's compact gauge header, icon-only
  window controls, card radius, and tighter metric typography to reduce the
  visual jump between the two screens, and removes the decorative analytics
  glyph.

## 0.5.4 - 2026-07-01

### Changed
- The desktop startup loader now uses the branded green quota-gauge animation
  instead of the stock blue spinner.
- The Quota Analytics screen now shares the main dashboard chrome and typography
  scale more closely, reducing the visual jump between screens.

### Fixed
- Antigravity reporting now reads the newer `Antigravity IDE` local status
  store, prefers the current account over legacy app data, and preserves current
  plan/model labels when falling back to cached quota windows.

## 0.5.3 - 2026-07-01

### Added
- The cloud model catalog now includes Claude Fable 5 and Claude Sonnet 5 from
  Anthropic's July 2026 model docs. Fable 5 carries a temporary
  `quota_included_until` cutoff so `--budget=quota` stops treating it as
  quota-backed after its documented included weekly-usage window.

## 0.5.2 - 2026-07-01

### Added
- `quotabot stats` now accepts explicit tier-fit inputs such as
  `--tier-plan=Lite:50:10,Current:100:20 --current-price=20`. The JSON output
  includes `tier_fit` with observed breach probability, recommended explicit
  tier, and optional monthly delta, without inferring provider prices or caps.
- The desktop widget header now shows a compact "Next" route signal using the
  same burn-aware `suggestRoute` provenance as the CLI/MCP path: current free
  headroom, burn-discounted headroom when material, and confidence. Single
  account emails remain hidden in the main view.
- Reset-aware best-time hints now pick the nearest strong weekday/hour slot
  that starts before the active quota reset, using only existing local history.
  `quotabot stats`, `quotabot report`, report JSON, and the desktop analytics
  card expose the hint when enough timing evidence exists.
- Best-time analytics now use a conservative wrapped weekday/hour smoother when
  neighboring history supports it. Reports, stats JSON, and desktop analytics
  keep the raw sampled mean and sample count, then add the smoothed score and
  support counts so a single isolated quiet hour does not dominate best-time
  recommendations.
- Analytics now compute current sampled-day usable/spent streaks from the
  existing compact hourly history buckets. `quotabot stats`, `quotabot report`,
  and `quotabot.report.v1` surface the streaks without adding provider calls or
  storing raw long-term samples.
- `quotabot suggest --local-first`, MCP `local_first`, and loopback HTTP
  `GET /suggest?local_first=true` now prefer an available local runtime before
  subscription quota for cost-sensitive dispatch. Routing JSON includes
  `routing_policy` so callers can verify `balanced` versus `local_first`
  behavior.
- Provider suggestions now accept explicit caller-supplied cost penalties:
  `quotabot suggest --cost-penalty=codex:2`, MCP `cost_penalties`, and loopback
  HTTP `GET /suggest?cost_penalty=codex:2`. The default cost weight is zero
  unless a caller supplies penalties, and quotabot never infers prices or enables
  paid API routes from this signal.
- `quotabot models` and profiled `quotabot suggest` now accept `--budget=local`
  or `--budget=quota`, with matching MCP `budget` arguments on `list_models`
  and `suggest_model`. `local` is a hard local-runtime cap; `quota` allows local
  runtimes plus measured built-in quota plans and excludes self-reported manual
  quotas so no-surprise routing stays explicit.
- Profiled `quotabot suggest --use-expiring-quota` and MCP
  `suggest_model` with `use_expiring_quota: true` can now let a qualifying
  measured quota-backed model outrank local capacity when local analytics project
  at least 35 percent of included quota would expire unused within 24 hours.
- Burn history is now account-scoped when a provider exposes a specific account.
  Routing, reports, projected-waste alerts, MCP decisions, loopback HTTP
  suggestions, and the desktop widget use the matching account's local history;
  legacy provider-only history is used only when the current snapshot is not
  ambiguous. Low-quota and projected-waste alert payloads now also include the
  account and can route from one spent account to a healthier sibling account on
  the same provider.
- Model registry entries now expose local runtime readiness as `local_readiness`
  (`loaded` or `cold`), and concrete model suggestions prefer loaded local
  models over installed-but-cold local models when both meet the requested
  profile. MCP model schemas now advertise local model size, loaded VRAM, and
  quantization fields, and local model recommendation reasons include available
  VRAM/context/size evidence without making model calls.
- LiteLLM routed-request metrics now record the selected spend class, and the
  desktop analytics view summarizes local, quota-plan, paid-API, and legacy
  unknown records separately.
- Desktop profiles now include a high-contrast Hacker theme, preserving the
  existing System, Light, and Dark choices while giving the widget a green
  terminal-style palette that still runs through Flutter's theme system.
- Stats and weekly quota-health reports now include a compact contribution
  calendar derived from existing hourly history buckets, showing light,
  moderate, heavy, mixed, and spent sampled days without adding any new provider
  reads.
- Stats, reports, JSON, and the desktop heatmap now surface best sampled
  weekday/hour windows from the same local history buckets, including sample
  counts so sparse evidence stays visible.
- A no-surprise-cost contract test now scans runtime sources for direct paid
  model, chat, image, and content-generation endpoints. Catalog auditing remains
  limited to provider model-list endpoints, so xAI image APIs and other
  request-metered inference surfaces cannot be added quietly.
- The LiteLLM router now defaults to no-surprise-billing guardrails. Candidates
  marked `spend: paid_api` are skipped unless `allow_paid_api: true` is set,
  `spend: quota_plan` is reserved for included quota plans with explicit
  overages-disabled proof, pinned agent deployments obey the same spend policy,
  and managed logical models fail closed when no safe route exists.
- The desktop Quota Analytics Now view now surfaces optional LiteLLM
  routed-request metrics from the default `~/.quotabot/litellm-metrics.jsonl`
  file, including served requests, routed requests, tokens, tracked cost, top
  served models, and last request age.
- `quotabot watch --waste-threshold=N` now raises opt-in `projected_waste`
  alerts when current burn pace shows paid quota is likely to expire unused at
  reset. The additive `quotabot.alert.v1` fields include `kind`,
  `projected_waste_percent`, and `burn_percent_per_hour`.
- `quotabot report` now prints a weekly quota-health markdown export, with
  structured `quotabot.report.v1` output behind `--json`.
- Manual quota entries can now be added with `quotabot manual set`, listed with
  `quotabot manual list`, and removed with `quotabot manual remove`. They are
  stored locally, appear in normal quota views and JSON as `source: "manual"`,
  and are excluded from measured analytics history.
- Quota-reading CLI commands now accept `--exclude=A,B` after profile filtering
  to ignore specific providers for one run without editing profiles, including
  `status`, `doctor`, `json`, `check`, `top`, `watch`, `stats`, `report`,
  `calibration`, `models`, and `suggest`.
- MCP read/routing/reservation/model tools now accept an `exclude` provider-id
  list, giving agents the same one-request provider avoidance available from the
  CLI.
- The loopback HTTP `GET /suggest` endpoint now accepts `?exclude=codex,grok`
  and returns a JSON 400 error for malformed provider ids.

### Security
- GitHub security automation now includes Dependabot update schedules for
  GitHub Actions, Dart packages, and the TypeScript MCP client snippet package,
  plus CodeQL analysis for the repository's Python and TypeScript surfaces.
- LiteLLM quota-plan routes now require `overages_disabled: true` or
  `overages: disabled`; ambiguous quota-plan labels fail closed instead of
  being treated as safe.

### Fixed
- Quota windows whose reset timestamp is at or before the current time now use
  one effective fresh-window calculation across routing, `doctor`, `top`, and
  Kiro out-of-quota messaging. A stale local snapshot that still says 100% used
  after reset no longer makes the CLI display disagree with `suggest`.
- The desktop dashboard no longer shows a single account email in the main
  provider card view. Account labels remain available only when a provider has
  multiple account snapshots and the user has opted to show account names.
- CI now pins the macOS runner to `macos-15`, avoiding the current
  `macos-latest` migration warning while keeping the desktop package build on a
  verified image.
- CI now uses `actions/setup-python@v6`, removing the Node 20 runtime
  deprecation warning while keeping Python pinned to 3.13 for coverage and
  LiteLLM proxy integration tests.
- Grok usage now labels the shared paid-plan pool as a weekly window, matching
  the current Grok Usage tab semantics where Imagine, Chat, and Build are
  category breakdowns inside one shared allowance.
- The desktop widget can now hide one account for a multi-account provider
  without hiding every account for that provider.
- Antigravity setup guidance no longer says persistent login requires custom
  Google OAuth client environment variables.

## 0.5.1 - 2026-06-30

### Security
- Completed a repository-wide adversarial security pass and fixed every
  candidate it found. Cache-only routing now accepts only canonical snapshot
  filenames with non-future timestamps, local cache directories are
  owner-restricted, Windows SQLite loading no longer trusts `WINDIR`, Windows
  ACL grants use the authenticated current-user SID, the LiteLLM router refuses
  HTTP redirects from the loopback quotabot endpoint, LiteLLM agent rules only
  trust key alias or user_id identity, LiteLLM metrics writes are contained
  under `~/.quotabot`, and CI constrains `GITHUB_TOKEN` to read-only contents.

### Changed
- Provider routing now applies a modest use-it-or-lose-it boost when measured
  burn and a near reset show included quota would otherwise expire unused. The
  signal skips local runtimes, manual quota, stale reads, and ambiguous
  multi-account provider-level burn.
- Routing suggestions now expose additive `runway_hours` provenance for metered
  subscriptions, making `routing_score = runway_hours * confidence` auditable
  before later optimizer weights are added.
- Best-time-to-run windows now carry beta-binomial usable-rate shrinkage and a
  reliability-weighted `scheduling_score`. A sparse quiet hour with spent
  samples no longer outranks a slightly lower-free window that is consistently
  usable.
- Provider analytics now apply conservative beta-binomial shrinkage to
  reliability rates before rendering stats, reports, and desktop analytics.
  Thin provider/account histories are pulled toward the current fleet usable
  rate, while mature histories remain close to their direct observed rate.
- Recent burn estimates used by routing now apply conservative empirical-Bayes
  shrinkage at the cache boundary. Thin provider/account histories are pulled
  toward the current fleet burn mean, while mature histories stay close to their
  direct measured slope.
- Provider suggestions now rank metered subscriptions by a
  confidence-weighted `routing_score` based on risk-adjusted runway, while
  keeping local runtimes governed by the explicit fallback and local-first
  policies. The score is included additively in suggestion JSON and MCP output.
- Collector SQLite reads now use `sqlite3` 3.x's hook-managed bundled native
  library and the current `Database.close()` API. The obsolete manual
  `open.dart` override path was removed, and CLI subprocess tests now avoid
  rebundling a locked `sqlite3.dll` during Windows test runs.
- CLI release packaging now uses `dart build cli` bundle archives so the
  `sqlite3` native library ships with the installed executable on every
  platform.
- macOS/Linux desktop package verification now includes the required tracked
  Flutter desktop scaffold files and Linux tray indicator development package,
  so native CI package builds exercise the same release bundles users build.
- The 1.0 roadmap final cut is now checked: every roadmap item is marked
  complete, the Windows local gate is green, and GitHub Actions passed the full
  suite plus macOS/Linux desktop package builds on native runners.
- Windows setup now removes legacy `quotabot.ps1`, `quotabot.cmd`, and
  `quotabot.bat` shims from the install directory before copying
  `quotabot.exe`, so stale source-launcher shims cannot shadow the release CLI.
- CI now verifies macOS and Linux desktop release bundle packaging on native
  runners. `tools/package-macos.sh` and `tools/package-linux.sh` build and
  validate the platform bundles, with optional local archives for release work.
- Owner-only local file hardening is now shared across token storage and routing
  lease metadata. Lease directories, lock files, and atomic write files are
  restricted with the same best-effort permissions used for OAuth tokens.
- Parser boundaries now reject non-finite numeric values and clamp direct
  provider percentages to 0..100 before they can reach routing or UI code.
- CI now runs the full suite on Linux, macOS, and Windows (a matrix of
  ubuntu-latest, macos-latest, and windows-latest), so the cross-platform paths
  are exercised on a real host of every claimed OS instead of assumed. The job
  uses bash on every runner (Git Bash on Windows) for consistent multi-line
  steps, and Python is pinned to 3.13 for the coverage gate and current
  `litellm[proxy]` integration tests.

### Added
- The README now has a reproducible animated demo GIF generated from Flutter
  demo screenshot mode. `tools/generate_readme_demo.py` captures the expanded
  widget, compact strip, 90-day analytics view, and demo `top` frame, refreshes
  the static screenshot PNGs, and assembles `docs/quotabot-demo.gif`.
- `quotabot.v1` is now frozen as an additive JSON Schema 2020-12 contract with a
  focused validator and tests. Built-in providers are also listed in a
  compile-time adapter registry, and every adapter now owns a required sanitized
  provider-shape fixture.
- MCP routing tools now accept exact `account` filters in addition to named
  `profile` filters, so routers can query one provider account without creating
  a profile. MCP also exposes `quotas://alerts` and standard
  `resources/subscribe` support: the subscription loop runs the existing
  edge-triggered alert engine and sends `notifications/resources/updated` when a
  provider crosses amber or red.
- MCP routing now has local concurrency leases and a cache-only decision path.
  `reserve_provider` and `release_provider` let parallel routers reserve a
  cloud provider/account locally before dispatch, and active leases reduce later
  `effective_headroom_percent` through `lease_discount_percent`. `decide_now`
  reads only the in-memory or disk last-known snapshot and reports source, age,
  and staleness so per-request routers can make a cheap decision without forcing
  live collection.
- Python and TypeScript MCP client snippets now cover quotabot over both stdio
  and Streamable HTTP. The snippets pin Python consumers to the stable MCP SDK
  v1 line, use the current TypeScript SDK transport imports, keep bearer tokens
  in headers only, print a compact routing decision, and are smoke-tested in CI
  with Python compilation plus strict TypeScript typechecking against the MCP
  TypeScript SDK.
- The MCP server now supports opt-in Streamable HTTP alongside stdio:
  `dart run bin/mcp_server.dart --http` serves the same nine tools and
  `quotas://current`/`quotas://alerts` resources on a loopback-only `/mcp` endpoint with
  DNS-rebinding host/origin checks, batch JSON-RPC rejection, optional bearer
  token auth, and integration tests through the package's Streamable HTTP client.
- A model-catalog audit tool now diffs the committed cloud catalog against
  provider-owned model-list endpoints. `dart run bin/catalog_audit.dart --json`
  emits `quotabot.catalog_audit.v1` with per-provider endpoint ids,
  `missing_from_catalog`, and `catalog_only` sets for OpenAI/Codex,
  Anthropic/Claude, xAI/Grok, and Gemini/Antigravity. It follows provider
  pagination tokens, skips missing API keys without failing by default, redacts
  query-string secrets, filters obvious non-language modalities, and leaves
  context/tools/vision/reasoning/tier fields curated.
- The LiteLLM router is now covered by a real proxy integration test. CI
  installs `litellm[proxy]`, launches a LiteLLM proxy on loopback with the
  actual quotabot `async_pre_call_hook`, serves a fake quotabot `/suggest`
  endpoint and a fake OpenAI-compatible backend, and verifies that a logical
  model is rewritten to the provider with budget. The test is token-free,
  external-network-free, and catches current LiteLLM loader behavior.
- Deterministic property/fuzz tests now cover the untrusted JSON, protobuf,
  gRPC-web, embedded-token, and local-runtime parser boundaries. Sanitized
  provider-shape fixtures for Codex, Claude, Antigravity, Cursor, Windsurf/Devin
  Desktop, Kiro, Grok, LM Studio, and Ollama are loaded from disk as integration
  fixtures.
- CLI simulation mode for deterministic tests: `--mock-provider NAME --state
  STATE` now returns a single synthetic provider snapshot without adapter calls,
  history reads, or burn-history influence. Supported states are `healthy`,
  `low`, `exhausted`, `blocked`, `signed-out`, and `stale`, with process-level
  tests covering JSON snapshots, `check`, `suggest`, and usage errors.
- The desktop app now has full profile controls: create, edit, delete, select,
  provider/account filters, routing policy, theme, and profile-scoped hidden
  providers plus sort. The widget, analytics, notifications, and alert webhooks
  all follow the active profile.
- MCP quota, routing, availability, and model tools now accept optional
  `profile`, applying the same local named profile filters as the CLI while
  preserving the unfiltered `quotas://current` resource.
- CLI quota reads now accept `--profile=NAME`, applying local named profile
  filters before status, JSON snapshots, suggestions, models, checks, stats,
  watch alerts, or top render.
- Named profile foundations now exist in the collector: `quotabot.profile.v1`
  JSON storage, safe profile names, provider/account filters, routing policy
  metadata, and an implicit zero-config default profile.
- Windsurf/Devin Desktop now reads daily and weekly Cascade quota shapes from
  local SQLite state, carries reset timestamps, surfaces account and plan labels
  when present, and no longer invents a 0% quota from undecodable raw blobs.
- Cursor now treats the current included-usage pool as a monthly quota window,
  reads string or blob SQLite state rows, and surfaces account and plan labels
  when local state provides them.
- Multi-account cache fallback now uses a shared tested active-account rule: a
  cached account is shown only while that account is still present in the
  provider's current local account index.
- The desktop widget now groups distinct account identities in the expanded
  view, scopes expansion state by provider/account, automatically disambiguates
  duplicate-provider cards, and keeps provider visibility menu rows unique when
  several accounts exist for the same provider.
- Antigravity now attempts a live read for every discovered active account from
  its cross-platform profile scan, merging duplicate profile records and keeping
  per-account cache fallback limited to accounts still present locally.
- Grok now reads every account present in `~/.grok/auth.json`, tries an
  account-scoped quotabot grant for each one, and caches successful reads per
  account so switching accounts does not overwrite the previous account's
  last-known-good quota.
- Antigravity OAuth login now resolves the signed-in Google email from userinfo
  after token exchange and stores the grant in the matching account-scoped slot
  as well as the provider-default slot. Userinfo failures fail closed and keep
  the default grant path.
- Codex adapter edge-case tests now cover missing session directories, rollout
  files with no `rate_limits`, stale snapshots whose file mtime is fresh, and
  multi-bucket scans that must keep only the newest snapshot per limit bucket.
- OAuth grants can now be stored in independent account-scoped slots as well as
  the existing provider-default slot. The auth filenames contain only a provider
  id plus a hash of the account id, never the raw email, and Grok/Antigravity now
  prefer the account-scoped grant for the detected account before falling back to
  the default grant or host-app token. This is foundation work for the Phase 2
  multi-account edge cases; current zero-config behavior is unchanged.
- `quotabot top` is now fully interactive: navigate the fleet with `j`/`k` or the
  arrow keys, hide a provider for the session with `x` (`h`) and bring them all
  back with `u`, and copy the recommended route to your clipboard with `c` (via
  an OSC 52 terminal escape, so it needs no clipboard dependency). The selected
  row shows a cursor and the footer shows the hidden count and a copy
  confirmation. The keyboard-navigation, hide, clipboard, and selection logic are
  pure, tested functions.
- Stable, documented CLI exit codes a shell or agent can branch on: `0` success,
  `64` usage error (bad argument or unknown provider), and `69` unavailable
  (the named provider for `check`, or the whole fleet for a piped `top`, has no
  usable quota now). For example `quotabot check claude || quotabot suggest`.
- New `quotabot watch` command: polls quota on the adaptive cadence and raises a
  low-quota alert the first time a provider's binding window crosses into red
  (spent or nearly so), naming where to route next ("Claude 5h at 8% free -
  route next to Grok (74% free)"). `--webhook URL` POSTs each alert as
  `quotabot.alert.v1` JSON so the signal can reach a tray toast, a shell, or
  chat; the host must be loopback unless `--allow-external`, so a stray or stale
  URL cannot send even quota metadata off the machine. `--json` emits alerts as
  JSON lines, `--once` runs a single pass (cron-friendly), and `--interval=N`
  pins the poll rate. The decision is a pure, edge-triggered function
  (`computeAlerts`) that fires once per crossing and re-arms only after recovery,
  so a steady spent window never spams; payloads are quota metadata only, never
  prompts, code, or content. The desktop widget raises the same alerts on the
  same engine, and can POST to a webhook configured from its menu ("Alert
  webhook"), loopback-only unless an external host is explicitly allowed.
- The desktop widget now shows the same forward-looking forecast as `quotabot
  top`, on each provider's binding window, in plain language at a glance: a
  runway estimate ("about an hour of usage left") when a window is visibly
  draining, or a plain warning ("likely to run out before it resets") once the
  burn and its history make a strand material. It appears only when there is a
  real burn signal, so a steady fleet shows nothing invented. The decision is one
  shared pure function (`classifyForecast`) used by both the CLI and the widget,
  so the two never drift; each only words it for its own surface. The burn
  estimate now carries its standard error (`Insights.burnSePerHour`) so the
  widget can state a calibrated strand probability rather than a point estimate.
- `quotabot top` is now sortable. Press `s` to cycle the order live (default,
  headroom, burn, strand risk, soonest reset) or start in one with `--sort=NAME`
  (also `QUOTABOT_SORT`); the active mode shows in the footer. The reorder is a
  pure, tested function (`sortProvidersForTop`) that is stable - providers a sort
  cannot rank (no burn history yet, or a local under a cloud-only metric) keep
  their order and sink below the ranked ones, so a cold fleet never reshuffles
  into nonsense. A piped `top` honors `--sort` and still prints one plain frame.

### Changed
- The desktop widget and the analytics screen now draw text from one shared size
  scale (`app/lib/typography.dart`), so the same kind of text is the same size on
  both screens (the few half-point mismatches between the views are gone).

### Added
- `quotabot top` surfaces the forward-looking forecast on each provider's binding
  window: a strand probability (the chance the window is spent before it resets,
  from the same first-passage model `suggest` uses) when burn history makes it
  material, otherwise a plain time-to-empty. The note is colored by urgency and
  only appears when there is a real burn signal - no history, no invented forecast.
  The meter column yields width for it only when a forecast is present, so a steady
  fleet keeps full-width bars.
- `quotabot top` now refreshes on the same adaptive cadence as the desktop app:
  it polls fast when a window is near its cap or a reset is imminent (down to 30s),
  and relaxes to hours when the whole fleet is healthy and resets are far off. The
  cadence is the shared `nextRefreshSeconds` used by the app, so both views agree.
  `--interval=<secs>` still pins a fixed rate, and `r` refreshes on demand. The
  footer shows an "updated Ns ago" indicator so a slow poll is never mistaken for
  a stall.
- `quotabot top` shows each local runtime's detail lines (VRAM, context, models
  installed, disk) under its headline, matching the desktop app instead of a single
  terse status line.
- Truecolor detection for the live view without `COLORTERM`: Windows Terminal
  (`WT_SESSION`) and known truecolor terminals (`TERM_PROGRAM` of vscode, iTerm,
  WezTerm, Ghostty, Hyper, Tabby, Rio, Warp) now render the 24-bit gradient meters.
  `--truecolor` forces it on for any terminal that supports it but is not detected.
- suggest-a-model: `quotabot suggest --task=hard` (or any capability flag) and the
  MCP `suggest_model` tool recommend one concrete model - the cheapest that meets
  the profile and has budget, local-first, escalating to a heavier or paid tier
  only when the requirements force it. Same filters as `models`; quotabot still
  never reads the task. Shapes: `quotabot.suggest_model.v1`.
- Capability-aware model filtering. `quotabot models` and the MCP `list_models`
  tool take a coarse `--task` profile (`simple|standard|hard`) plus explicit
  filters (`--min-context`, `--require-tools`/`--require-vision`/
  `--require-reasoning`, `--tier-floor`/`--tier-ceiling`), returning only the
  models that meet the stated need, most routable first. Each model carries the
  provider's own tier (light/standard/flagship). quotabot never reads the task: the
  caller supplies the profile, and tiers are objective facts, not a quality ranking.
- Color palettes for `quotabot top`: `--theme=<name>` (or `QUOTABOT_THEME`) selects
  `default`, `green` (phosphor CRT), `dark`, `light`, or `synthwave`, and a custom
  palette is a one-liner: `--theme=custom:HEALTHY-TIGHT-LOW-SPENT[-ACCENT]` of hex
  colors. Palettes drive the truecolor gradient meters and accent; 256/16-color
  terminals keep the standard named headroom colors, so a custom palette never
  renders unreadably. A malformed spec falls back to the default.
- A README screenshot of `quotabot top`, the live terminal dashboard, rendered
  from demo data. The collector now has a demo mode (`QUOTABOT_DEMO=1`) so the CLI
  and MCP can show a synthetic fleet without touching any account or history.

### Changed
- The app uses tabular (fixed-width) figures everywhere via the theme, so digits
  line up and the main quota view and the analytics screen render numbers
  consistently.
- The Quota Analytics screen now uses the same rounded-corner card as the main
  quota view, so the window corners are consistent between the two. Screenshots
  regenerated.

## 0.4.0 - 2026-06-28

### Added
- `quotabot calibration`: grades quotabot's own strand predictions against your
  recorded history by replaying the predictor over the hourly buckets it already
  keeps, and reports how often its calls come true as a calibration percentage, a
  Brier score, and a reliability diagram (per provider and overall). No new
  storage and no provider calls. It is honest by construction: a prediction is
  only graded once its horizon has fully elapsed, and it says plainly when there
  is not enough resolved history yet. A `quotabot.calibration.v1` JSON shape too.
- `quotabot top` gains gradient meters: on a truecolor terminal each bar fills
  with a smooth green-to-red gradient that deepens toward exhaustion, with
  color-depth auto-detected (truecolor / 256 / 16 / none) and a clean fall back to
  the single-color bar, plain text, NO_COLOR, and narrow terminals.
- Model registry: `quotabot models` (and the MCP `list_models` tool) list every
  model you can route to right now across cloud providers and local runtimes, each
  tagged with the live budget that gates it (headroom percent, binding window,
  reset) and capability hints (context window, tools, vision, reasoning), most
  routable first. Local-runtime models are read live from the runtime; cloud
  models come from a committed, stamped capability catalog that a refresh tool
  regenerates from each provider's own model endpoint (so it never goes stale by
  hand). The normalized snapshot now carries a provider's `models`, and the
  registry has its own `quotabot.models.v1` shape shared by the CLI and MCP.
- Risk-aware, self-explaining routing. `suggest` (CLI, the MCP `suggest_provider`
  tool, and the local `/suggest`) now estimates each provider's burn-rate
  uncertainty (the standard error of the fitted slope) and exposes, per candidate,
  `burn_se_percent_per_hour`, a first-passage `strand_probability` (the chance the
  binding window is spent before it resets), and a `confidence` (freshness times
  burn-sample adequacy). The payload also carries `as_of` and `risk_z` provenance.
  A new `--risk=Z` flag opts into risk-adjusted ranking: at the default `Z=0` the
  result is identical to before (mean headroom), and higher `Z` discounts
  providers whose burn is uncertain, so a cap being drawn down erratically is
  preferred less than its average headroom suggests. The CLI `suggest` view shows
  the confidence and a strand warning per candidate.

## 0.3.0 - 2026-06-27

### Added
- Lemonade Server now has its own branded lemon logo in the app instead of the
  generic placeholder dot, so every supported provider shows a real mark. The
  provider-to-logo map is pinned by a test, so a newly supported provider that
  ships without a logo is caught. The README screenshots are regenerated from
  demo data so the lemon shows.
- Programmatic screenshot export (`QUOTABOT_SHOTS=1`): the app loads demo data,
  captures the widget and analytics views to transparent PNGs via the real widget
  tree (Flutter's own RepaintBoundary, no OS screen grab), and exits. This keeps
  the README images deterministic and faithful to regenerate.
- `quotabot top`: a live, htop-style dashboard for the terminal. One bar per
  rolling window for every provider, colored on the headroom scale with live
  reset countdowns, local runtimes as always-on fallbacks, a header pool gauge,
  and a route line naming where to send the next request. It redraws in place on
  the alternate screen (wrapped in synchronized-output to avoid tearing),
  repaints countdowns every second, re-collects every `--interval` seconds
  (default 10, minimum 2), and takes `q`/Ctrl-C to quit and `r` to refresh now.
  Honors the binding-window collapse, and degrades to a single plain frame when
  piped or on a dumb terminal. The frame renderer is a pure, fully tested
  function; the ANSI styling is shared with the one-shot CLI output.
- MCP 2025-11-25 depth: every tool now advertises a JSON output schema and returns
  structured content (`structuredContent` alongside the back-compat text block),
  plus read-only/idempotent tool annotations so clients can validate results and
  see that the tools never mutate state. Tool shapes, schemas, and wiring moved
  into a tested `lib/mcp.dart` (the server binary is now a thin shell), covered by
  an in-memory client/server round-trip that exercises the real schema validation.
- System tray for the desktop app: a tray icon with a context menu (show, refresh,
  quota analytics, quit). The window now closes to the tray instead of quitting,
  so quotabot can sit quietly in the background; Quit lives in the tray menu.
- One-command from-source setup: `tools/setup.ps1` (Windows) and `tools/setup.sh`
  (macOS/Linux) build and install the CLI and the desktop app, create a shortcut,
  and finish with `quotabot doctor`. AGENTS.md documents it so an AI agent pointed
  at the repo can set everything up unattended. `tools/create-shortcut.ps1`
  (re)creates the Windows Desktop shortcut on its own.
- Routing suggestions now carry a versioned `schema` (`quotabot.suggest.v1`) and a
  guaranteed non-null `fallback` (a running local runtime, the soonest-resetting
  subscription to wait for, or a passthrough to the requested model), so a caller
  that skips the pick or gets no recommendation always has an actionable next step.

### Changed
- Routing (`quotabot suggest`, the MCP `suggest_provider` tool, and the local
  `/suggest` endpoint) now ranks on burn-aware effective headroom: each
  provider's remaining quota is discounted by its recent burn rate over a
  one-hour planning horizon, so a cap being drawn down fast is preferred less
  than its instantaneous headroom suggests, and a raw-comfortable provider can
  correctly fall back to a local runtime once burn is accounted for.
  Availability still reflects present headroom. The suggestion JSON gains
  `effective_headroom_percent` per candidate, plus `burn_percent_per_hour` when
  local history is available.
- Prebuilt CLI binaries cover macOS (Apple Silicon), Linux x64/arm64, and Windows.
  GitHub retired the Intel macOS runner, so Intel Macs build from source
  (`tools/setup.sh`); the installer prints that instead of failing on a missing
  asset.

## 0.2.0 - 2026-06-27

### Added
- Cross-platform release pipeline: pushing a `v*` tag builds the CLI asset
  natively on Linux (x64/arm64), macOS (x64/arm64), and Windows, each with a
  `.sha256` sidecar, so the one-line installers pull a real checksummed binary on
  every OS.
- Quota Analytics: a range-switched view (Now / 7d / 90d) in the same window,
  opened from the header. Now shows ranked headroom with resets and a
  consumption-share donut; 7d/90d recompute from history for the free-%
  distribution, reliability and per-day trend, and a best-time-to-run
  weekday-by-hour heatmap. Carries one math-derived glyph (the only emoji in the
  app), chosen by the fleet's own numbers.
- Antigravity live quota via the Antigravity OAuth client plus the onboarding
  step, so paid accounts read real model quota instead of 403. `quotabot login
  antigravity` now works with no Google Cloud setup and pins a chosen account.
- Full-featured CLI: `status`, `check <provider>`, `json`, `help`, and `version`
  alongside `suggest`/`stats`/`login`/`logout`, with `--json` on every read
  command, color that honors NO_COLOR/CLICOLOR/TTY, and a progress spinner.
- Lemonade Server adapter (OpenAI-compatible local runtime, port 8000, honors
  `LEMONADE_HOST`).
- Demo mode (`QUOTABOT_DEMO=1`) that renders synthetic, account-free data for
  previews and screenshots, plus widget and analytics screenshots in the README.
- Agent and reference docs: `AGENTS.md` (the routing contract), `docs/USAGE.md`,
  `docs/BUILDING.md`, and `docs/PROVIDER_CLIS.md` (each provider's own usage
  command, with a last-updated stamp).
- CLI release asset packaging helpers: `tools/package-cli.ps1` and
  `tools/package-cli.sh`, each writing the installer asset plus a `.sha256`
  sidecar under `release/`.
- Forward-looking pace analytics: burn rate, runway, pace-vs-reset, and projected
  waste, surfaced in `quotabot stats` and the in-app insights panel.
- Cross-provider meta-analytics: most/least used, and a "barely used, a lower tier
  may be enough" flag once a provider has a week-plus of history.
- Hour-by-weekday headroom heatmap in the expanded insights panel (a "best time to
  run" map), plus day-of-week and hour-of-day profiles.
- In-app Setup and help panel listing each provider's status with inline Connect
  (Grok/Antigravity) or setup tips, and a right-click card menu (set up / hide).
- Routing-aware low-quota alerts: the notification names where to route next.
- Versioned `quotabot.v1` schema on JSON outputs for agent consumers.
- Richer local-runtime detail: loaded model size, quantization, VRAM, context, and
  disk usage.
- New gauge-style app icon matching the in-app mark.
- LM Studio support, and a rethink of how local runtimes are shown. Local
  runtimes (Ollama, LM Studio) have no quota, so they no longer render a usage
  bar. Their card reports installed model count, which model is loaded, and an
  in-use indicator, and they sort below the cloud quota services. Real provider
  icons replace the placeholder dot (a llama for Ollama, a branded hexagon for
  LM Studio). Other OpenAI-compatible runtimes can be added with the shared
  `localRuntimeQuota` helper.
- Historical analytics: headroom is folded into compact hourly buckets retained
  for 90 days. Derives mean and spread, p10/p50/p90 from a histogram,
  reliability, a least-squares trend (percent per day with an R-squared
  confidence), and a by-hour tightness profile. Surfaced as `quotabot stats`
  (human and `--json`) and an expandable in-app insights panel with a sparkline.
- Codex multi-bucket aggregation so usage on one model is not hidden by a fresh
  bucket on another (see Fixed for the user-visible effect).

### Changed
- The desktop binary now uses the public `quotabot` name.
- Default provider order leads with the most widely used (Claude, then Codex).
- Header controls reordered to refresh, analytics, collapse, menu, help, close,
  with a clearer bar-chart analytics icon and tooltips.
- README tightened from roughly 390 to 150 lines, with the widget walkthrough,
  analytics, CLI reference, MCP, and build detail moved into linked docs.
- Cache, history, and analytics writes are atomic (temp file then rename).
- Dev tooling refreshed: lints 6.x, CI enforces 85 percent line coverage, and
  `actions/checkout` is on v5.

### Security
- Token and cache provider names are constrained or sanitized before they become
  local filenames.
- The LiteLLM router only accepts loopback `quotabot_url` values and clamps
  policy TTL/threshold values to bounded ranges.
- Installers validate `QUOTABOT_REPO`, reject malformed checksum sidecars, and
  verify Windows downloads before replacing an existing installed executable.
- Token files are created owner-only before the secret is written, and the auth
  directory is locked down, closing a brief world-readable window on POSIX.
- The local HTTP server returns generic error bodies and throttles the outbound
  provider calls behind a short cache.

### Fixed
- Antigravity now refreshes the Gemini/Antigravity access token from the stored
  refresh token instead of reusing the expired one, so the signed-in account no
  longer drops to "no live data" after about an hour. When the per-model quota
  endpoint returns nothing it now says so honestly instead of mislabeling a paid
  account as free tier.
- The Antigravity adapter tolerates a network error in the quotabot-grant path
  (falling back to the CLI/IDE token instead of hard-failing), a non-string tier
  id during onboarding, and no longer assigns a stringified user object as the
  account.
- Google and xAI token responses are decoded inside a guard, so a malformed 200
  can never surface token bytes in an error string.
- The LiteLLM router no longer lets a local fallback preempt a metered provider
  that still has budget.

## Earlier in this cycle

### Added
- Routing recommendation engine (`suggestRoute`): prefers the freest live
  subscription above a comfort threshold and falls back to a local runtime when
  every subscription is low. Surfaced as `quotabot suggest` (human and `--json`),
  the `suggest_provider` MCP tool, and `GET /suggest` on the local HTTP server.
- Ollama adapter: detects a local daemon and reports it as an always-available
  local fallback (`kind: local`); hidden when the daemon is not running.
- LiteLLM proxy plugin (`integrations/litellm/`): a quota-aware pre-call hook
  that routes each request to a deployment with budget, with per-agent steering,
  a local fallback, a usage-metrics logger, and fail-soft behavior. Runs on
  Windows, macOS, and Linux.
- `docs/SETUP.md`: a step-by-step getting started guide.
- `doctor` now prints a next step for each provider (cached to login, no data to
  open the app) and a closing routing suggestion.
- README disclaimer covering trademarks, no-affiliation, and that the user is
  responsible for complying with each provider's Terms of Service.

### Changed
- Usage bars read "X% free" instead of an unlabeled "X%".
- The header timestamp shows an absolute clock time ("as of 8:38 AM"), adding a
  date only once the snapshot is no longer from today.
- `ProviderQuota` gained a `kind` field (`subscription` or `local`).
- Repo layout tidied: contributor docs moved under `docs/dev/`, the dev helper
  moved to `tools/local-setup.ps1`, and internal journals plus build artifacts
  are git-ignored.

### Fixed
- Codex now aggregates the latest snapshot of each model limit bucket across
  recent sessions and shows the binding (most-used) window. Previously it read
  only the newest session, so usage on a different model bucket was invisible
  (a fresh model's 0% masked real weekly usage, reading as a false "100% free").
  Buckets past their reset are treated as fresh when choosing the binding one.
- Codex snapshots carry their real on-disk capture time and are marked stale
  past the window age, so an idle Codex no longer reads as a fresh "100% free".
- The Antigravity last-known-good fallback loads the per-account cache file it
  actually writes (the previous path was never created, so the fallback was
  dead code).
- Headroom selection prefers live data over a fuller but stale cache, and
  excludes local runtimes from winning on their unlimited headroom.
- Windsurf no longer emits duplicate `daily`/`weekly` windows from snake_case
  and camelCase keys.
- History files are size-bounded instead of growing without limit.
- The Grok device-login flow honors the `slow_down` backoff.
- Token files are restricted to the current user on Windows (icacls), matching
  the POSIX `chmod 600`.
- Hardcoded Flutter paths removed from the Windows helper scripts; they now
  discover Flutter on PATH so they work on any machine.
