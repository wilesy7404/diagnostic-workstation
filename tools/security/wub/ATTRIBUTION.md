# Windows Update Blocker (Sordum)

Unmodified freeware from Sordum (BlueLife / Velociraptor), https://www.sordum.org/9470/windows-update-blocker-v1-8/

The binaries and `Wub.ini` in this folder are the bytes from the owner-supplied archive. SHA-256 pins live in `tool-manifest.json`. The upstream GUI README is `UPSTREAM-README.md`. It does not document the command line. The installer uses the published Sordum switches:

- Disable and protect services: `Wub_x64.exe /D /P` (elevated). This is a full service stop, not a pause.
- Enable again: `Wub_x64.exe /E`
- 32-bit Windows uses `Wub.exe` with the same switches.

`Wub_x64.exe /?` was not run in this repository. Confirm the switches on a throwaway Windows VM before merge.

Windows Feature Updates can reset this tool and turn Windows Update back on. Re-apply `/D /P` with the Start Menu entry "Re-apply Windows Update block".

Sordum's own README says the tool is for educational use and that disabling updates leaves a system vulnerable. These files are not OEM diagnostic software. Confirm Sordum's redistribution terms before a public release.
