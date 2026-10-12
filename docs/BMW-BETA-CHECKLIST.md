# BMW v1.0.0-beta.1 source candidate

This branch is not a published or installable release.

- [ ] Import latest working BMW Launcher.ps1, Dock.ps1, Watchdog.ps1 and updater from test machine
- [ ] Wire SYSTEM button to shared SystemPanel.ps1
- [ ] Test Internet, Control Panel, Date/Time, Network, Task Manager; Settings fallback
- [ ] Test dock home visibility, fullscreen auto-hide and touch reveal
- [ ] Validate app configurations are preserved; do not ship OEM diagnostic software
- [ ] Validate watchdog start, crash recovery, rollback and silent boot
- [ ] Release with versioned assets and integrity checks only after testing

Use the WPF panel as follows (from the launcher): dot-source SystemPanel.ps1, then invoke Show-WorkstationSystemPanel -Owner $window.
