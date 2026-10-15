# Grok — diagnostic workstation project briefing

You are taking over the development of a Windows-based automotive diagnostic workstation suite, previously developed interactively with ChatGPT. The goal is a polished **factory/OEM-style diagnostic experience**, with brand-specific fullscreen launchers, custom floating docks, Windows system controls, a controlled way to open the normal desktop, and a reliable recovery option.

## Project architecture

- **Platform:** Windows 10/11, PowerShell 5.1, WPF/XAML and Windows APIs; a compiled `WorkstationManager.exe` supervises the universal workstation variant.
- **Brand isolation:** A machine can use different Windows installations/partitions/accounts for brands. Never assume the BMW and Mercedes file trees or startup strategies are interchangeable.
- **BMW live directory:** `C:\Users\Pro\AppData\Local\BMW-Stealth-Launcher`. The BMW installation uses `Launcher.ps1`, `Dock.ps1`, `SystemPanel.ps1`, `BMWWorkstationControls.ps1`, `Watchdog.ps1`, `UpdateAgent.ps1`, `UpdateRunner.ps1`, plus update/restart/recovery tools. Its installed `version.json` reads `1.0.1-beta.5`. Its visual design is BMW-specific; retain the existing look and app assignments.
- **Mercedes live directory:** `C:\Users\Mercedes\AppData\Local\DiagnosticWorkstation`. This universal-derived installation uses `Launcher.ps1`, `Dock.ps1`, `SystemPanel.ps1`, `WorkstationControls.ps1`, `WorkstationManager.exe`, watchdog/updater, brand assets, `profile.json`, and `WorkstationShell.ps1`. Its installed `version.json` reads `0.1.2-beta.1`. Mercedes has custom Mercedes-Benz styling, a fullscreen Home, and glass dock.
- **Custom shell target:** Each brand should be able to launch its Home and dock instead of a visible Explorer desktop/taskbar, with recovery and account isolation. A stored `WorkstationShell.ps1` does not on its own prove that the Windows shell registry setting is active.
- **System controls/UX:** Show battery **percentage only** (e.g., `87%`), Wi-Fi discovery/connection, Windows Settings, and a touch-friendly numerical PIN UI for switching into the normal Windows desktop. Provide a clear **Return to Workstation** action and a fail-safe Explorer recovery. The PIN is a UI convenience, not Windows logon security.
- **Diagnostic apps:** Brand-specific buttons/shortcuts open OEM diagnostic tools such as BMW ISTA, Mercedes XENTRY/DTS Monaco/Vediamo/WIS and corresponding tools for other brands. Preserve OEM app paths as machine-local configuration; do not bundle proprietary diagnostic software or license files into source distributions.
- **Brand scope:** BMW, Mercedes, Porsche, VW/Audi, JLR, Toyota, Honda, Ford and GM. Work toward a modern, minimal, professional visual language, with OEM-inspired branding and responsive DPI-aware layout.
- **Boot selection:** A separate rEFInd-based graphical multiboot concept favors a black background with clean white brand logos; that is distinct from the Windows workstation apps.

## How to use the handoff

1. Read `handoff/2026-10-14/README.md` and the two `live-source` folders. These are **current exported installed scripts**, not guessed reconstructions.
2. Download the BMW and Mercedes `live-builds` archives when you need exact snapshots, including allowed binary assets. Compare file SHA-256 values with the manifests.
3. Refer to `reference-packages` for the BMW beta.5 distribution, control packages and universal master v1.2. They are reference baselines, not necessarily equal to the newer live installations.
4. Treat each approved manufacturer build as a versioned, immutable input for the future **master installation tool**. The master should consume tested brand bundles, validate hashes, select the brand, preserve machine-specific settings and set up appropriate startup/recovery.
5. Ask for approval before changing shell registry values, OS boot configuration, update channels or deleting/replacing a brand's working files. Prefer guarded migrations, backups, tests and rollback.

## Desired development workflow

- Perfect each brand's working UI, controls, launcher, dock and startup separately.
- Capture that exact working installation as its own versioned approved export (not a speculative rebuild), stripped of personal information and secrets.
- Connect the master installer to those approved versions and publish manifest-driven updates.
- Maintain dedicated brand installers, archives, changelogs, checksums and recovery procedures; make both branded and universal installation paths easy to work on.

## What is included and what is not

These exported ZIPs were generated from the Windows installations and intentionally omit private PIN values/hashes, Wi-Fi credentials, app assignments, logs, and user-specific configuration where possible. The Mercedes live ZIP includes the workstation manager executable and branding images. The BMW ZIP includes the exported scripts and earlier launcher backups; its source export is not a full machine clone.

Keep this handoff forward-looking: treat the repository as the starting development baseline; there is no need to reproduce earlier troubleshooting conversations.
