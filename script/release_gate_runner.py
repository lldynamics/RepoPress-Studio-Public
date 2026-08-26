#!/usr/bin/env python3
"""Manifest-driven release gate. Shell entrypoints remain compatibility shims."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "script" / "release_checks.json"
DEFAULT_RESULT_JSON = ROOT / ".build" / "release-gate-result.json"
RELEASE_PROFILES = ("direct", "chrome")
PROFILE_GROUPS = ("common", *RELEASE_PROFILES)
RESULT_SCHEMA = ROOT / "script" / "release_gate_result.schema.json"


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


def execution_metadata() -> dict[str, object]:
    try:
        swift_version = subprocess.check_output(
            ["swift", "--version"],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=30,
        ).strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        swift_version = None
    github_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    ci: dict[str, object] = {"provider": "github-actions" if github_actions else None}
    if github_actions:
        ci.update({
            "repository": os.environ.get("GITHUB_REPOSITORY"),
            "workflow": os.environ.get("GITHUB_WORKFLOW"),
            "job": os.environ.get("GITHUB_JOB"),
            "runID": os.environ.get("GITHUB_RUN_ID"),
            "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "ref": os.environ.get("GITHUB_REF"),
            "sha": os.environ.get("GITHUB_SHA"),
        })
    return {
        "toolchain": {
            "pythonVersion": platform.python_version(),
            "swiftVersion": swift_version,
            "operatingSystem": platform.system(),
            "operatingSystemVersion": platform.mac_ver()[0] or platform.release(),
            "architecture": platform.machine(),
        },
        "ci": ci,
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def configured_build_identity() -> dict[str, str | None]:
    path = ROOT / "Packaging" / "BuildVersion.xcconfig"
    values: dict[str, str] = {}
    try:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.split("//", 1)[0].strip()
            match = re.fullmatch(r"(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)", line)
            if match:
                values[match.group(1)] = match.group(2)
    except OSError:
        pass
    return {
        "marketingVersion": values.get("MARKETING_VERSION"),
        "buildNumber": values.get("CURRENT_PROJECT_VERSION"),
    }


def codesign_metadata(app_bundle: Path) -> dict[str, object]:
    codesign = Path("/usr/bin/codesign")
    if not codesign.is_file():
        return {
            "status": "tool_unavailable",
            "codeDirectory": None,
            "cdHash": None,
            "teamIdentifier": None,
            "authorities": [],
            "verified": None,
        }
    try:
        inspection = subprocess.run(
            [str(codesign), "-dv", "--verbose=4", str(app_bundle)],
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        verification = subprocess.run(
            [str(codesign), "--verify", "--deep", "--strict", str(app_bundle)],
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {
            "status": "inspection_failed",
            "codeDirectory": None,
            "cdHash": None,
            "teamIdentifier": None,
            "authorities": [],
            "verified": False,
            "error": str(error),
        }
    output = "\n".join((inspection.stdout, inspection.stderr))

    def first_value(prefix: str) -> str | None:
        return next(
            (line[len(prefix) :] for line in output.splitlines() if line.startswith(prefix)),
            None,
        )

    code_directory = next(
        (line for line in output.splitlines() if line.startswith("CodeDirectory ")),
        None,
    )
    authorities = [
        line[len("Authority=") :]
        for line in output.splitlines()
        if line.startswith("Authority=")
    ]
    return {
        "status": "inspected" if inspection.returncode == 0 else "inspection_failed",
        "codeDirectory": code_directory,
        "cdHash": first_value("CDHash="),
        "teamIdentifier": first_value("TeamIdentifier="),
        "authorities": authorities,
        "verified": verification.returncode == 0,
        "inspectionReturnCode": inspection.returncode,
        "verificationReturnCode": verification.returncode,
    }


def bundle_entries(app_bundle: Path) -> tuple[list[dict[str, object]], str, int]:
    entries: list[dict[str, object]] = []
    total_size = 0
    for path in sorted(app_bundle.rglob("*"), key=lambda value: value.relative_to(app_bundle).as_posix()):
        relative = path.relative_to(app_bundle).as_posix()
        if path.is_symlink():
            target = os.readlink(path)
            encoded_target = target.encode("utf-8")
            entries.append(
                {
                    "path": relative,
                    "kind": "symlink",
                    "target": target,
                    "sha256": hashlib.sha256(encoded_target).hexdigest(),
                    "sizeBytes": len(encoded_target),
                }
            )
            total_size += len(encoded_target)
        elif path.is_file():
            size = path.stat().st_size
            entries.append(
                {
                    "path": relative,
                    "kind": "file",
                    "sha256": sha256(path),
                    "sizeBytes": size,
                }
            )
            total_size += size
    canonical = json.dumps(entries, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return entries, hashlib.sha256(canonical).hexdigest(), total_size


def packaged_artifact_metadata(
    results: list[dict[str, object]],
    strict_profile: str | None,
    repository: dict[str, object],
    observed_at: str,
) -> dict[str, object]:
    verification_check = (
        "direct-release-notarization-readiness"
        if strict_profile == "direct"
        else "ui-launch-verification"
        if strict_profile
        else "ui-runtime"
    )
    if verification_status(results, verification_check) != "passed":
        return {
            "status": "not_verified",
            "appBundle": None,
            "identity": None,
            "codeSignature": None,
            "content": None,
        }
    app_bundle = ROOT / "dist" / "PersonalSitePublisherMac.app"
    provenance = "local-package"
    if strict_profile == "direct":
        explicit_app = os.environ.get("DIRECT_DISTRIBUTION_APP_BUNDLE_PATH", "").strip()
        if explicit_app:
            app_bundle = Path(explicit_app).expanduser().resolve()
            provenance = "explicit-developer-id-app"
    files = {
        "executable": app_bundle / "Contents" / "MacOS" / "PersonalSitePublisherMac",
        "infoPlist": app_bundle / "Contents" / "Info.plist",
    }
    if not app_bundle.is_dir() or not all(path.is_file() for path in files.values()):
        return {
            "status": "missing",
            "appBundle": str(app_bundle),
            "identity": None,
            "codeSignature": None,
            "content": None,
        }
    try:
        info = plistlib.loads(files["infoPlist"].read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return {
            "status": "invalid_info_plist",
            "appBundle": str(app_bundle),
            "identity": None,
            "codeSignature": codesign_metadata(app_bundle),
            "content": None,
            "error": str(error),
        }
    configured = configured_build_identity()
    packaged_version = str(info.get("CFBundleShortVersionString", "")).strip() or None
    packaged_build = str(info.get("CFBundleVersion", "")).strip() or None
    entries, tree_sha256, total_size = bundle_entries(app_bundle)
    return {
        "status": "hashed",
        "appBundle": str(app_bundle),
        "provenance": provenance,
        "verificationCheck": verification_check,
        "observedAt": observed_at,
        "identity": {
            "marketingVersion": packaged_version,
            "buildNumber": packaged_build,
            "configuredMarketingVersion": configured["marketingVersion"],
            "configuredBuildNumber": configured["buildNumber"],
            "versionMatchesConfiguration": packaged_version == configured["marketingVersion"],
            "buildMatchesConfiguration": packaged_build == configured["buildNumber"],
            "sourceCommit": repository.get("commit"),
            "sourceDirty": repository.get("isDirty"),
        },
        "codeSignature": codesign_metadata(app_bundle),
        "content": {
            "algorithm": "sha256",
            "treeSha256": tree_sha256,
            "entryCount": len(entries),
            "totalSizeBytes": total_size,
            "entries": entries,
        },
    }


def load_manifest() -> tuple[list[dict[str, object]], dict[str, list[str]], int]:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"release gate: cannot load manifest: {error}")
    if data.get("schemaVersion") != 2 or not isinstance(data.get("checks"), list):
        raise SystemExit("release gate: unsupported release_checks.json schema")
    default_timeout = data.get("defaultTimeoutSeconds")
    if (
        not isinstance(default_timeout, int)
        or isinstance(default_timeout, bool)
        or default_timeout <= 0
    ):
        raise SystemExit("release gate: manifest requires a positive defaultTimeoutSeconds")
    checks = data["checks"]
    ids = [str(check.get("id", "")) for check in checks if isinstance(check, dict)]
    duplicate_ids = sorted({check_id for check_id in ids if ids.count(check_id) > 1})
    if duplicate_ids:
        raise SystemExit(f"release gate: duplicate manifest check ID(s): {', '.join(duplicate_ids)}")
    raw_profiles = data.get("profiles")
    if not isinstance(raw_profiles, dict) or set(raw_profiles) != set(PROFILE_GROUPS):
        raise SystemExit(
            "release gate: profiles must define exactly common, direct, chrome"
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
    return checks, profile_check_ids, default_timeout


def validate_check(check: dict[str, object], default_timeout: int) -> None:
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
    timeout_seconds = check.get("timeoutSeconds", default_timeout)
    if (
        not isinstance(timeout_seconds, int)
        or isinstance(timeout_seconds, bool)
        or timeout_seconds <= 0
    ):
        raise SystemExit(f"release gate: timeoutSeconds for {check['id']} must be a positive integer")


def argv_for(check: dict[str, object]) -> list[str]:
    return [str(ROOT / value) if value.startswith("script/") else value for value in check["command"]]


def run(check: dict[str, object], default_timeout: int) -> dict[str, object]:
    check_id = str(check["id"])
    print(f"release gate [{check_id}]: {check['title']}")
    print(f"  source: {', '.join(check['source'])}")
    print(f"  evidence: {', '.join(check['evidence'])}")
    environment = os.environ.copy()
    environment.update({str(key): str(value) for key, value in dict(check.get("environment", {})).items()})
    started_at = time.monotonic()
    command = argv_for(check)
    timeout_seconds = int(check.get("timeoutSeconds", default_timeout))
    execution_error: str | None = None
    status = "failed"
    try:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=environment,
            start_new_session=True,
        )
        try:
            return_code = process.wait(timeout=timeout_seconds)
            status = "passed" if return_code == 0 else "failed"
        except subprocess.TimeoutExpired:
            status = "timed_out"
            return_code = 124
            execution_error = f"timed out after {timeout_seconds} seconds"
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    pass
                process.wait()
    except OSError as error:
        return_code = 127
        execution_error = str(error)
    return {
        "id": check_id,
        "title": str(check["title"]),
        "status": status,
        "returnCode": return_code,
        "timeoutSeconds": timeout_seconds,
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
    *,
    repository: dict[str, object],
    execution: dict[str, object],
    run_started_at: str,
    run_state: str,
    expected_check_count: int,
    active_check: dict[str, object] | None = None,
) -> dict[str, object]:
    failures = [item for item in results if item["status"] != "passed"]
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    configured = configured_build_identity()
    complete = run_state == "complete"
    payload = {
        "$schema": "script/release_gate_result.schema.json",
        "schemaVersion": 2,
        "runState": run_state,
        "startedAt": run_started_at,
        "generatedAt": observed_at,
        "mode": mode,
        "profile": strict_profile,
        "repository": repository,
        "releaseIdentity": {
            "marketingVersion": configured["marketingVersion"],
            "buildNumber": configured["buildNumber"],
            "sourceCommit": repository.get("commit"),
            "sourceDirty": repository.get("isDirty"),
            "observedAt": observed_at,
        },
        "execution": execution,
        "summary": {
            "status": (
                "running"
                if not complete
                else "failed"
                if failures or blockers
                else "passed"
            ),
            "expectedCheckCount": expected_check_count,
            "completedCheckCount": len(results),
            "checkCount": len(results),
            "passedCount": len(results) - len(failures),
            "failedCount": len(failures),
            "uncheckedChecklistCount": unchecked,
            "blockerCount": len(blockers),
        },
        "blockers": blockers,
        "activeCheck": active_check,
        "verification": {
            "packagedArtifact": verification_status(results, "ui-runtime"),
            "realAppLaunch": verification_status(results, "ui-launch-verification"),
        },
        "artifacts": {
            "packagedApp": (
                packaged_artifact_metadata(results, strict_profile, repository, observed_at)
                if complete
                else {
                    "status": "pending",
                    "appBundle": None,
                    "identity": None,
                    "codeSignature": None,
                    "content": None,
                }
            ),
        },
        "checks": results,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".partial",
        delete=False,
    ) as handle:
        temporary_path = Path(handle.name)
        handle.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary_path.replace(path)
    label = "partial result JSON" if not complete else "result JSON"
    print(f"release gate: {label} {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")
    return payload


def markdown_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def write_result_markdown(path: Path, payload: dict[str, object]) -> None:
    summary = dict(payload["summary"])
    repository = dict(payload["repository"])
    execution = dict(payload["execution"])
    toolchain = dict(execution["toolchain"])
    profile = payload.get("profile") or "none"
    commit = repository.get("commit")
    commit_label = str(commit)[:12] if commit else "unavailable"
    lines = [
        "# Release Gate Summary",
        "",
        f"- Status: **{str(summary['status']).upper()}**",
        f"- Mode: `{payload['mode']}`",
        f"- Profile: `{profile}`",
        f"- Commit: `{commit_label}`",
        f"- Branch: `{repository.get('branch') or 'unavailable'}`",
        f"- Dirty worktree: `{repository.get('isDirty')}`",
        f"- Swift: `{markdown_cell(toolchain.get('swiftVersion') or 'unavailable')}`",
        (
            "- Checks: "
            f"`{summary['passedCount']}/{summary['checkCount']}` passed, "
            f"`{summary['failedCount']}` failed"
        ),
        "",
    ]
    blockers = list(payload["blockers"])
    if blockers:
        lines.extend(["## Blockers", ""])
        lines.extend(f"- {blocker}" for blocker in blockers)
        lines.append("")
    lines.extend([
        "## Checks",
        "",
        "| Check | Status | Duration |",
        "| --- | --- | ---: |",
    ])
    for check in list(payload["checks"]):
        lines.append(
            f"| {markdown_cell(check['title'])} | "
            f"{str(check['status']).upper()} | "
            f"{check['durationSeconds']}s |"
        )
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")
    print(
        "release gate: Markdown summary "
        f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}"
    )


def configure_swift_environment() -> None:
    runtime_home = os.environ.get("PERSONAL_SITE_PUBLISHER_RUNTIME_HOME") or os.environ.get("HOME")
    if runtime_home:
        os.environ.setdefault("PERSONAL_SITE_PUBLISHER_RUNTIME_HOME", runtime_home)
    swift_build_home_env = os.environ.get("SWIFT_BUILD_HOME")
    if swift_build_home_env:
        home = Path(swift_build_home_env)
    else:
        tmpdir = os.environ.get("TMPDIR")
        candidates = []
        if tmpdir:
            candidates.append(Path(tmpdir) / "personal-site-publisher-swift-home")
        candidates.append(Path("/private/tmp/personal-site-publisher-swift-home"))
        candidates.append(ROOT / ".build/tmp/swift-home")

        home = ROOT / ".build/tmp/swift-home"
        for cand in candidates:
            try:
                cand.mkdir(parents=True, exist_ok=True)
                test_file = cand / f".write_test_{os.getpid()}"
                test_file.write_text("ok", encoding="utf-8")
                test_file.unlink(missing_ok=True)
                home = cand
                break
            except OSError:
                continue

    os.environ["HOME"] = str(home)
    os.environ["SWIFT_BUILD_HOME"] = str(home)
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
        try:
            directory.mkdir(parents=True, exist_ok=True)
        except OSError:
            pass


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
        "--summary-markdown",
        type=Path,
        default=None,
        help="write a human-readable Markdown summary for CI and release review",
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

    checks, profile_check_ids, default_timeout = load_manifest()
    for check in checks:
        validate_check(check, default_timeout)
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

    if not args.check:
        checks = [
            check
            for check in checks
            if not (check["strictness"] == "strict" and not strict_profile)
        ]
    if args.list:
        for check in checks:
            print(f"{check['id']}\t{check['strictness']}\t{check['title']}")
        return 0
    mode = (
        "strict"
        if strict_profile
        else "tooling"
        if args.tooling
        else "quick"
        if args.quick
        else "selected"
        if args.check
        else "standard"
    )
    if args.result_json:
        result_json = args.result_json.resolve()
    elif args.profile:
        result_json = ROOT / ".build" / f"release-gate-{args.profile}-result.json"
    else:
        result_json = DEFAULT_RESULT_JSON
    run_started_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    repository = repository_metadata()
    execution = execution_metadata()
    configure_swift_environment()
    failures: list[str] = []
    results: list[dict[str, object]] = []
    write_result_json(
        result_json,
        mode,
        strict_profile,
        results,
        0,
        failures,
        repository=repository,
        execution=execution,
        run_started_at=run_started_at,
        run_state="partial",
        expected_check_count=len(checks),
    )
    for check in checks:
        write_result_json(
            result_json,
            mode,
            strict_profile,
            results,
            0,
            failures,
            repository=repository,
            execution=execution,
            run_started_at=run_started_at,
            run_state="partial",
            expected_check_count=len(checks),
            active_check={
                "id": str(check["id"]),
                "title": str(check["title"]),
                "timeoutSeconds": int(check.get("timeoutSeconds", default_timeout)),
            },
        )
        result = run(check, default_timeout)
        results.append(result)
        if result["status"] == "passed":
            pass
        else:
            failures.append(str(check["title"]))
        write_result_json(
            result_json,
            mode,
            strict_profile,
            results,
            0,
            failures,
            repository=repository,
            execution=execution,
            run_started_at=run_started_at,
            run_state="partial",
            expected_check_count=len(checks),
        )

    unchecked = 0
    payload = write_result_json(
        result_json,
        mode,
        strict_profile,
        results,
        unchecked,
        failures,
        repository=repository,
        execution=execution,
        run_started_at=run_started_at,
        run_state="complete",
        expected_check_count=len(checks),
    )
    if args.summary_markdown:
        write_result_markdown(args.summary_markdown.resolve(), payload)

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
        return 1
    if strict_profile:
        print(f"release gate: {strict_profile} profile passed ({len(results)} checks)")
        return 0
    print("release gate: automated checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
