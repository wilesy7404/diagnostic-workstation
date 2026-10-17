# Master installer

`installer/Master/Install-Master.ps1` installs one approved brand bundle, then disables Windows Update. It does not open a confirm screen. The brand is the `-Brand` argument (`mercedes` or `bmw`).

Run it elevated on a throwaway Windows VM. Do not run it on a live Mercedes or BMW shop PC. This repository does not execute the vendored tools.

## Online and offline install

Approved tags are `mercedes-v*` and `bmw-v*`. `universal-v*` and bare `v*` tags are retired. The old generic `v1.0.1-beta.5` BMW core package is not a master bundle.

`catalog/catalog.json` is the list of approved payloads. Each release entry pins the tag, `workstation.zip` size, and SHA-256. The installer builds only this download URL:

`https://github.com/wilesy7404/diagnostic-workstation/releases/download/<tag>/workstation.zip`

The same rule is used for `update-manifest.json`. The ZIP is checked for size and SHA-256, then every file path, size, and SHA-256 is checked before the brand folder is replaced. A bad hash, extra file, or `..` path stops the install. The live folder is not changed.

If the download fails, the installer looks in `-Source <folder>` and in `offline/<tag>/` for the same two files and checks the same pins. `-OfflineOnly` skips the network. An expired catalog still installs and records `Catalog dated ...; newer versions may exist`.

No `mercedes-v*` or `bmw-v*` ZIP is pinned yet. Until a release is added to the catalog, the installer stops with `No approved <brand> release is pinned` and writes nothing.

`keys/qa.pub` and `keys/release.pub` are placeholders. The catalog pin is a checksum of the catalog file, not an Ed25519 signature. A catalog that claims `release-signed` is rejected. Real key custody is a later step.

## Where files go

| Brand | Folder |
| --- | --- |
| Mercedes | `%LOCALAPPDATA%\DiagnosticWorkstation` |
| BMW | `%LOCALAPPDATA%\BMW-Stealth-Launcher` |

