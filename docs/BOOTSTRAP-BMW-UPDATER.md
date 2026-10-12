# BMW GitHub updater bootstrap

The first-stage BMW updater checks the public GitHub Releases API at startup and approximately every six hours. It can identify a published newer release and update local status without authentication.

**Current limitation:** it is a check-only bootstrap, not an automatic installer. We will enable Update Now / Later only after publishing a validated core package and testing checksums, backups, transactional install and rollback on the BMW device.

The updater must never replace local `apps.json`, any diagnostic application installations or licenses, or manufacturer-specific settings.

A GitHub Actions release workflow has been configured; it intentionally refuses to publish until core files and the installer are validated.
