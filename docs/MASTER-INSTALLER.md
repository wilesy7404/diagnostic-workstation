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

`/D /P` is a full service stop, not a pause. The hashes are in `tools/security/wub/tool-manifest.json`. See `tools/security/wub/ATTRIBUTION.md`. Windows Feature Updates can turn updates back on. The Start Menu entry **Re-apply Windows Update block** runs `/D /P` again. **Re-enable Windows Update and Defender** runs `/E`.

The Start Menu uninstall entry re-enables Windows Update and deletes those shortcuts. It leaves the brand files in place and does not change shell startup.

Every security action is logged with the tool hash, arguments, exit code, and service state before and after, under `%LOCALAPPDATA%\DiagnosticWorkstation-Installer\logs\install-journal.log`.

## Defender is blocked

Defender Control v2.1 is vendored under `tools/security/dcontrol/` and its SHA-256 is pinned. The bundled `ReadMe.txt` says v2.0 (13 Sep 2021) removed command-line parameters. The installer does not start `dControl.exe`, does not pass `/D` `/E` `/G`, and does not open the GUI. It does not call `Set-MpPreference` or any other Defender API.

Tamper Protection is read from `HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection` and `Get-MpComputerStatus`. The prompt to turn it off in Windows Security is used only when a future verified silent Defender command is about to run. While this slot is blocked, the installer records the block and continues. Exit code 10 means the brand install finished, Windows Update was disabled, and Defender was not changed.

## Windows VM check before merge

1. Run `pwsh -NoProfile -File scripts/Test-MasterInstaller.ps1`. It must not be elevated into a shop profile.
2. On a throwaway VM, run `Wub_x64.exe /?` elevated and confirm `/D`, `/E`, and `/P` before trusting a live disable.
3. Optional and manual: `installer/Master/Probe-DefenderControlCli.ps1 -IUnderstandThisMayOpenAWindow`. It passes only `/?` and may open a window. It does not mark Defender verified.
4. Confirm the install did not change Winlogon or the shell.
