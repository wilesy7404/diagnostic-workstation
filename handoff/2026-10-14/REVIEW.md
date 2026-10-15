# Review — 2026-10-14 handoff (BMW live beta.5, Mercedes live 0.1.2-beta.1)

Static review of the exported installations. No brand file was modified. PowerShell was not executed on Windows; behavior below is from the scripts, the master installer source, and SHA-256 checks run against the archives.

For Mercedes, the machine hash list taken at 6:49 PM PT matches the live ZIP for every file that ZIP recorded. `live-source/` is the readable copy of the text files. `reference-packages/` are earlier baselines. The repository scaffold under `core/`, `brands/`, `installer/`, and `docs/` describes a shared-runtime plan. The installed BMW and Mercedes trees do not follow that plan, and this review treats them as separate products.

## Integrity

`SHA256SUMS.txt` matches all ten archives in this handoff (both live ZIPs and all eight reference ZIPs).

Every file listed in each live `BUILD-MANIFEST.json` matches the corresponding live ZIP by size and SHA-256:

| Archive | Manifest entries | Result |
| --- | --- | --- |
| `live-builds/BMW-LIVE-BUILD-20261014-201549.zip` | 15 | All 15 match. ZIP also contains `BUILD-MANIFEST.json` and `TRANSFER-README.txt`, which the manifest does not hash. |
| `live-builds/Mercedes-LIVE-BUILD-20261014-202042.zip` | 28 | All 28 match, including `WorkstationManager.exe` and nine `branding/*.png` files. ZIP also contains the manifest and `TRANSFER-README.txt`. |

`live-source/Mercedes/` matches the ZIP for every text file. Branding PNGs and `WorkstationManager.exe` are only in the ZIP, which matches the handoff README.

`live-source/BMW/` matches the ZIP except for a UTF-8 BOM (`EF BB BF`, 3 bytes) that is present in the ZIP and absent from the committed blobs. After removing that BOM the bytes are identical. Affected committed files:

- `BMWWorkstationControls.ps1`, `Dock.ps1`, `SystemPanel.ps1`
- `Restart-BMW-Controls.ps1`, `Restore-BMW-ExplorerShell.ps1`, `Rollback-BMW-Controls-v1.ps1`, `Save-Approved-BMW.ps1`
- `BUILD-MANIFEST.json`, `TRANSFER-README.txt`

`Launcher.ps1`, both `Launcher.before-*.ps1` backups, `Watchdog.ps1`, `ApplyUpdate.ps1`, `UpdateAgent.ps1`, `UpdateRunner.ps1`, and `version.json` match the ZIP with no BOM on either side. There is no `.gitattributes` file. A later checkout that rewrites line endings would move these hashes again. Approved bundles need to be stored so the hashed bytes survive Git.

No `controls-pin.json`, `apps.json`, Wi-Fi profile, update log, or PIN hash is in the handoff. The Mercedes machine still has those account files; they are compared below and their digests are not copied into this review. Reference READMEs do contain this machine’s account paths (`C:\Users\Pro\...`, `C:\Users\Mercedes\...`). Updater scripts name the GitHub repository `wilesy7404/diagnostic-workstation`.

---

## Mercedes machine vs the repo export

The owner is booted into the Mercedes partition, and Mercedes is the brand to perfect first. The attached hash list is the files in `%LOCALAPPDATA%\DiagnosticWorkstation` at **2026-10-14 6:49 PM PT**, with logs omitted. `version.json` on the machine is `0.1.2-beta.1`.

The repo side of the comparison is `live-source/Mercedes/BUILD-MANIFEST.json` (export `2026-10-15T03:20:43Z`) and the members of `live-builds/Mercedes-LIVE-BUILD-20261014-202042.zip`. Those two already match each other for every manifest path. `live-source/Mercedes/` matches the same hashes for every text file. `WorkstationManager.exe` and `branding\*.png` are in the ZIP and on the machine, and are absent from `live-source/`.

The ZIP name `20261014-202042` and the manifest time `2026-10-15T03:20:43Z` are seven hours apart, which is Pacific Daylight Time. On that clock the hash list is 6:49 PM, the v2 backup folder stamp `194002` is 7:40:02 PM, and the export is 8:20:43 PM.

### Files that match

All 28 manifest paths match the machine by SHA-256 and size. `live-source/` matches the same text files. The executable and the nine logos match the machine and the ZIP, and are only missing from the text checkout.

| Path | Bytes | Machine vs manifest / ZIP |
| --- | --- | --- |
| `ApplyUpdate.ps1` | 5961 | Match. Also in `live-source/`. |
| `Create-Shortcuts.ps1` | 549 | Match. Also in `live-source/`. |
| `Dock.ps1` | 18099 | Match. Also in `live-source/`. |
| `Launcher.ps1` | 26847 | Match. Also in `live-source/`. |
| `profile.json` | 189 | Match. Also in `live-source/`. |
| `Remove-Legacy-Mercedes.ps1` | 2969 | Match. Also in `live-source/`. |
| `Restart-Mercedes-Controls.ps1` | 1045 | Match. Also in `live-source/`. |
| `Restore-ExplorerShell.ps1` | 811 | Match. Also in `live-source/`. |
| `Save-Approved-Mercedes.ps1` | 5150 | Match. Also in `live-source/`. |
| `SystemPanel.ps1` | 8267 | Match. Also in `live-source/`. |
| `Uninstall.ps1` | 3913 | Match. Also in `live-source/`. |
| `UpdateAgent.ps1` | 10556 | Match. Also in `live-source/`. |
| `UpdateRunner.ps1` | 4715 | Match. Also in `live-source/`. |
| `Validate.ps1` | 761 | Match. Also in `live-source/`. |
| `version.json` | 27 | Match (`0.1.2-beta.1`). Also in `live-source/`. |
| `Watchdog.ps1` | 1260 | Match. Also in `live-source/`. |
| `WorkstationControls.ps1` | 22205 | Match. Also in `live-source/`. |
| `WorkstationShell.ps1` | 4759 | Match. Also in `live-source/`. |
| `WorkstationManager.exe` | 2478080 | Match. In the ZIP only. |
| `branding\bmw.png` | 12416 | Match. In the ZIP only. |
| `branding\ford.png` | 16847 | Match. In the ZIP only. |
| `branding\gm.png` | 9112 | Match. In the ZIP only. |
| `branding\honda.png` | 3899 | Match. In the ZIP only. |
| `branding\jlr.png` | 8374 | Match. In the ZIP only. |
| `branding\mercedes.png` | 233049 | Match. In the ZIP only. |
| `branding\porsche.png` | 37350 | Match. In the ZIP only. |
| `branding\toyota.png` | 3592 | Match. In the ZIP only. |
| `branding\vw-audi.png` | 3900 | Match. In the ZIP only. |

