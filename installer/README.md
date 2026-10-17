# Installer

`Install-Update.ps1` is the older BMW core-file helper. It is not the master installer.

`Master/Install-Master.ps1` installs one pinned `mercedes-v*` or `bmw-v*` bundle into that brand's own folder, then disables Windows Update with the vendored Sordum Windows Update Blocker. Defender Control is vendored and hash-pinned, and its disable step is blocked until a silent command line is verified. See [docs/MASTER-INSTALLER.md](../docs/MASTER-INSTALLER.md).

Nothing in this tree publishes a release or changes a live machine by itself.
