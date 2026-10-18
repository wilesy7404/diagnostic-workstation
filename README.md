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

`scripts/build-mercedes-bundle.py` and `scripts/build-bmw-bundle.py` produce `dist/mercedes-v<version>/` and `dist/bmw-v<version>/` (`workstation.zip` and `update-manifest.json`). The next Mercedes build is `0.1.3-beta.3`. The next BMW build is `1.0.2-beta.1`. The manual bundle workflows upload artifacts only. They do not publish a GitHub release. An existing machine `profile.json` is kept; a new install receives the bundle default. `apps.json` is not in either bundle.

Windows Update disable is wired to the vendored Sordum Windows Update Blocker. Windows Defender disable is a silent elevated step in the same installer: `Set-MpPreference` runs as SYSTEM through a transient scheduled task, and policy DWORDs are written in that elevated process. `WinDefend`, `WdNisSvc`, and `MDCoreSvc` are left running. See [master installer](docs/MASTER-INSTALLER.md).

See [architecture](docs/ARCHITECTURE.md) and [release process](docs/RELEASES.md).
