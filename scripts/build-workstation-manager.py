#!/usr/bin/env python3
"""Compile WorkstationManager.exe from the Go manager in manager/.

Source of the Oct 14 binary is handoff/2026-10-14/reference-packages/
Diagnostic-Workstation-Master-Source-v1.2.zip (the same bytes as
Diagnostic-Workstation-Master-Setup-v1.2.exe). This script stages one brand
logo into assets/branding/ and builds with Go 1.23.2, -trimpath, and
-ldflags "-H windowsgui -s -w -buildid= -X main.embeddedBrand=<brand>".
The checked-in logos stay outside the embed tree.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / "manager"
LOGOS = MANAGER / "logos"
REQUIRED_GO = "go1.23.2"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_go() -> None:
    try:
        out = subprocess.check_output(["go", "version"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"Go {REQUIRED_GO} is required to build WorkstationManager.exe: {exc}") from exc
    if not out.startswith(f"go version {REQUIRED_GO} "):
        raise SystemExit(
            f"WorkstationManager builds are pinned to {REQUIRED_GO} so two builds match; found {out}"
        )


def build_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("GO") and key not in {"GOROOT", "GOPATH", "GOPROXY", "GOSUMDB"}:
            env.pop(key)
    env["CGO_ENABLED"] = "0"
    env["GOOS"] = "windows"
    env["GOARCH"] = "amd64"
    env["GOAMD64"] = "v1"
    env["GOTOOLCHAIN"] = "local"
    return env


def lf_bytes(data: bytes) -> bytes:
    """Checkout on windows-latest rewrites text to CRLF. Embed the LF sources."""
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def stage_module(stage: Path, brand: str) -> None:
    if any(part in {"..", "/", "\\"} or part.startswith(".") for part in Path(brand).parts) or not brand:
        raise SystemExit(f"invalid brand {brand}")
    logo = LOGOS / f"{brand}.png"
    if not logo.is_file():
        known = ", ".join(sorted(path.stem for path in LOGOS.glob("*.png")))
        raise SystemExit(f"no logo for {brand}; known brands: {known}")
    stage.mkdir(parents=True)
    (stage / "go.mod").write_bytes(lf_bytes((MANAGER / "go.mod").read_bytes()))
    sources = [path for path in MANAGER.glob("*.go") if not path.name.endswith("_test.go")]
    if not any(path.name == "main.go" for path in sources):
        raise SystemExit("manager/main.go is missing")
    for source in sources:
        (stage / source.name).write_bytes(lf_bytes(source.read_bytes()))
    assets = stage / "assets"
    for source in (MANAGER / "assets").rglob("*"):
        if not source.is_file():
            continue
        dest = assets / source.relative_to(MANAGER / "assets")
        dest.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        if source.suffix.lower() != ".png":
            data = lf_bytes(data)
        dest.write_bytes(data)
    branding = stage / "assets" / "branding"
    if branding.exists():
        shutil.rmtree(branding)
    branding.mkdir()
    shutil.copyfile(logo, branding / logo.name)
    pngs = sorted(path.relative_to(stage).as_posix() for path in (stage / "assets").rglob("*.png"))
    expected = f"assets/branding/{brand}.png"
    if pngs != [expected]:
        raise SystemExit(f"staged embed must contain only {expected}, found {pngs}")


def compile_to(brand: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    env = build_env()
    # Oct 14 flags were -H windowsgui -s -w -trimpath (GUI subsystem, no console,
    # symbol table and DWARF omitted). -buildid= is added so a temp staging
    # directory does not change the embedded build ID. -X sets the brand.
    ldflags = f"-H windowsgui -s -w -buildid= -X main.embeddedBrand={brand}"
    with tempfile.TemporaryDirectory(prefix="wm-build-") as tmp:
        stage = Path(tmp) / "manager"
        stage_module(stage, brand)
        cmd = [
            "go",
            "build",
            "-trimpath",
            "-ldflags",
            ldflags,
            "-o",
            str(dest.resolve()),
            ".",
        ]
        result = subprocess.run(cmd, cwd=stage, env=env, check=False)
        if result.returncode != 0:
            raise SystemExit("go build failed")


def build(brand: str, dest: Path, verify: bool) -> bytes:
    require_go()
    if verify:
        with tempfile.TemporaryDirectory(prefix="wm-compare-") as tmp:
            first = Path(tmp) / "a" / "WorkstationManager.exe"
            second = Path(tmp) / "b" / "WorkstationManager.exe"
            compile_to(brand, first)
            compile_to(brand, second)
            left = first.read_bytes()
            right = second.read_bytes()
            if left != right:
                raise SystemExit(
                    "WorkstationManager.exe is not reproducible: "
                    f"{sha256(left)} ({len(left)} bytes) != {sha256(right)} ({len(right)} bytes)"
                )
            data = left
        print("reproducible match")
    else:
        with tempfile.TemporaryDirectory(prefix="wm-once-") as tmp:
            once = Path(tmp) / "WorkstationManager.exe"
            compile_to(brand, once)
            data = once.read_bytes()
        print("reproducible not-checked")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    print(f"built {dest}")
    print(f"brand {brand}")
    print(f"embedded-logo branding/{brand}.png")
    print(f"sha256 {sha256(data)}")
    print(f"bytes {len(data)}")
    return data


def main(argv: list[str]) -> int:
    verify = "--verify-reproducible" in argv
    args = [arg for arg in argv[1:] if arg != "--verify-reproducible"]
    if len(args) != 2:
        raise SystemExit(
            "usage: build-workstation-manager.py <brand> <output.exe> [--verify-reproducible]"
        )
    build(args[0], Path(args[1]), verify)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
