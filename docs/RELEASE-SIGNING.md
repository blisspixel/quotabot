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
and recurring account costs. Activate signing only after all of these are true:

1. The reproducible bug inventory is empty and the current candidate passes the
   complete three-OS project gate.
2. Windows Public Trust identity validation and the macOS Developer ID identity
   are active under the publisher name the owner intends users to see.
3. The isolated signing jobs, native verifiers, and protected environment have
   passed a nonrelease rehearsal without weakening SmartScreen or Gatekeeper.
4. One signed release candidate passes fresh-download install, launch, update,
   rollback, uninstall, checksum, provenance, and immutable asset verification.

Identity enrollment can take time, but it does not require freezing development.
Do not describe an artifact as trusted, signed, or notarized until its own native
verification evidence exists.

The tag workflow has two explicit Windows modes:

- `unsigned` packages the unchanged, fully inventoried candidate and places an
  unsigned transition warning at the top of the GitHub release notes.
- `azure-artifact-signing` signs only the exact validated PE catalog, verifies
  Windows trust, SHA-256 Authenticode and RFC 3161 policy, and binds the signer
  to one durable Artifact Signing subscriber identity EKU.

The macOS mode is currently `unsigned`. Developer ID signing, notarization, and
stapling must be implemented and rehearsed before that mode can change.

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
the signing mode is `unsigned` and both signing jobs will be skipped. Confirm
the live policy before pushing an immutable release tag:

```bash
gh api repos/blisspixel/quotabot/actions/permissions
gh api repos/blisspixel/quotabot/actions/permissions/selected-actions
```

Create one protected environment named `release-signing`:

1. Restrict deployments to tag pattern `v*` only.
2. Require a maintainer review. If the repository has only one maintainer, keep
   self-review available so a release cannot deadlock. Disable administrator
   bypass when the repository plan and environment controls expose that option.
3. Keep every signing credential and signing-service identifier in this
   environment. Only the two isolated Windows signer jobs reference it.
   Unsigned builds, packaging, attestation, upload, verification, ordinary CI,
   and pull requests do not.

Set these repository variables so preflight can select and disclose the mode
before any environment-bound job starts:

```text
QUOTABOT_WINDOWS_SIGNING_BACKEND=unsigned
QUOTABOT_MACOS_SIGNING_MODE=unsigned
```

After Azure issues the profile's durable subscriber identity, also set this
non-secret repository variable so packaging and fresh-download verification can
enforce the public signer identity without entering the signing environment:

```text
QUOTABOT_WINDOWS_SUBSCRIBER_EKU
```

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

## Activation and rehearsal

Do not change the repository mode merely because Azure accepts one signing
request. First complete a protected nonrelease rehearsal using the same account,
profile, exact catalog generator, verifier, and fresh-download checks. Confirm
that every PE has one embedded signature, the timestamp message imprint binds
the outer signature, and every leaf contains exactly the configured subscriber
identity plus the common Public Trust and code-signing EKUs.

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
4. Finish the repository's macOS signer job. It must sign nested Mach-O files
   from the inside out with hardened runtime and a secure timestamp, submit the
   supported container with `notarytool`, wait for acceptance, staple the app
   ticket, and record only bounded evidence.
5. Verify the exact fresh-downloaded CLI and desktop artifacts with
   `codesign --verify --deep --strict`, `spctl --assess`, and stapler validation
   where a ticket can be stapled. Then run the full native lifecycle rehearsal.

The Apple signing key is different from the notarization credential. Keep both
out of ordinary build and packaging jobs. Do not switch the macOS release mode
until the signer, notarization, stapling, verification, failure-path tests, and
fresh-download rehearsal all pass.

When the macOS signer is implemented, create `release-signing-macos` with the
same `v*` tag restriction, required maintainer review, and no administrator
bypass as the Windows environment. Keep Apple certificate and notarization
secrets there so the Windows OIDC jobs cannot read them. The macOS job should
create a temporary keychain, import the password-protected Developer ID
Application identity, use it only for the inventoried candidate, and delete the
temporary keychain even when the job fails.

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
