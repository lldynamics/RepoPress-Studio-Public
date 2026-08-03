#!/usr/bin/env python3
"""Validate the deterministic, active Node dependency security boundary."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEPENDENCY_SECTIONS = (
    "dependencies",
    "devDependencies",
    "optionalDependencies",
    "peerDependencies",
)
RETIRED_FIREFOX_PACKAGES = frozenset(
    (
        "web-ext",
        "firefox-profile",
        "fx-runner",
    )
)
KNOWN_HIGH_RISK_VERSIONS = {
    ("adm-zip", "0.5.18"),
    ("brace-expansion", "1.1.16"),
    ("shell-quote", "1.8.4"),
}


class SecurityPolicyError(RuntimeError):
    pass


def load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SecurityPolicyError(f"cannot read valid JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise SecurityPolicyError(f"{path} must contain a JSON object")
    return value


def dependency_section(value: dict[str, Any], name: str, path: Path) -> dict[str, str]:
    section = value.get(name, {})
    if not isinstance(section, dict) or not all(
        isinstance(package, str) and isinstance(version, str)
        for package, version in section.items()
    ):
        raise SecurityPolicyError(f"{path}: {name} must map package names to versions")
    return dict(section)


def lock_package_name(path: str, metadata: dict[str, Any]) -> str:
    declared_name = metadata.get("name")
    if isinstance(declared_name, str) and declared_name:
        return declared_name
    marker = "node_modules/"
    if marker not in path:
        return path
    return path.rsplit(marker, 1)[1]


def validate(root: Path) -> None:
    package_path = root / "package.json"
    lock_path = root / "package-lock.json"
    package = load_object(package_path)
    lock = load_object(lock_path)

    if lock.get("lockfileVersion") != 3:
        raise SecurityPolicyError(f"{lock_path}: lockfileVersion must be 3")
    packages = lock.get("packages")
    if not isinstance(packages, dict):
        raise SecurityPolicyError(f"{lock_path}: packages must be an object")
    lock_root = packages.get("")
    if not isinstance(lock_root, dict):
        raise SecurityPolicyError(f"{lock_path}: packages must contain the root package")

    for section_name in DEPENDENCY_SECTIONS:
        declared = dependency_section(package, section_name, package_path)
        locked = dependency_section(lock_root, section_name, lock_path)
        if declared != locked:
            raise SecurityPolicyError(
                f"{lock_path}: root {section_name} does not match package.json"
            )
        retired = sorted(RETIRED_FIREFOX_PACKAGES.intersection(declared))
        if retired:
            raise SecurityPolicyError(
                f"{package_path}: retired Firefox package is active: {', '.join(retired)}"
            )

    scripts = package.get("scripts", {})
    if not isinstance(scripts, dict) or not all(
        isinstance(name, str) and isinstance(command, str)
        for name, command in scripts.items()
    ):
        raise SecurityPolicyError(f"{package_path}: scripts must map names to commands")
    retired_script_names = sorted(
        name
        for name, command in scripts.items()
        if "web-ext" in command or "firefox_extension_release.py lint" in command
    )
    if retired_script_names:
        raise SecurityPolicyError(
            f"{package_path}: scripts reactivate retired Firefox tooling: "
            f"{', '.join(retired_script_names)}"
        )

    for package_key, raw_metadata in packages.items():
        if package_key == "":
            continue
        if not isinstance(package_key, str) or not isinstance(raw_metadata, dict):
            raise SecurityPolicyError(f"{lock_path}: invalid package entry")
        package_name = lock_package_name(package_key, raw_metadata)
        version = raw_metadata.get("version")
        if package_name in RETIRED_FIREFOX_PACKAGES:
            raise SecurityPolicyError(
                f"{lock_path}: retired Firefox package remains in lockfile: {package_name}"
            )
        if isinstance(version, str) and (package_name, version) in KNOWN_HIGH_RISK_VERSIONS:
            raise SecurityPolicyError(
                f"{lock_path}: known high-risk package remains: {package_name}@{version}"
            )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=ROOT,
        help="repository or fixture root containing package.json and package-lock.json",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    try:
        validate(args.root.resolve())
    except SecurityPolicyError as error:
        print(f"Node toolchain security gate: {error}", file=sys.stderr)
        return 1
    print("Node toolchain security gate: retired Firefox dependency chain is absent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
