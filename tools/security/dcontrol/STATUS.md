# Defender Control v2.1 (Sordum) — blocked

Unmodified freeware from Sordum, vendored at the owner's request. SHA-256 of `dControl.exe` is pinned in `tool-manifest.json` and matches `1ef6c1a4dfdc39b63bfe650ca81ab89510de6c0d3d7c608ac5be80033e559326`.

`ReadMe.txt` in this folder is the vendor changelog. Version 2.1 is dated 1 Mar 2022. Version 2.0 (13 Sep 2021) says command-line parameter support was removed because the tool was being used inside malware.

This installer therefore does not start `dControl.exe`, does not pass `/D`, `/E`, or `/G`, and does not open the program. Tamper Protection is only prompted when a future verified silent command is about to run. No `Set-MpPreference` or other Defender policy is implemented here.

A throwaway Windows VM can run `installer/Master/Probe-DefenderControlCli.ps1 -IUnderstandThisMayOpenAWindow`, which passes only `/?` and may still open a window. That probe does not mark the tool verified.

These files are not OEM diagnostic software. Confirm Sordum's redistribution terms before a public release.
