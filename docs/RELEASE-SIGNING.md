# Release signing operations

quotabot remains an Apache 2.0 open-source project before and after platform
signing. Signing does not restrict source access or add a proprietary runtime.
It lets Windows and macOS verify who published a downloaded binary and whether
that binary changed after publication.

## Activation order

Keep both platform modes `unsigned` while the 0.10.x correctness, recovery,
quality-of-life, and native field-validation rounds are active. Every unsigned
candidate must retain the explicit release-note disclosure, checksums, GitHub
provenance, and exact asset audit.

Start identity enrollment when the owner is ready for the external validation
and recurring account costs. Complete signing readiness in this order:

1. The reproducible bug inventory is empty and the current candidate passes the
   complete three-OS project gate.
2. Windows Public Trust identity validation and the macOS Developer ID identity
   are active under the publisher name the owner intends users to see.
3. The isolated signing jobs, native verifiers, and protected environments pass
   nonpublishing rehearsals without weakening SmartScreen or Gatekeeper.
4. Set the repository signing modes for one protected release candidate, then
   run the complete signed tag workflow and fresh-download lifecycle.
5. Keep signing active for later releases only after that signed candidate
   passes install, launch, update, rollback, uninstall, checksum, provenance,
   native verification, and immutable asset verification.

Identity enrollment can take time, but it does not require freezing development.
Do not describe an artifact as trusted, signed, or notarized until its own native
verification evidence exists.

The tag workflow has two explicit Windows modes:

- `unsigned` packages the unchanged, fully inventoried candidate and places an
  unsigned transition warning at the top of the GitHub release notes.
- `azure-artifact-signing` signs only the exact validated PE catalog, verifies
  Windows trust, SHA-256 Authenticode and RFC 3161 policy, and binds the signer
  to one durable Artifact Signing subscriber identity EKU.

It also has two explicit macOS modes:

- `unsigned` packages the unchanged, fully inventoried candidate and retains the
  unsigned transition warning.
- `developer-id` signs the exact validated CLI and desktop targets inside out
  with hardened runtime and secure timestamps, requires accepted notarization,
  staples the desktop app, verifies signatures and Gatekeeper, and repeats those
  checks after packaging and fresh download. The standalone CLI cannot carry a
  stapled ticket, so it must pass accepted notarization, native signature
  verification, and Gatekeeper assessment without stapler validation.

The macOS `developer-id` path is implemented and covered by deterministic policy
and failure tests. Both repository modes remain `unsigned`, and current published
artifacts remain unsigned. Owner identity and credential provisioning, a
successful protected rehearsal, mode activation, and signed fresh-download
evidence remain required.

## GitHub configuration

The repository Actions policy must keep full-length commit SHA pinning required
and allow the two signing action repositories in addition to the existing
project allowlist:

```text
azure/login@*
Azure/artifact-signing-action@*
```

The workflow itself pins Azure Login and Artifact Signing Action to reviewed
full commit SHAs. GitHub resolves every referenced action before it evaluates a
job condition, so these repository allowlist entries are required even while
the Windows signing mode is `unsigned` and both Windows signer jobs are skipped.
Confirm the live policy before pushing an immutable release tag:

```bash
gh api repos/blisspixel/quotabot/actions/permissions
gh api repos/blisspixel/quotabot/actions/permissions/selected-actions
```

The protected Windows environment is named `release-signing`. Keep it configured
as follows:

1. Restrict deployments to the protected `main` branch and tag pattern `v*`.
2. Require a maintainer review. If the repository has only one maintainer, keep
   self-review available so a release cannot deadlock. Disable administrator
   bypass when the repository plan and environment controls expose that option.
3. Keep every Azure OIDC and signing-service identifier in this environment.
   Only the isolated Windows signer jobs reference it.
   Unsigned builds, packaging, attestation, upload, verification, ordinary CI,
   and pull requests do not.

