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

**Repository scaffold only.** No verified production release or updater endpoint is published yet. Do not point installed clients at this repository as a working unattended update source until distribution, authentication, signing, rollback and restart handling are tested.

See [architecture](docs/ARCHITECTURE.md) and [release process](docs/RELEASES.md).
