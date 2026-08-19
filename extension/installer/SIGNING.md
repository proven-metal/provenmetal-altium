# Code signing the installer

An unsigned installer triggers Windows SmartScreen's "unknown publisher" prompt.
Signing with a certificate from a trusted CA (or Microsoft) removes it. Two paths
are wired up in this repo.

## Path A — SignPath Foundation (free, for open source)

[SignPath Foundation](https://signpath.org) issues a free code-signing certificate
to qualifying OSS projects and signs on their HSM, tying the signature to this
public repo. Integration is via the `SignPath/github-action-submit-signing-request`
action — scaffolded in [`.github/workflows/sign-release.yml`](../../.github/workflows/sign-release.yml).

### ⚠️ Eligibility gate — read first

SignPath's GitHub connector, **for OSS projects, requires that all workflow jobs
leading up to the signing request run on GitHub‑hosted runners** (they verify the
binary was built in CI, from this repo). See
<https://docs.signpath.io/trusted-build-systems/github> → "Checks performed".

The ProvenMetal extension DLL is compiled against **Altium's proprietary SDK
assemblies**, which are not redistributable and are not present on GitHub-hosted
runners — so the installer (which embeds that DLL) **cannot be fully built in CI**.
That means the standard Foundation OSS origin rules can't be satisfied for this
artifact as-is.

Practical implications:

- The `sign-release.yml` workflow signs an installer **built externally** (on the
  Windows/Altium machine) and downloaded from the release. That works under a
  SignPath **signing policy that allows externally built artifacts**, but **not**
  under the default Foundation OSS origin policy.
- If SignPath Foundation approves the project with a relaxed policy for this case,
  the workflow is ready to use. Otherwise, use Path B.

### Setup checklist (if proceeding)

1. Apply at <https://signpath.org/apply> (link this repo).
2. Install the [SignPath GitHub App](https://github.com/apps/signpath) and grant it
   access to this repository.
3. In SignPath, create/note the **Organization ID**, a **Project** (slug), a
   **Signing Policy** (slug), and an **Artifact Configuration**. Because
   `actions/upload-artifact` zips the file, the artifact configuration's root must
   be a `<zip-file>` containing the `<pe-file>` installer (see
   <https://docs.signpath.io/artifact-configuration>).
4. Add repo **secret** `SIGNPATH_API_TOKEN`, and repo **variables**
   `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG`,
   `SIGNPATH_SIGNING_POLICY_SLUG`.
5. Publish a release with the (VM-built) `ProvenMetal-Altium-Setup-v<ver>.exe`
   attached, then run the **Sign release (SignPath)** workflow with that tag. It
   downloads the installer, submits it for signing, and re-attaches the signed exe.

## Path B — bring your own certificate (works today)

`Build-Installer.ps1` signs locally with `Set-AuthenticodeSignature` (no signtool
needed) from a PFX or a cert already in the store:

```powershell
$env:PM_SIGN_PFX  = 'C:\certs\provenmetal.pfx'
$env:PM_SIGN_PASS = '<pfx password>'
cd extension\installer
.\Build-Installer.ps1 -SkipBuild
```

Certificate options, cheapest first:

- **Certum** open-source code signing — ~$30/yr (cloud token).
- **Azure Trusted Signing** — ~$10/month; EV-level SmartScreen reputation; needs an
  Azure subscription + organization validation.
- **Sectigo / DigiCert OV** — ~$200–400/yr.

EV certificates and Azure Trusted Signing clear SmartScreen immediately; OV certs
clear it once download reputation accrues.

## Recommendation

Given the Altium-SDK build dependency, **Path B** (a Certum OSS cert or Azure
Trusted Signing applied via `Build-Installer.ps1`) is the most reliable route to a
SmartScreen-clean installer. Keep Path A wired in case SignPath Foundation approves
an externally-built-artifact policy for the project.
