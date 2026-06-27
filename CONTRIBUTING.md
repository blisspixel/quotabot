# Contributing to quotabot

Thanks for your interest. quotabot is a small, local-first tool, and
contributions that keep it simple and correct are very welcome.

## Ways to help

- **Report a bug or request a feature** via [issues](https://github.com/blisspixel/quotabot/issues).
  For a provider that reads wrong, include the output of `quotabot doctor --json`
  with any tokens or emails redacted.
- **Add or fix a provider adapter.** Adapters are thin I/O shells over pure
  parsing; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
  [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md).
- **Improve the widget, analytics, or routing.**

For security issues, do not open a public issue; see [SECURITY.md](SECURITY.md).

## Development setup

You need the Flutter SDK (it includes Dart). See
[Building from source](README.md#building-from-source) in the README.

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

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
