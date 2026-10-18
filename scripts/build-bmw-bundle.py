#!/usr/bin/env python3
"""Build a BMW workstation.zip and update-manifest.json. Does not publish.

Bytes for unchanged files come from the live export zip so the UTF-8 BOM the
git copies lost is preserved. Launcher.ps1 and profile.json are swapped in from
bundles/bmw/staging. Their hashes are computed at build time. apps.json is left
out. version.json is generated for the requested version (default
1.0.2-beta.1). The shipped updater is the live-export updater retargeted at
bmw-v* tags.
"""

import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIVE_ZIP = ROOT / "handoff" / "2026-10-14" / "live-builds" / "BMW-LIVE-BUILD-20261014-201549.zip"
MERCEDES_ZIP = ROOT / "handoff" / "2026-10-14" / "live-builds" / "Mercedes-LIVE-BUILD-20261014-202042.zip"
STAGING = ROOT / "bundles" / "bmw" / "staging"
DEFAULT_VERSION = "1.0.2-beta.1"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$")
# {"version":"1.0.2-beta.1"} with no trailing newline.
DEFAULT_VERSION_JSON_SHA256 = "e3129bf91276db28b6cce7f7e0b0464382d0556ca6a828ba5785b128aac785de"
DEFAULT_VERSION_JSON_BYTES = 26
OWN_LOGO = "branding/bmw.png"
# Approved bmw.png from the Mercedes live export. The BMW export has no logo file.
BMW_LOGO_SHA256 = "945132a86f0ab3023deecb40b1410c613e0ef075ec4da3c7466f357f086f34f8"
BMW_LOGO_BYTES = 12416
TAG_PREFIX = "bmw-v"
BACKUP_FILES = {
    "Launcher.before-shortcut-refresh-20261012-152554.ps1",
    "Launcher.before-updater-20261012-153610.ps1",
}
PATCHED = {"UpdateAgent.ps1", "UpdateRunner.ps1"}
GENERATED = {"version.json"}
STAGED_NAMES = {"Launcher.ps1", "profile.json"}
UNCHANGED = {
    "ApplyUpdate.ps1",
    "BMWWorkstationControls.ps1",
    "Dock.ps1",
    "Restart-BMW-Controls.ps1",
    "Restore-BMW-ExplorerShell.ps1",
    "Rollback-BMW-Controls-v1.ps1",
    "Save-Approved-BMW.ps1",
    "SystemPanel.ps1",
    "Watchdog.ps1",
}
EXCLUDED = {
    "update-settings.json",
    "apps.json",
    "controls-pin.json",
    "update-status.json",
    "update-deferred.json",
    "update-progress.json",
    "device.json",
    "secrets.json",
    "BUILD-MANIFEST.json",
    "TRANSFER-README.txt",
}
# 9 unchanged export files, patched updater pair, staging launcher, generated
# version.json, staging profile.json, and branding/bmw.png.
PACKAGED_FILE_COUNT = 15
BARE_FN = (
    "function Bare([string]$value){\n"
    " $v=[string]$value\n"
    " if($v.StartsWith('bmw-v')){return $v.Substring(5)}\n"
    " if($v -match '^v\\d'){return $v.Substring(1)}\n"
    " return $v\n"
    "}\n"
)
RETIRED_TAG = "^v\\d+\\.\\d+\\.\\d+(-beta\\.\\d+)?$"
BMW_TAG = "^bmw-v\\d+\\.\\d+\\.\\d+(-beta\\.\\d+)?$"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_version_json(version: str) -> bytes:
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"invalid version {version}")
    return ('{"version":"%s"}' % version).encode("utf-8")