The separate protected Apple environment is named `release-signing-macos`.
Keep deployments restricted to the protected `main` branch and the `v*` tag
pattern, require review, and apply the same administrator-bypass policy. The two
release signer jobs use the tag path. The nonpublishing rehearsal signer uses
the protected-main path and fails unless the workflow was dispatched from
`main`. No other jobs reference the environment. The Windows environment cannot
read the Apple certificate or notary credential, and the macOS jobs receive no
Azure OIDC permission.

Both live environment shells now require maintainer review and restrict
deployments to `main` and `v*`. They contain no signing values or secrets. This
is environment policy readiness, not owner identity provisioning, successful
rehearsal evidence, or signing activation.

Set these repository variables so preflight can select and disclose the mode
before any environment-bound job starts:

```text
QUOTABOT_WINDOWS_SIGNING_BACKEND=unsigned
QUOTABOT_MACOS_SIGNING_MODE=unsigned
QUOTABOT_MACOS_NOTARY_ISSUER_ID
QUOTABOT_MACOS_NOTARY_KEY_ID
```

When preparing the Apple path, set these non-secret repository variables. The
identity must begin with `Developer ID Application: ` and end with the same
ten-character team id in parentheses:

```text
QUOTABOT_MACOS_DEVELOPER_IDENTITY
QUOTABOT_MACOS_TEAM_ID
```

The notary issuer and key identifiers are non-secret verification policy. They
must be repository variables because release preflight validates and snapshots
them before any environment-bound signer starts. The P8 private key remains a
protected environment secret.

Set only these sensitive values as secrets in `release-signing-macos`:

```text
QUOTABOT_MACOS_CERTIFICATE_P12_BASE64
QUOTABOT_MACOS_CERTIFICATE_PASSWORD
QUOTABOT_MACOS_NOTARY_KEY_P8
```

The P12 holds the Developer ID Application identity. The P8 is the App Store
Connect notary key. Neither value belongs in repository variables, logs, cache,
or retained artifacts.

After Azure issues the profile's durable subscriber identity, also set this
non-secret repository variable so packaging and fresh-download verification can
enforce the public signer identity without entering the signing environment:

```text
QUOTABOT_WINDOWS_SUBSCRIBER_EKU
```

Release preflight validates the selected modes and captures this subscriber EKU
plus the macOS identity, team, and notary identifiers once. Every later signing,
packaging, and fresh-download verification job consumes that run-scoped
snapshot. Inactive policy fields are cleared, so changing a repository variable
during a release cannot change the verifier policy partway through that run.

Keep Windows in `unsigned` until every Azure value below is provisioned and a
protected rehearsal succeeds. Never create a PFX, client secret, certificate
file, password, or long-lived cloud credential for this workflow.

## Azure Artifact Signing Public Trust

Public Trust eligibility and identity validation are owner operations in the
Azure portal. Create one Artifact Signing account and one Public Trust
certificate profile for quotabot. Create one Entra application or managed
identity used only by this release environment.

The owner first chooses whether the visible publisher is an eligible individual
or a legal organization. The Azure billing account type must match that choice,
and its legal name and address must match the identity-validation documents.
Public Trust is geographically restricted. Check current eligibility before
creating resources, and allow for Microsoft's documented identity-validation
window of 1 through 20 business days or longer when more documents are needed.

Owner checklist:

1. Create or select the matching Azure subscription and Microsoft Entra tenant.
2. Register `Microsoft.CodeSigning`, create one Artifact Signing account, and
   choose the Basic or Premium service tier based on expected signing volume.
3. Complete Public Trust identity validation in the Azure portal and create one
   `PublicTrust` certificate profile for quotabot. Do not use `PublicTrustTest`
   for a public release.
4. Create the release-only Entra identity and federated GitHub credential, then
   grant only `Artifact Signing Certificate Profile Signer` on that one profile.
5. Supply the bounded environment values below, discover and independently
   verify the durable subscriber EKU, and approve a protected rehearsal.

