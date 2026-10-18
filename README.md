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

The master installer in `installer/Master/` installs a catalog-pinned `mercedes-v*` or `bmw-v*` bundle into that brand's own folder and can fall back to an offline payload. `universal-v*` packages are retired. `catalog/catalog.json` pins `bmw-v1.0.2-beta.1` and `mercedes-v0.1.3-beta.4`. Neither build is published: no tag and no GitHub release yet. Mercedes `0.1.3-beta.3` was voided and is not pinned. Placeholder signing keys are not production approval.

`scripts/build-mercedes-bundle.py` and `scripts/build-bmw-bundle.py` produce `dist/mercedes-v<version>/` and `dist/bmw-v<version>/` (`workstation.zip` and `update-manifest.json`). Mercedes `0.1.3-beta.4` and BMW `1.0.2-beta.1` are both pinned, and neither is published. The manual bundle workflows upload artifacts only. They do not publish a GitHub release. An existing machine `profile.json` is kept; a new install receives the bundle default. `apps.json` is not in either bundle.

`releases/versions.lock.json` is append-only. `sourceCommit` is the commit the tag points to, not proof of which commit built the zip. BMW `v1.0.1-beta.1`, `v1.0.1-beta.2`, and `v1.0.1-beta.3` all point at `186efe7531a6019dff2ebec56823de367d780a52` and have different zip bytes.

Windows Update disable is wired to the vendored Sordum Windows Update Blocker. Windows Defender disable is a silent elevated step in the same installer: `Set-MpPreference` runs as SYSTEM through a transient scheduled task, and policy DWORDs are written in that elevated process. `WinDefend`, `WdNisSvc`, and `MDCoreSvc` are left running. See [master installer](docs/MASTER-INSTALLER.md).

See [architecture](docs/ARCHITECTURE.md) and [release process](docs/RELEASES.md).
