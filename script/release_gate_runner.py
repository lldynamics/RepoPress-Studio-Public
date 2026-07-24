#!/usr/bin/env python3
"""Manifest-driven release gate. Shell entrypoints remain compatibility shims."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "script" / "release_checks.json"
DEFAULT_RESULT_JSON = ROOT / ".build" / "release-gate-result.json"
RELEASE_PROFILES = ("app-store", "chrome")
PROFILE_GROUPS = ("common", *RELEASE_PROFILES)


def repository_metadata() -> dict[str, object]:
    try:
        commit = subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        branch = subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--abbrev-ref", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        status = subprocess.check_output(
            ["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=all"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return {"available": False, "commit": None, "branch": None, "isDirty": None}
    return {
        "available": True,
        "commit": commit,
        "branch": branch,
        "isDirty": bool(status.strip()),
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def packaged_artifact_metadata(
    results: list[dict[str, object]],
    strict_profile: str | None,
) -> dict[str, object]:
    verification_check = "ui-launch-verification" if strict_profile else "ui-runtime"
    if verification_status(results, verification_check) != "passed":
        return {"status": "not_verified", "appBundle": None, "files": {}}
    app_bundle = ROOT / "dist" / "PersonalSitePublisherMac.app"
    provenance = "local-package"
    if strict_profile in {"app-store", "all"}:
        explicit_app = os.environ.get("APP_STORE_APP_BUNDLE_PATH", "").strip()
        explicit_archive = os.environ.get("APP_STORE_ARCHIVE_PATH", "").strip()
        if explicit_app:
            app_bundle = Path(explicit_app).expanduser().resolve()
            provenance = "explicit-signed-app"
        elif explicit_archive:
            app_bundle = (
                Path(explicit_archive).expanduser().resolve()
                / "Products"
                / "Applications"
                / "PersonalSitePublisherMac.app"
            )
            provenance = "explicit-xcarchive"
    files = {
        "executable": app_bundle / "Contents" / "MacOS" / "PersonalSitePublisherMac",
        "infoPlist": app_bundle / "Contents" / "Info.plist",
    }
    if not app_bundle.is_dir() or not all(path.is_file() for path in files.values()):
        return {"status": "missing", "appBundle": str(app_bundle), "files": {}}
    return {
        "status": "hashed",
        "appBundle": str(app_bundle),
        "provenance": provenance,
        "verificationCheck": verification_check,
        "files": {
            name: {
                "path": str(path),
                "sha256": sha256(path),
                "sizeBytes": path.stat().st_size,
            }
            for name, path in files.items()
        },
    }


def load_manifest() -> tuple[list[dict[str, object]], dict[str, list[str]]]:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"release gate: cannot load manifest: {error}")
    if data.get("schemaVersion") != 2 or not isinstance(data.get("checks"), list):
        raise SystemExit("release gate: unsupported release_checks.json schema")
    checks = data["checks"]
    ids = [str(check.get("id", "")) for check in checks if isinstance(check, dict)]
    duplicate_ids = sorted({check_id for check_id in ids if ids.count(check_id) > 1})
    if duplicate_ids:
        raise SystemExit(f"release gate: duplicate manifest check ID(s): {', '.join(duplicate_ids)}")
    raw_profiles = data.get("profiles")
    if not isinstance(raw_profiles, dict) or set(raw_profiles) != set(PROFILE_GROUPS):
        raise SystemExit(
            "release gate: profiles must define exactly common, app-store, chrome"
        )
    known_ids = set(ids)
    profile_check_ids: dict[str, list[str]] = {}
    assigned_ids: set[str] = set()
    for profile_name in PROFILE_GROUPS:
        profile_ids = raw_profiles[profile_name]
        if not isinstance(profile_ids, list) or not all(isinstance(value, str) for value in profile_ids):
            raise SystemExit(f"release gate: profile {profile_name} must contain check ID strings")
        if len(profile_ids) != len(set(profile_ids)):
            raise SystemExit(f"release gate: profile {profile_name} contains duplicate check IDs")
        unknown_ids = sorted(set(profile_ids) - known_ids)
        if unknown_ids:
            raise SystemExit(
                f"release gate: profile {profile_name} contains unknown checks: {', '.join(unknown_ids)}"
            )
        profile_check_ids[profile_name] = profile_ids
        assigned_ids.update(profile_ids)
    unassigned_ids = sorted(known_ids - assigned_ids)
    if unassigned_ids:
        raise SystemExit(
            "release gate: every check must belong to at least one profile: "
            + ", ".join(unassigned_ids)
        )
    return checks, profile_check_ids


def validate_check(check: dict[str, object]) -> None:
    required = ("id", "title", "source", "evidence", "strictness", "command")
    missing = [key for key in required if not check.get(key)]
    if missing:
        raise SystemExit(f"release gate: manifest check is missing {', '.join(missing)}: {check}")
    if check["strictness"] not in {"always", "standard", "strict"}:
        raise SystemExit(f"release gate: invalid strictness for {check['id']}")
    if not isinstance(check["command"], list) or not all(isinstance(value, str) for value in check["command"]):
        raise SystemExit(f"release gate: command for {check['id']} must be argv")
    if not isinstance(check["source"], list) or not isinstance(check["evidence"], list):
        raise SystemExit(f"release gate: source and evidence for {check['id']} must be string lists")
    if not all(isinstance(value, str) for value in check["source"]) or not all(
        isinstance(value, str) for value in check["evidence"]
    ):
        raise SystemExit(f"release gate: source and evidence for {check['id']} must be string lists")
    if not isinstance(check.get("environment", {}), dict):
        raise SystemExit(f"release gate: environment for {check['id']} must be an object")
    groups = check.get("groups", [])
    if not isinstance(groups, list) or not all(isinstance(value, str) for value in groups):
        raise SystemExit(f"release gate: groups for {check['id']} must be a string list")
    for value in check["command"]:
        if value.startswith("script/") and not (ROOT / value).is_file():
            raise SystemExit(f"release gate: manifest command path is missing for {check['id']}: {value}")


def argv_for(check: dict[str, object]) -> list[str]:
    return [str(ROOT / value) if value.startswith("script/") else value for value in check["command"]]


def run(check: dict[str, object]) -> dict[str, object]:
    check_id = str(check["id"])
    print(f"release gate [{check_id}]: {check['title']}")
    print(f"  source: {', '.join(check['source'])}")
    print(f"  evidence: {', '.join(check['evidence'])}")
    environment = os.environ.copy()
    environment.update({str(key): str(value) for key, value in dict(check.get("environment", {})).items()})
    started_at = time.monotonic()
    command = argv_for(check)
    execution_error: str | None = None
    try:
        return_code = subprocess.run(command, cwd=ROOT, env=environment).returncode
    except OSError as error:
        return_code = 127
        execution_error = str(error)
    return {
        "id": check_id,
        "title": str(check["title"]),
        "status": "passed" if return_code == 0 else "failed",
        "returnCode": return_code,
        "durationSeconds": round(time.monotonic() - started_at, 3),
        "source": list(check["source"]),
        "evidence": list(check["evidence"]),
        "verificationKind": str(check.get("verificationKind", "automated")),
        "command": command,
        "executionError": execution_error,
    }


def is_tooling_self_test(check: dict[str, object]) -> bool:
    return any(Path(value).name.startswith("test_") for value in check["command"])


def verification_status(results: list[dict[str, object]], check_id: str) -> str:
    result = next((item for item in results if item["id"] == check_id), None)
    return str(result["status"]) if result else "not_run"


def write_result_json(
    path: Path,
    mode: str,
    strict_profile: str | None,
    results: list[dict[str, object]],
    unchecked: int,
    blockers: list[str],
) -> None:
    failures = [item for item in results if item["status"] == "failed"]
    payload = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "mode": mode,
        "profile": strict_profile,
        "repository": repository_metadata(),
        "summary": {
            "status": "failed" if failures or blockers else "passed",
            "checkCount": len(results),
            "passedCount": len(results) - len(failures),
            "failedCount": len(failures),
            "uncheckedChecklistCount": unchecked,
            "blockerCount": len(blockers),
        },
        "blockers": blockers,
        "verification": {
            "packagedArtifact": verification_status(results, "ui-runtime"),
            "realAppLaunch": verification_status(results, "ui-launch-verification"),
        },
        "artifacts": {
            "packagedApp": packaged_artifact_metadata(results, strict_profile),
        },
        "checks": results,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"release gate: result JSON {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


def unchecked_checklist_count() -> int:
    checklist = ROOT / "APP_STORE_CHECKLIST.md"
    if not checklist.exists():
        return 0
    return sum(1 for line in checklist.read_text(encoding="utf-8").splitlines() if line.startswith("- [ ]"))


def configure_swift_environment() -> None:
    runtime_home = os.environ.get("PERSONAL_SITE_PUBLISHER_RUNTIME_HOME") or os.environ.get("HOME")
    if runtime_home:
        os.environ.setdefault("PERSONAL_SITE_PUBLISHER_RUNTIME_HOME", runtime_home)
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
    parser.add_argument(
        "--strict",
        action="store_true",
        help="compatibility alias for --profile all",
    )
    parser.add_argument(
        "--profile",
        choices=(*RELEASE_PROFILES, "all"),
        help="run strict release checks for exactly one distribution channel, or all",
    )
    parser.add_argument("--quick", action="store_true", help="run the core development checks only")
    parser.add_argument("--tooling", action="store_true", help="run release-tooling self-tests only")
    parser.add_argument(
        "--result-json",
        type=Path,
        default=None,
        help="write the gate result JSON (profile runs default to .build/release-gate-<profile>-result.json)",
    )
    parser.add_argument(
        "--check",
        action="append",
        default=[],
        metavar="ID",
        help="run one manifest check by ID; repeat to select multiple checks",
    )
    parser.add_argument("--list", action="store_true", help="print manifest entries without running them")
    args = parser.parse_args()
    if args.strict and args.profile:
        parser.error("--strict and --profile are mutually exclusive")
    strict_profile = args.profile or ("all" if args.strict else None)
    if strict_profile:
        os.environ["RELEASE_GATE_PROFILE"] = strict_profile
    else:
        os.environ.pop("RELEASE_GATE_PROFILE", None)
    if strict_profile and (args.quick or args.tooling or args.check):
        parser.error("strict release profiles cannot be combined with --quick, --tooling, or --check")
    if sum(bool(value) for value in (args.quick, args.tooling, args.check, strict_profile)) > 1:
        parser.error("--quick, --tooling, --check, and strict release profiles are mutually exclusive")

    checks, profile_check_ids = load_manifest()
    for check in checks:
        validate_check(check)
    known_ids = {str(check["id"]) for check in checks}
    unknown_ids = sorted(set(args.check) - known_ids)
    if unknown_ids:
        parser.error(f"unknown check ID(s): {', '.join(unknown_ids)}")
    if args.quick:
        checks = [check for check in checks if "quick" in check.get("groups", [])]
    elif args.tooling:
        checks = [check for check in checks if is_tooling_self_test(check)]
    elif args.check:
        selected_ids = set(args.check)
        checks = [check for check in checks if check["id"] in selected_ids]
    elif strict_profile:
        selected_ids = set(profile_check_ids["common"])
        if strict_profile == "all":
            for profile_name in RELEASE_PROFILES:
                selected_ids.update(profile_check_ids[profile_name])
        else:
            selected_ids.update(profile_check_ids[strict_profile])
        checks = [
            check
            for check in checks
            if check["id"] in selected_ids and not is_tooling_self_test(check)
        ]
    else:
        # Tooling behavior tests have their own path-filtered CI job and remain
        # available through --tooling or an explicit --check. Do not rerun the
        # whole tooling suite during every normal/strict release verification.
        checks = [check for check in checks if not is_tooling_self_test(check)]

    if args.list:
        for check in checks:
            if strict_profile and check["strictness"] == "standard":
                continue
            print(f"{check['id']}\t{check['strictness']}\t{check['title']}")
        return 0

    configure_swift_environment()
    failures: list[str] = []
    results: list[dict[str, object]] = []
    for check in checks:
        strictness = check["strictness"]
        if strictness == "standard" and strict_profile:
            continue
        if strictness == "strict" and not strict_profile:
            continue
        result = run(check)
        results.append(result)
        if result["status"] == "passed":
            continue
        failures.append(str(check["title"]))

    includes_app_store = strict_profile in {"app-store", "all"}
    unchecked = unchecked_checklist_count() if not strict_profile or includes_app_store else 0
    mode = "strict" if strict_profile else "tooling" if args.tooling else "quick" if args.quick else "selected" if args.check else "standard"
    if includes_app_store and unchecked:
        failures.append(f"APP_STORE_CHECKLIST.md ({unchecked} unchecked items)")
    if args.result_json:
        result_json = args.result_json.resolve()
    elif args.profile:
        result_json = ROOT / ".build" / f"release-gate-{args.profile}-result.json"
    else:
        result_json = DEFAULT_RESULT_JSON
    write_result_json(result_json, mode, strict_profile, results, unchecked, failures)

    if args.quick or args.tooling or args.check:
        if failures:
            print(f"release gate: {mode} mode has {len(failures)} failure(s):", file=sys.stderr)
            for failure in failures:
                print(f"  - {failure}", file=sys.stderr)
            return 1
        print(f"release gate: {mode} checks passed ({len(checks)} checks)")
        return 0

    if failures:
        display_mode = "strict mode" if args.strict else f"{strict_profile} profile" if strict_profile else "standard mode"
        label = "blocker(s)" if strict_profile else "failure(s)"
        print(f"release gate: {display_mode} has {len(failures)} {label}:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        if includes_app_store:
            print("\nrelease gate: remaining external verification targets:", file=sys.stderr)
            subprocess.run(["bash", str(ROOT / "script" / "print_remaining_external_verification.sh")], cwd=ROOT)
            rerun = "./script/check_release_gate.sh --strict" if args.strict else f"./script/check_release_gate.sh --profile {strict_profile}"
            print(f"\nrelease gate: rerun after recording evidence:\n  {rerun}", file=sys.stderr)
        return 1
    if strict_profile:
        print(f"release gate: {strict_profile} profile passed ({len(results)} checks)")
        return 0
    print(f"release gate: automated checks passed; unchecked checklist items: {unchecked}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