Other brand ids are refused. The installer copies `apps.json`, `controls-pin.json`, update status files, `logs\`, and `Backup-*` / `ControlBackup-*` folders into the new tree. A bundle that contains those machine-local files is rejected. User files that are not in the new bundle remain in the `*.prev-*` folder beside the install.

`WorkstationManager.exe` is the supervisor for every brand. BMW still uses `Watchdog.ps1` until a later migration. This installer does not start either program and does not write Winlogon, shell, or Run values.

## Security steps

After a verified install, the installer always runs the security step. There is no opt-in toggle.

Windows Update uses the vendored Sordum Windows Update Blocker, hidden and elevated:

- 64-bit: `Wub_x64.exe /D /P`
- 32-bit: `Wub.exe /D /P`
- Undo: the same exe with `/E`

`/D /P` is a full service stop, not a pause. The hashes are in `tools/security/wub/tool-manifest.json`. See `tools/security/wub/ATTRIBUTION.md`. Windows Feature Updates can turn updates back on. The Start Menu entry **Re-apply Windows Update block** runs `/D /P` again and does not change Defender. **Re-enable Windows Update and Defender** runs `/E` and restores Defender.

The Start Menu uninstall entry re-enables Windows Update and Defender, then deletes those shortcuts. It leaves the brand files in place and does not change shell startup.

Every security action is logged under `%LOCALAPPDATA%\DiagnosticWorkstation-Installer\logs\install-journal.log`.

## Windows Defender

Defender disable runs in the same elevated installer process, after the brand install and the Windows Update step. There is no confirm screen and no extra window. The old Defender Control binary is not shipped and is not started. `tools/security/dcontrol/ReadMe.txt` is a vendor changelog kept for reference.

`installer/Master/lib/Defender.ps1` is the implementation.

### Set-MpPreference

Disable writes the first value. Undo writes the captured pre-change value. When the snapshot has no value, undo writes the default in the second column.

| Setting | Disable | Undo default |
| --- | --- | --- |
| DisableRealtimeMonitoring | `$true` | `$false` |
| DisableBehaviorMonitoring | `$true` | `$false` |
| DisableIOAVProtection | `$true` | `$false` |
| DisableScriptScanning | `$true` | `$false` |
| DisableBlockAtFirstSeen | `$true` | `$false` |
| DisableIntrusionPreventionSystem | `$true` | `$false` |
| DisableEmailScanning | `$true` | `$false` |
| DisableRemovableDriveScanning | `$true` | `$false` |
| DisableScanningMappedNetworkDrivesForFullScan | `$true` | `$false` |
| DisableArchiveScanning | `$true` | `$false` |
| PUAProtection | `0` | `1` |
| MAPSReporting | `0` | `2` |
| SubmitSamplesConsent | `2` | `1` |

On-access protection is the policy value below. `Set-MpPreference` has no `DisableOnAccessProtection` parameter.

### Policy values

Disable creates each DWORD and sets it to `1`. Undo deletes the value when the pre-change snapshot did not have it, and otherwise restores the captured DWORD. With no snapshot, undo deletes all of these values.

`HKLM\SOFTWARE\Policies\Microsoft\Windows Defender`

- `DisableAntiSpyware`
- `DisableAntiVirus`

`HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection`

- `DisableRealtimeMonitoring`
- `DisableBehaviorMonitoring`
- `DisableOnAccessProtection`
- `DisableScanOnRealtimeEnable`
- `DisableIOAVProtection`
- `DisableScriptScanning`

### Services

`WinDefend`, `WdNisSvc`, and `MDCoreSvc` only. Boot drivers (`WdBoot`, `WdFilter`, `WdNisDrv`) and `SecurityHealthService` are not changed. A service that is not installed is skipped.

Disable sets `StartupType` to `Disabled` and stops the service, dependents first (`MDCoreSvc`, then `WdNisSvc`, then `WinDefend`). Undo restores the captured start mode (`Auto` is stored as `Automatic`) and the captured Running or Stopped state, parent first. With no snapshot, a service that exists is set back to Automatic and Running.

The pre-change snapshot is `%LOCALAPPDATA%\DiagnosticWorkstation-Installer\defender-pre-state.json` (`diagnostic-workstation.defender-snapshot/v1`). It is written before any Defender change. The journal steps are `defender-pre` and `defender-post`. Each one includes the `Get-MpPreference` values, the `Get-MpComputerStatus` fields the module reads, Tamper Protection, the policy values, and the service state.

### Tamper Protection

Before any change, the module reads `HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection` and `Get-MpComputerStatus` (`IsTamperProtected`). It prompts only when Tamper Protection is on, or when a later Defender command fails with a Tamper Protection error and the user was not already prompted. The prompt asks the user to turn it off in Windows Security, then the module reads the state again. If it is still on, nothing is left changed: a disable that already wrote settings is rolled back from the snapshot, and the status is `tamper-blocked`. An unknown Tamper Protection state does not prompt.

Exit codes from `Install-Master.ps1` after the brand files are in place:

| Code | Meaning |
| --- | --- |
| 0 | Windows Update and Defender are both disabled |
| 2 | Windows Update was not disabled |
| 10 | Tamper Protection stayed on, so Defender was not changed |
| 11 | Defender disable failed |

`Enable-Security.ps1 -Action enable` and `Uninstall-MasterBrand.ps1` use exit 10 and 11 for the Defender undo. `-Action reapply` does not call the Defender module.

## Windows VM check before merge

1. Run `pwsh -NoProfile -File scripts/Test-MasterInstaller.ps1`. It must not be elevated into a shop profile.
2. On a throwaway VM, run `Wub_x64.exe /?` elevated and confirm `/D`, `/E`, and `/P` before trusting a live disable. This environment has not executed that binary.
3. On a throwaway VM, run the installer and confirm Defender realtime protection, the policy values, and `WinDefend` actually change, then run **Re-enable Windows Update and Defender** and confirm every setting, policy value, and service returns to the captured state.
4. On a throwaway VM with Tamper Protection on, confirm the installer prompts once, changes nothing while it stays on, and continues only after it is turned off.
5. Confirm the install did not change Winlogon or the shell, and did not start the old Defender Control program.
