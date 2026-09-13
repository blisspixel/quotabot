# Repository history

The September 2026 history cleanup removes disallowed authorship metadata from
the active branch history while preserving the maintained source history. The
existing repository, historical release tags, published assets, download URLs,
and release attestations remain in place. Historical tags still identify their
original commits. Pull requests and other historical GitHub records remain
separate from the cleaned active branch history.

Active branches and new tags must pass the approved human identity and message
rules in `tools/check_authorship.py`. The fixed
[historical tag baseline](../tools/legacy_release_refs.json) pins each preserved
ref name, Git object type, and object ID. Only those exact refs and their ancestry
are exempt from the current metadata rules. `HEAD` and every other ref retain
full ancestry checks. Changed historical refs or copies under new tag names fail
the gate. Do not expand the baseline to bypass a failed check, or import old
branch and backup refs from another clone.

New release notes contain no assistant, tool, bot, or contributor-credit
trailers, and the owner publishes the reviewed assets. CI service identities
remain part of build logs and cryptographic provenance. Product names in source
and integration documentation are not authorship credit.

Published releases keep their original provenance and remain available for real
prior-version installation and upgrade checks. A new release must carry fresh
build and verification evidence for its own tag and commit. Historical artifact
attestations must never be presented as evidence for rewritten source commits.

GitHub says contributor displays can take about 24 hours to refresh after a
history rewrite; repository owners can contact Support if stale data persists.
[Contributor cache guidance](https://docs.github.com/en/repositories/viewing-activity-and-data-for-your-repository/viewing-a-projects-contributors#contributor-data-is-stale-after-history-changes)
A branch rename round trip is not a guaranteed cache reset. During the September
2026 round trip, all nine required-check application bindings became null while
the check names and protection flags remained. The bindings were restored from
the saved protection. Before repeating a rename, save the exact protection;
afterward, compare every flag and check application ID, restoring any dropped
bindings before running CI. See [GitHub's rename behavior](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/renaming-a-branch).

See [GitHub's immutable-release rules](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
and [the release procedure](BUILDING.md#release-dry-run).
