# Changelog

These builds are not published. There is no tag and no GitHub release yet. The catalog pin records the Actions artifact bytes so a later release can upload the same files.

## Mercedes-Benz 0.1.3-beta.3 (prerelease, beta) — 2026-10-17

Source commit `7b6befdfcb3d501a8b2f29b240adcb58df897fc5`. Pull requests #8, #9, #11, and #12.

`workstation.zip` is 1416210 bytes, SHA-256 `0d4ae7771c5e3d6a970f155f498cba3b5a37eb19933cdbf665ca93680202dd9a`. `update-manifest.json` is 3338 bytes, SHA-256 `fd9118ca903f620b4fcf7fcb12e0a827bd4d5357626460bc9b83b9d871c17528`. contentDigest `af87858cc58bf0f66cd379ff88cdb07f9508b1e6490275a02cea9d483e58af67`. Workflow run [39087424705](https://github.com/wilesy7404/diagnostic-workstation/actions/runs/39087424705).

Changes since the prior Mercedes label `mercedes-v0.1.3-beta.2`:

- The bundle ships only its own logo, `branding/mercedes.png`.
- `apps.json` is removed from the bundle and kept on the machine.
- `WorkstationManager.exe` is the supervisor.
- An existing `profile.json` is kept. A fresh install receives the bundle default.
- Non-ASCII `.ps1` files that had no UTF-8 BOM get that BOM during packaging.

`mercedes-v0.1.3-beta.1` and `mercedes-v0.1.3-beta.2` are existing published prereleases with different bytes. They are left untouched and unpinned. `0.1.3-beta.3` is a fresh label, not a reused one.

Known issues: no VM test yet. DPI, multi-monitor, and Windows PowerShell 5.1 are not yet verified.

File list (SHA-256, uncompressed bytes, path):

```
d75973d02b44881a1a254063d8151b8e67bdbecf4bafe0a780fdd827ba8ad0a8  15382  ApplyUpdate.ps1
e30e35f2145164f50de580166cdecf85cd9d850d1d91a832e24293448a4dc594  549  Create-Shortcuts.ps1
824ab5c00c8f1e482498f1a07e0d19b462c900efbf09bb7dc741a7f09e8b13fc  18125  Dock.ps1
b849b0a89c9d64db365ec90d80b500cbf2771817c0c8edea23e15c8f9360fe5e  38962  Launcher.ps1
fb66bea8533cc0e716715e7d05939a530d13305cf67ba51573746a66b3ac96ac  2969  Remove-Legacy-Mercedes.ps1
84ee7bd5f9392779bbd2be5005e0bb936c53a0536c0286f18123c9e5c3a965ae  1045  Restart-Mercedes-Controls.ps1
cb768f2647e41be26bb92d08bc1e2f8246506d1fa039999d811ba437cdaa32e8  811  Restore-ExplorerShell.ps1
571803fd639a2ec66df7e1fe7f1921ee7ad1e2e688f436d4157b94305e1827dc  5150  Save-Approved-Mercedes.ps1
3d34cfcbd76833d6fbd5b9baf4803760b6aa9ca8918ce3af2940226f56045192  8270  SystemPanel.ps1
71179b60644de4d64b66353036aad1fa6d8cc356d0b579cd3cd21e87985e90bc  3913  Uninstall.ps1
cf97590a50d3616a06a603a83efa63e5563153d964111504b91d55c23361e9cc  28966  UpdateAgent.ps1
57598439898e4d452ff378afc924f61878bc93ccf26d7ffd625bcaa0b0f895d9  5392  UpdateRunner.ps1
d221e4b89bec34a1ff426e301ffee17cee515d94484a52ba14c7604ecb6785e8  761  Validate.ps1
7e721f24fc1a3f20844ada2132900da45cf3afeb15ee763e43fa2aa57d057af9  1260  Watchdog.ps1
63807e5bf296f13678a4e1014006a3af98d5fffffafe54feeb7f88fb671c14df  22208  WorkstationControls.ps1
4981dc756c970e3a9bc4890f79a57cd0a525d525eb0da7ccfe050d3263a9c63f  2478080  WorkstationManager.exe
92758c6d2b2d77ffc4fc9217f6b3c10c46da59f5ee2f687e9977b08ca1109cb5  4759  WorkstationShell.ps1
9692d9bc8fea0731e1d68c4f5596783ff360c6cc2a9f48af4b8bdccec7234bab  233049  branding/mercedes.png
c15fa7d6f05b67c1f540213846ca8e44ebe25d9c76184a9a47ac9c00166fde01  257  profile.json
9b20aa7d3c0e616e397c52213ea068a04544bf72d101d6e37dbdd3fc6d9a690a  26  version.json
```

## BMW 1.0.2-beta.1 (prerelease, beta) — 2026-10-17

Source commit `7b6befdfcb3d501a8b2f29b240adcb58df897fc5`. Pull requests #8, #9, #11, and #12.

`workstation.zip` is 48955 bytes, SHA-256 `77bf2e85b4192d0485d79e82a256a68494b673c99c67eb81f62f194e94c69978`. `update-manifest.json` is 2554 bytes, SHA-256 `82075f0f9751191eb3547fba2e05868ef656b6f567c5eeede5b62cd4c90d1136`. contentDigest `e07829490aff1f4de7ae919fb9d2cd86f4ddc64ed684c5d1e14d1537753b5cd9`. Workflow run [39087426283](https://github.com/wilesy7404/diagnostic-workstation/actions/runs/39087426283).

Changes since the prior BMW label `v1.0.1-beta.5`:

- The bundle ships only its own logo, `branding/bmw.png`.
- `apps.json` is removed from the bundle and kept on the machine.
- The supervisor is the transitional `Watchdog.ps1`. The WorkstationManager migration is later.
- An existing `profile.json` is kept. A fresh install receives the bundle default.
- Non-ASCII `.ps1` files that had no UTF-8 BOM get that BOM during packaging. Every non-ASCII BMW script in this bundle already had a BOM, so none of those bytes changed.
- The updater targets `bmw-v*` tags.

Known issues: no VM test yet. DPI, multi-monitor, and Windows PowerShell 5.1 are not yet verified.

File list (SHA-256, uncompressed bytes, path):

```
0e1ee766fbb09da023bfc3d0dd893a4e94bfff5ab8824216565dc8508115220a  5242  ApplyUpdate.ps1
70fad854d93f035afbbdf1a42c8cc11394eef167df4ba77852f0981e06f60ae8  21507  BMWWorkstationControls.ps1
11dc722fc3b4e9a49eeb8391615e3c60726cc5a9db7a85da35993f53c804f8aa  16180  Dock.ps1
b59681daa35c4b91943e6e713263ba0d597ad500e4a2c8fda951334aee8e4029  28836  Launcher.ps1
e6b83656840df36c9ce059e23080faf0f77275f94410d62f33dc954878e97672  1125  Restart-BMW-Controls.ps1
5c7042977a751d0978da489f64253415fe923b87d788be6794a5221756e68054  986  Restore-BMW-ExplorerShell.ps1
ca0e91b41ae8ace1e847c3d1cdd6278e8f5b5aa2ef7dfc0c50c47b291225bd4c  1438  Rollback-BMW-Controls-v1.ps1
a696cd53e3c88f2040fe53d039ecb9f0b010f88df13e6b00be0bbb41355a0dd6  2958  Save-Approved-BMW.ps1
519196d8600a01ff3d50ac4557368d5f596425fc6e0fdd4a7cbbeed99b5c61e6  8025  SystemPanel.ps1
0c496bc0e7d2b3836f263d2d1dd6f3c93bf53789269fb0112ea34d93bf110a0a  10623  UpdateAgent.ps1
1864235c581a7f888d95badf798ff94f3f0c07da228c789f3d5dcf4e54954a24  4622  UpdateRunner.ps1
33ebfec7bf2c62ee6f009b667bbefffee83c5048f38bcafaf2ae012efbe99283  1279  Watchdog.ps1
945132a86f0ab3023deecb40b1410c613e0ef075ec4da3c7466f357f086f34f8  12416  branding/bmw.png
8307e5ce9430a1901e531627daab81c61ca460db122f9a77d458313780f4df40  92  profile.json
e3129bf91276db28b6cce7f7e0b0464382d0556ca6a828ba5785b128aac785de  26  version.json
```
