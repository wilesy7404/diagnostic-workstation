# Live diagnostic workstations — BMW and Mercedes

This handoff contains **actual exported files from the installed Windows partitions** (14 October 2026), a source view for easy browsing, and baseline release/installer archives for future build work.

## Start here

Read [GROK-INTRO.md](GROK-INTRO.md), then inspect `live-source/BMW/` and `live-source/Mercedes/`.

### Live exports

| Machine | Installed directory | Reported version | Live ZIP |
| --- | --- | --- | --- |
| BMW | `%LOCALAPPDATA%\BMW-Stealth-Launcher` (Windows account `Pro`) | `1.0.1-beta.5` | `live-builds/BMW-LIVE-BUILD-20261014-201549.zip` |
| Mercedes | `%LOCALAPPDATA%\DiagnosticWorkstation` (Windows account `Mercedes`) | `0.1.2-beta.1` | `live-builds/Mercedes-LIVE-BUILD-20261014-202042.zip` (also available in the ChatGPT source conversation) |

The `live-source/` folders contain the exported PowerShell, JSON and README source files for direct review. `BUILD-MANIFEST.json` files have per-file SHA-256 hashes. Both ZIPs are snapshots, **not installer packages**. BMW's live export does not include every brand graphic or application binary; Mercedes includes the manager executable and branding in its ZIP.

### Baseline packages

The `reference-packages/` folder holds earlier BMW/Mercedes source distributions, controls updates and universal master installer v1.2. **Prefer the live source for current installed behavior** over older reference packages. The current master installer does not yet automatically consume approved brand builds.

### Build policy

1. Develop and verify each brand in its own Windows installation.
2. Save its vetted files as an immutable, versioned *approved brand build* with manifest and checksums (exclude all secrets, PIN settings, Wi-Fi information, app/license paths, logs and personal machine data).
3. Have the master installer select and verify the approved brand archive rather than regenerate from unrelated templates.
4. Support recovery and preserve independent per-brand shell behavior.

See `SHA256SUMS.txt` to check transfer integrity.
