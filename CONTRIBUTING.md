# Contributing to quotabot

Thanks for your interest. quotabot is a small, local-first tool, and
contributions that keep it simple and correct are very welcome.

## Ways to help

- **Report a bug or request a feature** via [issues](https://github.com/blisspixel/quotabot/issues).
  For a provider that reads wrong, run `quotabot verify --json` and
  `quotabot explain --reads --network`. Review the files before attaching them;
  redact account identifiers and local paths. Credential values and user content
  should never appear, but reports can still contain private machine metadata.
- **Add or fix a provider adapter.** Adapters are thin I/O shells over pure
  parsing; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
  [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md).
- **Improve the widget, analytics, or routing.**

For security issues, do not open a public issue; see [SECURITY.md](SECURITY.md).

## Development setup

Use Flutter 3.44.6 with Dart 3.12.2, matching CI and release builds. Python
integration tests support Python 3.10 through 3.13 and CI uses 3.13; Python 3.14
is intentionally outside the LiteLLM integration's declared range. Confirm that
`flutter`, `dart`, and a supported `python` resolve in the current shell before
running gates. See [Building from source](docs/BUILDING.md).

On Windows, use the supported space-safe entry points. They automatically map
the bundled Dart SDK to a temporary path without spaces before any collector or
Flutter native-asset command runs:

```powershell
# Build and install from source.
pwsh tools/setup.ps1

# Run the complete contributor gate.
pwsh tools/check.ps1
```

The complete desktop gate requires Windows symlink support for Flutter plugins,
normally enabled through Windows Developer Mode. Source setup remains fail-soft:
if that desktop prerequisite is unavailable, it skips the app and still builds
and installs the CLI. The contributor gate stops so a desktop test is never
silently omitted.

On macOS or Linux, focused package checks can be run directly:

```bash
# Collector (CLI, MCP, HTTP, adapters)
cd collector
dart pub get
dart test

# App (desktop widget)
cd app
flutter pub get
flutter test
```

## Before you open a pull request

CI runs static policy, both Dart packages, the MCP clients, the LiteLLM router,
coverage floors, and native packaging. Run the portable gates locally first.
The exact platform package and readiness commands are in
[Building from source](docs/BUILDING.md#build-a-release-binary).
On Windows, `pwsh tools/check.ps1` is the equivalent complete gate and is the
supported invocation when the Flutter SDK path may contain spaces. The command
block below uses Bash syntax for macOS and Linux.

```bash
# repository policy and release consistency
ruff check .
ruff format --check .
python -m unittest discover -s tools -p "test_*.py"
python tools/check_release_version.py

# collector, including the 90 percent line-coverage floor
cd collector
dart pub get --enforce-lockfile
dart format --set-exit-if-changed .
dart analyze
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --check-ignore --in=coverage \
  --out=coverage/lcov.info --packages=.dart_tool/package_config.json \
  --report-on=lib
python ../tools/check_lcov.py coverage/lcov.info 90

# app, including the 80 percent line-coverage floor
cd ../app
flutter pub get --enforce-lockfile
dart format --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub --coverage
python ../tools/check_lcov.py coverage/lcov.info 80

# MCP client snippets
cd ../integrations/mcp_clients
npm ci
npm run typecheck
python -m unittest test_mcp_client_snippets.py

# LiteLLM router, with Python 3.10 through 3.13
cd ../litellm
python -m pip install --require-hashes -r requirements.txt
QUOTABOT_RUN_LITELLM_PROXY_TEST=1 python -m unittest \
  test_quotabot_router.py test_quotabot_proxy_integration.py
```

Guidelines:

- Keep changes focused and the diff small. One concern per pull request.
- Put logic in pure functions (parsing, analysis) with unit tests; keep adapters
  thin. The core carries high test coverage and CI enforces a floor.
- Match the surrounding style. No emoji in code, comments, or docs.
- Update [CHANGELOG.md](CHANGELOG.md) under "Unreleased" when behavior changes.
- New providers must read only local metadata, never make model/inference calls,
  and degrade gracefully (return account/plan with an explanatory note rather
  than throwing) when live data is unavailable.

## Dependency updates

Dependabot pull requests are advisory signals, not merge candidates. For every
selected dependency update:

1. Read the upstream release notes, security advisory when applicable, and
   breaking-change or runtime requirements.
2. Create a first-party branch from current `main`. Never merge, amend, or reuse
   the Dependabot branch or commit.
3. Apply the update with the ecosystem's native package manager so manifests and
   lockfiles are regenerated from trusted inputs. Keep GitHub Actions pinned to
   full commit SHAs with the version in a trailing comment.
4. Review the complete transitive diff, licensing or maintainer changes, and any
   new install scripts or platform packages.
5. Run the relevant format, analysis, unit, coverage, packaging, integration,
   dependency-review, and security gates before merging.
6. Confirm advisory intake retained the closed pull request as the warning
   record and deleted its branch. If intake failed, close the pull request and
   delete the bot branch manually.

Dependabot rebases are disabled and each ecosystem is limited to one open
advisory so warnings stay bounded while selected upgrades remain deliberate.
Dependabot-triggered CI jobs are skipped. A trusted second-stage workflow reads
only GitHub metadata, adds the advisory record, closes the pull request, and
removes its transient bot branch without checking out or executing bot code.

## Add a provider in 10 minutes

Use this checklist for every provider adapter:

1. Confirm the provider exposes quota or local-runtime metadata only. Do not add
   model inference, prompt reads, code reads, or token-spending calls.
2. Add the adapter under `collector/lib/adapters/` as a thin I/O shell over pure
   parsing helpers. Keep provider ids lowercase and stable.
3. Add one sanitized provider-shape fixture under
   `collector/test/fixtures/provider_shapes/`. Remove tokens, emails, prompts,
   paths, and account identifiers.
4. Add one compile-time row to `collector/lib/provider_adapters.dart` with the
   provider id, display name, adapter class, cache behavior, multi-account flag,
   fixture parser kind, and fixture filename.
5. Extend the registry-driven parser fixture test when the provider needs a new
   fixture parser kind.
6. Wire collection through `collectAll()` only after the pure parser and registry
   tests are green.
7. Update `docs/DATA_SOURCES.md`, `docs/ARCHITECTURE.md`, `docs/SCHEMA.md` if
   the public contract changes, README when user setup changes, and CHANGELOG
   under `Unreleased` for notable behavior, release, or documentation
   corrections.
8. Treat [the roadmap Next section](ROADMAP.md#next) as the sole immediate-priority
   claim. Update it when that item closes or the evidence changes. Other docs may
   explain the same reasoning or link to it, but must not create a competing
   "now" or "next" queue.
9. Run the collector, app, integration, coverage, and build gates described in
   this file before opening a pull request.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