No shared path differs. `Dock.ps1` and `WorkstationControls.ps1` on the machine at 6:49 PM are the same bytes the export stored at 8:20 PM.

### Files on only one side

On the machine, omitted from `live-source/` and from the live ZIP:

| Path | Bytes | Note |
| --- | --- | --- |
| `apps.json` | 43 | Account tile list. Digest not recorded here. |
| `controls-pin.json` | 121 | Account PIN record. Digest not recorded here. |
| `update-settings.json` | 139 | SHA-256 `240ffbbdad95d8ffb838b3306b81a4746367bec48003c8f4174f83a1de857fb4`. This is the stock master v1.2 asset: channel `beta`, repo `wilesy7404/diagnostic-workstation`, tag prefix `universal-v`. |
| `update-status.json` | 120 | Local updater state. The master template is 102 bytes and a different hash, so this file has been written since install. Body not in the handoff. |

Also only on the machine, called out in the hash list as backups rather than the live tree:

- `Dock.ps1.backup-20261013-*` (5), `Launcher.ps1.backup-20261013-*` (3), `SystemPanel.ps1.backup-20261013-074421`, and three `mercedes.png` backups.
- `ControlBackup-20261014-173029`. Its `Dock.ps1` and `Launcher.ps1` are the same hashes as the live files above. The folder also has `Restore-ExplorerShell.ps1` and `SystemPanel.ps1`.
- `ControlBackup-v2-20261014-194002`. Its `Dock.ps1` starts `535794AD` and its `WorkstationControls.ps1` starts `FE9A1281`. Both differ from the live/export files.

In the repo export, and not installed as workstation files: `BUILD-MANIFEST.json` and `TRANSFER-README.txt`.

### Does the export predate newer Dock and controls files?

No. The v2 backup folder does not make the export an older copy of the installed `Dock.ps1` and `WorkstationControls.ps1`.

`Install-Mercedes-Controls-v2.ps1` in `reference-packages/Mercedes-Controls-PreShell-v2.zip` creates `ControlBackup-v2-<local timestamp>`, copies the current `Dock.ps1` and `WorkstationControls.ps1` into it, and only then overwrites the live files. The folder holds the pre-write copies. Those copies are a different pair from the files hashed at 6:49 PM and from the files zipped at 8:20 PM.

A v2 run that kept its new files would make the 8:20 PM ZIP differ from the 6:49 PM hashes. The ZIP matches those hashes, including size. A v2 run that failed would restore the backup it had just taken (`535794AD…` / `FE9A1281…`). The ZIP is not that pair either. `ControlBackup-20261014-173029` still has the same Dock and Launcher hashes as the export, so that earlier folder is the same generation, not a newer one.

The installed Dock and controls that were hashed, and the copies in the Mercedes live ZIP and `live-source/`, are one generation. The v2 folder is a side copy of a different generation. Perfecting Mercedes starts from the matching live files, and leaves `ControlBackup-v2-20261014-194002` untouched unless the owner asks for that pair.

---

## BMW — live source `1.0.1-beta.5`

Installed directory on the machine: `%LOCALAPPDATA%\BMW-Stealth-Launcher` (account `Pro`). Export time in the manifest: `2026-10-15T01:15:50Z`. This tree has no `profile.json`, no `WorkstationManager.exe`, and no branding folder. The home window title is the literal `BMW Diagnostic System`. The dock title is `BMW Glass Dock`.

The version string `1.0.1-beta.5` matches the published reference package, and so do `Launcher.ps1`, `Watchdog.ps1`, and `version.json`. `Dock.ps1` and `SystemPanel.ps1` in the live ZIP are the later controls patch. They are different files from `BMW-v1.0.1-beta.5-source.zip` / the nested `workstation.zip` inside `BMW-v1.0.1-beta.5-release.zip`. The installed version label is therefore older than the installed dock and system menu.

### File inventory

