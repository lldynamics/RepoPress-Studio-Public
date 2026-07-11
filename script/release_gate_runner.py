#!/usr/bin/env python3
"""Manifest-driven release gate. Shell entrypoints remain compatibility shims."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "script" / "release_checks.json"
QUICK_CHECK_IDS = {
    "localization",
    "app-store-metadata",
    "ui-runtime",
    "privacy-copy",
    "storekit",
    "screenshot-privacy",
    "swift-tests",
}


def load_manifest() -> list[dict[str, object]]:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"release gate: cannot load manifest: {error}")
    if data.get("schemaVersion") != 1 or not isinstance(data.get("checks"), list):
        raise SystemExit("release gate: unsupported release_checks.json schema")
    return data["checks"]


def validate_check(check: dict[str, object]) -> None:
    required = ("id", "title", "source", "evidence", "strictness", "command")
    missing = [key for key in required if not check.get(key)]
    if missing:
        raise SystemExit(f"release gate: manifest check is missing {', '.join(missing)}: {check}")
    if check["strictness"] not in {"always", "standard", "strict"}:
        raise SystemExit(f"release gate: invalid strictness for {check['id']}")
    if not isinstance(check["command"], list) or not all(isinstance(value, str) for value in check["command"]):
        raise SystemExit(f"release gate: command for {check['id']} must be argv")
    if not all(isinstance(value, str) for value in check["source"]) or not all(
        isinstance(value, str) for value in check["evidence"]
    ):
        raise SystemExit(f"release gate: source and evidence for {check['id']} must be string lists")
    if not isinstance(check.get("environment", {}), dict):
        raise SystemExit(f"release gate: environment for {check['id']} must be an object")
    for value in check["command"]:
        if value.startswith("script/") and not (ROOT / value).is_file():
            raise SystemExit(f"release gate: manifest command path is missing for {check['id']}: {value}")


def argv_for(check: dict[str, object]) -> list[str]:
    return [str(ROOT / value) if value.startswith("script/") else value for value in check["command"]]


def run(check: dict[str, object]) -> bool:
    check_id = str(check["id"])
    print(f"release gate [{check_id}]: {check['title']}")
    print(f"  source: {', '.join(check['source'])}")
    print(f"  evidence: {', '.join(check['evidence'])}")
    environment = os.environ.copy()
    environment.update({str(key): str(value) for key, value in dict(check.get("environment", {})).items()})
    return subprocess.run(argv_for(check), cwd=ROOT, env=environment).returncode == 0


def unchecked_checklist_count() -> int:
    checklist = ROOT / "APP_STORE_CHECKLIST.md"
    if not checklist.exists():
        return 0
    return sum(1 for line in checklist.read_text(encoding="utf-8").splitlines() if line.startswith("- [ ]"))


def configure_swift_environment() -> None:
    home = Path(os.environ.get("SWIFT_BUILD_HOME", "/private/tmp/personal-site-publisher-swift-home"))
    os.environ["HOME"] = str(home)
    os.environ.setdefault("XDG_CACHE_HOME", str(home / ".cache"))
    os.environ.setdefault("CLANG_MODULE_CACHE_PATH", str(home / ".swift-clang-cache"))
    os.environ.setdefault("SWIFT_MODULE_CACHE_PATH", str(home / ".swift-module-cache"))
    for directory in (
        home,
        Path(os.environ["XDG_CACHE_HOME"]),
        Path(os.environ["CLANG_MODULE_CACHE_PATH"]),
        Path(os.environ["SWIFT_MODULE_CACHE_PATH"]),
        home / "Library/org.swift.swiftpm/configuration",
        home / "Library/org.swift.swiftpm/security",
        home / "Library/Caches/org.swift.swiftpm",
    ):
        directory.mkdir(parents=True, exist_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the manifest-driven release gate")
    parser.add_argument("--strict", action="store_true", help="also require external Release evidence")
    parser.add_argument("--quick", action="store_true", help="run the core development checks only")
    parser.add_argument(
        "--check",
        action="append",
        default=[],
        metavar="ID",
        help="run one manifest check by ID; repeat to select multiple checks",
    )
    parser.add_argument("--list", action="store_true", help="print manifest entries without running them")
    args = parser.parse_args()
    if args.strict and (args.quick or args.check):
        parser.error("--strict cannot be combined with --quick or --check")
    if args.quick and args.check:
        parser.error("--quick cannot be combined with --check")

    checks = load_manifest()
    for check in checks:
        validate_check(check)
    known_ids = {str(check["id"]) for check in checks}
    unknown_ids = sorted(set(args.check) - known_ids)
    if unknown_ids:
        parser.error(f"unknown check ID(s): {', '.join(unknown_ids)}")
    if args.quick:
        checks = [check for check in checks if check["id"] in QUICK_CHECK_IDS]
    elif args.check:
        selected_ids = set(args.check)
        checks = [check for check in checks if check["id"] in selected_ids]

    if args.list:
        for check in checks:
            print(f"{check['id']}\t{check['strictness']}\t{check['title']}")
        return 0

    configure_swift_environment()
    strict_failures: list[str] = []
    for check in checks:
        strictness = check["strictness"]
        if strictness == "standard" and args.strict:
            continue
        if strictness == "strict" and not args.strict:
            continue
        passed = run(check)
        if passed:
            continue
        if strictness == "strict":
            strict_failures.append(str(check["title"]))
            continue
        return 1

    if args.quick or args.check:
        mode = "quick" if args.quick else "selected"
        print(f"release gate: {mode} checks passed ({len(checks)} checks)")
        return 0

    unchecked = unchecked_checklist_count()
    if args.strict and unchecked:
        strict_failures.append(f"APP_STORE_CHECKLIST.md ({unchecked} unchecked items)")
    if args.strict and strict_failures:
        print(f"release gate: strict mode has {len(strict_failures)} blocker(s):", file=sys.stderr)
        for failure in strict_failures:
            print(f"  - {failure}", file=sys.stderr)
        print("\nrelease gate: remaining external verification targets:", file=sys.stderr)
        subprocess.run(["bash", str(ROOT / "script" / "print_remaining_external_verification.sh")], cwd=ROOT)
        print("\nrelease gate: rerun after recording evidence:\n  ./script/check_release_gate.sh --strict", file=sys.stderr)
        return 1
    print(f"release gate: automated checks passed; unchecked checklist items: {unchecked}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
