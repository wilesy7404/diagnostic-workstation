#!/usr/bin/env python3
"""Build a Mercedes workstation.zip and update-manifest.json. Does not publish."""

import hashlib
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "handoff" / "2026-10-14" / "live-source" / "Mercedes"
LIVE_ZIP = ROOT / "handoff" / "2026-10-14" / "live-builds" / "Mercedes-LIVE-BUILD-20261014-202042.zip"
BUILD_MANIFEST = SOURCE / "BUILD-MANIFEST.json"
CHANGED = {
    "Launcher.ps1",
    "UpdateAgent.ps1",
    "UpdateRunner.ps1",
    "ApplyUpdate.ps1",
    "version.json",
}
EXCLUDED = {
    "update-settings.json",
    "apps.json",
    "controls-pin.json",
    "update-status.json",
    "update-deferred.json",
    "update-progress.json",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
        "branding/mercedes.png",
        "version.json",
    }
    missing = sorted(required.difference(paths))
    if missing:
        raise SystemExit("approved set is missing: " + ", ".join(missing))
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


def main(argv: list[str]) -> int:
    version = argv[1] if len(argv) > 1 else "0.1.3-beta.1"
    if version != "0.1.3-beta.1":
        raise SystemExit("this bundle script is pinned to 0.1.3-beta.1")
    version_bytes = (SOURCE / "version.json").read_bytes()
    if json.loads(version_bytes.decode("utf-8")).get("version") != version:
        raise SystemExit("version.json does not match 0.1.3-beta.1")
    paths, expected = load_members(BUILD_MANIFEST.read_bytes())
    with zipfile.ZipFile(LIVE_ZIP) as archive:
        zip_members = {name.replace("\\", "/"): archive.read(name) for name in archive.namelist()}
    staged = []
    for path in paths:
        data = read_source(path, zip_members, expected)
        staged.append((path, data))
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
    if any(name in EXCLUDED for name in names):
        raise SystemExit("bundle contains a preserved user file")
    print(f"built {zip_path}")
    print(f"built {manifest_path}")
    print(f"tag mercedes-v{version}")
    print(f"sha256 {manifest['sha256']}")
    print(f"bytes {manifest['bytes']}")
    print("not published")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
