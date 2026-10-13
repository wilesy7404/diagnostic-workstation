# BMW v1.0.1-beta.5 — compact SYSTEM menu alignment

Release candidate prepared for the existing BMW public GitHub updater.

**User-confirmed visual change:** SYSTEM dropdown alignment at the user's display scaling, using:

```powershell
$popup.HorizontalOffset = [Math]::Round(([double]$Anchor.ActualWidth - 224.0) / 2.0) + 75
```

This fixes the menu being too far left and keeps the popup pointer with the button. Menu item is **Microsoft Edge**. Package also retains the improved icon loader introduced in the manual V2 sharp-icons patch.

**Release assets** (attach exact files for tag `v1.0.1-beta.5`, prerelease):
- `workstation.zip`
- `update-manifest.json`
- `workstation.zip.sha256`

`workstation.zip` SHA-256: `20e0f50cb73b72c5d3ebdcfe5302ac0b111916d01d6f9900bd5bc548e3c11cc3`

**Package layout:** `core/{Launcher,Dock,Watchdog,SystemPanel}.ps1` and `version.json`. Excludes apps.json, diagnostic OEM software, licenses and updater scripts so local paths/settings remain untouched.

**Validation:** manifest and SHA-256 verified, expected file layout verified, popup XAML parsed. Final +75 alignment was visually approved on the laptop as a manual patch. Windows runtime of the full packaged beta.5 was not rerun.

**Publication:** this repository note is not a GitHub Release. Publish as a GitHub prerelease with the exact three assets to make it available to the installed updater.