Before creating the federated credential, read the repository's active OIDC
subject configuration:

```bash
gh api repos/blisspixel/quotabot/actions/oidc/customization/sub
```

At the time this document was updated, the repository reports the default
non-immutable subject prefix `repo:blisspixel/quotabot`. The environment-bound
federated credential therefore uses:

```text
issuer:   https://token.actions.githubusercontent.com
subject:  repo:blisspixel/quotabot:environment:release-signing
audience: api://AzureADTokenExchange
```

If GitHub later reports immutable subjects, use the exact current subject form
from GitHub rather than the value recorded above.

Assign the Entra identity only the `Artifact Signing Certificate Profile
Signer` role at the single certificate-profile resource scope. Do not assign a
subscription-wide or resource-group-wide signing role.

Add these environment variables, not repository secrets:

```text
QUOTABOT_AZURE_CLIENT_ID
QUOTABOT_AZURE_TENANT_ID
QUOTABOT_AZURE_SUBSCRIPTION_ID
QUOTABOT_AZURE_SIGNING_ENDPOINT
QUOTABOT_AZURE_SIGNING_ACCOUNT
QUOTABOT_AZURE_CERTIFICATE_PROFILE
```

The subscriber EKU is the exact owner-specific OID under
`1.3.6.1.4.1.311.97.` found in a certificate issued from that Public Trust
profile. It is not the common Public Trust marker
`1.3.6.1.4.1.311.97.1.0`. Inspect an owner-authorized disposable signature or
the profile's issued-certificate evidence, record the exact subscriber OID, and
cross-check it against the identity validation before setting the variable.
Never infer it from a subject, thumbprint, or public key.

The workflow builds and inventories each Windows candidate in a job with no
OIDC permission or signing environment. An isolated signer downloads that
immutable handoff, revalidates the complete tree and exact catalog before Azure
authentication, signs and verifies it, and uploads a second immutable handoff.
A separate job with no signing environment revalidates, packages, attests, and
uploads the selected signed or explicitly unsigned candidate. This separation
keeps the federated signing identity out of dependency resolution, compilation,
packaging, and release publication.

The workflow pins Azure Login v3.0.1 and Artifact Signing Action v2.0.0 to full
commit SHAs. Azure Login obtains a short-lived token through GitHub OIDC. The
signing action is restricted to the Azure CLI credential established by that
login and receives:

- one exact `files-catalog` produced outside the candidate tree;
- SHA-256 file digests;
- `http://timestamp.acs.microsoft.com` with an SHA-256 RFC 3161 digest;
- no appended signature;
- no dependency cache or trace output.

## Windows activation and rehearsal

Do not change the repository mode merely because Azure accepts one signing
request. First complete a protected nonrelease rehearsal using the same account,
profile, exact catalog generator, full-tree delta validator, and verifier.
The manual `Windows signing rehearsal` workflow builds both unsigned candidates
outside `release-signing`, enters that protected environment only for OIDC
authentication and signing, and transfers each signed candidate through a
one-day handoff. A separate credential-free job re-downloads the original
unsigned baseline and signed handoff, regenerates the catalog, repeats the delta
and native signature checks, deletes both local payloads on every exit, retains
bounded JSON evidence for 14 days, and publishes nothing. Confirm that every
catalogued PE changes and no other tree entry does, every PE has one embedded
signature, the timestamp message imprint binds the outer signature, and every
leaf contains exactly the configured subscriber identity plus the common Public
Trust and code-signing EKUs.

Dispatch and inspect the protected rehearsal from `main`:

