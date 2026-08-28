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
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "script" / "release_checks.json"
DEFAULT_RESULT_JSON = ROOT / ".build" / "release-gate-result.json"
RELEASE_PROFILES = ("direct", "chrome")
PROFILE_GROUPS = ("common", *RELEASE_PROFILES)
RESULT_SCHEMA = ROOT / "script" / "release_gate_result.schema.json"
MAX_FAILURE_LOG_BYTES = 64 * 1024
FAILURE_LOG_TAIL_CHARACTERS = 4 * 1024
SENSITIVE_ENVIRONMENT_KEY = re.compile(
    r"(?:^|_)(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|AUTH|"
    r"CREDENTIALS?|COOKIE|SESSION|JWT|DSN|CONNECTION_STRING)(?:_|$)",
    re.IGNORECASE,
)

# The user-facing bundle name is the packaging contract. Keep the executable
# name and bundle identifier independently configurable for fixture builds,
# while making artifact discovery reject the historical executable-named
# bundle path instead of silently recording the wrong artifact.
APP_BUNDLE_NAME = os.environ.get("PERSONAL_SITE_PUBLISHER_BUNDLE_NAME", "RepoPress Studio")
APP_EXECUTABLE_NAME = os.environ.get("PERSONAL_SITE_PUBLISHER_APP_NAME", "PersonalSitePublisherMac")
APP_BUNDLE_IDENTIFIER = os.environ.get(
    "PERSONAL_SITE_PUBLISHER_BUNDLE_ID", "com.jinfang.PersonalSitePublisherMac"
)


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


def evidence_path(path: Path) -> str:
    """Return a stable evidence path without exposing local absolute paths."""
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return f"<external-result-dir>/{path.name}"


def redact_diagnostic_text(value: str, environment: dict[str, str]) -> str:
    """Remove ambient secrets and machine paths before output becomes evidence."""
    redacted = value
    for secret in sorted(
        {
            item
            for key, item in environment.items()
            if len(item) >= 4 and SENSITIVE_ENVIRONMENT_KEY.search(key)
        },
        key=len,
        reverse=True,
    ):
        redacted = redacted.replace(secret, "<redacted-env>")
    redacted = re.sub(
        r"(?i)\b(bearer\s+|token\s*[=:]\s*|api[_-]?key\s*[=:]\s*|"
        r"secret\s*[=:]\s*|password\s*[=:]\s*)([^\s,;]+)",
        r"\1<redacted>",
        redacted,
    )
    redacted = re.sub(
        r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
        r"sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
        r"AKIA[0-9A-Z]{16})\b",
        "<redacted-token>",
        redacted,
    )
    redacted = re.sub(r"(?<!\w)/(?:Users|home)/[^/\s]+", "<redacted-home>", redacted)
    redacted = re.sub(
        r"(?<!\w)/(?:private/)?tmp(?:/[^/\s]+)*|"
        r"(?<!\w)/var/folders/[^/\s]+(?:/[^/\s]+)*",
        "<redacted-temp>",
        redacted,
    )
    return redacted


class RedactedOutputCapture:
    """Streams safe command output while retaining bounded failure evidence."""

    def __init__(self, environment: dict[str, str]) -> None:
        self.environment = environment
        self.parts: list[str] = []
        self.tail = ""
        self.captured_bytes = 0
        self.truncated = False

    def consume(self, value: str) -> None:
        safe_value = redact_diagnostic_text(value, self.environment)
        sys.stdout.write(safe_value)
        sys.stdout.flush()
        encoded = safe_value.encode("utf-8", errors="replace")
        remaining = MAX_FAILURE_LOG_BYTES - self.captured_bytes
        if remaining > 0:
            retained = encoded[:remaining].decode("utf-8", errors="ignore")
            self.parts.append(retained)
            self.captured_bytes += len(retained.encode("utf-8"))
        if len(encoded) > max(remaining, 0):
            self.truncated = True
        self.tail = (self.tail + safe_value)[-FAILURE_LOG_TAIL_CHARACTERS:]

    def persist(self, diagnostics_directory: Path, check_id: str) -> dict[str, object]:
        diagnostics_directory.mkdir(parents=True, exist_ok=True)
        safe_id = re.sub(r"[^A-Za-z0-9._-]+", "-", check_id).strip("-") or "check"
        log_path = diagnostics_directory / f"{safe_id}.log"
        content = "".join(self.parts)
        if self.truncated:
            content += "\n[release gate output truncated]\n"
        atomic_write_text(log_path, content)
        return {
            "logPath": evidence_path(log_path),
            "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            "truncated": self.truncated,
            "capturedBytes": self.captured_bytes,
            "tail": self.tail,
        }


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