def zip_members(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        return {name.replace("\\", "/"): archive.read(name) for name in archive.namelist()}


def replace_exact(text: str, old: str, new: str, label: str, count: int = 1) -> str:
    found = text.count(old)
    if found != count:
        raise SystemExit(f"{label}: expected {count} match, found {found}")
    return text.replace(old, new)


def assert_bmw_tags(text: str, label: str) -> None:
    if RETIRED_TAG in text:
        raise SystemExit(f"{label} still matches retired v* tags")
    if BMW_TAG not in text or "function Bare(" not in text:
        raise SystemExit(f"{label} does not resolve bmw-v tags")


def patch_update_agent(data: bytes) -> bytes:
    text = data.decode("utf-8")
    text = replace_exact(text, "$ErrorActionPreference='Stop'\n", "$ErrorActionPreference='Stop'\n" + BARE_FN, "UpdateAgent Bare")
    text = replace_exact(
        text,
        "function Rank([string]$value){\n $v=$value -replace '^v',''\n",
        "function Rank([string]$value){\n $v=Bare $value\n",
        "UpdateAgent Rank",
    )
    text = replace_exact(
        text,
        "$rel.tag_name -match '%s'" % RETIRED_TAG,
        "$rel.tag_name -match '%s'" % BMW_TAG,
        "UpdateAgent tag",
    )
    text = replace_exact(
        text,
        "$versionMatches=($installedVersion -eq ($version -replace '^v',''))",
        "$versionMatches=($installedVersion -eq (Bare $version))",
        "UpdateAgent installed version",
    )
    assert_bmw_tags(text, "UpdateAgent.ps1")
    return text.encode("utf-8")


def patch_update_runner(data: bytes) -> bytes:
    text = data.decode("utf-8")
    text = replace_exact(text, "$ErrorActionPreference='Stop'\n", "$ErrorActionPreference='Stop'\n" + BARE_FN, "UpdateRunner Bare")
    text = replace_exact(
        text,
        "if($Tag -notmatch '%s'){throw 'Invalid release version'}" % RETIRED_TAG,
        "if($Tag -notmatch '%s'){throw 'Invalid release version'}" % BMW_TAG,
        "UpdateRunner tag",
    )
    text = replace_exact(text, "$Tag.Substring(1)", "(Bare $Tag)", "UpdateRunner bare version", count=3)
    assert_bmw_tags(text, "UpdateRunner.ps1")
    if "$Tag.Substring(1)" in text:
        raise SystemExit("UpdateRunner.ps1 still strips a single v from the tag")
    return text.encode("utf-8")


def load_export(members: dict):
    manifest = json.loads(members["BUILD-MANIFEST.json"].decode("utf-8-sig"))
    files = manifest.get("files") or []
    paths = []
    expected = {}
    for entry in files:
        path = str(entry["path"]).replace("\\", "/")
        if path in paths:
            raise SystemExit(f"duplicate manifest path {path}")
        paths.append(path)
        expected[path] = (str(entry["sha256"]).lower(), int(entry["bytes"]))
    expected_names = UNCHANGED | BACKUP_FILES | PATCHED | GENERATED | {"Launcher.ps1"}
    if set(paths) != expected_names:
        extra = sorted(set(paths).difference(expected_names))
        missing = sorted(expected_names.difference(paths))
        raise SystemExit(f"BMW live manifest set changed. extra={extra} missing={missing}")
    for path in UNCHANGED:
        digest, size = expected[path]
        data = members[path]
        if sha256(data) != digest or len(data) != size:
            raise SystemExit(f"live zip bytes do not match BUILD-MANIFEST for {path}")
    return expected


def read_staging_file(staging: Path, name: str) -> bytes:
    path = staging / name
    if not path.is_file():
        raise SystemExit(
            f"missing {path}. The BMW bundle reads {name} from bundles/bmw/staging. "
            "This build computes that file's hash and does not pin it."
        )
    return path.read_bytes()


def read_logo(mercedes: dict) -> bytes:
    if OWN_LOGO not in mercedes:
        raise SystemExit("Mercedes live export is missing branding/bmw.png")
    data = mercedes[OWN_LOGO]
    if sha256(data) != BMW_LOGO_SHA256 or len(data) != BMW_LOGO_BYTES:
        raise SystemExit("branding/bmw.png is not the approved live-export logo")
    others = [name for name in mercedes if name.startswith("branding/") and name.endswith(".png") and name != OWN_LOGO]
    if len(others) < 1:
        raise SystemExit("Mercedes live export no longer carries the other brand logos to exclude")
    return data


def assert_package(staged: list[tuple[str, bytes]], version: str) -> None:
    files = dict(staged)
    if len(files) != PACKAGED_FILE_COUNT:
        raise SystemExit(f"expected {PACKAGED_FILE_COUNT} packaged files, got {len(files)}")
    for name in EXCLUDED | BACKUP_FILES:
        if name in files:
            raise SystemExit(f"bundle contains {name}")
    logos = [path for path in files if path.startswith("branding/") and path.endswith(".png")]
    if logos != [OWN_LOGO]:
        raise SystemExit("BMW bundle must ship only branding/bmw.png")
    if files["version.json"] != canonical_version_json(version):
        raise SystemExit(f"packaged version.json is not {version}")
    if version == DEFAULT_VERSION and (
        sha256(files["version.json"]) != DEFAULT_VERSION_JSON_SHA256
        or len(files["version.json"]) != DEFAULT_VERSION_JSON_BYTES
    ):
        raise SystemExit("1.0.2-beta.1 version.json integrity guard failed")
    launcher = files["Launcher.ps1"].decode("utf-8-sig")
    if "BMW Diagnostic System" not in launcher:
        raise SystemExit("packaged Launcher.ps1 is not a BMW launcher")
    profile = json.loads(files["profile.json"].decode("utf-8-sig"))
    if profile.get("id") != "bmw":
        raise SystemExit("packaged profile.json is not the BMW profile")
    assert_bmw_tags(files["UpdateAgent.ps1"].decode("utf-8"), "packaged UpdateAgent.ps1")
    assert_bmw_tags(files["UpdateRunner.ps1"].decode("utf-8"), "packaged UpdateRunner.ps1")


def build(version: str, staging: Path, out_root: Path) -> Path:
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"invalid version {version}")
    members = zip_members(LIVE_ZIP)
    load_export(members)
    staged = [(path, members[path]) for path in sorted(UNCHANGED)]
    staged.append(("Launcher.ps1", read_staging_file(staging, "Launcher.ps1")))
    staged.append(("profile.json", read_staging_file(staging, "profile.json")))
    staged.append(("UpdateAgent.ps1", patch_update_agent(members["UpdateAgent.ps1"])))
    staged.append(("UpdateRunner.ps1", patch_update_runner(members["UpdateRunner.ps1"])))
    staged.append(("version.json", canonical_version_json(version)))
    staged.append((OWN_LOGO, read_logo(zip_members(MERCEDES_ZIP))))
    for path, _data in staged:
        if path in EXCLUDED or path in BACKUP_FILES:
            raise SystemExit(f"refusing to package {path}")
    assert_package(staged, version)
    out_dir = out_root / f"bmw-v{version}"
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
        "brand": "bmw",
        "channel": "beta",
        "version": version,
        "tag": f"{TAG_PREFIX}{version}",
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
    if any(name in EXCLUDED or name in BACKUP_FILES for name in names):
        raise SystemExit("bundle contains a preserved user file or a launcher backup")
    print(f"built {zip_path}")
    print(f"built {manifest_path}")
    print(f"tag {TAG_PREFIX}{version}")
    print(f"sha256 {manifest['sha256']}")
    print(f"bytes {manifest['bytes']}")
    print("not published")
    return out_dir


def main(argv: list[str]) -> int:
    version = argv[1] if len(argv) > 1 else DEFAULT_VERSION
    staging = Path(argv[2]) if len(argv) > 2 else STAGING
    out_root = Path(argv[3]) if len(argv) > 3 else ROOT / "dist"
    build(version, staging, out_root)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