```bash
main_sha="$(gh api repos/blisspixel/quotabot/commits/main --jq '.sha')"
gh workflow run windows-signing-rehearsal.yml --ref main
gh run list --workflow windows-signing-rehearsal.yml --branch main \
  --event workflow_dispatch --commit "$main_sha" --limit 5
run_id=123456789  # replace with the approved run id shown above
gh run watch "$run_id" --exit-status
gh run view "$run_id" --json workflowName,event,headSha,conclusion \
  | jq -e --arg sha "$main_sha" \
    '.workflowName == "Windows signing rehearsal" and .event == "workflow_dispatch" and .headSha == $sha and .conclusion == "success"'
gh run download "$run_id" \
  --pattern 'windows-*-signing-rehearsal-evidence' \
  --dir windows-signing-rehearsal-evidence
for surface in cli desktop; do
  evidence="windows-signing-rehearsal-evidence/windows-$surface-signing-rehearsal-evidence"
  jq -e '.schema == "quotabot.windows-signing-delta.v1" and .ok == true' \
    "$evidence/signing-delta.json"
  jq -e '.schema == "quotabot.windows-signature-verification.v2" and .verified == true' \
    "$evidence/signature-verification.json"
done
```

Retain the run URL, commit SHA, approval record, and both evidence artifacts.
The rehearsal does not replace the later signed release-candidate lifecycle.

Then set:

```text
QUOTABOT_WINDOWS_SIGNING_BACKEND=azure-artifact-signing
```

Push only a protected `v*` tag that points to the current protected `main` tip.
Approve the environment deployment, let the workflow create a draft, and wait
for every build, fresh-download verification, lifecycle, checksum, provenance,
and final asset audit job. A missing identifier, OIDC failure, untrusted chain,
wrong or extra subscriber identity, multiple signature, SHA-1 digest, missing
timestamp, changed candidate, or incomplete receipt leaves the release draft
unpublished.

After publication, download the exact Windows CLI and desktop archives again,
verify their checksums and GitHub attestations, extract them, and rerun
`tools/verify_windows_signatures.py` with the configured subscriber EKU. Retain
the inventories and bounded receipts with the release record.

## Apple Developer ID and notarization

Direct distribution outside the Mac App Store requires Apple Developer Program
membership to create a Developer ID identity and submit software to Apple's
notary service. The owner chooses the publisher identity before enrolling:

- An individual or sole proprietor publishes under the account holder's legal
  personal name.
- An organization publishes under its verified legal entity name and needs a
  matching D-U-N-S Number plus authority to bind that organization.

Apple currently lists the program at USD 99 per membership year, with local
pricing where available. Open-source status does not waive the ordinary fee by
itself. Apple documents possible waivers for eligible nonprofit, educational,
and government entities.

Owner checklist:

1. Enroll the intended individual or organization in the Apple Developer
   Program and complete Apple's identity verification.
2. As Account Holder, create a `Developer ID Application` certificate for the
   app and command-line binaries. Create a `Developer ID Installer` certificate
   only if quotabot later ships a signed installer package.
3. Create a role-limited App Store Connect team API key for notarization, or use
   another Apple-supported automation credential. An individual API key cannot
   authenticate `notarytool`. Place the credential only in a separate protected
   `release-signing-macos` environment and never in repository variables or
   artifacts.
