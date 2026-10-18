#!/usr/bin/env python3
"""Build a Mercedes workstation.zip and update-manifest.json. Does not publish.

The version is an argument (default 0.1.3-beta.3). version.json in the bundle is
the canonical encoding of that version, so a later version does not need a new
workflow guard or a new frozen hash. The beta.3 hash below only checks that
encoder.
"""

import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "handoff" / "2026-10-14" / "live-source" / "Mercedes"
LIVE_ZIP = ROOT / "handoff" / "2026-10-14" / "live-builds" / "Mercedes-LIVE-BUILD-20261014-202042.zip"
BUILD_MANIFEST = SOURCE / "BUILD-MANIFEST.json"
DEFAULT_VERSION = "0.1.3-beta.3"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$")
# {"version":"0.1.3-beta.3"} with no trailing newline.
BETA3_VERSION_JSON_SHA256 = "9b20aa7d3c0e616e397c52213ea068a04544bf72d101d6e37dbdd3fc6d9a690a"
BETA3_VERSION_JSON_BYTES = 26
OWN_LOGO = "branding/mercedes.png"
CHANGED = {
    "Launcher.ps1",
    "UpdateRunner.ps1",
    # Approved live profile.json (boldCardDescription). It stays in the bundle.
    # Its hash is taken from the source tree at build time.
    "profile.json",
}
# The Oct 14 BUILD-MANIFEST still records the pre-change export.
# These hashes are frozen here, and the files stay out of CHANGED.
APPROVED_HASHES = {
    # PR #3 Dock.ps1 (UTF-8 BOM, System gear Visibility=Collapsed).
    "Dock.ps1": ("824ab5c00c8f1e482498f1a07e0d19b462c900efbf09bb7dc741a7f09e8b13fc", 18125),
    # PR #6 restart check, safer rollback, and the updater idle loop.
    "ApplyUpdate.ps1": ("d75973d02b44881a1a254063d8151b8e67bdbecf4bafe0a780fdd827ba8ad0a8", 15382),
    "UpdateAgent.ps1": ("cf97590a50d3616a06a603a83efa63e5563153d964111504b91d55c23361e9cc", 28966),
}
XAML_NS = 'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
EXCLUDED = {
    "update-settings.json",
    "apps.json",
    "controls-pin.json",
    "update-status.json",
    "update-deferred.json",
    "update-progress.json",
}
PACKAGED_FILE_COUNT = 20


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_version_json(version: str) -> bytes:
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"invalid version {version}")
    return ('{"version":"%s"}' % version).encode("utf-8")


def packaged_version_json(version: str) -> bytes:
    data = canonical_version_json(version)
    parsed = json.loads(data.decode("utf-8"))
    if parsed.get("version") != version or sha256(data) != sha256(canonical_version_json(version)):
        raise SystemExit("version.json encoder did not round-trip")
    if version == DEFAULT_VERSION:
        if sha256(data) != BETA3_VERSION_JSON_SHA256 or len(data) != BETA3_VERSION_JSON_BYTES:
            raise SystemExit("beta.3 version.json integrity guard failed")
        source = (SOURCE / "version.json").read_bytes()
        if source != data:
            raise SystemExit("source version.json is not the canonical 0.1.3-beta.3 file")
    return data


def is_other_brand_logo(path: str) -> bool:
    name = path.replace("\\", "/")
    return name.startswith("branding/") and name.endswith(".png") and name != OWN_LOGO


def load_members(blob: bytes):
    manifest = json.loads(blob.decode("utf-8"))
    files = manifest.get("files") or []
    if len(files) != 28:
        raise SystemExit("BUILD-MANIFEST.json must list the 28 approved Mercedes files")
    paths = []
    expected = {}
    for entry in files:
        path = str(entry["path"]).replace("\\", "/")
        if path in paths:
            raise SystemExit(f"duplicate manifest path {path}")
        paths.append(path)
        expected[path] = (str(entry["sha256"]).lower(), int(entry["bytes"]))
    required = {
        "Launcher.ps1",
        "Dock.ps1",
        "WorkstationShell.ps1",
        "Validate.ps1",
        "Create-Shortcuts.ps1",
        "Remove-Legacy-Mercedes.ps1",
        "WorkstationManager.exe",
        OWN_LOGO,
        "version.json",
        "profile.json",
    }
    missing = sorted(required.difference(paths))
    if missing:
        raise SystemExit("approved set is missing: " + ", ".join(missing))
    for path, frozen in APPROVED_HASHES.items():
        if path not in expected:
            raise SystemExit(f"approved hash is not in the manifest: {path}")
        if path in CHANGED:
            raise SystemExit(f"{path} cannot be both changed and hash-pinned")
        expected[path] = frozen
    return paths, expected


def read_source(path: str, zip_members: dict, expected: dict) -> bytes:
    if path in EXCLUDED:
        raise SystemExit(f"refusing to package user data: {path}")
    source_path = SOURCE / path
    if source_path.is_file():
        data = source_path.read_bytes()
    elif path in zip_members:
        data = zip_members[path]
    else:
        raise SystemExit(f"missing approved file: {path}")
    digest = sha256(data)
    size = len(data)
    if path not in CHANGED:
        want_hash, want_bytes = expected[path]
        if digest != want_hash or size != want_bytes:
            raise SystemExit(f"unexpected bytes for unchanged file {path}")
    return data