| File | Role |
| --- | --- |
| `Launcher.ps1` | Fullscreen borderless WPF home. Loads `apps.json`, draws tiles, ADMIN editor, wallpaper from `HKCU\Control Panel\Desktop`, hides the Explorer taskbar while maximized, clock, footer update status, SYSTEM and ADMIN buttons. On load, starts `UpdateAgent.ps1` hidden. Dot-sources `SystemPanel.ps1`. |
| `Dock.ps1` | Separate topmost transparent dock: Home, up to eight running-app buttons, battery text, SYSTEM menu. 220 ms slide/fade when another window covers the monitor. Bottom-center touch strip (`BMW Dock Touch Reveal`, 30 px tall). |
| `SystemPanel.ps1` | SYSTEM popup attached to the home button. Same actions as the dock menu. Launches controls by the absolute path `%LOCALAPPDATA%\BMW-Stealth-Launcher\BMWWorkstationControls.ps1`. |
| `BMWWorkstationControls.ps1` | Out-of-process WPF helper. Modes: `Wifi`, `Battery`, `Settings`, `Desktop`, `Return`, `Recovery`. Header says it does not change the custom shell. |
| `Watchdog.ps1` | Infinite loop, 4 s poll. Restarts `Launcher.ps1` and `Dock.ps1` when no `powershell.exe` command line contains that file name. 8 s backoff per script. No log. |
| `UpdateAgent.ps1` | Mutex `Local\BMW-Workstation-UpdateAgent-v2`. Sleeps 10 s, then every 6 hours reads `update-settings.json`, queries `https://api.github.com/repos/<repo>/releases`, and accepts tags `v<semver>` with assets `workstation.zip` and `update-manifest.json`. Channel `beta` includes prereleases. Prompts Update now / Later (12 h deferral). |
| `UpdateRunner.ps1` | Downloads only from `https://github.com/wilesy7404/diagnostic-workstation/releases/download/`. Checks tag shape, manifest version, and SHA-256, parses the four core scripts, then runs `ApplyUpdate.ps1`. |
| `ApplyUpdate.ps1` | Replaces only `Launcher.ps1`, `Dock.ps1`, `Watchdog.ps1`, `SystemPanel.ps1`, and `version.json` from `package\core` plus package `version.json`. Stops those PowerShell processes (including Watchdog), copies files, starts Watchdog, waits 35 s for a responding window titled `BMW Diagnostic System`, otherwise restores the backup. |
| `Restore-BMW-ExplorerShell.ps1` | HKCU only. Removes `Shell` under Policies\System and Winlogon when the value matches `BMW-Stealth-Launcher\(Watchdog\|Launcher\|BMWWorkstationShell).ps1`. Starts `explorer.exe`. Leaves any other custom shell in place. |
| `Restart-BMW-Controls.ps1` | Stops and restarts Launcher and Dock only. Leaves Watchdog running. Hard-coded to `%LOCALAPPDATA%\BMW-Stealth-Launcher`. |
| `Rollback-BMW-Controls-v1.ps1` | Copies `Dock.ps1` and `SystemPanel.ps1` back from the newest `BMW-ControlBackup-v1-*` directory after a parse check. Does not remove the controls helper or the PIN file. |
| `Save-Approved-BMW.ps1` | Requires `-ConfirmApproved`. Writes `Documents\DiagnosticWorkstation-ApprovedBuilds\BMW-Approved-<timestamp>.zip` plus `approved-brand-manifest.json`. |
| `version.json` | `{"version":"1.0.1-beta.5"}`. |
| `Launcher.before-shortcut-refresh-20261012-152554.ps1`, `Launcher.before-updater-20261012-153610.ps1` | On-disk backups. Watchdog will not start them (different file names). They are history inside the live folder. |
| `BUILD-MANIFEST.json`, `TRANSFER-README.txt` | Export metadata. |

Not in this export, and required at runtime if those features are in use: `apps.json`, `controls-pin.json`, `update-settings.json`, `update-status.json`, control-backup directories, the desktop shortcut `Return to BMW Workstation.lnk`.

`Save-Approved-BMW.ps1` omits `version.json` and `Rollback-BMW-Controls-v1.ps1`. Running it as written would freeze an incomplete tree.

### Startup, shell, watchdog, update, recovery

Startup that can be proved from files:

1. Something outside this export must start `Watchdog.ps1` (a per-user shell value or a login task). No script in the live tree writes the shell registry.
2. Watchdog starts Launcher and Dock with `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File`.
3. Launcher hides `Shell_TrayWnd` and `Shell_SecondaryTrayWnd` (`ShowWindow` 0) once maximized, and shows them again on close (`ShowWindow` 5). A killed launcher leaves the taskbar hidden until the next launcher start or Explorer recovery.
4. Launcher’s Loaded handler starts UpdateAgent. The footer reads `update-status.json` every 12 s. Missing settings surface as `Update check unavailable` / `Update source not connected`, which matches the “status unknown” rule better than a false “up to date”.
5. Dock positions itself on the WPF work area and polls processes every 2 s.

Shell: `Restore-BMW-ExplorerShell.ps1` knows how to undo a shell that points at `Watchdog.ps1`, `Launcher.ps1`, or `BMWWorkstationShell.ps1`. The third file is not in the export. Presence of a recovery script is not evidence the registry is set. The controls header and the controls-package README both say the controls installer does not change the shell.

Update: the agent is wired and will not install a package whose URL is outside that GitHub releases prefix. The package layout it applies is `core\*.ps1` plus `version.json`. That layout is the published beta.5 release, which would replace the live controls-patched `Dock.ps1` and `SystemPanel.ps1` with the older pair if a newer tag were published from the reference package. `BMWWorkstationControls.ps1` is outside the replace list, so the helper would remain on disk while the menus that call it disappeared. The controls README already warns about this.

`ApplyUpdate.ps1` stops the Watchdog process. If Watchdog is the Winlogon shell, stopping it can end the session. `docs/BMW-RECOVERY-BETA3.md` already says not to run the installer inside the custom shell.

Recovery paths that exist:

- SYSTEM / dock “Emergency Recovery” asks, then runs `Restore-BMW-ExplorerShell.ps1`. No PIN.
- Task Manager → Run can launch that same script (path is documented in the controls README).
- Failed update rolls file copies back and tries to show Home again.
- `Rollback-BMW-Controls-v1.ps1` reverts only the two patched UI scripts.

Desktop switch (`-Mode Desktop`) starts Explorer, waits up to 8 s for `Shell_TrayWnd`, then minimizes home, dock, and the touch strip (`ShowWindow` 6) and shows the taskbar (`ShowWindow` 5). Return (`-Mode Return`) starts Launcher/Dock if needed, restores/maximizes them, and hides the taskbar again. Nothing in the live scripts creates the Return shortcut. `Install-BMW-Controls-v1.ps1` inside `reference-packages/BMW-Stealth-Controls-v1.zip` creates `Return to BMW Workstation.lnk` on the desktop, targeting `-Mode Return`.

### Feature goals

