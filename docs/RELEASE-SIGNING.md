# Release signing operations

The tag workflow has two explicit Windows modes:

- `unsigned` packages the unchanged, fully inventoried candidate and places an
  unsigned transition warning at the top of the GitHub release notes.
- `azure-artifact-signing` signs only the exact validated PE catalog, verifies
  Windows trust, SHA-256 Authenticode and RFC 3161 policy, and binds the signer
  to one durable Artifact Signing subscriber identity EKU.

The macOS mode is currently `unsigned`. Developer ID signing, notarization, and
stapling must be implemented and rehearsed before that mode can change.

## GitHub configuration

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

Primary references:

- [Artifact Signing GitHub Action](https://github.com/Azure/artifact-signing-action)
- [Artifact Signing certificate management](https://learn.microsoft.com/en-us/azure/artifact-signing/concept-certificate-management)
- [Artifact Signing roles](https://learn.microsoft.com/en-us/azure/artifact-signing/tutorial-assign-roles)
- [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