def packaged_app_candidates(strict_profile: str | None) -> tuple[Path, list[Path]]:
    """Return the expected app path and all app bundles in the output scope.

    The build script is the producer of the user-facing ``RepoPress Studio``
    bundle. Artifact evidence must not fall back to the old executable-named
    path: if that path is all that exists, it is reported as an identity
    mismatch instead of being silently accepted.
    """
    if strict_profile == "direct":
        output_root = ROOT / "dist" / "direct"
        expected = output_root / f"{APP_BUNDLE_NAME}.app"
        candidates = sorted(
            (
                path
                for path in output_root.rglob(f"{APP_BUNDLE_NAME}.app")
                if path.is_dir()
            ),
            key=lambda value: value.as_posix(),
        ) if output_root.is_dir() else []
        if expected.is_dir() and expected not in candidates:
            candidates.insert(0, expected)
        if not candidates and output_root.is_dir():
            candidates = sorted(
                (path for path in output_root.rglob("*.app") if path.is_dir()),
                key=lambda value: value.as_posix(),
            )
        return expected, candidates

    output_root = ROOT / "dist"
    expected = output_root / f"{APP_BUNDLE_NAME}.app"
    candidates = sorted(
        (path for path in output_root.glob("*.app") if path.is_dir()),
        key=lambda value: value.as_posix(),
    ) if output_root.is_dir() else []
    return expected, candidates


