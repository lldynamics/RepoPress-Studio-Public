#!/usr/bin/env python3
"""Fail closed on the release gate's quick and tooling selection contracts."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from check_swift_module_boundaries import EXPECTED_PRODUCTION_TARGET_TYPES


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_release_gate.sh"
MANIFEST = ROOT / "script" / "release_checks.json"

EXCLUDED_QUICK_IDS = {
    "typography-tests",
    "build-version-tests",
    "swift-format-lint-tests",
    "swift-safety-tests",
    "swift-module-boundaries-tests",
    "swift-module-build-benchmark-tests",
    "swift-tests-sharding-tests",
    "release-performance-tests",
    "release-performance-trace-tests",
    "ci-quality",
    "swift-strict-build",
}

REQUIRED_QUICK_PRODUCT_IDS = {
    "repository-source-boundary",
    "localization",
    "typography",
    "build-version",
    "swift-format-lint",
    "swift-safety",
    "swift-module-boundaries",
    "swift-tests",
}


def fail(message: str) -> None:
    raise SystemExit(f"release gate selection test: {message}")


def listed_ids(mode: str) -> set[str]:
    completed = subprocess.run(
        [str(GATE), mode, "--list"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        fail(
            f"{mode} list failed ({completed.returncode}): "
            f"{completed.stdout}{completed.stderr}"
        )
    ids: set[str] = set()
    for line in completed.stdout.splitlines():
        fields = line.split("\t", maxsplit=2)
        if len(fields) != 3 or not all(fields):
            fail(f"{mode} list emitted an invalid row: {line!r}")
        check_id = fields[0]
        if check_id in ids:
            fail(f"{mode} list emitted duplicate check: {check_id}")
        ids.add(check_id)
    return ids


def has_test_command(check: dict[str, object]) -> bool:
    command = check["command"]
    if not isinstance(command, list):
        fail(f"manifest command is not a list: {check.get('id')}")
    return any(Path(value).name.startswith("test_") for value in command if isinstance(value, str))


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    checks = manifest.get("checks")
    profiles = manifest.get("profiles")
    if not isinstance(checks, list) or not isinstance(profiles, dict):
        fail("manifest must contain checks and profiles")

    checks_by_id: dict[str, dict[str, object]] = {}
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get("id"), str):
            fail("manifest contains an invalid check")
        check_id = check["id"]
        if check_id in checks_by_id:
            fail(f"manifest contains duplicate check: {check_id}")
        checks_by_id[check_id] = check

    module_boundary_sources = checks_by_id["swift-module-boundaries"].get("source")
    if not isinstance(module_boundary_sources, list):
        fail("swift-module-boundaries sources must be a list")
    expected_module_sources = {
        f"Sources/{target}" for target in EXPECTED_PRODUCTION_TARGET_TYPES
    }
    missing_module_sources = expected_module_sources - set(module_boundary_sources)
    if missing_module_sources:
        fail(
            "swift-module-boundaries source metadata omits governed targets: "
            f"{sorted(missing_module_sources)}"
        )

    profile_ids: set[str] = set()
    for profile_name, ids in profiles.items():
        if not isinstance(profile_name, str) or not isinstance(ids, list):
            fail("manifest contains an invalid profile")
        profile_ids.update(ids)
    unprofiled_ids = set(checks_by_id) - profile_ids
    if unprofiled_ids:
        fail(f"manifest checks missing from profiles: {sorted(unprofiled_ids)}")

    quick_ids = listed_ids("--quick")
    tooling_ids = listed_ids("--tooling")
    expected_quick_ids = {
        check_id
        for check_id, check in checks_by_id.items()
        if "quick" in check.get("groups", []) and check.get("strictness") != "strict"
    }
    expected_tooling_ids = {
        check_id
        for check_id, check in checks_by_id.items()
        if has_test_command(check) and check.get("strictness") != "strict"
    }

    if quick_ids != expected_quick_ids:
        fail(
            "quick selection differs from the manifest: "
            f"missing={sorted(expected_quick_ids - quick_ids)}, "
            f"unexpected={sorted(quick_ids - expected_quick_ids)}"
        )
    if tooling_ids != expected_tooling_ids:
        fail(
            "tooling selection differs from test-command coverage: "
            f"missing={sorted(expected_tooling_ids - tooling_ids)}, "
            f"unexpected={sorted(tooling_ids - expected_tooling_ids)}"
        )
    included_excluded_ids = quick_ids & EXCLUDED_QUICK_IDS
    if included_excluded_ids:
        fail(f"quick selection retains tooling checks: {sorted(included_excluded_ids)}")
    missing_product_ids = REQUIRED_QUICK_PRODUCT_IDS - quick_ids
    if missing_product_ids:
        fail(f"quick selection lost product evidence: {sorted(missing_product_ids)}")
    if "release-gate-selection-tests" not in profiles.get("common", []):
        fail("selection contract test must remain in the common profile")
    if "release-gate-selection-tests" in quick_ids:
        fail("selection contract test must not run in quick mode")
    if "swift-strict-build" not in profiles.get("direct", []):
        fail("targeted strict build must remain available to the direct release profile")
    if "swift-strict-build" in profiles.get("common", []):
        fail("common profile must use swift-tests instead of a duplicate strict build")
    if "swift-tests" not in profiles.get("common", []):
        fail("common profile must retain the authoritative strict test inventory build")
    if "swift-strict-build-tests" not in profiles.get("common", []):
        fail("strict-build contract test must remain in the common tooling profile")

    print(
        "release gate selection test: "
        f"quick={len(quick_ids)} tooling={len(tooling_ids)} profiles={len(profile_ids)} passed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
