# Release and update policy

Release artifacts contain only our own workstation source, presentation assets and deployment files. **Do not bundle or update ISTA, XENTRY, PIWIS, ODIS, other OEM diagnostic tools, databases, activation assets, or user credentials.**

1. Build versioned core and optional brand profile packages.
2. Validate PowerShell parsing, WPF startup, tile launch, dock auto-hide, touch navigation and Settings fallback.
3. Stage to beta test installations and verify recovery.
4. Publish immutable versioned artifacts and SHA-256 checksums; prefer verified signatures.
5. Clients query a trusted release manifest, compare version and brand, then offer **Update now** or **Later**.
6. On consent, download and verify artifacts, back up current runtime, install transactionally, and relaunch. Roll back on failed health check.

For a **private GitHub repository**, no GitHub token may be hardcoded into the application or distributed to all devices. Use a narrowly scoped authenticated release delivery service or per-device expiring credentials after designing access management.

There is **no automatic update backend active yet**. A repository alone is not an updater endpoint.
