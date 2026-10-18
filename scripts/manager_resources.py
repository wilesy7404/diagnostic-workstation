"""Scan a WorkstationManager.exe for embedded brand logos and update templates.

The Oct 14 universal manager embeds nine brand PNGs. A brand build may embed
only that brand's logo. update-settings.json and update-status.json are the
default templates from the manager source; they are kept only while their keys
stay free of device data.
"""

from __future__ import annotations

import hashlib
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOGOS = ROOT / "manager" / "logos"
TEMPLATES = {
    "update-settings.json": {"channel", "source", "repo", "tagPrefix"},
    "update-status.json": {"checked", "state", "latest", "message"},
}
PNG_SIG = b"\x89PNG\r\n\x1a\n"
PNG_IEND = b"IEND\xaeB`\x82"
LIVE_ZIP = ROOT / "handoff" / "2026-10-14" / "live-builds" / "Mercedes-LIVE-BUILD-20261014-202042.zip"
OCT14_EXE_NAME = "WorkstationManager.exe"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def png_blobs(blob: bytes) -> list[bytes]:
    found = []
    start = 0
    while True:
        index = blob.find(PNG_SIG, start)
        if index < 0:
            break
        end = blob.find(PNG_IEND, index)
        if end < 0:
            break
        found.append(blob[index : end + len(PNG_IEND)])
        start = index + 1
    return found


def logo_bytes() -> dict[str, bytes]:
    logos = {}
    for path in sorted(LOGOS.glob("*.png")):
        logos[path.stem] = path.read_bytes()
    if "mercedes" not in logos:
        raise SystemExit("manager/logos/mercedes.png is missing")
    return logos


def logo_problems(blob: bytes, brand: str) -> list[str]:
    """Return reasons this exe is not a single-brand build. Empty means clean."""
    logos = logo_bytes()
    if brand not in logos:
        return [f"unknown brand {brand}"]
    problems = []
    own = logos[brand]
    own_hash = sha256(own)
    embedded = png_blobs(blob)
    embedded_hashes = {sha256(item) for item in embedded}
    if own not in blob or own_hash not in embedded_hashes:
        problems.append(f"missing branding/{brand}.png")
    own_name = f"assets/branding/{brand}.png"
    if own_name.encode("ascii") not in blob:
        problems.append(f"missing resource name {own_name}")
    for name, data in logos.items():
        if name == brand:
            continue
        resource = f"assets/branding/{name}.png"
        if data in blob or sha256(data) in embedded_hashes or resource.encode("ascii") in blob:
            problems.append(f"embeds branding/{name}.png")
    for item in embedded:
        if sha256(item) != own_hash:
            problems.append(f"embeds an unexpected PNG sha256 {sha256(item)}")
    return problems


def template_problems(blob: bytes) -> list[str]:
    problems = []
    for name, allowed in TEMPLATES.items():
        path = ROOT / "manager" / "assets" / name
        # The compiler embeds LF. A Windows checkout may have CRLF in the working tree.
        data = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        parsed = json.loads(data.decode("utf-8"))
        if not isinstance(parsed, dict):
            problems.append(f"{name} is not a JSON object")
            continue
        keys = set(parsed)
        if keys != allowed:
            problems.append(f"{name} keys {sorted(keys)} are not the device-free template")
        for key, value in parsed.items():
            if not isinstance(value, str):
                problems.append(f"{name} {key} is not a string")
                continue
            lowered = value.lower()
            if any(token in lowered for token in ("localappdata", "c:\\", "c:/", "\\\\", "serial", "hostname")):
                problems.append(f"{name} {key} looks like device data")
        if data not in blob:
            problems.append(f"{name} template is missing from the exe")
    return problems


def oct14_manager_bytes() -> bytes:
    with zipfile.ZipFile(LIVE_ZIP) as archive:
        return archive.read(OCT14_EXE_NAME)
