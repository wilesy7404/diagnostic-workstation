# BMW release candidate 1.0.1-beta.1

Release package **prepared and hash-checked**, not published yet.

- Version: 1.0.1-beta.1 (intentionally newer than installed 1.0.0 so the existing updater sees it)
- Release asset: workstation.zip
- Required companion asset: update-manifest.json
- Optional verification: workstation.zip.sha256
- SHA-256: ba9ee12f23a9043196788d4fc7778971f86bc360dcee0a2e26cb20dc687d0eea
- Package contains exactly core/{Launcher,Dock,Watchdog,SystemPanel}.ps1 plus version.json
- Local apps.json, ISTA, OEM databases and credentials excluded

**Publication gate:** The on-device ApplyUpdate.ps1 worker's complete real apply/rollback path is not yet tested. GitHub Releases publish is not available from the connected GitHub integration. Publishing through GitHub's Releases UI requires attaching the three exact assets and marking as pre-release, and should be done only after acknowledging beta risk. Do not interpret this document as a published release.