def assert_current_package(staged: list[tuple[str, bytes]], version: str) -> None:
    files = dict(staged)
    for path in ("Launcher.ps1", "UpdateAgent.ps1", "ApplyUpdate.ps1", "version.json", "Dock.ps1", "profile.json"):
        if path != "version.json" and not (SOURCE / path).is_file():
            raise SystemExit(f"{path} must come from the current Mercedes source tree")
    version_bytes = files["version.json"]
    if version_bytes != canonical_version_json(version):
        raise SystemExit(f"packaged version.json is not {version}")
    if version == DEFAULT_VERSION and (
        sha256(version_bytes) != BETA3_VERSION_JSON_SHA256 or len(version_bytes) != BETA3_VERSION_JSON_BYTES
    ):
        raise SystemExit("packaged version.json failed the beta.3 integrity guard")
    for path in ("ApplyUpdate.ps1", "UpdateAgent.ps1"):
        want_hash, want_bytes = APPROVED_HASHES[path]
        data = files[path]
        if sha256(data) != want_hash or len(data) != want_bytes:
            raise SystemExit(f"packaged {path} is not the approved file")
    launcher = files["Launcher.ps1"].decode("utf-8-sig")
    if "LAUNCHER SETTINGS" not in launcher or "#C0C6CE" not in launcher:
        raise SystemExit("packaged Launcher.ps1 is not the current Mercedes launcher")
    if "#D0D5DB" in launcher or "DWMWA_WINDOW_CORNER_PREFERENCE" not in launcher:
        raise SystemExit("packaged Launcher.ps1 is not the approved rounded admin launcher")
    if "Bold description text on home cards" not in launcher or "No AllowsTransparency" not in launcher:
        raise SystemExit("packaged Launcher.ps1 is missing the approved admin chrome")
    if "AllowsTransparency=" in launcher:
        raise SystemExit("packaged Launcher.ps1 sets AllowsTransparency")
    agent = files["UpdateAgent.ps1"].decode("utf-8-sig")
    templates = re.findall(r"<ControlTemplate(?:\s[^>]*)?>", agent)
    if "Software Update" not in agent or not templates or any(XAML_NS not in item for item in templates):
        raise SystemExit("packaged UpdateAgent.ps1 is missing the xmlns:x redesign")
    dock_hash, dock_bytes = APPROVED_HASHES["Dock.ps1"]
    dock = files["Dock.ps1"]
    if sha256(dock) != dock_hash or len(dock) != dock_bytes:
        raise SystemExit("packaged Dock.ps1 is not the approved PR #3 file")
    logos = [path for path in files if path.startswith("branding/") and path.endswith(".png")]
    if logos != [OWN_LOGO]:
        raise SystemExit("Mercedes bundle must ship only branding/mercedes.png")
    if "apps.json" in files or "profile.json" not in files:
        raise SystemExit("profile.json must ship and apps.json must not")


def main(argv: list[str]) -> int:
    version = argv[1] if len(argv) > 1 else DEFAULT_VERSION
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"invalid version {version}")
    paths, expected = load_members(BUILD_MANIFEST.read_bytes())
    with zipfile.ZipFile(LIVE_ZIP) as archive:
        zip_members = {name.replace("\\", "/"): archive.read(name) for name in archive.namelist()}
    staged = []
    for path in paths:
        if path == "version.json":
            data = packaged_version_json(version)
        else:
            data = read_source(path, zip_members, expected)
        if is_other_brand_logo(path):
            continue
        staged.append((path, data))
    if len(staged) != PACKAGED_FILE_COUNT:
        raise SystemExit(f"expected {PACKAGED_FILE_COUNT} packaged files, got {len(staged)}")
    assert_current_package(staged, version)
    out_dir = ROOT / "dist" / f"mercedes-v{version}"
    out_dir.mkdir(parents=True, exist_ok=True)
    zip_path = out_dir / "workstation.zip"
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path, data in sorted(staged, key=lambda item: item[0]):
            info = zipfile.ZipInfo(path)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            bundle.writestr(info, data)
    blob = zip_path.read_bytes()
    manifest = {
        "schemaVersion": 1,
        "brand": "mercedes",
        "channel": "beta",
        "version": version,
        "tag": f"mercedes-v{version}",
        "asset": "workstation.zip",
        "sha256": sha256(blob),
        "bytes": len(blob),
        "files": [
            {"path": path, "sha256": sha256(data), "bytes": len(data)}
            for path, data in sorted(staged, key=lambda item: item[0])
        ],
    }
    manifest_path = out_dir / "update-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    names = [item["path"] for item in manifest["files"]]
    if any(name in EXCLUDED or is_other_brand_logo(name) for name in names):
        raise SystemExit("bundle contains a preserved user file or another brand logo")
    print(f"built {zip_path}")
    print(f"built {manifest_path}")
    print(f"tag mercedes-v{version}")
    print(f"sha256 {manifest['sha256']}")
    print(f"bytes {manifest['bytes']}")
    print("not published")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
