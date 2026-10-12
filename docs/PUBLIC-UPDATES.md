# Public GitHub Updates

This repository is public. Release assets can therefore be downloaded without any GitHub credential.

## Release system

A manually triggered GitHub Actions workflow packages the common core, every brand profile, and a versioned installer; computes SHA-256; and attaches the package, checksum and JSON metadata to a GitHub Release.

**Important:** this workflow is gated. It refuses to publish until real validated core scripts and a tested transactional installer have been imported. That prevents an empty or damaged release from being distributed.

## Device update process (planned)

1. A locally installed updater checks the GitHub Releases API for the selected channel.
2. If newer, show version info and an explicit Update Now / Later prompt.
3. On approval, download the versioned asset over HTTPS.
4. Verify its SHA-256 against the manifest. SHA-256 detects transfer corruption; for defense against compromised release metadata, use code signing or a separately trusted signature.
5. Back up the existing shared core, update that core atomically, and roll back if the new launcher does not start.
6. Preserve local `apps.json`, diagnostic tool paths, profile selection and all OEM installations.
7. The main UI shows its installed version and the most recently verified update status. When offline, it shows 'Unable to check'.

## What is NOT done yet

- Current BMW source is not imported/verified on the main branch.
- The on-device auto-updater and transactional installer are not deployed or tested.
- There is not yet a published verified release.

Until these steps are finished, GitHub releases are not connected to installed machines. A public repo alone does not turn on automatic updates.
