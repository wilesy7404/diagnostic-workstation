# BMW v1.0.1-beta.4 release candidate

Prepared package: `workstation.zip`, `update-manifest.json`, `workstation.zip.sha256`.

**Changes**
- ADMIN editor supports optional `description` string and `showDescription` boolean for each app.
- BMW Home tiles display the customized description only if enabled and nonempty. Removes the hardcoded “BMW DIAGNOSTIC APPLICATION” subtitle.
- SYSTEM popup position is recalculated when opened and the fixed legacy version label removed.
- The deployment ZIP contains only `core/Launcher.ps1`, `core/Dock.ps1`, `core/Watchdog.ps1`, `core/SystemPanel.ps1`, and `version.json`. Local `apps.json` and updater scripts remain untouched.

SHA-256 (`workstation.zip`): `7e9ba028d09dabe49b68de72aa0c0daf1036c18ef107bac52bca3296df076186`

**Testing status:** archive structure and SHA-256 verified; Windows WPF runtime test still pending. Do not mark this release as fully tested until BMW Home, ADMIN saving, and SYSTEM popup are tested locally.

**Release action:** upload the three release assets under prerelease tag `v1.0.1-beta.4`. This note does not publish a GitHub Release.
