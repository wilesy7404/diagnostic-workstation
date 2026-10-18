# Diagnostic Workstation

Private multi-manufacturer Windows diagnostic workstation.

## Architecture

- **core/**: shared launcher, dock, watchdog, system controls, and update client.
- **brands/**: manufacturer presentation and default application definitions.
- **installer/**: deployment and migration logic.
- **releases/**: release specifications and checksums.
- **docs/**: architecture and rollout policies.

Supported profiles planned: BMW, Mercedes-Benz, Porsche, VW/Audi, Toyota, Ford, Honda, GM/Chevrolet, and Jaguar Land Rover.

### Configuration ownership

Core updates may replace versioned **core files only**. They must not overwrite `apps.json`, executable paths, user-added cards, license files, installed OEM tools, saved connection information, or brand-specific config.

Each installation selects one profile, for example `brand.id= "bmw"`. The profile is data, not a separate application fork. Shared software updates are common to all profiles; brand assets and layouts can version independently.

### Current status

The master installer in `installer/Master/` installs a catalog-pinned `mercedes-v*` or `bmw-v*` bundle into that brand's own folder and can fall back to an offline payload. `universal-v*` packages are retired. No approved brand ZIP is pinned in `catalog/catalog.json` yet, and placeholder signing keys are not production approval.

Windows Update disable is wired to the vendored Sordum Windows Update Blocker. Windows Defender disable is a silent elevated step in the same installer. Policy values are written in that process. `Set-MpPreference` and the WinDefend service family run as SYSTEM through a transient scheduled task. See [master installer](docs/MASTER-INSTALLER.md).

See [architecture](docs/ARCHITECTURE.md) and [release process](docs/RELEASES.md).