| Goal | Status | Evidence |
| --- | --- | --- |
| Modern professional UI, BMW look kept | Partial | Home, tiles, glass dock, and SYSTEM popup are a deliberate dark BMW layout (`Launcher.ps1`, `Dock.ps1`, `SystemPanel.ps1`). ADMIN, the battery dialog, the Wi-Fi window, and the update prompt are plain WPF. Empty-state copy exists and is forced to `Collapsed` on every render (`Launcher.ps1` `Render-Cards`), so a machine with no tiles shows a blank center. |
| Wi-Fi management | Partial | `Show-WifiPanel` lists SSIDs from English `netsh wlan show networks mode=bssid`, connects a saved profile, or writes a temporary WPA2-PSK/AES profile (`protected=false`) and deletes the temp XML. WPA3, enterprise, open, and hidden networks are sent to Windows Settings. Temp file prefix is `mb-wifi-` (copied from the Mercedes helper). |
| Battery as percentage only | Partial | Dock button text is `87%` or `--` when Windows reports no battery (`Dock.ps1` battery timer). The Battery Status window adds “remaining”, AC vs on-battery, and a button to `ms-settings:powersleep`. |
| Windows Settings | Working | SYSTEM “Windows Settings” runs `ms-settings:`. Wi-Fi panel has a Wi-Fi settings button. Control Panel, `timedate.cpl`, `ncpa.cpl`, and Task Manager are separate menu entries. |
| Touch PIN to reach the desktop | Partial | `Ask-ControlPin` is a borderless keypad (6–12 digits, touch and keyboard, 5 attempts). `Test-ControlPin` checks PBKDF2 (`Rfc2898DeriveBytes`) with `version = 1` and at least 100,000 iterations, then compares hashes without early exit. The live tree has no enrollment UI. `Install-BMW-Controls-v1.ps1` creates `controls-pin.json` at 150,000 iterations when the file is absent. If the file is missing, Desktop mode shows “not configured” and stays on the workstation. |
| Return to Workstation | Partial | `-Mode Return` is implemented in `Set-WindowMode $false`. The live scripts never pass that mode. The shortcut is created only by the controls installer. |
| Explorer recovery | Working as a script | Menu path plus `Restore-BMW-ExplorerShell.ps1` (HKCU only, no PIN). Whether it is reachable when the shell is already broken depends on Task Manager still being available. It will not clear a shell command that fails the path regex. |
| Smooth startup | Partial | Watchdog restarts crashed UI with an 8 s gap. Dock hide/show is animated. There is no splash or ordered handoff. Taskbar hide and a hidden PowerShell host can flash Explorer. Fullscreen detection uses a 3 px inset against the foreground window rect. |

### Bugs and risks

- **Version collision.** Live dock/system panel hashes differ from the published `1.0.1-beta.5` asset (`Dock.ps1` 16180 vs 13855 bytes, `SystemPanel.ps1` 8025 vs 7000). Shipping another build under this same version would not describe the machine that is actually running.
- **Next BMW update replaces the controls UI.** `ApplyUpdate.ps1` overwrites `Dock.ps1` and `SystemPanel.ps1` and does not ship `BMWWorkstationControls.ps1`.
- **Empty home.** `Render-Cards` always sets `EmptyState` to `Collapsed`, including when every tile is disabled or `apps.json` is missing.
- **Watchdog fail-stop.** `Is-Running` returns `$true` when `Get-CimInstance` throws, so a WMI failure stops restarts. It matches on file name only (`Launcher.ps1`), so another PowerShell command line that merely contains that name counts as healthy. Start failures are swallowed (`catch {}`).
- **Shell stop during update.** Stopping Watchdog is unsafe if that process is the user shell.
- **PS 5.1 encoding.** The installed ZIP copies of `BMWWorkstationControls.ps1` and `SystemPanel.ps1` have a BOM and contain `–`, `•`, `●`, and `—`. PowerShell 5.1 treats a BOM as UTF-8. The committed copies dropped the BOM. Re-deploying the Git blobs on a non-UTF-8 ANSI code page would leave the script runnable and would show those characters wrong (the PIN dots and the “6–12” hint). `::new()` and the other syntax used here are valid in Windows PowerShell 5.1.
- **DPI.** Tile size is fixed at 326×132. The SYSTEM popup offset is `ActualWidth` math plus a constant `+75` (“user-tested” at one scale). The battery button is 40×40 around an 11 px `100%` label. The touch strip is placed from the primary monitor. `powershell.exe` is not per-monitor v2 aware. `AllowsTransparency` docks are the usual fractional-DPI risk.
- **Wi-Fi plaintext window.** The passphrase is in a temp XML until `netsh` returns, then the file is deleted. A crash in that window can leave it under `%TEMP%`. Windows still stores the WLAN profile afterward.
- **PIN is a UI gate.** Emergency recovery, Task Manager, and file edit of `controls-pin.json` bypass it. The scripts say this on purpose.
- **Hard-coded install root** in `SystemPanel.ps1`, `Dock.ps1`, and `Restart-BMW-Controls.ps1`. A copy of the scripts outside `BMW-Stealth-Launcher` still launches the installed helper.
- **Mixed newlines.** `Dock.ps1` and `SystemPanel.ps1` contain a few CRLF lines inside an otherwise LF file (the controls insertions). PowerShell accepts that. Hashing must use the original bytes.
- **Secrets.** No PIN, WLAN key, or diagnostic app path is in the BMW export. The controls README in the reference ZIP embeds `C:\Users\Pro\AppData\Local\BMW-Stealth-Launcher\...`.

---

## Mercedes — live source `0.1.2-beta.1`

