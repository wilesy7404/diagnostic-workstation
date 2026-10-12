# BMW Recovery Build: v1.0.0-beta.3

Status: **testing required; do not publish as an auto-installing GitHub Release yet.**

The reviewed candidate archive `BMW-Recovery-Ready-beta3.zip` was built from the latest uploaded BMW scripts, with replaced `ApplyUpdate.ps1` and `UpdateAgent.ps1` and a preserved SYSTEM popup fix.

Proposed safeguards:
- Validate all required core components and PowerShell parsing before stopping the current workstation.
- Create a backup with a manifest describing which prior files existed.
- Restart watchdog and check for the *actual WPF BMW Diagnostic System window*, twice, rather than merely a PowerShell process.
- On failure stop new processes, restore previous files, restore the version file and restart previous watchdog.
- Record update and rollback results in `update-recovery.log` and `update-status.json`.
- If previous launcher also fails, start recovery Explorer and show a recovery warning.
- Never replace `apps.json` or any OEM diagnostic tools.

## Required Windows test

Do not run the candidate installer inside the running custom shell. Before release, run a controlled test from a separate administrator/recovery desktop, verifying successful apply and deliberate failed-start rollback, the UI, and a recovery route. A Windows shell process may not reliably allow Explorer to become a complete fallback desktop merely by launching explorer.exe. Keep Task Manager available; test fallback independently.

After Windows validation, import the exact tested six scripts into `main`, ensure `.github/workflows/validate.yml` passes, correct the GitHub publish workflow package/manifest scheme, and publish a tagged pre-release with integrity metadata. At that point test Update Now / Later and end-to-end apply and rollback before any stable release.

Candidate archive SHA256: `49b349cfca3738c348453d6d649df27589dff504dc292b0c5cd10d8257924707`.

This is not an official release asset: the public GitHub repository does not yet host the ZIP itself.
