# Defender Control v2.1 — reference only, not shipped

The installer does not run Sordum Defender Control. `ReadMe.txt` in this folder is the vendor changelog kept so the v2.0 note (13 Sep 2021, command-line parameters removed) stays with the repo. `dControl.exe` and `dControl.ini` are not in the tree and are not started.

Windows Defender is changed by `installer/Master/lib/Defender.ps1` through documented `Set-MpPreference` settings and Defender policy values. `WinDefend`, `WdNisSvc`, and `MDCoreSvc` are left running. See [master installer](../../../docs/MASTER-INSTALLER.md).

These notes are not OEM diagnostic software. The old binary was freeware from Sordum. Confirm redistribution terms before putting that binary in a public release.