def artifact_failure(
    app_bundle: Path,
    status: str,
    *,
    expected_bundle: Path | None = None,
    provenance: str = "local-package",
    error: str | None = None,
) -> dict[str, object]:
    result: dict[str, object] = {
        "status": status,
        "appBundle": str(app_bundle) if app_bundle else None,
        "expectedAppBundle": str(expected_bundle) if expected_bundle else None,
        "provenance": provenance,
        "identity": None,
        "codeSignature": None,
        "content": None,
    }
    if error:
        result["error"] = error
    return result


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
    expected_bundle, candidates = packaged_app_candidates(strict_profile)
    app_bundle = expected_bundle
    provenance = "local-package"
    if strict_profile == "direct":
        explicit_app = os.environ.get("DIRECT_DISTRIBUTION_APP_BUNDLE_PATH", "").strip()
        if explicit_app:
            app_bundle = Path(explicit_app).expanduser().resolve()
            provenance = "explicit-developer-id-app"
    elif len(candidates) == 1:
        app_bundle = candidates[0]
    elif len(candidates) > 1:
        return artifact_failure(
            expected_bundle,
            "ambiguous",
            expected_bundle=expected_bundle,
            provenance=provenance,
            error="multiple app bundles were found in the packaging output",
        )

    if strict_profile == "direct" and not os.environ.get("DIRECT_DISTRIBUTION_APP_BUNDLE_PATH", "").strip():
        if len(candidates) > 1:
            return artifact_failure(
                expected_bundle,
                "ambiguous",
                expected_bundle=expected_bundle,
                provenance=provenance,
                error="multiple direct-release app bundles were found in the packaging output",
            )
        if len(candidates) == 1:
            app_bundle = candidates[0]

    files = {
        "executable": app_bundle / "Contents" / "MacOS" / APP_EXECUTABLE_NAME,
        "infoPlist": app_bundle / "Contents" / "Info.plist",
    }
    if not app_bundle.is_dir():
        status = "missing" if not candidates else "identity_mismatch"
        return artifact_failure(
            app_bundle,
            status,
            expected_bundle=expected_bundle,
            provenance=provenance,
            error="expected app bundle is missing" if status == "missing" else "app bundle path does not match the packaging contract",
        )
    if not all(path.is_file() for path in files.values()):
        return artifact_failure(
            app_bundle,
            "unhashable",
            expected_bundle=expected_bundle,
            provenance=provenance,
            error="app bundle is missing a required Info.plist or executable",
        )
    try:
        info = plistlib.loads(files["infoPlist"].read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return artifact_failure(
            app_bundle,
            "unhashable",
            expected_bundle=expected_bundle,
            provenance=provenance,
            error=f"Info.plist could not be read: {error}",
        )
    configured = configured_build_identity()
    packaged_version = str(info.get("CFBundleShortVersionString", "")).strip() or None
    packaged_build = str(info.get("CFBundleVersion", "")).strip() or None
    identity = {
        "bundleName": str(info.get("CFBundleName", "")).strip() or None,
        "displayName": str(info.get("CFBundleDisplayName", "")).strip() or None,
        "executableName": str(info.get("CFBundleExecutable", "")).strip() or None,
        "bundleIdentifier": str(info.get("CFBundleIdentifier", "")).strip() or None,
        "expectedBundleName": APP_BUNDLE_NAME,
        "expectedExecutableName": APP_EXECUTABLE_NAME,
        "expectedBundleIdentifier": APP_BUNDLE_IDENTIFIER,
        "marketingVersion": packaged_version,
        "buildNumber": packaged_build,
        "configuredMarketingVersion": configured["marketingVersion"],
        "configuredBuildNumber": configured["buildNumber"],
        "versionMatchesConfiguration": packaged_version == configured["marketingVersion"],
        "buildMatchesConfiguration": packaged_build == configured["buildNumber"],
        "sourceCommit": repository.get("commit"),
        "sourceDirty": repository.get("isDirty"),
    }
    identity_matches = (
        app_bundle.name == f"{APP_BUNDLE_NAME}.app"
        and identity["bundleName"] == APP_BUNDLE_NAME
        and identity["displayName"] == APP_BUNDLE_NAME
        and identity["executableName"] == APP_EXECUTABLE_NAME
        and identity["bundleIdentifier"] == APP_BUNDLE_IDENTIFIER
        and identity["versionMatchesConfiguration"] is True
        and identity["buildMatchesConfiguration"] is True
    )
    if not identity_matches:
        return {
            "status": "identity_mismatch",
            "appBundle": str(app_bundle),
            "expectedAppBundle": str(expected_bundle),
            "provenance": provenance,
            "verificationCheck": verification_check,
            "observedAt": observed_at,
            "identity": identity,
            "codeSignature": codesign_metadata(app_bundle),
            "content": None,
            "error": "app bundle identity does not match the configured release identity",
        }
    try:
        entries, tree_sha256, total_size = bundle_entries(app_bundle)
    except (OSError, PermissionError, ValueError) as error:
        return artifact_failure(
            app_bundle,
            "unhashable",
            expected_bundle=expected_bundle,
            provenance=provenance,
            error=f"app bundle contents could not be hashed: {error}",
        )
    return {
        "status": "hashed",
        "appBundle": str(app_bundle),
        "expectedAppBundle": str(expected_bundle),
        "provenance": provenance,
        "verificationCheck": verification_check,
        "observedAt": observed_at,
        "identity": identity,
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
    if not isinstance(check["id"], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", check["id"]):
        raise SystemExit("release gate: manifest check ID must be a bounded identifier")
    if not isinstance(check["title"], str):
        raise SystemExit(f"release gate: title for {check['id']} must be a string")
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


def run(
    check: dict[str, object],
    default_timeout: int,
    diagnostics_directory: Path,
) -> dict[str, object]:
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
    output = RedactedOutputCapture(environment)
    process: subprocess.Popen[str] | None = None
    reader: threading.Thread | None = None

    def stream_output() -> None:
        assert process is not None and process.stdout is not None
        for line in process.stdout:
            output.consume(line)

    try:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=environment,
            start_new_session=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        reader = threading.Thread(target=stream_output, name=f"release-gate-{check_id}", daemon=True)
        reader.start()
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
        execution_error = redact_diagnostic_text(str(error), environment)
    finally:
        if reader:
            reader.join(timeout=5)
        if process and process.stdout:
            process.stdout.close()
    if execution_error:
        output.consume(f"release gate: {execution_error}\n")
    diagnostics = (
        None
        if status == "passed"
        else output.persist(diagnostics_directory, check_id)
    )
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
        "command": [redact_diagnostic_text(value, environment) for value in command],
        "executionError": execution_error,
        "diagnostics": diagnostics,
    }


def is_tooling_self_test(check: dict[str, object]) -> bool:
    return any(Path(value).name.startswith("test_") for value in check["command"])


def verification_status(results: list[dict[str, object]], check_id: str) -> str:
    result = next((item for item in results if item["id"] == check_id), None)
    return str(result["status"]) if result else "not_run"


def packaged_artifact_blockers(artifact: dict[str, object]) -> list[str]:
    """Turn artifact evidence gaps into final-gate blockers.

    ``not_verified`` means the package-producing check did not run or already
    failed, so its check result remains the primary diagnostic. Once that
    check passes, every missing, ambiguous, mismatched, or unhashed artifact
    must block the run rather than being recorded as advisory metadata.
    """
    status = str(artifact.get("status", "unknown"))
    if status == "not_verified":
        return []
    if status == "missing":
        return [
            "Packaged app artifact is missing: "
            + str(artifact.get("expectedAppBundle") or artifact.get("appBundle") or "unknown path")
        ]
    if status == "ambiguous":
        return [
            "Packaged app artifact is ambiguous: "
            + str(artifact.get("error") or "multiple app bundles matched the packaging scope")
        ]
    if status == "identity_mismatch":
        return [
            "Packaged app identity mismatch: "
            + str(artifact.get("error") or "bundle identity does not match the release contract")
        ]
    if status == "unhashable":
        return [
            "Packaged app artifact is not hashable: "
            + str(artifact.get("error") or "bundle contents could not be read")
        ]
    if status != "hashed":
        return [f"Packaged app artifact has unsupported evidence status: {status}"]

    identity = artifact.get("identity")
    if not isinstance(identity, dict):
        return ["Packaged app artifact is missing identity evidence"]
    if not identity.get("versionMatchesConfiguration") or not identity.get("buildMatchesConfiguration"):
        return ["Packaged app version/build identity does not match Packaging/BuildVersion.xcconfig"]
    content = artifact.get("content")
    if not isinstance(content, dict) or not content.get("treeSha256"):
        return ["Packaged app artifact is missing a content SHA-256"]
    return []


def require_exact_keys(value: object, keys: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError(f"{label} must contain exactly: {', '.join(sorted(keys))}")
    return value


def require_string(value: object, label: str, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{label} must be {'a string or null' if nullable else 'a string'}")
    return value


def require_integer(value: object, label: str, *, minimum: int | None = None) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{label} must be an integer")
    if minimum is not None and value < minimum:
        raise ValueError(f"{label} must be at least {minimum}")
    return value


def require_datetime(value: object, label: str) -> datetime:
    text = require_string(value, label)
    assert text is not None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{label} must be an RFC 3339 date-time") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{label} must include a timezone")
    return parsed


def require_string_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{label} must be a string array")
    return value


def validate_diagnostics(value: object) -> None:
    if value is None:
        return
    diagnostic = require_exact_keys(
        value,
        {"logPath", "sha256", "truncated", "capturedBytes", "tail"},
        "check diagnostics",
    )
    log_path = require_string(diagnostic["logPath"], "check diagnostics.logPath")
    assert log_path is not None
    if log_path.startswith("/") or ".." in Path(log_path).parts:
        raise ValueError("check diagnostics.logPath must be a relative safe evidence path")
    digest = require_string(diagnostic["sha256"], "check diagnostics.sha256")
    if not re.fullmatch(r"[0-9a-f]{64}", digest or ""):
        raise ValueError("check diagnostics.sha256 must be a SHA-256 digest")
    if not isinstance(diagnostic["truncated"], bool):
        raise ValueError("check diagnostics.truncated must be a boolean")
    require_integer(diagnostic["capturedBytes"], "check diagnostics.capturedBytes", minimum=0)
    require_string(diagnostic["tail"], "check diagnostics.tail")


def validate_code_signature(value: object) -> None:
    if not isinstance(value, dict):
        raise ValueError("packaged app.codeSignature must be an object")
    if value.get("status") == "tool_unavailable":
        keys = {"status", "codeDirectory", "cdHash", "teamIdentifier", "authorities", "verified"}
    elif "error" in value:
        keys = {
            "status", "codeDirectory", "cdHash", "teamIdentifier",
            "authorities", "verified", "error",
        }
    else:
        keys = {
            "status", "codeDirectory", "cdHash", "teamIdentifier",
            "authorities", "verified", "inspectionReturnCode", "verificationReturnCode",
        }
    signature = require_exact_keys(value, keys, "packaged app.codeSignature")
    if signature["status"] not in {"tool_unavailable", "inspected", "inspection_failed"}:
        raise ValueError("packaged app.codeSignature has an unsupported status")
    for key in ("codeDirectory", "cdHash", "teamIdentifier"):
        require_string(signature[key], f"packaged app.codeSignature.{key}", nullable=True)
    require_string_list(signature["authorities"], "packaged app.codeSignature.authorities")
    if signature["verified"] is not None and not isinstance(signature["verified"], bool):
        raise ValueError("packaged app.codeSignature.verified must be a boolean or null")
    if "inspectionReturnCode" in signature:
        require_integer(signature["inspectionReturnCode"], "packaged app.codeSignature.inspectionReturnCode")
        require_integer(signature["verificationReturnCode"], "packaged app.codeSignature.verificationReturnCode")
    if "error" in signature:
        require_string(signature["error"], "packaged app.codeSignature.error")


def validate_check_result(value: object) -> None:
    check = require_exact_keys(
        value,
        {
            "id", "title", "status", "returnCode", "timeoutSeconds",
            "durationSeconds", "source", "evidence", "verificationKind",
            "command", "executionError", "diagnostics",
        },
        "check result",
    )
    check_id = require_string(check["id"], "check result.id")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", check_id or ""):
        raise ValueError("check result.id must be a bounded identifier")
    require_string(check["title"], "check result.title")
    status = require_string(check["status"], "check result.status")
    if status not in {"passed", "failed", "timed_out"}:
        raise ValueError("check result.status is unsupported")
    return_code = require_integer(check["returnCode"], "check result.returnCode")
    require_integer(check["timeoutSeconds"], "check result.timeoutSeconds", minimum=1)
    if not isinstance(check["durationSeconds"], (int, float)) or isinstance(check["durationSeconds"], bool):
        raise ValueError("check result.durationSeconds must be numeric")
    if check["durationSeconds"] < 0:
        raise ValueError("check result.durationSeconds must not be negative")
    require_string_list(check["source"], "check result.source")
    require_string_list(check["evidence"], "check result.evidence")
    require_string(check["verificationKind"], "check result.verificationKind")
    require_string_list(check["command"], "check result.command")
    require_string(check["executionError"], "check result.executionError", nullable=True)
    validate_diagnostics(check["diagnostics"])
    if status == "passed":
        if return_code != 0 or check["executionError"] is not None or check["diagnostics"] is not None:
            raise ValueError("a passed check cannot carry failure evidence")
    elif status == "timed_out":
        if return_code != 124 or not isinstance(check["executionError"], str) or check["diagnostics"] is None:
            raise ValueError("a timed out check requires code 124 and failure diagnostics")
    elif return_code == 0 or check["diagnostics"] is None:
        raise ValueError("a failed check requires a nonzero return code and diagnostics")


def validate_packaged_artifact(value: object, run_state: str) -> None:
    artifact = require_exact_keys(value, {"packagedApp"}, "artifacts")
    packaged = artifact["packagedApp"]
    if not isinstance(packaged, dict):
        raise ValueError("artifacts.packagedApp must be an object")
    status = packaged.get("status")
    pending_keys = {"status", "appBundle", "identity", "codeSignature", "content"}
    if status in {"pending", "not_verified"}:
        require_exact_keys(packaged, pending_keys, "pending packaged app")
        if run_state == "complete" and status == "pending":
            raise ValueError("a complete result cannot contain a pending packaged app")
        if any(packaged[key] is not None for key in pending_keys - {"status"}):
            raise ValueError("a pending packaged app cannot contain artifact evidence")
        return
    failure_keys = {
        "status", "appBundle", "expectedAppBundle", "provenance",
        "identity", "codeSignature", "content", "error",
    }
    if status in {"missing", "ambiguous", "unhashable"}:
        require_exact_keys(packaged, failure_keys, "failed packaged app")
        require_string(packaged["appBundle"], "failed packaged app.appBundle", nullable=True)
        require_string(packaged["expectedAppBundle"], "failed packaged app.expectedAppBundle", nullable=True)
        require_string(packaged["provenance"], "failed packaged app.provenance")
        require_string(packaged["error"], "failed packaged app.error")
        if any(packaged[key] is not None for key in ("identity", "codeSignature", "content")):
            raise ValueError("failed packaged app cannot contain partial artifact evidence")
        return
    detailed_keys = {
        "status", "appBundle", "expectedAppBundle", "provenance",
        "verificationCheck", "observedAt", "identity", "codeSignature",
        "content",
    }
    if status == "identity_mismatch":
        require_exact_keys(packaged, detailed_keys | {"error"}, "mismatched packaged app")
        require_string(packaged["error"], "mismatched packaged app.error")
    elif status == "hashed":
        require_exact_keys(packaged, detailed_keys, "hashed packaged app")
    else:
        raise ValueError("artifacts.packagedApp has an unsupported status")
    require_string(packaged["appBundle"], "packaged app.appBundle")
    require_string(packaged["expectedAppBundle"], "packaged app.expectedAppBundle")
    require_string(packaged["provenance"], "packaged app.provenance")
    require_string(packaged["verificationCheck"], "packaged app.verificationCheck")
    require_datetime(packaged["observedAt"], "packaged app.observedAt")
    identity = require_exact_keys(
        packaged["identity"],
        {
            "bundleName", "displayName", "executableName", "bundleIdentifier",
            "expectedBundleName", "expectedExecutableName", "expectedBundleIdentifier",
            "marketingVersion", "buildNumber", "configuredMarketingVersion",
            "configuredBuildNumber", "versionMatchesConfiguration",
            "buildMatchesConfiguration", "sourceCommit", "sourceDirty",
        },
        "packaged app.identity",
    )
    for key in (
        "bundleName", "displayName", "executableName", "bundleIdentifier",
        "marketingVersion", "buildNumber", "configuredMarketingVersion",
        "configuredBuildNumber", "sourceCommit",
    ):
        require_string(identity[key], f"packaged app.identity.{key}", nullable=True)
    for key in ("expectedBundleName", "expectedExecutableName", "expectedBundleIdentifier"):
        require_string(identity[key], f"packaged app.identity.{key}")
    for key in ("versionMatchesConfiguration", "buildMatchesConfiguration"):
        if not isinstance(identity[key], bool):
            raise ValueError(f"packaged app.identity.{key} must be a boolean")
    if identity["sourceDirty"] is not None and not isinstance(identity["sourceDirty"], bool):
        raise ValueError("packaged app.identity.sourceDirty must be a boolean or null")
    validate_code_signature(packaged["codeSignature"])
    if status == "hashed":
        content = require_exact_keys(
            packaged["content"],
            {"algorithm", "treeSha256", "entryCount", "totalSizeBytes", "entries"},
            "packaged app.content",
        )
        if content["algorithm"] != "sha256" or not re.fullmatch(r"[0-9a-f]{64}", str(content["treeSha256"])):
            raise ValueError("packaged app.content must carry a SHA-256 tree digest")
        require_integer(content["entryCount"], "packaged app.content.entryCount", minimum=0)
        require_integer(content["totalSizeBytes"], "packaged app.content.totalSizeBytes", minimum=0)
        if not isinstance(content["entries"], list):
            raise ValueError("packaged app.content.entries must be an array")
        if content["entryCount"] != len(content["entries"]):
            raise ValueError("packaged app.content.entryCount must match entries")
        for entry in content["entries"]:
            if not isinstance(entry, dict) or entry.get("kind") not in {"file", "symlink"}:
                raise ValueError("packaged app.content.entries contain an unsupported entry")
            required = {"path", "kind", "sha256", "sizeBytes"}
            if entry["kind"] == "symlink":
                required.add("target")
            require_exact_keys(entry, required, "packaged app.content entry")
            require_string(entry["path"], "packaged app.content entry.path")
            if entry["kind"] == "symlink":
                require_string(entry["target"], "packaged app.content entry.target")
            if not re.fullmatch(r"[0-9a-f]{64}", str(entry["sha256"])):
                raise ValueError("packaged app.content entry.sha256 must be a SHA-256 digest")
            require_integer(entry["sizeBytes"], "packaged app.content entry.sizeBytes", minimum=0)


def validate_result_payload(payload: object) -> None:
    """Authoritatively validate every persisted partial or complete result."""
    result = require_exact_keys(
        payload,
        {
            "$schema", "schemaVersion", "runState", "startedAt", "generatedAt",
            "mode", "profile", "repository", "releaseIdentity", "execution",
            "summary", "blockers", "activeCheck", "verification", "artifacts", "checks",
        },
        "release gate result",
    )
    if result["$schema"] != "script/release_gate_result.schema.json" or result["schemaVersion"] != 2:
        raise ValueError("release gate result has an unsupported schema identity")
    run_state = require_string(result["runState"], "runState")
    if run_state not in {"partial", "complete"}:
        raise ValueError("runState must be partial or complete")
    started_at = require_datetime(result["startedAt"], "startedAt")
    generated_at = require_datetime(result["generatedAt"], "generatedAt")
    if generated_at < started_at:
        raise ValueError("generatedAt must not precede startedAt")
    if result["mode"] not in {"standard", "quick", "tooling", "selected", "strict"}:
        raise ValueError("mode is unsupported")
    if result["profile"] is not None and result["profile"] not in {"direct", "chrome", "all"}:
        raise ValueError("profile is unsupported")
    repository = require_exact_keys(result["repository"], {"available", "commit", "branch", "isDirty"}, "repository")
    if not isinstance(repository["available"], bool):
        raise ValueError("repository.available must be a boolean")
    for key in ("commit", "branch"):
        require_string(repository[key], f"repository.{key}", nullable=True)
    if repository["isDirty"] is not None and not isinstance(repository["isDirty"], bool):
        raise ValueError("repository.isDirty must be a boolean or null")
    release_identity = require_exact_keys(
        result["releaseIdentity"],
        {"marketingVersion", "buildNumber", "sourceCommit", "sourceDirty", "observedAt"},
        "releaseIdentity",
    )
    for key in ("marketingVersion", "buildNumber", "sourceCommit"):
        require_string(release_identity[key], f"releaseIdentity.{key}", nullable=True)
    if release_identity["sourceDirty"] is not None and not isinstance(release_identity["sourceDirty"], bool):
        raise ValueError("releaseIdentity.sourceDirty must be a boolean or null")
    require_datetime(release_identity["observedAt"], "releaseIdentity.observedAt")
    execution = require_exact_keys(result["execution"], {"toolchain", "ci"}, "execution")
    toolchain = require_exact_keys(
        execution["toolchain"],
        {"pythonVersion", "swiftVersion", "operatingSystem", "operatingSystemVersion", "architecture"},
        "execution.toolchain",
    )
    for key in toolchain:
        require_string(toolchain[key], f"execution.toolchain.{key}", nullable=True)
    ci = execution["ci"]
    if not isinstance(ci, dict) or ci.get("provider") not in {None, "github-actions"}:
        raise ValueError("execution.ci provider is unsupported")
    expected_ci_keys = {"provider"} if ci["provider"] is None else {
        "provider", "repository", "workflow", "job", "runID", "runAttempt", "ref", "sha",
    }
    require_exact_keys(ci, expected_ci_keys, "execution.ci")
    for key, value in ci.items():
        if key != "provider":
            require_string(value, f"execution.ci.{key}", nullable=True)
    summary = require_exact_keys(
        result["summary"],
        {
            "status", "expectedCheckCount", "completedCheckCount", "checkCount",
            "passedCount", "failedCount", "uncheckedChecklistCount", "blockerCount",
        },
        "summary",
    )
    for key in (
        "expectedCheckCount", "completedCheckCount", "checkCount", "passedCount",
        "failedCount", "uncheckedChecklistCount", "blockerCount",
    ):
        require_integer(summary[key], f"summary.{key}", minimum=0)
    checks = result["checks"]
    if not isinstance(checks, list):
        raise ValueError("checks must be an array")
    for check in checks:
        validate_check_result(check)
    if len({str(check["id"]) for check in checks}) != len(checks):
        raise ValueError("checks must not contain duplicate IDs")
    failures = [check for check in checks if check["status"] != "passed"]
    if (
        summary["completedCheckCount"] != len(checks)
        or summary["checkCount"] != len(checks)
        or summary["passedCount"] != len(checks) - len(failures)
        or summary["failedCount"] != len(failures)
        or summary["completedCheckCount"] > summary["expectedCheckCount"]
    ):
        raise ValueError("summary counts do not match checks")
    blockers = require_string_list(result["blockers"], "blockers")
    if len(set(blockers)) != len(blockers) or summary["blockerCount"] != len(blockers):
        raise ValueError("blockers must be unique and match summary.blockerCount")
    active = result["activeCheck"]
    if active is not None:
        active_check = require_exact_keys(active, {"id", "title", "timeoutSeconds"}, "activeCheck")
        require_string(active_check["id"], "activeCheck.id")
        require_string(active_check["title"], "activeCheck.title")
        require_integer(active_check["timeoutSeconds"], "activeCheck.timeoutSeconds", minimum=1)
    verification = require_exact_keys(result["verification"], {"packagedArtifact", "realAppLaunch"}, "verification")
    for key in verification:
        if verification[key] not in {"not_run", "passed", "failed", "timed_out"}:
            raise ValueError(f"verification.{key} is unsupported")
    validate_packaged_artifact(result["artifacts"], run_state)
    if run_state == "partial":
        if summary["status"] != "running" or summary["completedCheckCount"] >= summary["expectedCheckCount"] and active is not None:
            raise ValueError("a partial result must have a running summary and valid active check state")
    else:
        if summary["status"] not in {"passed", "failed"} or active is not None:
            raise ValueError("a complete result must be final and have no active check")
        if summary["completedCheckCount"] != summary["expectedCheckCount"]:
            raise ValueError("a complete result must include every expected check")


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".partial",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
        try:
            directory_descriptor = os.open(path.parent, os.O_RDONLY)
        except OSError:
            return
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary_path and temporary_path.exists():
            temporary_path.unlink()


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
    packaged_app = (
        packaged_artifact_metadata(results, strict_profile, repository, observed_at)
        if complete
        else {
            "status": "pending",
            "appBundle": None,
            "identity": None,
            "codeSignature": None,
            "content": None,
        }
    )
    all_blockers = list(dict.fromkeys(
        [*blockers, *packaged_artifact_blockers(packaged_app)]
    ))
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
                if failures or all_blockers
                else "passed"
            ),
            "expectedCheckCount": expected_check_count,
            "completedCheckCount": len(results),
            "checkCount": len(results),
            "passedCount": len(results) - len(failures),
            "failedCount": len(failures),
            "uncheckedChecklistCount": unchecked,
            "blockerCount": len(all_blockers),
        },
        "blockers": all_blockers,
        "activeCheck": active_check,
        "verification": {
            "packagedArtifact": verification_status(results, "ui-runtime"),
            "realAppLaunch": verification_status(results, "ui-launch-verification"),
        },
        "artifacts": {
            "packagedApp": packaged_app,
        },
        "checks": results,
    }
    validate_result_payload(payload)
    atomic_write_text(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
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
    diagnostics_directory = result_json.with_name(f"{result_json.stem}.diagnostics")
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
        result = run(check, default_timeout, diagnostics_directory)
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

    final_blockers = list(payload["blockers"])
    if args.quick or args.tooling or args.check:
        if final_blockers:
            print(f"release gate: {mode} mode has {len(final_blockers)} blocker(s):", file=sys.stderr)
            for blocker in final_blockers:
                print(f"  - {blocker}", file=sys.stderr)
            return 1
        print(f"release gate: {mode} checks passed ({len(checks)} checks)")
        return 0

    if final_blockers:
        display_mode = "strict mode" if args.strict else f"{strict_profile} profile" if strict_profile else "standard mode"
        label = "blocker(s)"
        print(f"release gate: {display_mode} has {len(final_blockers)} {label}:", file=sys.stderr)
        for blocker in final_blockers:
            print(f"  - {blocker}", file=sys.stderr)
        return 1
    if strict_profile:
        print(f"release gate: {strict_profile} profile passed ({len(results)} checks)")
        return 0
    print("release gate: automated checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
