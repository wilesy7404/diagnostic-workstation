# BMW workstation updater: one-time setup

The one-time setup bundle contains `UpdateAgent.ps1`, `ApplyUpdate.ps1`, and `Install.ps1`.

## Expected behavior
- Uses the public GitHub Releases API for the `wilesy7404/diagnostic-workstation` repository.
- Checks at startup and about every six hours while the agent is running.
- Preserves the installed OEM diagnostic software and local `apps.json`.
- Requests explicit approval (Yes/No) before downloading a workstation update.
- Verifies the package version and SHA-256, validates PowerShell script syntax and backs up existing runtime files before replacement.
- Uses a separate worker to restart the workstation, and attempts file rollback if startup health checks fail.

## Release prerequisites
This is **not** a production auto-update channel yet. The repository's main branch requires the source from the latest working BMW installation; the publish workflow blocks incomplete releases. New runtime behavior also requires testing on the Windows hardware. Until a validated release asset exists, clients must report `No verified release published yet` rather than `Up to date`.

The first release should be beta and rolled out to only one known-good machine. Stronger authenticity protections such as code signing should be required before wider deployment. Public GitHub download access does not require a token.