4. Configure the repository and protected-environment variables and secrets named
   in [GitHub configuration](#github-configuration). Confirm the Developer ID
   identity ends with the configured team id and that the notary key belongs to
   that Apple team.
5. Run a successful protected rehearsal through both isolated macOS signer jobs.
   Deterministic tests prove the fail-closed policy but do not substitute for a
   real certificate import, Apple notarization, Gatekeeper assessment, or staple.
   Dispatch `.github/workflows/macos-signing-rehearsal.yml` from protected
   `main`; it builds unsigned
   CLI and desktop candidates outside `release-signing-macos`, signs and verifies
   them inside that protected environment, uploads only bounded receipts and
   digest records, and does not publish either candidate.
   Dispatch and inspect it with:

   ```bash
   main_sha="$(gh api repos/blisspixel/quotabot/commits/main --jq '.sha')"
   gh workflow run macos-signing-rehearsal.yml --ref main
   gh run list --workflow macos-signing-rehearsal.yml --branch main \
     --event workflow_dispatch --commit "$main_sha" --limit 5
   run_id=123456789  # replace with the approved run id shown above
   gh run watch "$run_id" --exit-status
   gh run view "$run_id" --json workflowName,event,headSha,conclusion \
     | jq -e --arg sha "$main_sha" \
       '.workflowName == "macOS signing rehearsal" and .event == "workflow_dispatch" and .headSha == $sha and .conclusion == "success"'
   gh run download "$run_id" \
     --pattern 'macos-*-signing-rehearsal-evidence' \
     --dir macos-signing-rehearsal-evidence
   for surface in cli desktop; do
     evidence="macos-signing-rehearsal-evidence/macos-$surface-signing-rehearsal-evidence"
     jq -e '.schema == "quotabot.macos-signing-delta.v1" and .ok == true and .operation == "signing"' \
       "$evidence/signing-delta.json"
     jq -e '.schema == "quotabot.macos-notarization.v1" and .ok == true and .status == "accepted"' \
       "$evidence/notarization.json"
     jq -e '.schema == "quotabot.macos-signature-verification.v1" and .ok == true' \
       "$evidence/signature-verification.json"
   done
   jq -e '.schema == "quotabot.macos-signing-delta.v1" and .ok == true and .operation == "stapling"' \
     macos-signing-rehearsal-evidence/macos-desktop-signing-rehearsal-evidence/stapling-delta.json
   ```

   Retain the run URL, commit SHA, approval record, and both evidence artifacts.
6. Only after that protected rehearsal succeeds, set
   `QUOTABOT_MACOS_SIGNING_MODE=developer-id`, push the protected release-candidate
   tag at the current `main` tip, approve both signer jobs, and let the complete
   release workflow publish the signed candidate.
7. Verify the exact fresh-downloaded CLI and desktop artifacts. Both require
   `codesign --verify --strict`, `spctl --assess`, and accepted notarization
   evidence. The desktop app additionally requires `codesign --verify --deep
   --strict` and `stapler validate`. A standalone CLI cannot carry a stapled
   ticket and must not be failed merely because no staple exists.

The Apple signing key is different from the notarization credential. Keep both
out of ordinary build and packaging jobs. Do not leave the macOS release mode
active for later releases until the signer, notarization, stapling, verification,
failure-path tests, and signed fresh-download lifecycle all pass.

### Implemented macOS release path

The repository now implements the following protected macOS path for both CLI
and desktop:

1. An ordinary macOS build job inventories the complete unsigned candidate and
   creates an exact inside-out signing plan. It places the candidate, inventory,
   and plan in an immutable handoff artifact.
2. The isolated signer downloads that handoff, regenerates and compares the
   inventory and plan, imports the password-protected P12 into a temporary
   keychain, and signs every exact Mach-O and containing bundle with hardened
   runtime and a secure timestamp. Only the outer desktop app receives the exact
   committed `app/macos/Runner/DeveloperID.entitlements`; the CLI and every
   other target require empty entitlements. A complete pre-signing and
   post-signing inventory comparison requires every planned Mach-O to change,
   forbids removals, and permits other additions or changes only inside a
   planned bundle's `_CodeSignature` metadata.
3. The signer submits a bounded ZIP to `notarytool`, requires both the submission
   and log to say `Accepted`, rejects notarization errors, and binds Apple's
   logged archive SHA-256 and name to the submitted ZIP. Before submission, it
   extracts that exact ZIP and requires its complete inventory to match the
   signed candidate. The recorder extracts and inventories the Apple-accepted
   ZIP again and rejects any mid-validation change; the accepted receipt records
   that extracted inventory and requires the ticket to cover every signed code
   directory. It staples the
   desktop app, then permits only signature metadata changes and requires no
   native-code change. When the ticket is attached only as extended metadata,
   the file inventory remains unchanged and `stapler validate` supplies the
   ticket proof. The CLI records accepted notarization without attempting an
   unsupported staple.
4. Native verification loads the original plan and checks every planned target's
   Developer ID authority,
   team id, timestamp, hardened-runtime flag, strict signature, and exact
   embedded entitlements. It binds the CLI's current inventory directly to its
   notarized inventory and chains desktop notarization through the exact
   stapling-delta receipt. It also binds current code-directory hashes to the
   accepted notarization receipt, requires Gatekeeper to report `Notarized
   Developer ID` for the CLI or app, and validates the desktop staple. It writes
   bounded receipts without retaining raw native diagnostics.
5. The signer creates a new post-signing inventory and a second immutable
   handoff. A separate job with no Apple credentials revalidates, packages,
   checksums, attests, and uploads that exact candidate.
6. Clean macOS verification jobs download the exact draft CLI and desktop assets,
   recheck their complete inventories, rerun the native verifier with the
   accepted notarization receipts, and retain bounded release evidence before
   publication can continue. They emit the exact verified archive digests and
   captured signing mode; final audit requires those values to match the assets
   immediately before the immutable asset manifest can reach publication.

The manual `macOS signing rehearsal` workflow exercises the same core signing,
notarization, delta, entitlement, Gatekeeper, and desktop-staple contract without
creating a release. It fails unless dispatched from protected `main`. Its
unsigned handoffs expire after two days, the protected jobs delete their
candidates and credentials, and only bounded receipts and digest records are
retained for 14 days. It is ready to run but has not completed successfully
because the owner Apple identity, repository verification variables, and
protected environment secrets are not provisioned.

The manual `Windows signing rehearsal` workflow applies the same protected-main,
nonpublishing, bounded-evidence model to both Windows surfaces. Release and
rehearsal signers compare the complete signed tree with the trusted unsigned
tree and exact Azure catalog. Every originally catalogued PE must change, while
added, removed, out-of-catalog, non-Authenticode, or unchanged entries fail the
run. A separate credential-free rehearsal verifier and each release packaging
job independently download the original unsigned handoff and repeat that
comparison before evidence or a signed package can be accepted.

All macOS build, signing, packaging, verification, and rehearsal jobs use the
explicit `macos-15` arm64 image and Xcode 16.4 build 16F6. Ordinary CI compiles
minimal arm64 CLI and app fixtures, applies hardened ad hoc signatures in the
generated inside-out order, and exercises real Apple entitlement, architecture,
and code-directory output. That credential-free test does not replace the
protected Developer ID, secure-timestamp, notarization, Gatekeeper, and staple
rehearsal.

The signer deletes the P12, P8, raw notarization submission and log, submission
archive, and temporary keychain on success or failure. Missing credentials,
identity or team mismatch, changed candidates or plans, signing failure,
unexpected signing or stapling delta, non-accepted or unbound notarization,
entitlements mismatch, missing desktop staple, Gatekeeper rejection, or
incomplete verification leaves the release unpublished. The delta validator
emits `quotabot.macos-signing-delta.v1` on success and bounded
`quotabot.macos-signing-delta-error.v1` evidence for handled failures. Unsigned
mode skips the signer and packages only the unchanged inventoried candidate with
an explicit release-note warning.

This implementation is repository readiness, not activation evidence. Existing
published macOS artifacts are immutable and remain unsigned. Future macOS
artifacts remain unsigned until owner provisioning, a successful protected
rehearsal, mode activation, and signed fresh-download verification are complete.

Primary references:

- [Artifact Signing GitHub Action](https://github.com/Azure/artifact-signing-action)
- [Artifact Signing setup](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
- [Artifact Signing certificate management](https://learn.microsoft.com/en-us/azure/artifact-signing/concept-certificate-management)
- [Artifact Signing roles](https://learn.microsoft.com/en-us/azure/artifact-signing/tutorial-assign-roles)
- [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [Apple Developer Program membership](https://developer.apple.com/support/compare-memberships/)
- [Apple Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [App Store Connect API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
