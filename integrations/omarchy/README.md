# Omarchy bar widget

quotabot can show remaining headroom, reset times, freshness, and one
recommendation in the Omarchy bar. The widget is a third-party plugin for the
stable Omarchy 4.0.4 shell (`c668141`, Quickshell 0.3.1). It is source in this
repository. It is not part of the 0.11.8 release, and this checkout does not
by itself prove an installed Omarchy desktop.

## Why this is a separate panel

Omarchy 4.0.4 already ships `omarchy.agents`. Its collector writes one JSON
record per agent into `~/.local/state/omarchy/agents/usage/<id>.json`, and the
stock panel renders that directory. That record cannot carry this workflow:

- A limit percent is amount used. quotabot headroom is amount remaining.
  There is no unknown meter: a missing or negative percent drops the row.
- `usageStatusText` replaces the plan line and opens an urgent card. It is
  the wrong place for a routing recommendation.
- The stable panel has no per-account rows and no per-provider freshness.
- The unreleased quattro branch can show `accounts[]`, and those rows call
  account-switch commands. Reading status must not switch a harness account.
- One record's fullest window becomes the bar alarm. Putting every provider
  on one record would mark the bar urgent because a spent account is full,
  even when the recommendation is a healthy route.
- A local runtime is not a prepaid balance or a rate limit.

The widget therefore does not write `claude.json`, `codex.json`, `grok.json`,
`fireworks.json`, or any other file in the agents usage directory. Its id is
`blisspixel.quotabot`, outside the reserved `omarchy.` prefix.

## What a refresh does

`integrations/omarchy/plugin/collect.py refresh` runs only:

```text
quotabot --json
quotabot suggest --json
```

Both are metadata reads. The collector does not run a model, does not pass a
prompt, and does not call `omarchy-agent-account-use` or any print-mode
command. It writes one redacted file:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/quotabot/omarchy-display.json
```

Set `QUOTABOT_OMARCHY_STATE_DIR` to move that file. Set `QUOTABOT_BIN` to
choose the quotabot executable; otherwise the collector uses the first
`quotabot` on `PATH`.

The display schema is `quotabot.omarchy.v1`. Recommendation fields come from
the suggestion. Account windows come from the snapshot. The file omits the
decision receipt, model catalogs, hardware dumps, raw account identifiers,
emails, bearer tokens, and home paths. Account labels are either short public
words such as `default` or a stable `account:` prefix plus a keyed digest.
The digest key stays in `alias.key` next to the display file and is not a
provider credential.

Unknown headroom stays null. A drifted or out-of-range window is `drift` and
is not given a remaining percent. A stale snapshot keeps the last trusted
percent and says `stale`. A provider that fails without last-trusted windows
stays in the list as `unknown`. If the CLI times out, exits nonzero, or
returns invalid JSON, the previous display file is kept and `read_ok` becomes
false. That failure records `read_failed_at` and does not advance
`generated_at`, `snapshot_as_of`, or `suggestion_as_of`. The meters are not
replaced with zeros.

The stored file keeps the freshness from the moment quotabot wrote it. On
load, including a shell restart before the next refresh, the widget ages that
file from the original capture times. A `live` row older than 900 seconds,
missing a capture time, or more than 120 seconds ahead of the clock is shown
as `stale` with its last percent. Drift and unknown do not change. The
default refresh interval is 900 seconds and can be changed with the widget
setting `refreshIntervalSec` (30 through 3600). A rendered Quickshell panel
was not part of the fixture check.

The bar button shows the recommendation's remaining percent, or `qb` when
that percent is unknown or drifted. The tooltip names the aged freshness and,
when known, how old the evidence is. Left click opens the panel. Middle click
or the panel's Refresh line runs the collector again. Right click does
nothing. The panel does not switch accounts.

## Install on Omarchy 4.0.4

`omarchy plugin add` clones a git repository whose manifest is at the
repository root. This repository's manifest is not at the root, so do not
point that command at the quotabot repository. Copy the plugin directory by
hand:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/blisspixel.quotabot"
cp -R integrations/omarchy/plugin/. \
  "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/blisspixel.quotabot/"
omarchy-shell shell rescanPlugins
omarchy plugin enable blisspixel.quotabot
```

A Linux CLI archive built by `tools/package-cli.sh` carries the same files in
`lib/omarchy/`. Copy that directory to the plugin path above. Building the
archive is not a published release, and copying the files is not a test that
the panel rendered.

Remove it with:

```bash
python3 integrations/omarchy/plugin/collect.py uninstall \
  --plugin-dir "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/blisspixel.quotabot" \
  --agents-dir "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage"
```

That deletes the display file, the local alias key, and the plugin directory
only when its manifest id is `blisspixel.quotabot`. It does not delete agent
usage records. `omarchy plugin remove blisspixel.quotabot` removes a git
checkout created by `omarchy plugin add`; a hand copy still needs the command
above or a manual delete of that plugin directory.

Plugins run unsandboxed in the user shell. Review the QML before enabling it.
There is no marketplace submission. Publishing to a public plugin directory
needs a separate decision.

## Host contract notes

The widget imports `qs.Commons as Commons` and uses `Commons.Color` and
`Commons.Style`. On 8 October 2026, Qt 6.12 added a `QtQuick.Color` singleton
that shadows an unqualified `Color` import inside the Omarchy 4.0.4 shell.
Namespacing this plugin's own colors avoids that collision. The shell's
`KeyboardPanel` still references unqualified `Color` until a newer Omarchy
release; the panel paints its own popup background from `Commons.Color` so
the text stays readable when that host binding is undefined.

The popup uses `KeyboardPanel` from `qs.Ui`. Opening it calls
`bar.requestPopout`, and closing it calls `bar.releasePopout`. The widget root
does not declare required properties, which is what the 4.0.4 injector sets:
`bar`, `moduleName`, and `settings`.

## Checks that this repository can run

From the repository root:

```bash
python -m unittest discover -s integrations/omarchy -p 'test_*.py'
```

Those tests cover mapping, redaction, one failed provider, a timed-out CLI
that keeps the previous snapshot, a reload that does not run quotabot, and
uninstall that leaves other agent files in place. They also check that a
sample Linux CLI archive may contain `lib/omarchy/` without weakening the
archive verifier.

They do not start Omarchy, do not render Quickshell, and do not publish a
release. A green unit run is not an installed-desktop proof.
