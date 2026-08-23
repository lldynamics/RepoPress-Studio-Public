#!/usr/bin/env python3
"""Behavior tests for the public-copy/entitlement consistency gate."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "script/check_public_copy_entitlements.py"


def make_fixture(base: Path) -> Path:
    fixture = base / "project"
    (fixture / "docs/public-pages").mkdir(parents=True)
    (fixture / "Packaging").mkdir(parents=True)
    shutil.copy2(ROOT / "docs/privacy-support-copy.md", fixture / "docs")
    for name in (
        "privacy-zh-Hans.html",
        "privacy-en.html",
        "support-zh-Hans.html",
        "support-en.html",
    ):
        shutil.copy2(
            ROOT / "docs/public-pages" / name,
            fixture / "docs/public-pages" / name,
        )
    shutil.copy2(
        ROOT / "Packaging/DirectDistribution.entitlements",
        fixture / "Packaging",
    )
    shutil.copy2(
        ROOT / "Packaging/SafariWebExtension.entitlements",
        fixture / "Packaging",
    )
    return fixture


def run_gate(fixture: Path) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["PUBLIC_COPY_ENTITLEMENTS_ROOT"] = str(fixture)
    return subprocess.run(
        ["python3", str(CHECKER)],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )


def expect_failure(fixture: Path, label: str) -> None:
    result = run_gate(fixture)
    if result.returncode == 0:
        raise SystemExit(f"public copy entitlement test: gate accepted {label}")


def set_sandbox_entitlement(path: Path, enabled: bool) -> None:
    with path.open("rb") as handle:
        entitlements = plistlib.load(handle)
    if enabled:
        entitlements["com.apple.security.app-sandbox"] = True
    else:
        entitlements.pop("com.apple.security.app-sandbox", None)
    with path.open("wb") as handle:
        plistlib.dump(entitlements, handle, sort_keys=False)


with tempfile.TemporaryDirectory(prefix="public-copy-entitlements.") as directory:
    fixture_root = Path(directory)

    fixture = make_fixture(fixture_root)
    accepted = run_gate(fixture)
    if accepted.returncode != 0:
        raise SystemExit(
            "public copy entitlement test: valid fixture failed\n"
            f"{accepted.stdout}{accepted.stderr}"
        )

    privacy_en = fixture / "docs/public-pages/privacy-en.html"
    privacy_en.write_text(
        privacy_en.read_text(encoding="utf-8")
        + "\n<p>The app uses the macOS sandbox.</p>\n",
        encoding="utf-8",
    )
    expect_failure(fixture, "a generic sandbox claim for the unsandboxed direct app")

    shutil.rmtree(fixture)
    fixture = make_fixture(fixture_root)
    set_sandbox_entitlement(
        fixture / "Packaging/DirectDistribution.entitlements",
        enabled=True,
    )
    expect_failure(fixture, "stale non-sandbox copy after enabling the direct entitlement")

    shutil.rmtree(fixture)
    fixture = make_fixture(fixture_root)
    set_sandbox_entitlement(
        fixture / "Packaging/SafariWebExtension.entitlements",
        enabled=False,
    )
    expect_failure(fixture, "a sandboxed Safari extension claim without its entitlement")

    shutil.rmtree(fixture)
    fixture = make_fixture(fixture_root)
    support_en = fixture / "docs/public-pages/support-en.html"
    support_en.write_text(
        support_en.read_text(encoding="utf-8").replace(
            "do not provide App Sandbox isolation",
            "are separate security controls",
        ),
        encoding="utf-8",
    )
    expect_failure(fixture, "copy that conflates Hardened Runtime with sandbox isolation")

print("public copy entitlement test: passed")
