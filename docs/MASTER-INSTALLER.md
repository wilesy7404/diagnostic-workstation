# Master installer

`installer/Master/Install-Master.ps1` installs one approved brand bundle, then disables Windows Update. It does not open a confirm screen. The brand is the `-Brand` argument (`mercedes` or `bmw`).

Run it elevated on a throwaway Windows VM. Do not run it on a live Mercedes or BMW shop PC. This repository does not execute the vendored tools.

## Online and offline install

Approved tags are `mercedes-v*` and `bmw-v*`. `universal-v*` and bare `v*` tags are retired. The old generic `v1.0.1-beta.5` BMW core package is not a master bundle.

`catalog/catalog.json` is the list of approved payloads. Each release entry pins the tag, `workstation.zip` size, and SHA-256. The installer builds only this download URL:

`https://github.com/wilesy7404/diagnostic-workstation/releases/download/<tag>/workstation.zip`

The same rule is used for `update-manifest.json`. The ZIP is checked for size and SHA-256, then every file path, size, and SHA-256 is checked before the brand folder is replaced. A bad hash, extra file, or `..` path stops the install. The live folder is not changed.

If the download fails, the installer looks in `-Source <folder>` and in `offline/<tag>/` for the same two files and checks the same pins. `-OfflineOnly` skips the network. An expired catalog still installs and records `Catalog dated ...; newer versions may exist`.

`catalog/catalog.json` pins `bmw-v1.0.2-beta.1` and `mercedes-v0.1.3-beta.4` (channel beta). Neither build is published: no tag and no GitHub release yet, and the repository has no `offline/<tag>/` copy. An install of either pin therefore stops with `No offline payload was found` until the release assets exist, and it does not create the brand folder. `mercedes-v0.1.3-beta.3` was voided and is not pinned. `mercedes-v0.1.3-beta.1` and `mercedes-v0.1.3-beta.2` stay unpinned. A brand with an empty release list stops with `No approved <brand> release is pinned`.

`keys/qa.pub` and `keys/release.pub` are placeholders. The catalog pin is a checksum of the catalog file, not an Ed25519 signature. A catalog that claims `release-signed` is rejected. Real key custody is a later step.

## Where files go

| Brand | Folder |
| --- | --- |
| Mercedes | `%LOCALAPPDATA%\DiagnosticWorkstation` |
| BMW | `%LOCALAPPDATA%\BMW-Stealth-Launcher` |

