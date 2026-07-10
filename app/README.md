# quotabot desktop app

Flutter desktop application for Windows, macOS, and Linux. It imports the
collector package directly, so desktop cards, routing summaries, analytics,
alerts, profiles, and local preferences use the same normalized quota and
routing core as the CLI and MCP server.

This file is intentionally developer-specific. Canonical behavior and product
claims live in:

- [../README.md](../README.md): product overview and acquisition;
- [../docs/USAGE.md](../docs/USAGE.md): widget, analytics, profile, alert, and
  accessibility behavior;
- [../docs/BUILDING.md](../docs/BUILDING.md): prerequisites, build, packaging,
  and launch paths;
- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md): app-to-collector
  boundaries;
- [../docs/DATA_SOURCES.md](../docs/DATA_SOURCES.md): provider evidence and
  limitations.

Run from the repository root with the platform target documented in
[../docs/BUILDING.md](../docs/BUILDING.md). Keep platform-specific shell and
window integration thin; product state and decision logic belong in the
collector or in pure app helpers with tests.