Installed directory: `%LOCALAPPDATA%\DiagnosticWorkstation` (account `Mercedes`). Export time: `2026-10-15T03:20:43Z`. The 6:49 PM PT machine hash list matches this export for every manifest file; see [Mercedes machine vs the repo export](#mercedes-machine-vs-the-repo-export). This is the universal manager layout with a Mercedes profile, plus a controls patch and a shell host that the master package does not embed.

`WorkstationManager.exe` in the live ZIP is byte-identical to `Diagnostic-Workstation-Master-Setup-v1.2.exe` (SHA-256 `4981dc756c970e3a9bc4890f79a57cd0a525d525eb0da7ccfe050d3263a9c63f`, 2,478,080 bytes). `UpdateAgent.ps1`, `UpdateRunner.ps1`, `ApplyUpdate.ps1`, `Watchdog.ps1`, `Uninstall.ps1`, `Validate.ps1`, `Remove-Legacy-Mercedes.ps1`, and `version.json` match `Diagnostic-Workstation-Master-Source-v1.2.zip` `assets\`. `Launcher.ps1` differs by the header logo treatment (live: transparent, `UniformToFill`; master: bordered, `Uniform`). `Dock.ps1` and `SystemPanel.ps1` differ by the controls patch (master dock has no battery, Wi-Fi, PIN, or recovery entries). `branding\mercedes.png` is 233,049 bytes live vs 15,451 bytes in the master source. The other eight brand PNGs match the master source.

`profile.json` is the Mercedes universal profile: `id=mercedes`, display name Mercedes-Benz, short MB, `updateFamily=universal`, accent `#BBC7D0` / `#E6ECEF`, logo `branding/mercedes.png`.

### File inventory

| File | Role |
| --- | --- |
| `Launcher.ps1` | Same home structure as BMW, driven by `profile.json` (title `Mercedes-Benz Diagnostic System`, header logo, accent tokens). Requires the logo file or it throws before the window opens. Does **not** start UpdateAgent. Comment still says `UniversalSupervisor.exe`; the binary on disk is `WorkstationManager.exe`. |
| `Dock.ps1` | `Workstation Glass Dock`. Brand logo from `profile.json`, DPI-adjusted position on the primary monitor, battery percent, same autohide/touch strip as BMW (`Workstation Dock Touch Reveal`). Controls path is `%LOCALAPPDATA%\DiagnosticWorkstation\WorkstationControls.ps1`. |
| `SystemPanel.ps1` | Home SYSTEM popup. Brand short name is patched into the XAML from `profile.json`. Message-box caption on failure is the leftover string `WORKSTATION Workstation`. |
| `WorkstationControls.ps1` | Same modes as the BMW helper, Mercedes PIN window (logo image, “MERCEDES-BENZ”), home title from the profile. Does not change the shell. |
| `WorkstationShell.ps1` | Optional shell host. Parses Launcher and Dock, checks the logo, starts `WorkstationManager.exe` if it is not running, starts Launcher and Dock if their command lines are absent, and requires both windows to be visible. `-SelfTest` checks visibility and exits. On failure it appends `logs\ShellHost.log` and runs `Restore-ExplorerShell.ps1`. |
| `WorkstationManager.exe` | Master setup binary. `/supervise` holds mutex `Local\UniversalDiagnosticWorkstationSupervisorV1` and restarts `Launcher.ps1`, `Dock.ps1`, and `UpdateAgent.ps1`. It skips Launcher/Dock restarts while `install-in-progress.lock` exists. Also the GUI installer (see reference section). |
| `Watchdog.ps1` | Same 4 s loop as BMW, but the running check uses the full script path. The manager does not launch this file. It runs only if something else starts it (shell, manual, or an older updater). |
| `UpdateAgent.ps1` | Mutex `Local\UniversalDiagnosticWorkstation-UpdateAgent-v1`. Accepts tags `universal-v<semver>` only. Same GitHub repo and asset names as BMW. Ranks `0.1.2-beta.1` against that prefix. |
| `UpdateRunner.ps1` | Same allow-listed download, SHA-256, and `core\` layout as BMW, with the Mercedes home title taken from `profile.json`. |
| `ApplyUpdate.ps1` | Replaces the same five files as BMW. Writes `install-in-progress.lock`, stops Launcher/Dock/Watchdog/SystemPanel PowerShell processes, does **not** start Watchdog afterward, deletes the lock, and waits 50 s for Home. The error text still says 35 s. Rollback can start Launcher directly. The lock is honored by `WorkstationManager.exe`, not by `Watchdog.ps1` or `WorkstationShell.ps1`. |
| `Restore-ExplorerShell.ps1` | Removes HKCU `Shell` when it points at `DiagnosticWorkstation\(WorkstationShell\|Watchdog\|Launcher).ps1`. Starts Explorer. |
| `Restart-Mercedes-Controls.ps1` | Restarts Launcher and Dock from the script’s own directory. Leaves the manager running. |
| `Create-Shortcuts.ps1` | Desktop and Start Menu shortcuts to `WorkstationManager.exe /supervise`. |
| `Uninstall.ps1` | Confirms, backs up `apps.json`, `profile.json`, and `update-settings.json`, sets HKCU shell to `explorer.exe` if it mentions `DiagnosticWorkstation` or `Mercedes-Diagnostic-Workstation`, removes the Run value `UniversalDiagnosticWorkstation` and the uninstall key, stops this install’s manager/launcher/dock/update agent, removes shortcuts, then deletes the install directory. |
| `Remove-Legacy-Mercedes.ps1` | Cleans `%LOCALAPPDATA%\Mercedes-Diagnostic-Workstation` (the older v2 tree), with backups. Does not remove OEM tools. |
| `Validate.ps1` | Parse-checks the eight runtime scripts and requires `profile.json` `id` and `displayName`. |
| `Save-Approved-Mercedes.ps1` | Requires `-ConfirmApproved` and a Mercedes `displayName`. Writes `Mercedes-Approved-<timestamp>.zip` under Documents. |
| `version.json` | `{"version":"0.1.2-beta.1"}`. |
| `profile.json` | Mercedes presentation profile above. |
| `branding\*.png` | Nine manufacturer marks. Live `mercedes.png` is the larger mark; the other eight match the master source. |

`Save-Approved-Mercedes.ps1` includes the helper, one logo, the manager exe, and the updater. It omits `WorkstationShell.ps1`, `Validate.ps1`, `Create-Shortcuts.ps1`, `Remove-Legacy-Mercedes.ps1`, and the other branding files. An “approved” ZIP from the current script is not the full live directory.

Not exported, machine-local if present: `apps.json`, `controls-pin.json`, `update-settings.json`, `update-status.json`, `logs\`, `install-in-progress.lock`, `Return to Mercedes Workstation.lnk`.

### Startup, shell, watchdog, update, recovery

Two supervisors are in the tree, and they do not do the same job.

**Manager path (what master v1.2 actually registers).** `Create-Shortcuts.ps1` and the installer’s HKCU Run value `UniversalDiagnosticWorkstation` start `WorkstationManager.exe /supervise`. The manager starts Launcher, Dock, and UpdateAgent, logs under `logs\`, and waits out `install-in-progress.lock` during an update. Launcher then hides the taskbar and does not start a second update agent. This path leaves Explorer as the Windows shell. That matches the master README: first-run installs keep Explorer.

**Shell-host path (live file, not in the master embed).** `WorkstationShell.ps1` can be the Winlogon shell. It starts the manager and also starts Launcher and Dock itself. Initial failure to show both windows within 90 s, or a later 90 s stretch where either window is not visible, throws and runs `Restore-ExplorerShell.ps1`. Desktop mode minimizes those windows (`ShowWindow` 6 in `WorkstationControls.ps1`). If this script is the shell, a successful PIN desktop session looks “unhealthy” and can restore Explorer about 90 s later. Nothing in the live scripts or in `main.go` writes this file into `HKCU\...\Winlogon\Shell`. The file’s presence does not mean the registry points at it.

**Watchdog.ps1** restarts Launcher and Dock only, ignores the update lock, and is not started by the manager. A second copy running beside the manager can relaunch UI during `ApplyUpdate.ps1`.

Update channel is `universal-v*`, shared with every brand the master installer would lay down. A published universal package built from today’s master `assets\` would copy the pre-controls `Dock.ps1` and `SystemPanel.ps1` over the live menus and would not update `WorkstationControls.ps1`, `WorkstationShell.ps1`, or `mercedes.png`. `profile.json` and `apps.json` are outside that replace list.

`update-settings.json` is not in the export. The master asset that the installer writes (and overwrites on every install) is channel `beta`, repo `wilesy7404/diagnostic-workstation`, `tagPrefix` `universal-v`. The agent’s tag filter is hard-coded; it does not read `tagPrefix`.

Recovery:

- SYSTEM / dock Emergency Recovery → confirm → `Restore-ExplorerShell.ps1` (no PIN).
- `Uninstall.ps1` forces HKCU shell back to `explorer.exe` when the value mentions this install or the legacy directory.
- `Remove-Legacy-Mercedes.ps1` does the same for the old `Mercedes-Diagnostic-Workstation` path.
- Update failure restores the five backed-up files. With the manager running, clearing the lock lets it start Home again. The fallback starts Launcher only.

Return to the workstation is `-Mode Return`, same window logic as BMW, with titles `Mercedes-Benz Diagnostic System`, `Workstation Glass Dock`, and `Workstation Dock Touch Reveal`. The desktop shortcut is created by `Install-Mercedes-Controls.ps1` in the pre-shell v1 reference package, not by the live scripts.

### Feature goals

| Goal | Status | Evidence |
| --- | --- | --- |
| Modern professional UI, Mercedes look kept | Partial | Profile-driven home, larger Mercedes mark, transparent header, glass dock. Accent comes from `profile.json`. Battery dialog and update window are unstyled. Empty state is forced collapsed (`Launcher.ps1` `Render-Cards`). Failure caption still says `WORKSTATION Workstation`. |
| Wi-Fi management | Partial | Same `netsh` WPA2-Personal panel as BMW, including the `mb-wifi-` temp profile and the English SSID parser. Settings fallback is present. |
| Battery as percentage only | Partial | Dock text is `N%` or `--` (`Dock.ps1`). The Battery Status window still shows charge source and a settings button. Controls v2 README describes the dock text as the percentage-only change; that part is in the live dock. |
| Windows Settings | Working | `ms-settings:` from the SYSTEM menu and from the controls helper, plus the Wi-Fi settings URI. |
| Touch PIN to the desktop | Partial | Keypad UI and PBKDF2 check match BMW, with a Mercedes header and logo. Enrollment is only in `Install-Mercedes-Controls.ps1` (150,000 iterations) when `controls-pin.json` is absent. Live `WorkstationControls.ps1` and `SystemPanel.ps1` contain `–`, `•`, `●`, and `—` and have **no BOM in the live ZIP**. On PowerShell 5.1 with a traditional ANSI code page those glyphs display wrong; the keypad still functions. |
| Return to Workstation | Partial | `-Mode Return` works if invoked. No live script creates the shortcut. Pre-shell v1 installer creates `Return to Mercedes Workstation.lnk`. |
| Explorer recovery | Working as a script | `Restore-ExplorerShell.ps1` is on the menu and is what `WorkstationShell.ps1` calls after a failed health check. HKCU only. It does not require the PIN. Activating `WorkstationShell.ps1` as the shell is a separate, unproven step. |
| Smooth startup | Partial | Manager starts Launcher, Dock, and UpdateAgent together and logs them. Dock animates. There is no splash. `WorkstationShell.ps1` adds a 90 s visibility gate that fights desktop mode. Taskbar hide still depends on the launcher reaching the maximized state. |

### Bugs and risks

- **Reinstall or universal update rolls the live UI back.** Master `install()` writes its embedded `Launcher.ps1`, `Dock.ps1`, and `SystemPanel.ps1` over the directory, replaces `mercedes.png` with the smaller master asset, and never installs `WorkstationControls.ps1` or `WorkstationShell.ps1`. It keeps existing `apps.json`. It rewrites `profile.json` and `update-settings.json`. `ApplyUpdate.ps1` has the same effect on Dock and SystemPanel for any future `universal-v*` release built from those assets.
- **Version collision.** `0.1.2-beta.1` already means “master v1.2 generic runtime” and “this Mercedes machine” at the same time. The hashes are not the same set.
- **Shell health vs desktop mode.** If `WorkstationShell.ps1` is later set as the shell, PIN-to-desktop minimizes the windows the health check requires, and the catch block restores Explorer.
- **Three starters.** Manager, `Watchdog.ps1`, and `WorkstationShell.ps1` can all launch Launcher and Dock. Only the manager understands `install-in-progress.lock`.
- **Empty home** and the stale `WORKSTATION Workstation` caption, as above.
- **PS 5.1.** Same language level as BMW. Mercedes controls files are UTF-8 without a BOM on the machine, not only in Git. `Start-Process -ArgumentList` arrays with manual quotes are safe for `Pro` and `Mercedes` (no spaces) and brittle for other account names.
- **DPI.** Same fixed sizes and `+75` popup offset as BMW. Dock and touch-strip placement convert primary-monitor physical pixels with `TransformFromDevice`. The home tiles do not.
- **Wi-Fi temp XML and PIN scope.** Same as BMW. Recovery is intentionally available without the PIN.
- **Logo licensing.** Master setup README says several marks are design-stage stand-ins and asks for a licensing check before distribution. The live Mercedes mark differs from the one embedded in v1.2. This review does not treat either PNG as cleared for a public release.
- **Personal data.** No PIN hash, WLAN key, or `apps.json` in the Mercedes export. Legacy cleanup and the controls README name `C:\Users\Mercedes\...`. `Remove-Legacy-Mercedes.ps1` can copy old `apps.json` and logs into a backup on the machine; those backups are not in this handoff.

---

## How reference packages differ from live

| Package | What it is relative to the live ZIP |
| --- | --- |
| `BMW-v1.0.1-beta.5-source.zip` and the `workstation.zip` inside `BMW-v1.0.1-beta.5-release.zip` | Identical `Launcher.ps1`, `Watchdog.ps1`, `version.json`. Older `Dock.ps1` and `SystemPanel.ps1` (no battery, Wi-Fi, PIN, or recovery entries). Release notes describe SYSTEM-menu alignment and say that GUI run of that exact package was not yet tested. Manifest SHA-256 is of that older `workstation.zip`. |
| `BMW-Stealth-Controls-v1.zip` | `BMWWorkstationControls.ps1`, restore, restart, rollback, and save scripts are byte-identical to the live ZIP (including BOM). Adds `Install-BMW-Controls-v1.ps1`, which is the PIN enrollment and Return-shortcut step, and which refuses to run if the BMW scripts do not match the layout it expects. |
| `Mercedes-Controls-PreShell-v1.zip` | Installer, PIN enrollment, backup of Dock/SystemPanel, Return shortcut. `Restart-Mercedes-Controls.ps1` and `Restore-ExplorerShell.ps1` match live. `WorkstationControls.ps1` is the older helper (15,021 bytes vs live 22,205). |
| `Mercedes-Controls-PreShell-v2.zip` | PIN keypad fragment, rollback, and `Save-Approved-Mercedes.ps1` (identical to live). Does not contain the full live helper. |
| `Mercedes-Workstation-Source-v2.zip` | Previous product. Install root `Mercedes-Diagnostic-Workstation`, version `1.0.0-beta.2`, tags `mercedes-v*`, `MercedesSupervisor.exe` (not the live manager). Live `Watchdog.ps1` happens to match. Launcher, Dock, SystemPanel, and the updater scripts do not. README states this installer does not set HKLM or HKCU Winlogon shell. |
| `Diagnostic-Workstation-Master-Source-v1.2.zip` | Go installer (`main.go`) plus embedded assets. Updater, uninstall, watchdog, validate, legacy cleanup, and `version.json` match Mercedes live. Dock, SystemPanel, Launcher chrome, and `mercedes.png` do not. `brands.json` holds empty-path tiles for all nine brands (ISTA+, XENTRY, PIWIS, ODIS, and so on). `install()` writes one shared script set, generates `profile.json` from the selected brand, preserves an existing `apps.json`, copies every brand PNG, registers HKCU Run and uninstall, and logs `shell=Explorer`. It aborts if `BMW-Stealth-Launcher\Launcher.ps1` exists in the **same** Windows account. It does not read an approved-brand ZIP or check a per-file manifest of a brand bundle. |
| `Diagnostic-Workstation-Master-Setup-v1.2.zip` | The compiled EXE, identical to live `WorkstationManager.exe`, plus a README that still calls Windows runtime install untested and says Explorer stays the shell for first tests. |

`core/`, `brands/*/profile.json`, and `installer/Install-Update.ps1` in the repository root are the scaffold. `Install-Update.ps1` only knows `BMW-Stealth-Launcher` and the four core names. `brands/bmw/profile.json` uses a different schema (`accentColor`, `profileVersion`) from the Mercedes live `profile.json`. None of that scaffold is what the two machines are running.

---

## Proposed layout and manifest

Keep brand bundles immutable and brand-specific. The master installer selects a bundle, checks hashes, and copies it. It should stop generating a generic launcher per brand.

```
bundles/
  bmw/
    1.0.2-beta.1/                  # new version; do not reuse 1.0.1-beta.5
      bundle-manifest.json
      files/                       # paths relative to the install root
        Launcher.ps1
        Dock.ps1
        ...
  mercedes/
    0.1.3-beta.1/                  # new version; do not reuse 0.1.2-beta.1
      bundle-manifest.json
      files/
        ...
        branding/mercedes.png
        WorkstationManager.exe
catalog.json                       # brand, version, channel, bundle path, bundle sha256
installer/
  Master/                          # future tool; reads catalog.json only
```

Leave `handoff/2026-10-14/` as the frozen evidence drop. Do not point the running updaters at `bundles/` until an approved version exists. Store bundle files with Git attributes that disable text conversion (`-text`), or store the ZIP and hash the ZIP members. The BMW BOM loss is the reason.

`bundle-manifest.json` (schema `diagnostic-workstation.approved-bundle/v1`):

- `brand`, `version` (SemVer, prerelease allowed), `channel` (`beta` until the owner promotes it)
- `install.root` under `%LOCALAPPDATA%` (`BMW-Stealth-Launcher` or `DiagnosticWorkstation`; later brands get their own root written here, not inferred)
- `supervisor.entry` (`Watchdog.ps1` for BMW, `WorkstationManager.exe` with `/supervise` for Mercedes)
- `shell`: `explorer` until the owner approves a shell value. A shell bundle would name the script, the exact HKCU value, and the recovery script.
- `files[]`: `path`, `sha256`, `bytes`. Hash the file the ZIP will install, BOM included.
- `preserve[]`: `apps.json`, `controls-pin.json`, `logs\`, update deferral/progress files, control-backup directories
- `seedIfMissing[]`: a template `update-settings.json` whose `repo` and `tagPrefix` match that brand’s own tags (`bmw-v*`, `mercedes-v*`, later `porsche-v*`). Do not overwrite an existing settings file.
- `firstRun`: create the PIN file only when it is absent (150,000 PBKDF2 iterations, same record the verifiers already accept) and create the Return shortcut. Never copy a PIN from another machine.
- `health`: window title to wait for (`BMW Diagnostic System`, `Mercedes-Benz Diagnostic System`)
- `recovery`: script name that may run without the PIN

`catalog.json` is what the master installer loads. Each entry points at one bundle and the SHA-256 of `bundle-manifest.json` plus a hash of the archive. The installer:

1. Offers only brands that have an approved bundle.
2. Verifies the archive hash, then every file hash, before writing.
3. Refuses to install a BMW bundle into `DiagnosticWorkstation` or a Mercedes bundle into `BMW-Stealth-Launcher`.
4. Backs up the current runtime files, writes only manifest paths, leaves `preserve[]` alone.
5. Does not write Winlogon or boot configuration.
6. Starts that bundle’s supervisor and checks the health title.
7. Restores the backup if the health check fails.

Update packages for a brand should be that same bundle layout, tag prefix included, so a Mercedes agent cannot accept a BMW asset. Retire `universal-v*` for UI updates. A universal tag that replaces `Dock.ps1` is how the live controls get erased.

Do not publish under the current version strings.

- BMW live: mint a version above `1.0.1-beta.5` (for example `1.0.2-beta.1`) after the owner accepts the file list, including `version.json`, the controls helper, and rollback. Leave the `Launcher.before-*.ps1` backups out of the bundle.
- Mercedes live: mint a version above `0.1.2-beta.1` after the owner accepts the file list, including `WorkstationShell.ps1` only as an inactive file until shell mode is approved, the live `mercedes.png`, and the manager exe.

`Save-Approved-*.ps1` can stay as the capture tool once their allowlists match the manifest. Today they drop files the bundle needs.

Later brands (Porsche, VW/Audi, JLR, Toyota, Honda, Ford, GM) get a bundle only after that brand’s own UI is approved. `brands.json` tile names are placeholders with empty paths. They are not approved builds. Logo files need an explicit licensing decision before they ship in a bundle.

---

## Prioritized next steps

1. **Perfect Mercedes first, from the matching live tree.** The Mercedes partition is the one booted now. `Dock.ps1` and `WorkstationControls.ps1` hashed at 6:49 PM PT are the files in the live ZIP. Leave `ControlBackup-v2-20261014-194002` as a side copy; those two backup hashes are a different pair. Freeze `SHA256SUMS.txt` and both `BUILD-MANIFEST.json` files as the byte list. Repair the BMW Git blobs only when the owner wants that text checkout to hash-match its ZIP (BOM). That is a byte change to working files, so it waits.
2. **Stop the generic overwrite path before any publish.** Do not run Master Setup v1.2 against the Mercedes account, and do not publish a `universal-v*` or a new `v*` package built from `reference-packages` or from `assets\`. Either one replaces the live dock and system menu. Do not copy the v2 backup over the live Dock or controls unless the owner asks.
3. **Owner picks the approved file list** for each brand (tables above, plus the gaps in `Save-Approved-*.ps1`). Capture with the existing save scripts only after those lists are corrected, on the Windows machine, with `-ConfirmApproved`.
4. **Assign new versions** and write `bundle-manifest.json` from that capture. Verify by re-hashing. Keep `1.0.1-beta.5` and `0.1.2-beta.1` as historical labels only.
5. **Change the master installer** so it consumes `catalog.json` and refuses embedded generic scripts. Keep per-brand install roots. Preserve `apps.json` and the PIN file. Seed update settings once.
6. **Split update tags** (`bmw-v*`, `mercedes-v*`) and point each agent at its own prefix. Include the controls helper and the patched dock/panel in the BMW package. Include the Mercedes helper, shell script (inactive), logo, and manager in the Mercedes package.
7. **On the hardware, after a bundle exists:** empty-tile home, Wi-Fi (saved, WPA2, and a WPA3 network that should fall back to Settings), dock percent vs no battery, PIN wrong/right, Return shortcut, Emergency Recovery from the menu and from Task Manager, update apply and a forced failed-start rollback. Repeat at the panel’s real DPI.
8. **Then** decide shell mode per brand. Mercedes needs the `WorkstationShell.ps1` health check changed so desktop mode is not a failure, before that script is eligible to be the shell.
9. **Small UI defects to schedule with the owner, in the brand tree only:** empty-state visibility, Mercedes error caption, BMW `mb-wifi-` temp prefix, UTF-8 BOM on every script that contains non-ASCII, battery-button width at 125% and 150% scale. Each of these edits a file that is running today.
10. **Later brands** start as new bundles copied from an approved Mercedes or BMW layout only after that brand’s screens are signed off. Do not point them at the universal asset pipeline.

## Needs the owner’s approval

- **Shell registry.** No live script currently sets it. Turning on `WorkstationShell.ps1` or BMW `Watchdog.ps1` as `HKCU\...\Winlogon\Shell` (or the Policies\System shell value) is a behavior change, and the Mercedes health check can undo desktop mode.
- **Boot configuration.** rEFInd / multiboot is mentioned in `GROK-INTRO.md` and is not present in this handoff. Nothing here should change firmware or boot entries.
- **Update channels and the GitHub repo.** Live agents call `wilesy7404/diagnostic-workstation` with `v*` (BMW) and `universal-v*` (Mercedes). Moving to per-brand tags, disabling the universal package, or changing the repo is an updater change.
- **Replacing working files.** Re-running Master Setup, publishing the current beta.5 or 0.1.2-beta.1 assets, applying `Rollback-*-Controls`, restoring `ControlBackup-v2-20261014-194002` over the live Mercedes Dock or controls, or editing Dock/Launcher/SystemPanel in place all replace files the Mercedes machine is using. Empty-state, caption, encoding, and DPI fixes belong in a new approved version after a Windows test, with the existing rollback scripts kept.
- **Logo distribution** for the nine `branding\*.png` files, especially the live Mercedes mark versus the smaller master asset.
- **Whether `WorkstationManager.exe` stays the Mercedes supervisor** while BMW keeps Watchdog. The master EXE is also a full installer; copying it into a BMW directory is not a BMW install.
