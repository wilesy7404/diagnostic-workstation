#!/usr/bin/env python3
"""Assert the built WorkstationManager.exe embeds only the Mercedes logo."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import manager_resources  # noqa: E402

ROOT = manager_resources.ROOT
BUILD = SCRIPTS / "build-workstation-manager.py"
BRAND = "mercedes"


def fail(message: str) -> None:
    raise SystemExit(message)


def built_exe() -> bytes:
    override = os.environ.get("WORKSTATION_MANAGER_EXE", "").strip()
    if override:
        path = Path(override)
        if not path.is_file():
            fail(f"WORKSTATION_MANAGER_EXE does not exist: {path}")
        print(f"scanning provided exe {path}")
        return path.read_bytes()
    with tempfile.TemporaryDirectory(prefix="wm-logo-test-") as tmp:
        out = Path(tmp) / "WorkstationManager.exe"
        result = subprocess.run(
            [sys.executable, str(BUILD), BRAND, str(out), "--verify-reproducible"],
            check=False,
        )
        if result.returncode != 0:
            fail("WorkstationManager build failed")
        return out.read_bytes()


def main() -> int:
    old = manager_resources.oct14_manager_bytes()
    old_problems = manager_resources.logo_problems(old, BRAND)
    if not any("bmw.png" in item for item in old_problems):
        fail("logo scanner did not flag the Oct 14 exe, which embeds the BMW logo")
    print("Oct 14 exe still embeds other brand logos")

    data = built_exe()
    problems = manager_resources.logo_problems(data, BRAND)
    problems.extend(manager_resources.template_problems(data))
    if problems:
        fail("Mercedes WorkstationManager.exe failed the resource scan:\n" + "\n".join(problems))
    print(f"sha256 {manager_resources.sha256(data)}")
    print(f"bytes {len(data)}")
    print("kept update-settings.json and update-status.json (no device data)")
    print("WorkstationManager logo checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
