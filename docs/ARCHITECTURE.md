# Architecture

## Core + profiles

One shared WPF / Windows PowerShell-based workstation runtime. Individual Windows installations select a brand profile. Manufacturer-specific UI, startup artwork, color tokens, default diagnostic tile definitions, and home-screen copy belong to that profile.

Profiles must not contain copies of core launcher logic. Core APIs provide tile launch, navigation, active-window switching, a persistent dock, controlled administration, and version display.

Brand profile defaults are merged with *local user settings*, never blindly copied over them.

## Configuration precedence

1. Versioned core defaults
2. Versioned brand profile
3. Per-installation local settings (highest priority)

Store local settings outside versioned install directories. Preserve and migrate them transactionally.

## Brand IDs

`bmw`, `mercedes`, `porsche`, `vw-audi`, `toyota`, `ford`, `honda`, `gm`, `jlr`.

## App and dock lifecycle

An independent supervisor may restart the launcher and dock after crashes, with backoff and an escape/recovery route. Update installation must stop and replace versioned components atomically while maintaining recoverability.

Dock stays visible on home; when another application is truly fullscreen it can slide away and return upon intentional bottom-edge interaction. Touch behavior must be tested on the actual hardware.

## Version model

- Core version: SemVer, e.g. `1.0.0`
- Per-brand profile version: independent SemVer
- Channel: `stable` or `beta`
- Local device brand selection remains unchanged on updates.

The application should display **status unknown** when the update server is unreachable, rather than claiming up to date.
