# Installer

`Install-Update.ps1` is the older BMW core-file helper. It is not the master installer.

`Master/Install-Master.ps1` installs one pinned `mercedes-v*` or `bmw-v*` bundle into that brand's own folder, then disables Windows Update with the vendored Sordum Windows Update Blocker and disables Windows Defender with `Set-MpPreference`, Defender policy values, and the WinDefend service family. The old Defender Control binary is not shipped. See [docs/MASTER-INSTALLER.md](../docs/MASTER-INSTALLER.md).

Nothing in this tree publishes a release or changes a live machine by itself.