Other brand ids are refused. The installer copies `apps.json`, `controls-pin.json`, update status files, `logs\`, and `Backup-*` / `ControlBackup-*` folders into the new tree. A bundle that contains those machine-local files is rejected. User files that are not in the new bundle remain in the `*.prev-*` folder beside the install.

`profile.json` does ship in the bundle. A new install receives that default. If the brand folder already has `profile.json`, the installer keeps the machine copy and does not overwrite it.

The install marker `.installed-bundle.json` records Mercedes supervisor `WorkstationManager.exe` and BMW supervisor `Watchdog.ps1`. WorkstationManager migration for BMW is later. This installer does not start either program and does not write Winlogon, shell, or Run values.

The Mercedes `WorkstationManager.exe` in the pinned `0.1.3-beta.4` bundle uses `godebug default=go1.20`. With that setting, `netedns0` is omitted. `godebug default=go1.16` would include it. The build stays on `go1.20` because the program does not use DNS. When `brands.json` does not contain the embedded brand, the install prompt title is `Install ` with a blank name. That is a known cosmetic issue for the next exe rebuild. `manager/` and the current exe are unchanged.

`releases/versions.lock.json` is append-only. `sourceCommit` is the commit the tag points to, not build provenance. BMW `v1.0.1-beta.1`, `v1.0.1-beta.2`, and `v1.0.1-beta.3` all point at `186efe7531a6019dff2ebec56823de367d780a52` and have different zip bytes.

## Bundle builds

`scripts/build-mercedes-bundle.py` and `scripts/build-bmw-bundle.py` write `dist/<tag>/workstation.zip` and `update-manifest.json`. The manual workflows `mercedes-release-bundle.yml` and `bmw-release-bundle.yml` upload those files as Actions artifacts. They do not create a release, push a tag, or sign anything. `catalog/catalog.json` is not updated here.

Each bundle ships only that brand's logo. `apps.json` stays out of both bundles. Mercedes `profile.json` and `Launcher.ps1` come from the approved live source. BMW `Launcher.ps1` and `profile.json` come from `bundles/bmw/staging/`. Those hashes are computed at build time. The BMW updater in the bundle looks for `bmw-v*` tags.

## Security steps

After a verified install, the installer always runs the security step. There is no opt-in toggle. The whole run stays in one elevated process. If it is not already elevated, it relaunches itself once, hidden, and waits. The relaunch passes `-ElevatedRelaunch`. A second relaunch is refused, so a failed admin check cannot open another window.

## Why PowerShell windows were repeating

WorkstationManager starts a new `powershell.exe` for Launcher, Dock, and UpdateAgent whenever those processes exit. It waits only while `<brand root>\install-in-progress.lock` exists. The installer renames that folder and Windows Update Blocker then stops the update services, which makes the watched scripts exit. The previous build never wrote the lock, so the supervisor opened another PowerShell for each exit. Watchdog and the shell host do the same on a timer, and some of those start paths leave the console visible. On a shop account that is already an administrator, those windows are elevated. Aborting the run left Defender and Windows Update running because the failure path rolls the security changes back.

The installer checks that the folder belongs to this brand and is not an older version as soon as the release is selected, before it extracts a payload or creates a staging directory beside the target, and again before it writes `install-in-progress.lock` or stops that brand's supervisor. A wrong-brand or downgrade attempt leaves the target folder and its neighbors unchanged: nothing is staged beside it, no lock file is written there, and an `install-in-progress.lock` that another run already wrote stays byte for byte. Launcher, Dock, Watchdog, WorkstationShell, and UpdateAgent for that root are not stopped. After those checks pass, the installer writes `install-in-progress.lock` in the brand root before the rename and again on the new root before the security steps, and removes only a lock this run wrote. It stops Launcher, Dock, Watchdog, WorkstationShell, and UpdateAgent for that root before the rename, and again after the new root is in place. It leaves `WorkstationManager.exe` running so the manager can keep honoring the lock. It does not start the supervisor afterward and does not change Winlogon. An interrupted swap is repaired at the start of the next run. After the previous tree is restored, the partial `.failed-repair` folder is deleted.

`DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP=1` is a library-only hook. `Install-VerifiedTree` throws after the previous folder has been renamed aside and before the staged tree replaces it, and the catch restores the previous folder. `Install-Master.ps1` deletes that variable with `[Environment]::SetEnvironmentVariable(..., $null, 'Process')` immediately after the library early-return and before elevation. A production run, including the elevated relaunch, cannot arm the hook. The hosted VM report therefore marks that in-install catch as not proven. `scripts/Test-MasterInstaller.ps1` arms the hook in-process.

The only scheduled task is the transient Defender SYSTEM task below: it is created, run, and deleted in that same step, and it has no trigger. Start Menu undo shortcuts use `-WindowStyle Hidden`. Windows Update Blocker is still started hidden and awaited.

Windows Update uses the vendored Sordum Windows Update Blocker, hidden and elevated:

- 64-bit: `Wub_x64.exe /D /P`
- 32-bit: `Wub.exe /D /P`
- Undo: the same exe with `/E`

`/D /P` is a full service stop, not a pause. The hashes are in `tools/security/wub/tool-manifest.json`. See `tools/security/wub/ATTRIBUTION.md`. Windows Feature Updates can turn updates back on. The Start Menu entry **Re-apply Windows Update block** runs `/D /P` again and does not change Defender. **Re-enable Windows Update and Defender** runs `/E` and restores Defender.

The Start Menu uninstall entry re-enables Windows Update and Defender, then deletes those shortcuts. It leaves the brand files in place and does not change shell startup.

Every security action is logged under `%LOCALAPPDATA%\DiagnosticWorkstation-Installer\logs\install-journal.log`.

## Windows Defender

Defender disable runs after the brand install and the Windows Update step. There is no confirm screen and no extra window. The old Defender Control binary is not shipped and is not started. `tools/security/dcontrol/ReadMe.txt` is a vendor changelog kept for reference.

`installer/Master/lib/Defender.ps1` builds the command list. Success is the `Set-MpPreference` values below plus the policy DWORDs. `WinDefend`, `WdNisSvc`, and `MDCoreSvc` stay running. A Mercedes retest showed `Set-MpPreference` works as SYSTEM, and stopping those services is Access Denied for SYSTEM and for TrustedInstaller because the services are PPL-protected. The installer does not try to stop or reconfigure them, and it does not roll back when they keep running.

### SYSTEM task

`Set-MpPreference` is one SYSTEM batch. Policy writes stay in the elevated admin process, after that batch on disable and around the restored preferences on re-enable. A failed preference or policy write still rolls back through the same split. A service that keeps running is not a failure.

For each batch the installer:

1. Writes the batch to a `commands.json` file under the installer log directory.
2. Registers a scheduled task named `DiagnosticWorkstation-Defender-<guid>`. The principal is `SYSTEM`, the run level is highest, and there is no trigger. Settings allow the task to run on battery, hide it, and limit it to five minutes.
3. Starts the task. The action is Windows PowerShell with `-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File` on `Invoke-DefenderSystemJob.ps1`.
4. Waits up to three minutes for `result.json`.
5. Deletes the task in a `finally` block, including when the batch fails. A later Defender step also removes any leftover `DiagnosticWorkstation-Defender-*` task before it registers a new one. A leftover task has no trigger, so it does not run at boot or logon.

The journal step is `defender-system-task` (`taskName`, principal `SYSTEM`, `runLevel` `Highest`, `deleted`, `transient`). The SYSTEM job accepts only `Set-MpPreference`. The Tamper Protection prompt stays in the admin process, before any task is created. The task runs in session 0 and cannot show a window.

### PowerShell 5.1 paths

Windows PowerShell 5.1 `Join-Path` accepts only `-Path` and `-ChildPath`. `Copy-MasterCommands` used to call the three-argument form, which threw before the re-enable scripts were copied. Installer paths now use nested two-argument `Join-Path` calls. The copied `Master\lib` folder includes `Invoke-DefenderSystemJob.ps1`, which re-enable and uninstall load.

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

### Services left running

`WinDefend`, `WdNisSvc`, and `MDCoreSvc` are recorded in the pre/post log and are not stopped, disabled, or started. Boot drivers (`WdBoot`, `WdFilter`, `WdNisDrv`) and `SecurityHealthService` are not changed either. Re-enable does not restore a service, because disable never changed one.

The pre-change snapshot is `%LOCALAPPDATA%\DiagnosticWorkstation-Installer\defender-pre-state.json` (`diagnostic-workstation.defender-snapshot/v1`). It is written before any Defender change. The journal steps are `defender-pre` and `defender-post`. Each one includes the `Get-MpPreference` values, the `Get-MpComputerStatus` fields the module reads, Tamper Protection, the policy values, and the observed service state.

### Tamper Protection

Before any change, the module reads `HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection` and `Get-MpComputerStatus` (`IsTamperProtected`). It prompts only when Tamper Protection is on, or when a later Defender command fails with a Tamper Protection error and the user was not already prompted. The prompt asks the user to turn it off in Windows Security, then the module reads the state again. If it is still on, nothing is left changed: a disable that already wrote settings is rolled back from the snapshot, and the status is `tamper-blocked`. An unknown Tamper Protection state does not prompt.

Exit codes from `Install-Master.ps1` after the brand files are in place:

| Code | Meaning |
| --- | --- |
| 0 | Windows Update is disabled, and Defender preferences plus policy DWORDs are applied. Protected Defender services are still running. |
| 2 | Windows Update was not disabled |
| 10 | Tamper Protection stayed on, so Defender was not changed |
| 11 | A Defender preference or policy write failed |

`Enable-Security.ps1 -Action enable` and `Uninstall-MasterBrand.ps1` use exit 10 and 11 for the Defender undo. `-Action reapply` does not call the Defender module.

## Windows check before merge

Do not retest on a live shop PC. Mercedes retests already confirmed the supervisor lock, `Wub_x64.exe /D /P` then `/E`, the PowerShell 5.1 path copy, and `Set-MpPreference` as SYSTEM (real-time protection turns off). Stopping `WinDefend` and `MDCoreSvc` stays Access Denied for SYSTEM and TrustedInstaller, so that attempt is no longer part of the installer. This environment still does not execute the Windows Update Blocker binary.

The next retest, with Tamper Protection off, should confirm:

1. No extra PowerShell windows. `install-in-progress.lock` exists only during the run.
2. `Wub_x64.exe /D /P` then `/E` still round-trips.
3. Real-time protection and the other `Set-MpPreference` values change, and the policy DWORDs appear. The installer exits 0. `WinDefend`, `WdNisSvc`, and `MDCoreSvc` are still running, with the same start mode as before the run.
4. Re-enable restores the captured `Set-MpPreference` values and removes policy values that were not present before. It does not change those services. Task Scheduler has no leftover `DiagnosticWorkstation-Defender-*` task, and the journal shows `defender-system-task` with `deleted` true.
5. With Tamper Protection on, the installer prompts once and changes nothing while it stays on.
6. Winlogon, the shell, and Run startup are unchanged. The old Defender Control program does not start.
