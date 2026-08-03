#!/usr/bin/env python3
"""Behavior tests for the active Node dependency security gate."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "script" / "check_node_toolchain_security.py"


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def write_fixture(
    root: Path,
    *,
    dev_dependencies: dict[str, str] | None = None,
    lock_packages: dict[str, object] | None = None,
    scripts: dict[str, str] | None = None,
) -> None:
    dependencies = dev_dependencies or {"playwright-core": "1.61.1"}
    write_json(
        root / "package.json",
        {
            "name": "node-security-fixture",
            "private": True,
            "scripts": scripts or {},
            "devDependencies": dependencies,
        },
    )
    packages: dict[str, object] = {
        "": {
            "name": "node-security-fixture",
            "devDependencies": dependencies,
        },
        "node_modules/playwright-core": {
            "version": "1.61.1",
        },
    }
    if lock_packages:
        packages.update(lock_packages)
    write_json(
        root / "package-lock.json",
        {
            "name": "node-security-fixture",
            "lockfileVersion": 3,
            "requires": True,
            "packages": packages,
        },
    )


def run_check(root: Path, *, succeeds: bool) -> str:
    result = subprocess.run(
        [sys.executable, str(CHECK), "--root", str(root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if (result.returncode == 0) != succeeds:
        raise AssertionError(result.stdout)
    return result.stdout


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="node-toolchain-security-") as directory:
        fixture = Path(directory)
        write_fixture(fixture)
        run_check(fixture, succeeds=True)

        write_fixture(
            fixture,
            dev_dependencies={
                "playwright-core": "1.61.1",
                "web-ext": "10.5.0",
            },
            lock_packages={
                "node_modules/web-ext": {
                    "version": "10.5.0",
                },
            },
        )
        assert "retired Firefox package is active: web-ext" in run_check(
            fixture, succeeds=False
        )

        write_fixture(
            fixture,
            lock_packages={
                "node_modules/firefox-profile": {
                    "version": "4.7.0",
                },
            },
        )
        assert "retired Firefox package remains in lockfile: firefox-profile" in run_check(
            fixture, succeeds=False
        )

        for package_name, version in (
            ("adm-zip", "0.5.18"),
            ("brace-expansion", "1.1.16"),
            ("shell-quote", "1.8.4"),
        ):
            write_fixture(
                fixture,
                lock_packages={
                    f"node_modules/{package_name}": {
                        "version": version,
                    },
                },
            )
            assert (
                f"known high-risk package remains: {package_name}@{version}"
                in run_check(fixture, succeeds=False)
            )

        write_fixture(
            fixture,
            scripts={"lint:firefox": "python3 script/firefox_extension_release.py lint"},
        )
        assert "scripts reactivate retired Firefox tooling" in run_check(
            fixture, succeeds=False
        )

    signing_result = subprocess.run(
        ["bash", str(ROOT / "script" / "sign_firefox_extension.sh")],
        env={
            **os.environ,
            "AMO_JWT_ISSUER": "must-not-be-read",
            "AMO_JWT_SECRET": "must-not-be-read",
        },
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    assert signing_result.returncode == 2, signing_result.stdout
    assert "Firefox release signing is retired" in signing_result.stdout

    help_result = subprocess.run(
        [sys.executable, str(ROOT / "script" / "firefox_extension_release.py"), "--help"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True,
    )
    assert "{lint," not in help_result.stdout
    assert "lint-amo" not in help_result.stdout

    print("Node toolchain security gate tests: passed")


if __name__ == "__main__":
    main()
