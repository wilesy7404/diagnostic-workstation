# Installer

`Install-Update.ps1` is the older BMW core-file helper. It is not the master installer.

`Master/Install-Master.ps1` installs one pinned `mercedes-v*` or `bmw-v*` bundle into that brand's own folder, then disables Windows Update with the vendored Sordum Windows Update Blocker and disables Windows Defender. Policy values are written in the elevated process. `Set-MpPreference` and the WinDefend service family run as SYSTEM in a scheduled task that is created and deleted in the same step. Paths use the two-argument `Join-Path` form so Windows PowerShell 5.1 can copy the re-enable scripts. The installer holds `install-in-progress.lock` so WorkstationManager does not open another PowerShell during the run, and it relaunches for elevation at most once. The old Defender Control binary is not shipped. See [docs/MASTER-INSTALLER.md](../docs/MASTER-INSTALLER.md).

Nothing in this tree publishes a release or changes a live machine by itself.
