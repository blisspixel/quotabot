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

You need the Flutter SDK (it includes Dart). See
[Building from source](docs/BUILDING.md).

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

CI runs the same checks for both Dart packages and the LiteLLM router; run them
locally first:

```bash
# collector
cd collector && dart format . && dart analyze && dart test

# app
cd app && dart format lib test && flutter analyze && flutter test

# litellm router
cd integrations/litellm && python -m unittest test_quotabot_router.py
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
   the public contract changes, README when user setup changes, ROADMAP when a
   planned item closes, and CHANGELOG for behavior changes.
8. Run the collector, app, integration, coverage, and build gates described in
   this file before opening a pull request.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
